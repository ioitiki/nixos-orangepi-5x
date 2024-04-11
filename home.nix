{ pkgs, lib, home-manager, ... }:

{
  home-manager.users.andy = { pkgs, ... }: {
    imports = [./zsh.nix];

    
  };
}
