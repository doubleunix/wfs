{
  description = "Tiny LFS-style OS (one shared root for Docker + ISO/QEMU)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
  let
    system = "x86_64-linux";
    pkgs   = import nixpkgs { inherit system; };
    lib    = nixpkgs.lib;

    bb     = pkgs.pkgsStatic.busybox;     # static, tiny
    nix    = pkgs.nix;                    # dynamic, we’ll include its closure
    cacert = pkgs.cacert;
    kernel = pkgs.linuxPackages_latest.kernel;

    # Full runtime closure for nix so it runs in ISO/initramfs (offline)
    nixClosure = pkgs.closureInfo { rootPaths = [ nix ]; };

    # -------- minimal root at / (what Docker's copyToRoot should see) --------
    rootfs = pkgs.runCommand "wnix-rootfs" { } ''
      set -euo pipefail
      mkdir -p $out/{bin,etc/nix,etc/ssl/certs,tmp}
      chmod 1777 $out/tmp

      # Shell + a couple of applets (we'll "install" the rest at boot)
      cp -a ${bb}/bin/busybox  $out/bin/busybox
      ln -s busybox            $out/bin/sh
      ln -s busybox            $out/bin/ls
      ln -s busybox            $out/bin/cat

      # nix CLI in PATH (libs come from nixStore below)
      ln -s ${nix}/bin/nix     $out/bin/nix

      # certs + tiny config
      ln -s ${cacert}/etc/ssl/certs/ca-bundle.crt $out/etc/ssl/certs/ca-bundle.crt
      cat > $out/etc/os-release <<'EOF'
      ID=wnix
      NAME="WNIX"
      EOF
      echo 'root:x:0:0:Root:/root:/bin/sh' > $out/etc/passwd
      echo 'root:x:0:'                     > $out/etc/group
      cat > $out/etc/nix/nix.conf <<'EOF'
      experimental-features = nix-command flakes
      accept-flake-config = true
      build-users-group =
      ssl-cert-file = /etc/ssl/certs/ca-bundle.crt
      substituters = https://cache.nixos.org
      trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=
      EOF
    '';

    # Bring /nix/store for nix (and friends) into the root (works offline)
    nixStore = pkgs.runCommand "wnix-nixstore" { } ''
      set -euo pipefail
      mkdir -p $out/nix/store
      while IFS= read -r p; do cp -a "$p" $out/nix/store/; done < ${nixClosure}/store-paths
    '';

    # Single source of truth for all targets
    systemRoot = pkgs.symlinkJoin {
      name  = "wnix-system-root";
      paths = [ rootfs nixStore ];
    };

    # -------- tiny, target-agnostic /init (no ISO-specific logic here) -------
    stage1Init = pkgs.writeShellScript "init" ''
      set -euo pipefail
      export PATH=/bin
      # Ensure mount points exist *before* mounting (fixes ENOENT)
      mkdir -p /proc /sys /dev /dev/pts /dev/shm /run
      # Make BusyBox applets visible (ls, mount, mknod, etc.)
      /bin/busybox --install -s /bin || true

      mount -t proc     proc     /proc
      mount -t sysfs    sysfs    /sys
      mount -t devtmpfs devtmpfs /dev || true
      mount -t devpts   devpts   /dev/pts || true
      mount -t tmpfs    tmpfs    /dev/shm || true
      mount -t tmpfs    tmpfs    /run || true

      echo "Wnix is alive!"
      exec /bin/sh
    '';

    # -------- initramfs: same root as Docker, but with symlinks resolved -----
    initramfs = pkgs.runCommand "wnix-initramfs.cpio.gz"
      { buildInputs = with pkgs; [ cpio gzip rsync ]; }
      ''
        set -euo pipefail
        mkdir -p root
        # Deref symlinks from systemRoot so binaries are *real* files in RAM.
        rsync -a --copy-links --chmod=Du+w ${systemRoot}/ root/
        install -Dm0755 ${stage1Init} root/init
        # sanity
        test -x root/bin/sh
        test -x root/bin/busybox
        test -e root/nix/store
        (cd root; find . -print0 | cpio --null -ov --format=newc | gzip -9) > $out
      '';

    # -------- BIOS-bootable ISO (boots kernel + the initramfs above) ---------
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
        TIMEOUT 20
        LABEL wnix
          KERNEL /boot/bzImage
          APPEND initrd=/boot/initramfs.cpio.gz console=ttyS0
        CFG
        cp ${kernel}/bzImage            iso/boot/bzImage
        cp ${initramfs}                 iso/boot/initramfs.cpio.gz
        xorriso -as mkisofs \
          -iso-level 3 -full-iso9660-filenames \
          -volid WNIX \
          -eltorito-boot isolinux/isolinux.bin \
          -eltorito-catalog isolinux/boot.cat \
          -no-emul-boot -boot-load-size 4 -boot-info-table \
          -isohybrid-mbr ${pkgs.syslinux}/share/syslinux/isohdpfx.bin \
          -output $out iso
      '';
  in
  {
    packages.${system} = {
      # Docker: same root; your -v nix:/nix still overrides /nix if you want
      docker = pkgs.dockerTools.buildImage {
        name = "wnix";
        tag  = "latest";
        copyToRoot = [ systemRoot ];  # add one thing, not many
        config = {
          Entrypoint = [ "/bin/sh" ]; # BusyBox sh
          WorkingDir = "/";
          Env = [
            "HOME=/root"
            "PATH=/bin:/root/.nix-profile/bin"
            "NIX_CONF_DIR=/etc/nix"
            "NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
          ];
        };
      };

      root      = systemRoot;
      kernel    = kernel;
      initramfs = initramfs;
      iso       = iso;
    };

    apps.${system} = {
      initrd = {
        type = "app";
        program = lib.getExe (pkgs.writeShellApplication {
          name = "run-qemu-initrd";
          text = ''
            exec ${pkgs.qemu_kvm}/bin/qemu-system-x86_64 \
              -m 1024 -nographic \
              -kernel ${kernel}/bzImage \
              -initrd ${initramfs} \
              -append "console=ttyS0"
          '';
        });
      };
      qemu = {
        type = "app";
        program = lib.getExe (pkgs.writeShellApplication {
          name = "run-qemu-iso";
          text = ''
            exec ${pkgs.qemu_kvm}/bin/qemu-system-x86_64 \
              -m 1024 -nographic \
              -cdrom ${iso} \
              -boot d
          '';
        });
      };
    };
  };
}

