{
  description = "Simple NixOS configuration";

  inputs = {
    # Use the same version of nixpkgs as the parent flake
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-23.11-small";

    mesa-panfork = {
      url = "gitlab:panfork/mesa/csf";
      flake = false;
    };

    linux-rockchip = {
      url = "github:armbian/linux-rockchip/rk-5.10-rkr5.1";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, mesa-panfork, linux-rockchip }: {
    nixosConfigurations.myConfig = nixpkgs.lib.nixosSystem {
      system = "aarch64-linux";
      modules = [
        ({ pkgs, ... }: {
          # Set the system configuration
          boot.loader.grub.enable = false;
          boot.loader.generic-extlinux-compatible.enable = true;

          boot.kernelPackages = pkgs.linuxPackagesFor (pkgs.callPackage ./board/kernel {
            src = linux-rockchip;
          });

          # most of required modules had been builtin
          boot.supportedFilesystems = lib.mkForce [ "vfat" "ext4" "btrfs" ];

          boot.kernelParams = [
            "console=ttyS2,1500000" # serial port for debugging
            "console=tty1" # should be HDMI
            "loglevel=4" # more verbose might help
          ];
          boot.initrd.includeDefaultModules = false; # no thanks, builtin modules should be enough

          hardware = {
            deviceTree = { name = "rockchip/rk3588s-orangepi-5b.dtb"; };

            opengl = {
              enable = true;
              package = lib.mkForce (
                (pkgs.mesa.override {
                  galliumDrivers = [ "panfrost" "swrast" ];
                  vulkanDrivers = [ "swrast" ];
                }).overrideAttrs (_: {
                  pname = "mesa-panfork";
                  version = "23.0.0-panfork";
                  src = mesa-panfork;
                })
              ).drivers;
            };

            firmware = [ (pkgs.callPackage ./board/firmware { }) ];

            pulseaudio.enable = true;
          };

          networking = {
            networkmanager.enable = true;
            wireless.enable = false;
            hostName = "miNix";
          };

          time.timeZone = "America/Los_Angeles";
          i18n.defaultLocale = "en_US.UTF-8";

          # Install Sublime Text 4
          environment.systemPackages = with pkgs; [
            sublime4

            git
            htop
            neovim
            neofetch

            # only wayland can utily GPU as of now
            wayland
            waybar
            swaylock
            swayidle
            foot
            wdisplays
            wofi
          ];

          # Create user "andy"
          users.users.andy = {
            isNormalUser = true;
            initialPassword = "password";
            extraGroups = [ "wheel" "networkmanager" ];
          };

          environment.loginShellInit = ''
            # https://wiki.archlinux.org/title/Sway
            if [ -z "$WAYLAND_DISPLAY" ] && [ "$XDG_VTNR" -eq 1 ]; then
              exec sway
            fi
          '';

          programs.sway = {
            enable = true;
            wrapperFeatures.gtk = true;
          };

          # Enable essential services
          services.openssh.enable = true;

          system.stateVersion = "23.05";
        })
      ];
    };
  };
}