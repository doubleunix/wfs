{
  description = "Tiny LFS-style OS (shared root for Docker + ISO/QEMU)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
  let
    system = "x86_64-linux";
    pkgs   = import nixpkgs { inherit system; };
    lib    = nixpkgs.lib;

    busybox = pkgs.pkgsStatic.busybox;
    bash    = pkgs.pkgsStatic.bash;
    nix     = pkgs.nix;
    cacert  = pkgs.cacert;
    kernel  = pkgs.linuxPackages_latest.kernel;

    nixClosure = pkgs.closureInfo { rootPaths = [ nix ]; };

    # ---------------------- ROOTFS (assembled via mkDerivation) ----------------------
    rootfs = pkgs.stdenvNoCC.mkDerivation {
      name = "wnix-rootfs";
      dontUnpack = true;
      dontFixup = true;
      dontPatchShebangs = true;
      nativeBuildInputs = [ ];
      installPhase = ''
        set -euo pipefail
        mkdir -p $out/{bin,etc/nix,etc/ssl/certs,tmp,nix/store}
        chmod 1777 $out/tmp

        ln -s ${nix}/bin/nix $out/bin/nix
        ln -s ${cacert}/etc/ssl/certs/ca-bundle.crt $out/etc/ssl/certs/ca-bundle.crt

        cp -v ${busybox}/bin/busybox $out/bin/busybox
        ln -sf busybox $out/bin/sh
        $out/bin/busybox --install -s $out/bin

        cat > $out/etc/os-release <<'EOF'
        ID=wnix
        NAME="WNIX"
        EOF

        cat > $out/etc/passwd << 'EOF'
        root:x:0:0:Root:/root:/bin/sh
        EOF

        cat > $out/etc/group << 'EOF'
        root:x:0:
        EOF

        cat > $out/etc/nix/nix.conf <<'EOF'
        experimental-features = nix-command flakes
        accept-flake-config = true
        build-users-group =
        ssl-cert-file = /etc/ssl/certs/ca-bundle.crt
        substituters = https://cache.nixos.org
        trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=
        EOF

        cat > $out/init <<'EOF'
        #!/bin/sh
        export PATH=/bin
        export HOME=/root

        mknod -m 666 /dev/null    c 1 3
        mknod -m 622 /dev/console c 5 1
        mknod -m 666 /dev/tty     c 5 0

        mkdir -p /proc /sys /dev /run /root
        mount -t proc     proc     /proc
        mount -t sysfs    sysfs    /sys
        mount -t tmpfs    tmpfs    /run
        mount -t devtmpfs devtmpfs /dev

        mkdir -p /dev/{shm,pts}
        mount -t devpts   devpts   /dev/pts
        mount -t tmpfs    tmpfs    /dev/shm

        echo "Wnix is alive!"
        exec /bin/sh
        EOF
        chmod +x $out/init
      '';
    };

    # ------------------------- INITRAMFS (cpio.gz of rootfs) -------------------------
    initramfs = pkgs.stdenvNoCC.mkDerivation {
      name = "wnix-initramfs.cpio.gz";
      dontUnpack = true;
      dontFixup = true;
      dontPatchShebangs = true;
      nativeBuildInputs = with pkgs; [ cpio rsync coreutils ];
      installPhase = ''
        set -euo pipefail
        mkdir root
        rsync -aHL --numeric-ids ${rootfs}/ root/
        chmod -R u+w root/
        test -x root/init
        test -x root/bin/sh
        test -x root/bin/busybox
        test -e root/nix/store
        (cd root; find . -print0 | cpio --null -ov --format=newc) > $out
      '';
    };

    # ------------------------------ BIOS/ISO image -----------------------------------
    iso = pkgs.stdenvNoCC.mkDerivation {
      name = "wnix.iso";
      dontUnpack = true;
      dontFixup = true;
      dontPatchShebangs = true;
      nativeBuildInputs = with pkgs; [ xorriso syslinux ];
      installPhase = ''
        set -euo pipefail
        mkdir -p iso/isolinux iso/boot
        cp ${pkgs.syslinux}/share/syslinux/isolinux.bin iso/isolinux/
        cp ${pkgs.syslinux}/share/syslinux/ldlinux.c32  iso/isolinux/
        cat > iso/isolinux/isolinux.cfg <<'CFG'
        DEFAULT wnix
        PROMPT 0
        TIMEOUT 20

        LABEL wnix
          LINUX /boot/bzImage
          INITRD /boot/initramfs.cpio
          APPEND console=ttyS0 rdinit=/init
        CFG
        cp ${kernel}/bzImage  iso/boot/bzImage
        cp ${initramfs}       iso/boot/initramfs.cpio
        xorriso -as mkisofs \
          -iso-level 3 -full-iso9660-filenames \
          -volid WNIX \
          -eltorito-boot isolinux/isolinux.bin \
          -eltorito-catalog isolinux/boot.cat \
          -no-emul-boot -boot-load-size 4 -boot-info-table \
          -isohybrid-mbr ${pkgs.syslinux}/share/syslinux/isohdpfx.bin \
          -output $out iso
      '';
    };

  in {
    packages.${system} = {
      root      = rootfs;
      kernel    = kernel;
      initramfs = initramfs;
      iso       = iso;

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
              -append "console=ttyS0 rdinit=/init" \
              -nic user,model=virtio-net-pci
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
              -boot d \
              -nic user,model=virtio-net-pci
          '';
        });
      };
    };
  };
}

