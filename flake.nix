{
  description = "NixOS Installer AArch64";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-23.05-small";

    mesa-panfork = {
      url = "gitlab:panfork/mesa/csf";
      flake = false;
    };

    linux-rockchip = {
      url = "github:armbian/linux-rockchip/rk-5.10-rkr5.1";
      flake = false;
    };
  };

  outputs = inputs@{ nixpkgs, ... }:
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

        # u-boot for evb is not enable the sdmmc node, which cause issue as
        # b-boot cannot detect sdcard to boot from
        # the order of boot also need to swap, the eMMC mapped to mm0 (not same as Linux kernel)
        # will then tell u-boot to load images from eMMC first instead of sdcard
        # FIXME: this is strage cuz the order seem correct in Linux kernel
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
          mkdir $out
          cp u-boot-rockchip.bin $out
        '';
      };

      nixos-orangepi-5x = pkgs.stdenvNoCC.mkDerivation {
        pname = "nixos-orangepi-5x";
        version = "unstable";

        src = ./.;

        installPhase = ''
          tar czf $out *
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
                src = inputs.mesa-panfork;
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

          # only wayland can utily GPU as of now
          wayland
          waybar
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
      # to install NixOS on eMMC
      nixosConfigurations.opi5 = nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        modules = [
          (buildConfig { inherit pkgs; lib = nixpkgs.lib; })
          ({ pkgs, lib, ... }:
            {
              boot = {
                loader = { grub.enable = false; generic-extlinux-compatible.enable = true; };
                initrd.luks.devices."Encrypted".device = "/dev/disk/by-partlabel/Encrypted";
                initrd.availableKernelModules = lib.mkForce [ "dm_mod" "dm_crypt" "encrypted_keys" "nvme" ];
              };

              fileSystems."/" = { device = "none"; fsType = "tmpfs"; options = [ "mode=0755,size=8G" ]; };
              fileSystems."/boot" = { device = "/dev/disk/by-partlabel/Firmwares"; fsType = "vfat"; };
              fileSystems."/nix" = { device = "/dev/mapper/Encrypted"; fsType = "btrfs"; options = [ "subvol=nix,compress=zstd,noatime" ]; };
              fileSystems."/home/${user}" = { device = "/dev/mapper/Encrypted"; fsType = "btrfs"; options = [ "subvol=usr,compress=zstd,noatime" ]; };

              fileSystems."/tmp" = { device = "none"; fsType = "tmpfs"; options = [ "mode=0755,size=12G" ]; };

              networking = {
                hostName = "opi5";
                networkmanager.enable = true;
              };

              time.timeZone = "America/Los_Angeles";
              i18n.defaultLocale = "en_US.UTF-8";

              users.users.andy = {
                isNormalUser = true;
                initialPassword = "andy";
                extraGroups = [ "wheel" "networkmanager" "tty" "video" ];
                packages = with pkgs; [
                  neofetch
                  pavucontrol
                ];
              };

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
        ];
      };

      formatter.aarch64-linux = pkgs.nixpkgs-fmt;

      packages.aarch64-linux.default = nixosConfigurations.live.config.system.build.sdImage;
      packages.aarch64-linux.sdwriter = pkgs.writeScript "flash" ''
        echo "= flash to sdcard (/dev/mmcblk1) if presented, requires sudo as well."
        [ -e /dev/mmcblk1 ] && zstdcat result/sd-image/*.zst | \
              sudo dd of=/dev/mmcblk1 bs=8M status=progress
  [ -e /dev/mmcblk1 ] || echo "=  no sdcard found"
      '';
      apps.aarch64-linux.default = { type = "app"; program = "${packages.aarch64-linux.sdwriter}"; };
    };
}
