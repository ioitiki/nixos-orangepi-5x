{ pkgs
, src
, linuxManualConfig
, ubootTools
, ...
}:
((linuxManualConfig {
  version = "6.1.43-rk3588s";
  modDirVersion = "6.1.43";

  inherit src;

  configfile = ./defconfig;

  extraMeta.branch = "6.1";

  allowImportFromDerivation = true;
}).override { stdenv = pkgs.ccacheStdenv; }).overrideAttrs (old: {
  name = "k"; # dodge uboot length limits
  nativeBuildInputs = old.nativeBuildInputs ++ [ ubootTools ];
})
