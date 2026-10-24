# System-wide install: `programs.ugarit.enable = true;`
self:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.ugarit;
in
{
  options.programs.ugarit = {
    enable = lib.mkEnableOption "ugarit, a Git-backed agent skill linker";
    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
      defaultText = lib.literalExpression "ugarit.packages.\${system}.default";
      description = "The ugarit package to install.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];
  };
}
