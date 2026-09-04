# extism-js (the js-pdk CLI) compiles immich's core plugin to WASM.
#
# nixpkgs builds this from source, but its extism-js-core is marked broken on
# Darwin: rquickjs-sys' build script fails to link against libiconv. Immich
# itself doesn't build it from source either -- it pulls the upstream release
# binary via mise. We do the same, reusing the exact version and checksum that
# immich's own mise.lock pins, so this stays as reproducible as their build.
{
  lib,
  stdenvNoCC,
  fetchurl,
  gzip,
}:

let
  version = "1.6.0";

  # sha256 values are copied verbatim from immich's mise.lock at the tag we
  # build. Update them together with the immich version.
  sources = {
    aarch64-darwin = {
      url = "https://github.com/extism/js-pdk/releases/download/v${version}/extism-js-aarch64-macos-v${version}.gz";
      sha256 = "548e25bda3971a07c32d78a249135cf8cb7b3eede101e878e06e53e01ac2e0ce";
    };
    aarch64-linux = {
      url = "https://github.com/extism/js-pdk/releases/download/v${version}/extism-js-aarch64-linux-v${version}.gz";
      sha256 = "15a186250e68d6bff4ec839fff275d45a90e383a69209dcc1239eb9e3aee6e1b";
    };
    x86_64-linux = {
      url = "https://github.com/extism/js-pdk/releases/download/v${version}/extism-js-x86_64-linux-v${version}.gz";
      sha256 = "4ded271ccf465031ccd0dc35e7a140e134d7f30721671cc4a8e1ff805d4aad68";
    };
  };

  source =
    sources.${stdenvNoCC.hostPlatform.system}
      or (throw "extism-js: no pinned release for ${stdenvNoCC.hostPlatform.system}");
in
stdenvNoCC.mkDerivation {
  pname = "extism-js";
  inherit version;

  src = fetchurl { inherit (source) url sha256; };

  nativeBuildInputs = [ gzip ];

  dontUnpack = true;

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/bin"
    gzip -dc "$src" > "$out/bin/extism-js"
    chmod +x "$out/bin/extism-js"

    runHook postInstall
  '';

  meta = {
    description = "Extism js-pdk CLI (upstream release binary)";
    homepage = "https://github.com/extism/js-pdk";
    license = lib.licenses.bsd3;
    platforms = lib.attrNames sources;
    mainProgram = "extism-js";
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
