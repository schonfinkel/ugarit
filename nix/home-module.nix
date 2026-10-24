# Per-user install with an optional declarative `config.json`.
self:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.ugarit;
  json = pkgs.formats.json { };
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
    settings = lib.mkOption {
      type = lib.types.nullOr json.type;
      default = null;
      example = lib.literalExpression ''
        {
          version = 1;
          default_search_path = ".agents/skills";
          sources = [{
            name = "skills";
            url = "ssh://git@codeberg.org/schonfinkel/skills.git";
            target = ".agents/skills";
          }];
        }
      '';
      description = ''
        Contents of `$XDG_CONFIG_HOME/ugarit/config.json`. When set, the file
        is managed by Home Manager and overwrites changes made by
        `ugarit source-add` on the next activation. Run `ugarit source-sync`
        to clone newly declared sources.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ cfg.package ];
    xdg.configFile."ugarit/config.json" = lib.mkIf (cfg.settings != null) {
      source = json.generate "ugarit-config.json" cfg.settings;
      force = true;
    };
  };
}
