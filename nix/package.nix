{ lib, stdenvNoCC, fetchurl, unzip
, version ? "0.8.0"
, url ? "https://github.com/alexjmiller5/cochlea/releases/download/v${version}/Cochlea-v${version}.zip"
, hash ? "sha256-jvViPDdzr2004GwlqePaRftcaaIdMxmx7w+BowcPldE="
}:
stdenvNoCC.mkDerivation {
  pname = "cochlea";
  inherit version;
  src = fetchurl { inherit url hash; };
  nativeBuildInputs = [ unzip ];
  phases = [ "unpackPhase" "installPhase" ];
  unpackPhase = ''unzip -q "$src"'';
  # The release is already signed and notarized. Even shebang rewriting or
  # stripping an embedded executable would invalidate its sealed contents.
  dontFixup = true;
  dontStrip = true;
  installPhase = ''
    mkdir -p "$out/Applications"
    cp -R Cochlea.app "$out/Applications/"
  '';
  meta = {
    description = "Offline music recognition for macOS";
    homepage = "https://github.com/alexjmiller5/cochlea";
    platforms = lib.platforms.darwin;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
