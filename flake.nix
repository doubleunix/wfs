{
  description = "An extremely small nix based OS (not nixos)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:

  let

    system = "x86_64-linux";
    pkgs   = import nixpkgs { inherit system; };
    lib    = nixpkgs.lib;

    bb  = pkgs.pkgsStatic.busybox;
    bash   = pkgs.bash;
    nix    = pkgs.nix;
    cacert = pkgs.cacert;

    # Build a tiny rootfs from repo files + two symlinks in /bin
    rootfs = pkgs.runCommand "wnix-rootfs" { } ''
      set -euo pipefail
      mkdir -p $out/bin $out/tmp $out/etc/nix $out/etc/wnix $out/etc/ssl/certs
      #ln -s ${bb}/bin/busybox                      $out/bin/sh
      ln -s ${bb}/bin/busybox                       $out/bin/ls
      ln -s ${bb}/bin/busybox                       $out/bin/cat
      ln -s ${bash}/bin/bash                        $out/bin/sh
      ln -s ${nix}/bin/nix                          $out/bin/nix
      cp -a ${./root/bin/wnix}                      $out/bin/wnix

      ln -s ${cacert}/etc/ssl/certs/ca-bundle.crt   $out/etc/ssl/certs/ca-bundle.crt
      cp -a ${./root/etc/os-release}                $out/etc/os-release
      cp -a ${./root/etc/nix/nix.conf}              $out/etc/nix/nix.conf
      cp -a ${./root/etc/wnix/flake.nix}            $out/flake.nix
      cp -a ${./root/etc/passwd}                    $out/etc/passwd
      cp -a ${./root/etc/group}                     $out/etc/group
    '';

    extra = pkgs.buildEnv {
      name = "extra";
      paths = with pkgs; [
      ];
    };

    # *** Pin nixpkgs in-image WITHOUT installing anything ***
    # This just drops a symlink in /etc/wnix/.pin -> /nix/store/...-source,
    # which causes dockerTools to include the nixpkgs store path in the image.
    pin-nixpkgs = pkgs.runCommand "pin-nixpkgs" { } ''
      set -euo pipefail
      mkdir -p $out/etc/wnix/.pin
      ln -s ${nixpkgs.outPath} $out/etc/wnix/.pin/nixpkgs
    '';

    nixpkgs-src = pkgs.runCommand "nixpkgs-src" {} ''
      set -euo pipefail
      mkdir -p $out/etc/wnix
      cp -a ${nixpkgs.outPath} $out/etc/wnix/nixpkgs
    '';

    # System registry: nixpkgs -> /etc/wnix/nixpkgs (NOT /nix/store)
    pinned-registry = pkgs.writeTextFile {
      name = "registry.json";
      destination = "/etc/nix/registry.json";
      text = builtins.toJSON {
        version = 2;
        flakes = [{
          from = { type = "indirect"; id = "nixpkgs"; };
          to   = { type = "path"; path = "/etc/wnix/nixpkgs"; };
          # If /etc/wnix/nixpkgs is NOT a flake, add:
          # to.flake = false;
        }];
      };
    };

    # ---------------------------
    # QEMU: kernel + initramfs
    # ---------------------------
    kernel = pkgs.linuxPackages_latest.kernel;

    initramfs = pkgs.runCommand "wnix-initramfs.cpio.gz"
      { buildInputs = with pkgs; [ cpio gzip ]; }
      ''
        set -euo pipefail
        mkdir -pv root/{bin,etc/{nix,wnix,ssl/certs},proc,sys,dev,run,tmp,root}
        chmod 1777 root/tmp

        # Put statically linked busybox in /bin
        cp -av ${bb}/bin/busybox root/bin/busybox
        ln -sv busybox           root/bin/sh
        ln -sv busybox           root/bin/mount
        ln -sv busybox           root/bin/mknod
        ln -sv busybox           root/bin/mkdir

        ln -s ${nix}/bin/nix     root/bin/nix
        ln -s ${cacert}/etc/ssl/certs/ca-bundle.crt \
                   root/etc/ssl/certs/ca-bundle.crt

        # Reuse your config/registry/nixpkgs from rootfs
        cp -a ${rootfs}/etc/nix/nix.conf                root/etc/nix/nix.conf
        #cp -a ${pinned-registry}/etc/nix/registry.json  root/etc/nix/registry.json
        #cp -a ${nixpkgs-src}/etc/wnix/nixpkgs           root/etc/wnix/nixpkgs

        cat > root/init <<"SH"
        #!/bin/sh
        set -euo pipefail
        mount -t proc proc /proc
        mount -t sysfs sysfs /sys
        mkdir -p /dev/pts /dev/shm
        mount -t devpts devpts /dev/pts
        mount -t tmpfs tmpfs /dev/shm
        # devices
        mknod -m 666 /dev/null      c 1 3
        mknod -m 666 /dev/zero      c 1 5
        mknod -m 666 /dev/tty       c 5 0
        mknod -m 666 /dev/random    c 1 8
        mknod -m 666 /dev/urandom   c 1 9
        echo "Wnix is alive!"
        exec /bin/sh
        SH
        chmod +x root/init

        (cd root; find . -print0 | cpio --null -ov --format=newc | gzip -9) > $out
      '';

    # ---------------------------
    # BIOS-bootable ISO (isolinux)
    # ---------------------------
    iso = pkgs.runCommand "wnix.iso"
      { buildInputs = with pkgs; [ xorriso syslinux ]; }
      ''
        set -eu
        mkdir -p iso/isolinux iso/boot iso/bin

        # isolinux (BIOS)
        cp ${pkgs.syslinux}/share/syslinux/isolinux.bin iso/isolinux/
        cp ${pkgs.syslinux}/share/syslinux/ldlinux.c32  iso/isolinux/
        cat > iso/isolinux/isolinux.cfg <<'CFG'
        DEFAULT wnix
        PROMPT 10
        TIMEOUT 20
        LABEL wnix
          KERNEL /boot/bzImage
          APPEND initrd=/boot/initramfs.cpio.gz console=ttyS0
        CFG

        # Kernel + initramfs
        cp ${kernel}/bzImage     iso/boot/bzImage
        cp ${initramfs}          iso/boot/initramfs.cpio.gz
        #cp -av ${bb}/bin/*       iso/bin

        # Create hybrid ISO (BIOS boot)
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

  in {

    packages.${system} = {

      docker = pkgs.dockerTools.buildImage {
        name = "wnix";
        tag  = "latest";
        copyToRoot = [
          rootfs
          extra
          pin-nixpkgs
          nixpkgs-src
          pinned-registry
        ];
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

      kernel    = kernel;
      initramfs = initramfs;
      iso       = iso;

    };

    # Convenience launchers
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

