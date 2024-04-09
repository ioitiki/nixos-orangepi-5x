{ pkgs, ... }:
{
  services.postgresql = {
    enable = true;
    port = 54321;
    package = pkgs.postgresql_16;
    ensureDatabases = [
      "dev_db"
      "smsd"
      "railbird"
    ];
    ensureUsers = [
      { name = "andy"; }
    ];
  };
}
