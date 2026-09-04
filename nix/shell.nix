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
  zlib,

  # build and runtime utilities
  curl,
  git,
  lsof,
  procps,

  # plugin (WASM) toolchain
  binaryen,

  # image / media libraries
  vips,
  libspng,
  libraw,
  libheif,
  imagemagick,
  exiftool,
  perl,
  # Immich relies on jellyfin's ffmpeg patches, not stock ffmpeg.
  # https://github.com/NixOS/nixpkgs/issues/351943
  jellyfin-ffmpeg,

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
  valkey,

  apple-sdk,
  libiconv,
}:

let
  # Track whatever libvips upstream builds against -- see UPGRADING.md §2.2.
  # Immich v3.1.0's official image uses 8.18.4; nixpkgs' immich pins 8.17 with a
  # comment claiming 8.18 breaks thumbnails, which upstream contradicts.
  #
  # -Dtiff=disabled matches upstream's own build (base-images
  # server/sources/libvips.sh): vips' tiff reader mishandles some raw files
  # ("tiff2vips: samples_per_pixel not a whole number of bytes").
  #
  # The patch is upstream's too, and is REQUIRED from libvips 8.18 on: 8.18
  # added dcrawload at priority 100, which outranks jpegload (50) and heifload
  # (0), so the RAW loader would otherwise get first refusal on JPEG and HEIC.
  # The patch raises both to 150. See UPGRADING.md §2.2.
  #
  # PNG goes through libspng rather than libpng, matching upstream, which
  # installs only libspng-dev. vips treats spng strictly as a *fallback* --
  # meson.build only looks for it `if not png_package.found()` -- so libpng has
  # to be disabled for spng to be used at all. Setting -Dspng=enabled alone
  # silently does nothing.
  vips' = vips.overrideAttrs (prev: {
    # overrideAttrs runs after mkDerivation applied chooseDevOutputs, so the dev
    # output has to be named explicitly for spng.pc to be on the pkg-config path.
    buildInputs = prev.buildInputs ++ [
      (lib.getDev libspng)
      libspng
    ];
    mesonFlags =
      (builtins.filter (
        f: !(lib.hasPrefix "-Dpng=" f || lib.hasPrefix "-Dspng=" f)
      ) prev.mesonFlags)
      ++ [
        "-Dpng=disabled"
        "-Dspng=enabled"
        "-Dtiff=disabled"
      ];
    patches = (prev.patches or [ ]) ++ [
      ./patches/0001-put-other-loaders-ahead-of-dcrawload.patch
    ];
  });

  # Immich prefers VectorChord when both extensions are available. VectorChord
  # depends on pgvector, and its PostgreSQL library must be preloaded at runtime.
  # nixpkgs marks every pgrx extension broken on Darwin because its sandboxed
  # PostgreSQL tests can leak shared-memory objects (Nix issue #12548). The
  # builder has Darwin linker support, so opt this package back in.
  postgresql' = postgresql_17.withPackages (
    ps:
    let
      vectorchord =
        if stdenv.hostPlatform.isDarwin then
          ps.vectorchord.overrideAttrs (old: {
            meta = old.meta // {
              broken = false;
            };
          })
        else
          ps.vectorchord;
    in
    [
      ps.pgvector
      vectorchord
    ]
  );

  extism-js = callPackage ./extism-js.nix { };
  geodata = callPackage ./geodata.nix { };
in
mkShell {
  name = "immich-local";

  packages = [
    nodejs_24
    pnpm_11
    python312
    uv
    node-gyp
    pkg-config

    curl
    git
    lsof

    binaryen
    extism-js

    vips'
    libraw
    libheif
    imagemagick
    exiftool
    # exiftool-vendored probes for perl even when exiftool comes from PATH.
    perl
    jellyfin-ffmpeg

    cairo
    giflib
    libjpeg
    libpng
    librsvg
    pango
    pixman

    postgresql'
    valkey
  ]
  ++ lib.optionals stdenv.hostPlatform.isDarwin [
    apple-sdk
    libiconv
  ]
  ++ lib.optionals stdenv.hostPlatform.isLinux [
    procps
  ];

  # Build sharp against the vips above instead of downloading a prebuilt binary.
  SHARP_FORCE_GLOBAL_LIBVIPS = 1;

  # Consumed by scripts/build.sh when assembling the runtime tree.
  IMMICH_GEODATA = geodata;

  # build.sh asserts sharp actually linked against this, not a bundled copy.
  IMMICH_VIPS_VERSION = vips'.version;

  # node-gyp looks for node headers here.
  # https://github.com/nodejs/node-gyp/issues/1191#issuecomment-301243919
  npm_config_nodedir = nodejs_24;

  # uv installs upstream binary Python wheels, whose ELF dependencies are not
  # patched like Nix-built packages. On Linux, make their runtime dependencies
  # visible both to isolated PEP 517 builds and to the assembled ML venv.
  ${if stdenv.hostPlatform.isLinux then "LD_LIBRARY_PATH" else null} = lib.makeLibraryPath [
    stdenv.cc.cc.lib
    zlib
  ];
}
