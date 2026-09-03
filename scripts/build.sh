#!/usr/bin/env bash
# Build immich from source and assemble a runnable tree under $IMMICH_PREFIX.
#
# Expects to run inside the flake devShell (`nix develop`), which supplies the
# toolchain, the native libraries, and $IMMICH_GEODATA.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

IMMICH_VERSION="${IMMICH_VERSION:-$(cat "$REPO_ROOT/immich-version")}"
SRC_DIR="${IMMICH_SRC_DIR:-$REPO_ROOT/work/immich}"
PREFIX="${IMMICH_PREFIX:-$REPO_ROOT/.local/immich-app}"
UPSTREAM="${IMMICH_UPSTREAM:-https://github.com/immich-app/immich.git}"

log() { printf '\033[1;36m[build]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[build]\033[0m %s\n' "$*" >&2; exit 1; }

[[ -n "${IN_NIX_SHELL:-}${IMMICH_GEODATA:-}" ]] \
  || die "run inside the devShell: nix develop --command scripts/build.sh"
[[ -n "${IMMICH_GEODATA:-}" ]] || die "IMMICH_GEODATA is unset; is the devShell current?"

# --- source ------------------------------------------------------------------

fetch_source() {
  if [[ ! -d "$SRC_DIR/.git" ]]; then
    log "cloning immich $IMMICH_VERSION"
    mkdir -p "$(dirname "$SRC_DIR")"
    git clone -q --depth=1 --branch "$IMMICH_VERSION" "$UPSTREAM" "$SRC_DIR"
    return
  fi

  local current
  current="$(git -C "$SRC_DIR" describe --tags --exact-match 2>/dev/null || echo "")"
  if [[ "$current" == "$IMMICH_VERSION" ]]; then
    log "source already at $IMMICH_VERSION"
    return
  fi

  log "checking out immich $IMMICH_VERSION"
  git -C "$SRC_DIR" fetch -q --depth=1 origin "refs/tags/$IMMICH_VERSION:refs/tags/$IMMICH_VERSION"
  git -C "$SRC_DIR" checkout -q --force "$IMMICH_VERSION"
  git -C "$SRC_DIR" clean -qfdx -e node_modules
}

# --- javascript --------------------------------------------------------------

build_js() {
  cd "$SRC_DIR"

  # The plugin chain must come first: plugin-core's WASM is produced by
  # extism-js, and the server's build depends on the generated SDK.
  log "building sdk, plugin-sdk and plugin-core"
  pnpm --filter @immich/sdk --filter @immich/plugin-sdk --filter @immich/plugin-core \
    install --frozen-lockfile
  pnpm --filter @immich/sdk --filter @immich/plugin-sdk --filter @immich/plugin-core build

  log "building server"
  pnpm --filter immich install --frozen-lockfile
  pnpm --filter immich build

  log "building web"
  pnpm --filter immich-web install --frozen-lockfile
  pnpm --filter immich-web build
}

# --- assembly ----------------------------------------------------------------

deploy_server() {
  log "deploying server to $PREFIX/server"
  rm -rf "$PREFIX/server"
  mkdir -p "$PREFIX"

  # --no-optional keeps sharp's prebuilt binaries (which bundle their own
  # libvips) out of the tree, so sharp's install script builds from source
  # against the devShell's vips instead. SHARP_FORCE_GLOBAL_LIBVIPS, set by the
  # shell, is what makes that build use it.
  cd "$SRC_DIR"
  pnpm --filter immich --prod --no-optional deploy "$PREFIX/server"

  local vips
  vips="$(cd "$PREFIX/server" && node -p 'require("sharp").versions.vips')" \
    || die "sharp is not loadable in the deployed tree"
  log "sharp linked against libvips $vips"
}

assemble_build_data() {
  local build="$PREFIX/build"
  log "assembling build data in $build"

  rm -rf "$build"
  mkdir -p "$build/plugins/immich-plugin-core"

  cp -r "$SRC_DIR/web/build" "$build/www"
  cp -r "$SRC_DIR/packages/plugin-core/dist" "$build/plugins/immich-plugin-core/"
  cp "$SRC_DIR/packages/plugin-core/manifest.json" "$build/plugins/immich-plugin-core/"

  # Symlink rather than copy: the geodata is ~55MB and already content-addressed
  # in the nix store.
  ln -sfn "$IMMICH_GEODATA" "$build/geodata"

  # Only a fallback for the version numbers shown in the admin UI; immich falls
  # back to querying the binaries on PATH, which is what we want anyway.
  echo '{"sources":[],"packages":[]}' > "$build/build-lock.json"
}

# --- machine learning --------------------------------------------------------

build_ml() {
  local ml="$PREFIX/machine-learning"
  log "installing machine-learning into $ml"

  rm -rf "$ml"
  mkdir -p "$ml"
  # Copy the project rather than syncing in-tree, so the venv's absolute paths
  # point at the runtime location.
  tar -C "$SRC_DIR/machine-learning" --exclude=.venv --exclude=__pycache__ -cf - . \
    | tar -C "$ml" -xf -

  cd "$ml"
  # Use the devShell's python; never let uv download its own interpreter.
  UV_PYTHON_DOWNLOADS=never uv sync \
    --frozen --extra cpu --no-dev --no-editable --no-install-project \
    --python "$(command -v python3)"

  local providers
  providers="$("$ml/.venv/bin/python" -c 'import onnxruntime; print(",".join(onnxruntime.get_available_providers()))')"
  log "onnxruntime providers: $providers"
}

# --- main --------------------------------------------------------------------

fetch_source
build_js
deploy_server
assemble_build_data
build_ml

printf '%s\n' "$IMMICH_VERSION" > "$PREFIX/immich-version"
log "built immich $IMMICH_VERSION into $PREFIX"
