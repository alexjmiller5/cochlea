{ config, lib, pkgs, ... }:
let cfg = config.programs.cochlea;
in {
  options.programs.cochlea = {
    enable = lib.mkEnableOption "Cochlea";
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ./package.nix {};
      defaultText = lib.literalExpression "pkgs.callPackage ./package.nix {}";
      description = "The immutable signed Cochlea release to install.";
    };
  };
  config = lib.mkIf cfg.enable {
    assertions = [{
      assertion = pkgs.stdenv.hostPlatform.isDarwin;
      message = "programs.cochlea requires macOS; the web development shell also supports Linux.";
    }];
    home.packages = [ cfg.package ];
  };
}
