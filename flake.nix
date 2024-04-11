{
  description = "NixOS Installer AArch64";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-23.05-small";

    # mesa-panfork = {
    #   url = "gitlab:panfork/mesa/csf";
    #   flake = false;
    # };

    home-manager = {
      url = "github:nix-community/home-manager/release-23.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    linux-rockchip = {
      url = "github:armbian/linux-rockchip/rk-5.10-rkr5.1";
      flake = false;
    };
  };

  outputs = inputs@{ nixpkgs, home-manager, ... }:
    let
      pkgs = import nixpkgs { system = "aarch64-linux"; };
      rkbin = pkgs.stdenvNoCC.mkDerivation {
        pname = "rkbin";
        version = "unstable-b4558da";

        src = pkgs.fetchFromGitHub {
          owner = "rockchip-linux";
          repo = "rkbin";
          rev = "b4558da0860ca48bf1a571dd33ccba580b9abe23";
          sha256 = "sha256-KUZQaQ+IZ0OynawlYGW99QGAOmOrGt2CZidI3NTxFw8=";
        };

        # we just need TPL and BL31 but it doesn't hurt,
        # follow single point of change to make life easier
        installPhase = ''
          mkdir $out && cp bin/rk35/rk3588* $out/
        '';
      };

      u-boot = pkgs.stdenv.mkDerivation rec {
        pname = "u-boot";
        version = "v2023.07.02";

        src = pkgs.fetchFromGitHub {
          owner = "u-boot";
          repo = "u-boot";
          rev = "${version}";
          sha256 = "sha256-HPBjm/rIkfTCyAKCFvCqoK7oNN9e9rV9l32qLmI/qz4=";
        };

        patches = [ ./patches/u-boot/0001-sdmmc-enable.patch ];

        nativeBuildInputs = with pkgs; [
          (python3.withPackages (p: with p; [
            setuptools
            pyelftools
          ]))
          swig
          ncurses
          gnumake
          bison
          flex
          openssl
          bc
        ] ++ [ rkbin ];

        configurePhase = ''
          make ARCH=arm evb-rk3588_defconfig
        '';

        buildPhase = ''
          patchShebangs tools scripts
          make -j$(nproc) \
            ROCKCHIP_TPL=${rkbin}/rk3588_ddr_lp4_2112MHz_lp5_2736MHz_v1.12.bin \
            BL31=${rkbin}/rk3588_bl31_v1.40.elf
        '';

        installPhase = ''
          mkdir -p /mnt/nix/boot
          cp u-boot-rockchip.bin /mnt/nix/boot
        '';
      };

      buildConfig = { pkgs, lib, ... }: {
        boot.kernelPackages = pkgs.linuxPackagesFor (pkgs.callPackage ./board/kernel {
          src = inputs.linux-rockchip;
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
                src = pkgs.fetchFromGitLab {
                  owner = "panfork";
                  repo = "mesa";
                  rev = "120202c675749c5ef81ae4c8cdc30019b4de08f4"; # branch: csf
                  hash = "sha256-4eZHMiYS+sRDHNBtLZTA8ELZnLns7yT3USU5YQswxQ0=";
                };
              })
            ).drivers;
          };

          firmware = [ (pkgs.callPackage ./board/firmware { }) ];

          pulseaudio.enable = true;
        };

        networking = {
          networkmanager.enable = true;
          wireless.enable = false;
        };

        environment.systemPackages = with pkgs; [
          git
          htop
          neovim
          neofetch
          direnv

          # only wayland can utily GPU as of now
          wayland
          waybar
          wev
          swaylock
          swayidle
          foot
          wdisplays
          wofi
        ];

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

        services.openssh.enable = true;

        system.stateVersion = "23.05";
      };
    in
    rec
    {
      # to install NixOS on nvme
      nixosConfigurations.opi5 = nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        modules = [
          (buildConfig { inherit pkgs; lib = nixpkgs.lib; })
          ({ pkgs, lib, ... }:
            let
              bunOverlay = import /home/andy/nixos-orangepi-5x/bun-overlay.nix;
            in
            {
              boot = {
                loader = { grub.enable = false; generic-extlinux-compatible.enable = true; };
                initrd.luks.devices."Encrypted".device = "/dev/disk/by-partlabel/Encrypted";
                initrd.availableKernelModules = lib.mkForce [ "dm_mod" "dm_crypt" "encrypted_keys" "nvme" ];
              };

              fileSystems."/" = { device = "none"; fsType = "tmpfs"; options = [ "mode=0755,size=8G" ]; };
              fileSystems."/boot" = { device = "/dev/disk/by-partlabel/Firmwares"; fsType = "vfat"; };
              fileSystems."/nix" = { device = "/dev/mapper/Encrypted"; fsType = "btrfs"; options = [ "subvol=nix,compress=zstd,noatime" ]; };
              fileSystems."/home/andy" = { device = "/dev/mapper/Encrypted"; fsType = "btrfs"; options = [ "subvol=usr,compress=zstd,noatime" ]; };

              fileSystems."/tmp" = { device = "none"; fsType = "tmpfs"; options = [ "mode=0755,size=12G" ]; };

              networking = {
                hostName = "opi5";
                networkmanager.enable = true;
              };

              time.timeZone = "America/Los_Angeles";
              i18n.defaultLocale = "en_US.UTF-8";

              nixpkgs.overlays = [ bunOverlay ];

              nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [
                "vscode"
                # "slack"
                # "morgen"
                # "ngrok"
                # "android-studio-stable"
                # "sublime-merge"
                # "google-chrome"
                "sublimetext4"
              ];

              nixpkgs.config.permittedInsecurePackages = [
                "electron-25.9.0"
                "electron-24.8.6"
                "openssl-1.1.1w"
              ];

              users.users.andy = {
                isNormalUser = true;
                initialPassword = "andy";
                extraGroups = [ "wheel" "networkmanager" "tty" "video" ];
                packages = with pkgs; [
                  vscode
                  sublime4
                  chromium
                  neofetch
                  pavucontrol
                  # slack
                  gammu
                  nodejs_18
                  yarn
                  bun
                ];
              };

              programs.zsh.enable = true;
              users.defaultUserShell = pkgs.zsh;
              environment.shells = with pkgs; [ zsh ];

              nix = {
                settings = {
                  auto-optimise-store = true;
                  experimental-features = [ "nix-command" "flakes" ];
                };

                gc = {
                  automatic = true;
                  dates = "weekly";
                  options = "--delete-older-than 30d";
                };

                # Free up to 1GiB whenever there is less than 100MiB left.
                extraOptions = ''
                  min-free = ${toString (100 * 1024 * 1024)}
                  max-free = ${toString (1024 * 1024 * 1024)}
                '';
              };
            })

            home-manager.nixosModules.home-manager
            {
              home-manager.users.andy = { pkgs, ... }: {
                home.username = "andy";
                home.homeDirectory = "/home/andy";
                home.packages = with pkgs; [
                  alacritty

                  roboto
                  roboto-mono
                  nerdfonts

                  ftop
                ];

                programs.zsh = {
                  enable = true;
                  enableAutosuggestions = true;
                  enableSyntaxHighlighting = true;

                  shellAliases = {
                    # zsh
                    rezsh = "source ~/.zshrc";
                    zshrc = "sublime ~/.zshrc";
                    # sublime
                    code = "sublime";
                    s = "sublime";
                    ".ssh" = "sublime ~/.ssh";
                    verified-fans-graphql = "sublime ~/verified-fans/verified-fans-graphql";
                    verified-fans-react = "sublime ~/verified-fans/verified-fans-react";
                    # nixos
                    clean = "nix-collect-garbage";
                    config = "";
                    update = "sudo nixos-rebuild switch --flake .#opi5 --impure";
                    # git
                    icm = "git add -A && git commit -m 'ic' && git push origin main";
                    gcm = "git commit -m";
                    sgit = "sudo git";
                    # yarn
                    yd = "yarn deploy";
                    ydd = "yarn deploy round-five";
                    ydp = "yarn deploy release";
                    # bun
                    b = "bun";
                    bi = "bun install";
                    bd = "bun run deploy";
                    bunx = "bun x";
                    buni = "bun run ./index.ts";
                    bun-update = "sudo bash ~/.config/bun/update.sh";

                    ".." = "cd ..";
                    "myip" = "curl -4 icanhazip.com";
                  };

                  oh-my-zsh = {
                    enable = true;
                    custom = "$HOME/.config/oh-my-zsh/custom";
                    plugins = [
                      "git"
                      "per-directory-history"
                      "kubectl"
                      "helm"
                      "yarn"
                    ];
                    theme = "miRobbyRussle";
                  };
                };

                home.stateVersion = "23.05";

                programs.home-manager.enable = true;
              };
            }
        ];
      };

      packages.aarch64-linux.opi5 = nixosConfigurations.opi5.config.system.build.toplevel;
      # packages.u-boot = u-boot;
    };
}
