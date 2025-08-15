{
  description = "Tiny LFS-style OS with a single shared root (Docker + QEMU ISO)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
  let
    system = "x86_64-linux";
    pkgs   = import nixpkgs { inherit system; };
    lib    = nixpkgs.lib;

    # Core payload we want at / in every target
    bb     = pkgs.pkgsStatic.busybox;
    bash   = pkgs.pkgsStatic.bash;
    #nix    = pkgs.pkgsStatic.nix;  # Try this later! It was compiling and looked promising.
    nix    = pkgs.nix;
    cacert = pkgs.cacert;

    # --- Minimal root filesystem (copyToRoot payload) ---
    rootfs = pkgs.runCommand "wnix-rootfs" { } ''
      set -euo pipefail
      mkdir -p $out/bin $out/etc/nix $out/etc/ssl/certs $out/etc/wnix $out/tmp
      chmod 1777 $out/tmp

      # BusyBox + /bin/sh, nix CLI
      cp -a ${bb}/bin/busybox   $out/bin/busybox
      cp -a ${bash}/bin/bash    $out/bin/sh
      cp -a ${nix}/bin/nix      $out/bin/nix
      ln -s busybox             $out/bin/ls
      ln -s busybox             $out/bin/cat

      # Certs via store path
      ln -s ${cacert}/etc/ssl/certs/ca-bundle.crt $out/etc/ssl/certs/ca-bundle.crt

      # Make etc

      cat > $out/etc/passwd << 'EOF'
      root:x:0:0:Root:/root:/bin/sh
      EOF

      cat > $out/etc/group << 'EOF'
      root:x:0:
      EOF

      cat > $out/etc/os-release << 'EOF'
      id=wnix
      EOF

      cat > $out/etc/nix/nix.conf << 'EOF'
      experimental-features = nix-command flakes
      accept-flake-config = true
      build-users-group =
      #sandbox = false
      # We'll provide this FHS path via a symlink in the rootfs build step:
      ssl-cert-file = /etc/ssl/certs/ca-bundle.crt

      # Substituter & key:
      substituters = https://cache.nixos.org
      trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=
      EOF

      cat > $out/etc/profile << EOF
      HOME=/root
      PATH=/bin:/root/.nix-profile/bin
      NIX_CONF_DIR=/etc/nix
      NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt
      EOF

      install -Dm0755 ${stage1Init} root/init

      install -Dm0755 ${./root/bin/wnix} $out/bin/wnix

    '';

    # Single tree to reuse everywhere (cheap union; easy to extend later)
    systemRoot = pkgs.symlinkJoin {
      name  = "wnix-system-root";
      paths = [ rootfs ];
    };

    # shared stage-1 /init
    stage1Init = pkgs.writeShellScript "init" ''
      set -euo pipefail
      mount -t proc     proc     /proc
      mount -t sysfs    sysfs    /sys
      mount -t devtmpfs devtmpfs /dev || true
      mkdir -p /dev/pts /dev/shm /run
      mount -t devpts   devpts   /dev/pts || true
      mount -t tmpfs    tmpfs    /dev/shm || true
      mount -t tmpfs    tmpfs    /run || true
      echo "Wnix is alive!"
      exec /bin/sh
    '';

    # Kernel
    kernel = pkgs.linuxPackages_latest.kernel;

    # Initramfs that contains EXACTLY the same / as Docker's copyToRoot

    initramfs = pkgs.runCommand "wnix-initramfs.cpio.gz"
      { buildInputs = with pkgs; [ cpio gzip rsync ]; }  # <-- add rsync
      ''
        #set -euo pipefail
        mkdir -p root/

        # Effect of copyToRoot for initramfs:
        #rsync -av --copy-links --hard-links --chmod=Du+w ${rootfs}/ root/
        rsync -Pav --delete ${rootfs}/ root/

        (cd root; find . -print0 | cpio --null -ov --format=newc | gzip -9) > $out
      '';

    # BIOS-bootable ISO (isolinux) that boots the kernel+initramfs above
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
        cp ${kernel}/bzImage iso/boot/bzImage
        cp ${initramfs}     iso/boot/initramfs.cpio.gz
        xorriso -as mkisofs \
          -iso-level 3 -full-iso9660-filenames \
          -volid WNIX \
          -eltorito-boot isolinux/isolinux.bin \
          -eltorito-catalog isolinux/boot.cat \
          -no-emul-boot -boot-load-size 4 -boot-info-table \
          -isohybrid-mbr ${pkgs.syslinux}/share/syslinux/isohdpfx.bin \
          -output $out \
          iso
      '';
  in
  {
    packages.${system} = {
      # Docker image: identical root at /
      docker = pkgs.dockerTools.buildImage {
        name = "wnix";
        tag  = "latest";
        copyToRoot = [ rootfs ];
        config = {
          Entrypoint = [ "/bin/sh" ];
          WorkingDir = "/";
          Env = [
            "HOME=/root"
            "PATH=/bin:/root/.nix-profile/bin"
            "NIX_CONF_DIR=/etc/nix"
            "NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
          ];
        };
      };

      root      = rootfs;      # handy for tar/partition installs
      kernel    = kernel;
      initramfs = initramfs;   # contains systemRoot at /
      iso       = iso;         # boots kernel+initramfs
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

