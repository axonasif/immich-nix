# Reverse-geocoding data from Immich's pinned production base image.
{
  lib,
  runCommand,
  cacert,
  curl,
  jq,
}:

let
  # Immich v3.1.0 pins base-server-prod:202607211135 at this image digest.
  # The layer is the linux/arm64 image's `COPY /build/ /build/` step. Its
  # geodata payload is architecture-neutral and is exactly what upstream ships.
  # Update the image digest, layer digest, and output hash together.
  imageDigest = "sha256:ced131da7523544fe975cfd25abd67386e712e39496340b437cd95a08d0a18f3";
  layerDigest = "sha256:59d996877722cab7968b5c667dbde9b2d4993fb3a7df8ec6c1cd46ce97c4e0da";
  repository = "immich-app/base-server-prod";
in
runCommand "immich-geodata"
  {
    outputHash = "sha256-qLdYr0tdZEzpgAtvU/qwvEWYy6QI0N1rdmgNfbIBfLw=";
    outputHashMode = "recursive";

    nativeBuildInputs = [
      cacert
      curl
      jq
    ];

    passthru.upstreamImageDigest = imageDigest;
    meta.license = lib.licenses.cc-by-40;
  }
  ''
    token="$(${curl}/bin/curl -fsSL \
      'https://ghcr.io/token?scope=repository:${repository}:pull&service=ghcr.io' \
      | ${jq}/bin/jq -er .token)"

    ${curl}/bin/curl -fsSL --retry 5 --retry-all-errors \
      -H "Authorization: Bearer $token" \
      -o layer.tar.gz \
      'https://ghcr.io/v2/${repository}/blobs/${layerDigest}'

    mkdir source
    tar -xzf layer.tar.gz -C source build/geodata
    mv source/build/geodata "$out"
  ''
