# vim: tabstop=2 expandtab autoindent list
{
  description = "NixOS Installer AArch64";

  inputs = rec {
    # the rest, we can start using newer version, they are on nix cache already
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-23.05-small";

    home-manager = {
      url = "github:nix-community/home-manager/release-23.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    mesa-panfork = {
      url = "gitlab:panfork/mesa/csf";
      flake = false;
    };

    linux-rockchip = {
      url = "github:armbian/linux-rockchip/rk-5.10-rkr5.1";
      flake = false;
    };

    ubuntu-rockchip-meta = {
      url = "github:Joshua-Riek/ubuntu-rockchip/v1.33";
      flake = false;
    };

    armbian-firmware = {
      url = "github:armbian/firmware/master";
      flake = false;
    };

  };

  outputs = inputs@{ nixpkgs, home-manager, ... }:
    let
      user = "dao";

      pkgs = import nixpkgs {
        system = "aarch64-linux";
        overlays = [
          (self: super: {
            ccacheWrapper = super.ccacheWrapper.override {
              extraConfig = ''
                export CCACHE_COMPRESS=1
                export CCACHE_DIR="/nix/var/cache/ccache"
                export CCACHE_UMASK=007
                if [ ! -d "$CCACHE_DIR" ]; then
                  echo "====="
                  echo "Directory '$CCACHE_DIR' does not exist"
                  echo "Please create it with:"
                  echo "  sudo mkdir -m0770 '$CCACHE_DIR'"
                  echo "  sudo chown root:nixbld '$CCACHE_DIR'"
                  echo "====="
                  exit 1
                fi
                if [ ! -w "$CCACHE_DIR" ]; then
                  echo "====="
                  echo "Directory '$CCACHE_DIR' is not accessible for user $(whoami)"
                  echo "Please verify its access permissions"
                  echo "====="
                  exit 1
                fi
              '';
            };
          })
        ];
      };

      rkbin = pkgs.stdenvNoCC.mkDerivation {
        pname = "rkbin";
        version = "unstable-b4558da";

        src = pkgs.fetchFromGitHub {
          owner = "rockchip-linux";
          repo = "rkbin";
          rev = "a2a0b89b6c8c612dca5ed9ed8a68db8a07f68bc0";
          sha256 = "sha256-U/jeUsV7bhqMw3BljmO6SI07NCDAd/+sEp3dZnyXeeA=";
        };

        # we just need TPL and BL31 but it doesn't hurt,
        # follow single point of change to make life easier
        installPhase = ''
          mkdir $out && cp bin/rk35/rk3588* $out/
        '';
      };

      rk-valhal = pkgs.stdenv.mkDerivation rec {
        pname = "rk-valhal";
        version = "unstable";

        buildInputs = with pkgs; [
          autoPatchelfHook
          xorg.libxcb
          libdrm
          xorg.libX11
          stdenv.cc.cc.lib
        ];

        src = pkgs.fetchurl {
          url = "https://github.com/tsukumijima/libmali-rockchip/raw/master/lib/aarch64-linux-gnu/libmali-valhall-g610-g6p0-x11-gbm.so";
          sha256 = "sha256-PVfLdtyoUch2o/9xxJ/r1b/AD8FQH0btN98z5168uZs=";
        };

        unpackPhase = ''
          :
        '';
        installPhase = ''
          mkdir $out/lib -p
          cp $src $out/lib/libmali.so.1
          ln -s libmali.so.1 $out/lib/libmali-valhall-g610-g6p0-x11-gbm.so
          for l in libEGL.so libEGL.so.1 libgbm.so.1 libGLESv2.so libGLESv2.so.2 libOpenCL.so.1; do ln -s libmali.so.1 $out/lib/$l; done
        '';
      };

      u-boot = pkgs.ccacheStdenv.mkDerivation rec {
        pname = "u-boot";
        version = "v2024.01";

        src = pkgs.fetchFromGitHub {
          owner = "u-boot";
          repo = "u-boot";
          rev = "${version}";
          sha256 = "sha256-0Da7Czy9cpQ+D5EICc3/QSZhAdCBsmeMvBgykYhAQFw=";
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
          make ARCH=arm orangepi-5-rk3588s_defconfig
        '';

        buildPhase = ''
          patchShebangs tools scripts
          make -j$(nproc) \
            ROCKCHIP_TPL=${rkbin}/rk3588_ddr_lp4_2112MHz_lp5_2400MHz_v1.16.bin \
            BL31=${rkbin}/rk3588_bl31_v1.45.elf
        '';

        installPhase = ''
          mkdir $out
          cp u-boot-rockchip.bin $out
          cp ${rkbin}/rk3588_ddr_lp4_2112MHz_lp5_2400MHz_v1.16.bin $out
          cp ${rkbin}/rk3588_bl31_v1.45.elf $out
        '';
      };

      opi-5b-overlay = pkgs.stdenv.mkDerivation {
        pname = "opi-5b-overlay";
        version = "unstable";

        src = inputs.ubuntu-rockchip-meta;

        buildInputs = with pkgs; [
          autoPatchelfHook
        ];

        configurePhase = ''
          patchShebangs overlay
        '';

        installPhase = ''
          mkdir $out
          cp -rf overlay/* $out

          # paths have to be corrected
          sed -i 's|brcm_patchram_plus|'$out'/usr/bin/brcm_patchram_plus|g' $out/usr/lib/scripts/ap6275p-bluetooth.sh
          sed -i 's|/lib/firmware|${inputs.armbian-firmware}|g' $out/usr/lib/scripts/ap6275p-bluetooth.sh
          sed -i 's|rfkill|/run/current-system/sw/bin/rfkill|g' $out/usr/lib/scripts/ap6275p-bluetooth.sh
        '';
      };

      nixos-orangepi-5x = pkgs.stdenvNoCC.mkDerivation {
        pname = "nixos-orangepi-5x";
        version = "unstable";

        src = ./.;

        installPhase = ''
          mkdir $out
          tar czf $out/meta.tar.gz *
        '';
      };

      buildConfig = { pkgs, lib, ... }: rec {
        boot.kernelPackages = pkgs.linuxPackagesFor (pkgs.callPackage ./board/kernel {
          src = inputs.linux-rockchip;
          inherit pkgs;
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
                stdenv = pkgs.ccacheStdenv;
              }).overrideAttrs (_: {
                pname = "mesa-panfork";
                version = "23.0.0-panfork";
                src = inputs.mesa-panfork;
              })
            ).drivers;
            extraPackages = [ rk-valhal ];
          };

          firmware = [
            (pkgs.callPackage ./board/firmware { })

            (pkgs.runCommandNoCC "build-firmware-drv" { } ''
              mkdir -p $out/lib/firmware
              cp -Rf ${inputs.armbian-firmware}/* $out/lib/firmware
            '')
          ];

          pulseaudio.enable = true;
        };

        networking = {
          networkmanager.enable = true;
          wireless.enable = false;
        };

        environment.systemPackages = with pkgs; [
          git
          htop
          neofetch

          gnome.adwaita-icon-theme
          xst
          rofi
          ripgrep
          fzf

          taskwarrior
        ] ++ [ u-boot ];

        # save u-boot for later usage
        environment.etc."u-boot".source = u-boot;

        environment.loginShellInit = ''
           # if [ -z "$DISPLAY" ] && [ "_$(tty)" == "_/dev/tty1" ]; then
           #   dunst&

           #   # set default output to headphone
           #   pacmd set-default-sink alsa_output.platform-es8388-sound.stereo-fallback &

           #   # start the X
           #   # startx
            if [ -z "$WAYLAND_DISPLAY" ] && [ "_$(tty)" == "_/dev/tty1" ]; then
              export GDK_BACKEND=wayland
              export MOZ_ENABLE_WAYLAND=1
              export QT_QPA_PLATFORM=wayland
              export XDG_SESSION_TYPE=wayland

              dunst&

              exec sway
            fi

            alias e=nvim
            alias rebuild='sudo nixos-rebuild switch --flake .'
        '';

        time.timeZone = "Asia/Ho_Chi_Minh";
        i18n.defaultLocale = "en_US.UTF-8";

        services.sshd.enable = true;
        services.fstrim = { enable = true; };

        services.xserver = {
          enable = true;
          videoDrivers = [ "modesetting" ];
          displayManager.startx.enable = true;
          windowManager.spectrwm.enable = true;
          desktopManager = {
            xterm.enable = false;
            xfce = {
              enable = true;
            };
          };
        };

        services.cockpit = {
          enable = true;
          port = 9090;
          settings = {
            WebService = {
              AllowUnencrypted = true;
            };
          };
        };

        nix = {
          settings = {
            auto-optimise-store = true;
            experimental-features = [ "nix-command" "flakes" ];
          };

          gc = {
            automatic = true;
            dates = "weekly";
            options = "--delete-older-than 10d";
          };

          # Free up to 1GiB whenever there is less than 100MiB left.
          extraOptions = ''
            min-free = ${toString ( 100 * 1024 * 1024)}
            max-free = ${toString (1024 * 1024 * 1024)}
          '';
        };

        programs = {
          sway.enable = true;
          # starship.enable = true;
          neovim.enable = true;
          neovim.defaultEditor = true;
          ccache.enable = true;
          ccache.packageNames = [ "linux" ];
        };

        nix.settings.extra-sandbox-paths = [ "/nix/var/cache/ccache" ];
        # make sure using local cache for searching packages
        nix.registry.nixpkgs.flake = inputs.nixpkgs;
        nix.nixPath = [ "nixpkgs=${inputs.nixpkgs}" ];

        system.stateVersion = "23.05";
      };
    in
    rec
    {
      # to boot from SDCard
      nixosConfigurations.live = nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        modules = [
          "${nixpkgs}/nixos/modules/installer/sd-card/sd-image-aarch64-installer.nix"

          (buildConfig { inherit pkgs; lib = nixpkgs.lib; })

          ({ pkgs, lib, ... }: {
            # all modules we need are builtin already, the nixos default profile might add
            # some which is not available, force to not use any other.
            boot.initrd.availableKernelModules = lib.mkForce [ ];

            users.users.nixos = {
              initialPassword = "nixos";
              isNormalUser = true;
              extraGroups = [ "networkmanager" "wheel" ];

              packages = [
                u-boot
                nixos-orangepi-5x

                (pkgs.writeScriptBin "extract-install-files" ''
                  tmpdir=$(mktemp -d)
                  cp ${u-boot}/u-boot-rockchip.bin $tmpdir
                  tar -xzf ${nixos-orangepi-5x}/meta.tar.gz -C $tmpdir
                  echo "dd if=$tmpdir/u-boot-rockchip.bin of=\$1 seek=64 conv=notrunc" > $tmpdir/update-bootloader
                '')
              ];
            };

            # rockchip bootloader needs 16MiB+
            sdImage = {
              # 16MiB should be enough (u-boot-rockchip.bin ~ 10MiB)
              firmwarePartitionOffset = 16;
              firmwarePartitionName = "Firmwares";

              compressImage = true;
              expandOnBoot = true;

              # u-boot-rockchip.bin is all-in-one bootloader blob, flashing to the image should be enough
              populateFirmwareCommands = "dd if=${u-boot}/u-boot-rockchip.bin of=$img seek=64 conv=notrunc";

              # make sure u-boot available on the firmware partition, cuz we do need this
              # to write to eMMC
              postBuildCommands = ''
                cp ${u-boot}/u-boot-rockchip.bin firmware/
                cp ${nixos-orangepi-5x}/meta.tar.gz firmware/nixos-orangepi-5x.tar.gz
              '';
            };
          })
        ];
      };

      # to install NixOS on eMMC
      nixosConfigurations.singoc = nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";

        modules = [
          (buildConfig { inherit pkgs; lib = nixpkgs.lib; })
          ({ config, pkgs, lib, ... }: rec {

            boot = {
              loader = { grub.enable = false; generic-extlinux-compatible.enable = true; };
              initrd.luks.devices."Encrypted".device = "/dev/disk/by-partlabel/Encrypted";
              initrd.availableKernelModules = lib.mkForce [ "dm_mod" "dm_crypt" "encrypted_keys" ];
            };

            fileSystems."/" = { device = "none"; fsType = "tmpfs"; options = [ "mode=0755,size=8G" ]; };
            fileSystems."/boot" = { device = "/dev/disk/by-partlabel/Firmwares"; fsType = "vfat"; };
            fileSystems."/nix" = { device = "/dev/mapper/Encrypted"; fsType = "btrfs"; options = [ "subvol=nix,compress=zstd,noatime" ]; };
            fileSystems."/home/${user}" = { device = "/dev/mapper/Encrypted"; fsType = "btrfs"; options = [ "subvol=usr,compress=zstd,noatime" ]; };

            # why not, we have 16GiB RAM
            fileSystems."/tmp" = { device = "none"; fsType = "tmpfs"; options = [ "mode=0755,size=12G" ]; };

            hardware.wirelessRegulatoryDatabase = true;
            hardware.opengl.driSupport = true;
            hardware.bluetooth.enable = true;
            hardware.bluetooth.powerOnBoot = true;

            networking = {
              hostName = "singoc";
              networkmanager.enable = true;
            };

            users.users.${user} = {
              isNormalUser = true;
              initialPassword = "${user}";
              extraGroups = [ "wheel" "networkmanager" "tty" "video" ];
              packages = with pkgs; [
                home-manager

                foot
                wofi
                waybar

                neofetch
                pavucontrol
                direnv
                dunst
                firefox
                chromium
                qemu
              ];
            };

            services.getty.autologinUser = "${user}";
            services.atftpd = {
              enable = true;
              root = "/tmp/tftpboot";
            };

            # systemd services
            systemd.services = {
              bluetooth-ap6275p = {
                wantedBy = [ "multi-user.target" ];
                after = [ "bluetooth.target" ];
                description = "Bluetooth AP6275P";
                serviceConfig = {
                  Type = "forking";
                  ExecStartPre = ''/run/current-system/sw/bin/sleep 5'';
                  ExecStart = ''${opi-5b-overlay}/usr/lib/scripts/ap6275p-bluetooth.sh'';
                  ExecStop = ''/run/current-system/sw/bin/pkill -9 brcm_patchram_plus'';
                };
              };
            };
          })

          home-manager.nixosModules.home-manager
          {
            home-manager.users.${user} = { pkgs, ... }: {
              home.packages = with pkgs; [
                roboto
                roboto-mono
                nerdfonts

                ftop
              ];

              programs.bash = {
                enable = true;
                enableCompletion = true;

                shellAliases = {
                  hme = "${pkgs.neovim}/bin/nvim $HOME/conf/flake.nix";
                  hmw = "sudo nixos-rebuild --switch --flake $HOME/conf";
                };

                bashrcExtra = ''
                  set -o vi
                '';
              };


              home.file = {
                ".local/share/fonts/ocra.ttf".source = pkgs.fetchurl {
                  url = "https://github.com/qwazix/free-libre-fonts/raw/master/OCRA/OCRA.ttf";
                  sha256 = "sha256-oPWICXBdVBCP5BQJuucPu4MVpk6Ymq8q+gTVz7uU9U4=";
                };

                ".local/share/fonts/latin-modern-mono".source = pkgs.fetchzip {
                  url = "https://www.fontsquirrel.com/fonts/download/Latin-Modern-Mono";
                  extension = ".zip";
                  stripRoot = false;
                  sha256 = "sha256-Td//b/M9IafhG2jtHLfvfTWdqyLtMr/jBizZAeBRPwM=";
                };

                ".local/share/fonts/mplus-1m".source = pkgs.fetchzip {
                  url = "https://www.fontsquirrel.com/fonts/download/M-1m";
                  extension = ".zip";
                  stripRoot = false;
                  sha256 = "sha256-zpZ1B4x756FKuAJOazggN3UQUgW3zji95533WbiU/Lw=";
                };
              };

              home.stateVersion = "23.05";
            };
          }
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
