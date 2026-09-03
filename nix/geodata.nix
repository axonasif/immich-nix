# Reverse-geocoding data for immich.
#
# geonames.org publishes only a "latest" dump with no versioned URLs, so this
# pulls a fixed Internet Archive snapshot instead -- otherwise the contents
# would drift and the output hash would break at random. Bump `timestamp` and
# `hash` together when refreshing the data.
{
  lib,
  runCommand,
  cacert,
  curl,
  unzip,
}:

let
  timestamp = "20260710111330";

  date =
    "${lib.substring 0 4 timestamp}-${lib.substring 4 2 timestamp}-${lib.substring 6 2 timestamp}T"
    + "${lib.substring 8 2 timestamp}:${lib.substring 10 2 timestamp}:${lib.substring 12 2 timestamp}Z";

  # Pinned commit of natural-earth-vector, which is versioned properly.
  naturalEarthRev = "ca96624a56bd078437bca8184e78163e5039ad19";
in
runCommand "immich-geodata"
  {
    outputHash = "sha256-Pf5u+bqzF2x1PECxKwZ6dfGiEj1YMlRejTcTI1amMvU=";
    outputHashMode = "recursive";

    nativeBuildInputs = [
      cacert
      curl
      unzip
    ];

    meta.license = lib.licenses.cc-by-40;
  }
  ''
    mkdir $out
    url="https://web.archive.org/web/${timestamp}/http://download.geonames.org/export/dump"

    curl -Lo ./cities500.zip "$url/cities500.zip"
    curl -Lo $out/admin1CodesASCII.txt "$url/admin1CodesASCII.txt"
    curl -Lo $out/admin2Codes.txt "$url/admin2Codes.txt"
    curl -Lo $out/ne_10m_admin_0_countries.geojson \
      https://github.com/nvkelso/natural-earth-vector/raw/${naturalEarthRev}/geojson/ne_10m_admin_0_countries.geojson

    unzip ./cities500.zip -d $out/
    echo "${date}" > $out/geodata-date.txt
  ''
