{
  description = "Signed Cochlea macOS application";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/2bd3427b41d10b8318383195efe502ed1baca6cd";
  outputs = { nixpkgs, ... }:
    let
      systems = [ "aarch64-darwin" "x86_64-darwin" ];
      each = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
      homeModule = import ./nix/home-manager.nix;
    in {
      packages = each (pkgs: let package = pkgs.callPackage ./nix/package.nix {}; in {
        default = package;
        cochlea = package;
      });
      darwinModules.default = import ./nix/darwin.nix;
      darwinModules.cochlea = import ./nix/darwin.nix;
      homeModules.default = homeModule;
      homeModules.cochlea = homeModule;
      checks = each (pkgs: import ./nix/checks.nix {
        inherit pkgs homeModule;
        package = pkgs.callPackage ./nix/package.nix {};
      });
    };
}
