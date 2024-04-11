self: super:

{
  bun = super.bun.overrideAttrs (oldAttrs: rec {
    version = "1.1.3";
    src = super.fetchurl {
      url = "https://github.com/oven-sh/bun/releases/download/bun-v${version}/bun-linux-aarch64.zip";
      sha256 = "f1ba64cc7d12a86eed826e90efee004fd45fac52a7b121ae16dd92d495c6c2bc";
    };
  });
}
