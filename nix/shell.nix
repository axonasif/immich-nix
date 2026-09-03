{
  lib,
  mkShell,
  stdenv,
  callPackage,

  # toolchain
  nodejs_24,
  pnpm_11,
  python312,
  uv,
  node-gyp,
  pkg-config,

  # plugin (WASM) toolchain
  binaryen,

  # image / media libraries
  vips_8_17,
  libraw,
  libheif,
  imagemagick,
  exiftool,

  # node-canvas deps
  cairo,
  giflib,
  libjpeg,
  libpng,
  librsvg,
  pango,
  pixman,

  # services
  postgresql_17,
  redis,

  apple-sdk,
  libiconv,
}:

let
  # Immich's thumbnail generation for raw photos fails with vips' bundled tiff
  # reader ("samples_per_pixel not a whole number of bytes"), and outright
  # breaks on vips 8.18 -- so pin 8.17 with tiff disabled, as nixpkgs does.
  vips' = vips_8_17.overrideAttrs (prev: {
    mesonFlags = prev.mesonFlags ++ [ "-Dtiff=disabled" ];
  });

  postgresql' = postgresql_17.withPackages (ps: [ ps.pgvector ]);

  extism-js = callPackage ./extism-js.nix { };
in
mkShell {
  name = "immich-native";

  packages = [
    nodejs_24
    pnpm_11
    python312
    uv
    node-gyp
    pkg-config

    binaryen
    extism-js

    vips'
    libraw
    libheif
    imagemagick
    exiftool

    cairo
    giflib
    libjpeg
    libpng
    librsvg
    pango
    pixman

    postgresql'
    redis
  ]
  ++ lib.optionals stdenv.hostPlatform.isDarwin [
    apple-sdk
    libiconv
  ];

  # Build sharp against the vips above instead of downloading a prebuilt binary.
  SHARP_FORCE_GLOBAL_LIBVIPS = 1;

  # node-gyp looks for node headers here.
  # https://github.com/nodejs/node-gyp/issues/1191#issuecomment-301243919
  npm_config_nodedir = nodejs_24;
}
