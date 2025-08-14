{ config, pkgs, ... }: {
  # This is not NixOS!
  # This is an extremely tiny OS with nix.

  boot.loader.grub.enable = false;
  boot.isContainer = true;

  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
  };

  environment.systemPackages = with pkgs; [
    bash
    vim
    nix
    coreutils
    nixos-rebuild
  ];

  fileSystems."/" = { device = "tmpfs"; fsType = "tmpfs"; options = [ "mode=755" ]; };

  system.stateVersion = "25.11";
}
