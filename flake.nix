{
  description = "An extremely small nix based OS (not nixos)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:

  let

    system = "x86_64-linux";
    pkgs   = import nixpkgs { inherit system; };

    bb  = pkgs.pkgsStatic.busybox;

    # Build a tiny rootfs from repo files + two symlinks in /bin
    rootfs = with pkgs; pkgs.runCommand "wnix-rootfs" { } ''
      set -eu
      mkdir -p $out/bin $out/tmp $out/etc/nix $out/etc/wnix $out/etc/ssl/certs
      #ln -s ${bb}/bin/busybox                       $out/bin/sh
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
      # pathsToLink = [ "/bin" ];
    };

  in {

    packages.${system}.default = pkgs.dockerTools.buildImage {
      name = "wnix";
      tag  = "latest";

      copyToRoot = [
        rootfs
        extra
      ];

      config = {
        Entrypoint = [ "/bin/sh" ];
        WorkingDir = "/";
        Env = [
          "PATH=/bin:/.nix-profile/bin"
          "NIX_CONF_DIR=/etc/nix"
          "NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
        ];
        Volumes = { "/nix" = {}; };
      };
    };
  };
}

