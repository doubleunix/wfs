{
  description = "Tiny LFS-style OS (one shared root for Docker + ISO/QEMU)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:

  let
    system = "x86_64-linux";
    pkgs   = import nixpkgs { inherit system; };

    # core
    bb      = pkgs.pkgsStatic.busybox;
    nix     = pkgs.nix;
    systemd = pkgs.systemd;            # provides systemd, networkd, resolved
    iwd     = pkgs.iwd;                # Wi-Fi daemon + iwctl
    cacert  = pkgs.cacert;
    kernel  = pkgs.linuxPackages_latest.kernel;

    # include systemd, iwd, nix in the closure so ISO/initramfs are self-contained
    runtimeClosure = pkgs.closureInfo { rootPaths = [ systemd iwd nix ]; };

    # --- tiny stage-1: mount basics + cgroup2, then jump to systemd PID1 ---
    stage1Init = pkgs.writeShellScript "init" ''
      #!/bin/sh
      set -eu
      mount -t proc     proc /proc
      mount -t sysfs    sys  /sys
      mount -t devtmpfs dev  /dev || true
      mkdir -p /run /dev/pts /dev/shm /sys/fs/cgroup
      mount -t devpts   devpts /dev/pts || true
      mount -t tmpfs    tmpfs /dev/shm || true
      # systemd (PID1) needs unified cgroup v2 here:
      mount -t cgroup2  none /sys/fs/cgroup || true
      exec /lib/systemd/systemd
    '';

    # --- root filesystem shared by Docker/ISO/partition ---
    rootfs = pkgs.runCommand "wnix-rootfs" { } ''
      set -euo pipefail
      mkdir -p $out/{bin,sbin,lib,usr,run,etc/{systemd/network,iwd,ssl/certs},var,root}
      chmod 1777 $out/run

      # minimal userland: busybox for tools; nix CLI; systemd & iwd from store (rsync will deref)
      cp -a ${bb}/bin/busybox $out/bin/busybox
      ln -s busybox $out/bin/sh; ln -s busybox $out/bin/ls; ln -s busybox $out/bin/cat
      ln -s ${nix}/bin/nix     $out/bin/nix
      ln -s ${iwd}/bin/iwctl   $out/bin/iwctl

      # make systemd available in-place (rsync --copy-links later will materialize files)
      ln -s ${systemd}/lib/systemd $out/lib/systemd

      # certificates & nix.conf
      mkdir -p $out/etc/nix
      ln -s ${cacert}/etc/ssl/certs/ca-bundle.crt $out/etc/ssl/certs/ca-bundle.crt
      cat > $out/etc/nix/nix.conf <<'EOF'
      experimental-features = nix-command flakes
      accept-flake-config = true
      build-users-group =
      ssl-cert-file = /etc/ssl/certs/ca-bundle.crt
      substituters = https://cache.nixos.org
      trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=
      EOF

      # ---------------- systemd networking (wifi via iwd + DHCP via networkd) ----------------
      # Let networkd DHCP any WLAN interface
      cat > $out/etc/systemd/network/25-wlan.network <<'EOF'
      [Match]
      Type=wlan

      [Network]
      DHCP=yes
      EOF
      # iwd: leave IP config to networkd (iwctl for connecting)
      cat > $out/etc/iwd/main.conf <<'EOF'
      [General]
      EnableNetworkConfiguration=false
      EOF
      # resolved stub resolver
      mkdir -p $out/etc
      cp -v /run/systemd/resolve/stub-resolv.conf $out/etc/resolv.conf

      # enable services (like `systemctl enable ...`)
      mkdir -p $out/etc/systemd/system/multi-user.target.wants
      cp -v /lib/systemd/system/systemd-networkd.service \
            $out/etc/systemd/system/multi-user.target.wants/systemd-networkd.service
      cp -v /lib/systemd/system/systemd-resolved.service \
            $out/etc/systemd/system/multi-user.target.wants/systemd-resolved.service
      cp -v ${iwd}/lib/systemd/system/iwd.service \
            $out/etc/systemd/system/multi-user.target.wants/iwd.service

      # required for systemd on first boot
      : > $out/etc/machine-id

      # os-release (optional)
      cat > $out/etc/os-release <<'EOF'
      ID=wnix
      NAME="WNIX"
      PRETTY_NAME="WNIX (systemd+iwd)"
      EOF
    '';

    # put /nix/store payload for systemd+iwd+nix into the image
    storePayload = pkgs.runCommand "store" {} ''
      set -euo pipefail
      mkdir -p $out/nix/store
      while IFS= read -r p; do cp -a "$p" $out/nix/store/; done < ${runtimeClosure}/store-paths
    '';

    systemRoot = pkgs.symlinkJoin { name = "wnix-system-root"; paths = [ rootfs storePayload ]; };

    # initramfs: same root as disk/ISO/docker, then add /init that execs systemd
    initramfs = pkgs.runCommand "wnix-initramfs.cpio.gz"
      { buildInputs = with pkgs; [ cpio gzip rsync ]; }
      ''
        set -euo pipefail
        mkdir -p root
        rsync -a --copy-links --chmod=Du+w ${systemRoot}/ root/
        install -Dm0755 ${stage1Init} root/init
        (cd root; find . -print0 | cpio --null -ov --format=newc | gzip -9) > $out
      '';

    iso = pkgs.runCommand "wnix.iso"
      { buildInputs = with pkgs; [ xorriso syslinux ]; }
      ''
        set -euo pipefail
        mkdir -p iso/isolinux iso/boot
        cp ${pkgs.syslinux}/share/syslinux/isolinux.bin iso/isolinux/
        cp ${pkgs.syslinux}/share/syslinux/ldlinux.c32  iso/isolinux/
        cat > iso/isolinux/isolinux.cfg <<'CFG'
        DEFAULT wnix
        PROMPT 0
        TIMEOUT 10
        LABEL wnix
          KERNEL /boot/bzImage
          APPEND initrd=/boot/initramfs.cpio.gz console=ttyS0
        CFG
        cp ${kernel}/bzImage iso/boot/bzImage
        cp ${initramfs}     iso/boot/initramfs.cpio.gz
        xorriso -as mkisofs \
          -iso-level 3 -full-iso9660-filenames \
          -volid WNIX \
          -eltorito-boot isolinux/isolinux.bin \
          -eltorito-catalog isolinux/boot.cat \
          -no-emul-boot -boot-load-size 4 -boot-info-table \
          -isohybrid-mbr ${pkgs.syslinux}/share/syslinux/isohdpfx.bin \
          -output $out iso
      '';
  in {
    packages.${system} = {
      docker = pkgs.dockerTools.buildImage {
        name = "wnix"; tag = "latest";
        copyToRoot = [ systemRoot ];
        config = {
          Entrypoint = [ "/bin/sh" ];  # dev shell; systemd-in-docker is not needed
          Env = [
            "HOME=/root" "PATH=/bin:/usr/bin:/root/.nix-profile/bin"
            "NIX_CONF_DIR=/etc/nix" "NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
          ];
        };
      };
      root      = systemRoot;
      kernel    = kernel;
      initramfs = initramfs;
      iso       = iso;
    };

    apps.${system} = {
      qemu = {
        type = "app";
        program = pkgs.lib.getExe (pkgs.writeShellApplication {
          name = "run-qemu-iso";
          text = ''
            exec ${pkgs.qemu_kvm}/bin/qemu-system-x86_64 \
              -m 2048 -nographic \
              -cdrom ${iso} \
              -nic user,model=e1000 \
              -boot d
          '';
        });
      };
    };
  };
}
