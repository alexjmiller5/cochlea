{ pkgs, package, homeModule }:
let
  inherit (pkgs) lib;
  sample = pkgs.runCommand "cochlea-package-fixture" { nativeBuildInputs = [ pkgs.zip ]; } ''
    mkdir -p Cochlea.app/Contents/{MacOS,Resources,_CodeSignature}
    printf '#!/bin/sh\nprintf signed-payload' > Cochlea.app/Contents/MacOS/Cochlea
    chmod +x Cochlea.app/Contents/MacOS/Cochlea
    printf profile > Cochlea.app/Contents/embedded.provisionprofile
    printf ticket > Cochlea.app/Contents/CodeResources
    printf signature > Cochlea.app/Contents/_CodeSignature/CodeResources
    ln -s ../MacOS/Cochlea Cochlea.app/Contents/Resources/executable
    zip -qry fixture.zip Cochlea.app
    mv fixture.zip "$out"
  '';
  fixturePackage = package.overrideAttrs { src = sample; };
  evaluate = settings: lib.evalModules {
    specialArgs = { inherit pkgs; };
    modules = [
      homeModule
      {
        options.home.packages = lib.mkOption { type = lib.types.listOf lib.types.package; default = []; };
        options.assertions = lib.mkOption { type = lib.types.listOf lib.types.attrs; default = []; };
      }
      settings
    ];
  };
  enabled = (evaluate { programs.cochlea = { enable = true; package = fixturePackage; }; }).config;
  disabled = (evaluate {}).config;
  defaultEnabled = (evaluate { programs.cochlea.enable = true; }).config;
  customRelease = package.override {
    version = "1.2.3";
    url = "https://example.invalid/releases/app.zip";
    hash = lib.fakeHash;
  };
  darwinEvaluate = settings: lib.evalModules {
    specialArgs = { inherit pkgs; };
    modules = [
      ./darwin.nix
      {
        options = {
          environment.systemPackages = lib.mkOption { type = lib.types.listOf lib.types.package; default = []; };
          assertions = lib.mkOption { type = lib.types.listOf lib.types.attrs; default = []; };
          homebrew = {
            enable = lib.mkOption { type = lib.types.bool; default = true; };
            user = lib.mkOption { type = lib.types.str; default = "fixture-user"; };
            prefix = lib.mkOption { type = lib.types.str; default = "/fixture/brew"; };
            casks = lib.mkOption { type = lib.types.listOf lib.types.attrs; default = []; };
          };
          system.checks.text = lib.mkOption { type = lib.types.lines; default = ""; };
          system.activationScripts.homebrew.text = lib.mkOption { type = lib.types.lines; default = ""; };
        };
      }
      settings
    ];
  };
  darwinEnabled = (darwinEvaluate { programs.cochlea = { enable = true; package = fixturePackage; }; }).config;
  darwinDisabled = (darwinEvaluate {}).config;
  duplicateOwner = (darwinEvaluate {
    programs.cochlea.enable = true;
    homebrew.casks = [{ name = "alexjmiller5/tap/cochlea"; }];
  }).config;
in {
  darwin-module = assert darwinDisabled.environment.systemPackages == [];
    assert darwinDisabled.system.checks.text == "";
    assert darwinEnabled.environment.systemPackages == [ fixturePackage ];
    assert lib.all (entry: entry.assertion) darwinEnabled.assertions;
    assert !(lib.all (entry: entry.assertion) duplicateOwner.assertions);
    pkgs.runCommand "cochlea-darwin-module-check" {} "touch $out";
  home-module = assert disabled.home.packages == [];
    assert enabled.home.packages == [ fixturePackage ];
    assert (builtins.head defaultEnabled.home.packages).drvPath == package.drvPath;
    assert lib.all (entry: entry.assertion) enabled.assertions;
    assert customRelease.version == "1.2.3";
    assert customRelease.src.url == "https://example.invalid/releases/app.zip";
    assert customRelease.src.outputHash == lib.fakeHash;
    pkgs.runCommand "cochlea-home-module-check" {} "touch $out";
  bundle-preservation = pkgs.runCommand "cochlea-bundle-preservation-check" {
    nativeBuildInputs = [ pkgs.unzip pkgs.diffutils ];
  } ''
    unzip -q ${sample}
    diff -r --no-dereference Cochlea.app ${fixturePackage}/Applications/Cochlea.app
    test -x ${fixturePackage}/Applications/Cochlea.app/Contents/MacOS/Cochlea
    test -L ${fixturePackage}/Applications/Cochlea.app/Contents/Resources/executable
    test "$(readlink ${fixturePackage}/Applications/Cochlea.app/Contents/Resources/executable)" = ../MacOS/Cochlea
    touch "$out"
  '';
}
