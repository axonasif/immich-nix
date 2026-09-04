#!/usr/bin/env bash
# Build immich from source and assemble a runnable tree under $IMMICH_PREFIX.
#
# Expects to run inside the flake devShell (`nix develop`), which supplies the
# toolchain, the native libraries, and $IMMICH_GEODATA.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

IMMICH_VERSION="${IMMICH_VERSION:-$(cat "$REPO_ROOT/immich-version")}"
SRC_DIR="${IMMICH_SRC_DIR:-$REPO_ROOT/upstream/immich}"
PREFIX="${IMMICH_PREFIX:-$REPO_ROOT/.local/immich-app}"
UPSTREAM="${IMMICH_UPSTREAM:-https://github.com/immich-app/immich.git}"

log() { printf '\033[1;36m[build]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[build]\033[0m %s\n' "$*" >&2; exit 1; }

[[ -n "${IN_NIX_SHELL:-}${IMMICH_GEODATA:-}" ]] \
  || die "run inside the devShell: nix develop --command scripts/build.sh"
[[ -n "${IMMICH_GEODATA:-}" ]] || die "IMMICH_GEODATA is unset; is the devShell current?"

# --- source ------------------------------------------------------------------

# The immich source is the upstream/immich submodule -- it doubles as the local
# pinned reference. immich-version stays authoritative; the submodule is checked
# out to match it, and the recorded gitlink is just a convenience snapshot.
fetch_source() {
  if [[ ! -d "$SRC_DIR/.git" && ! -f "$SRC_DIR/.git" ]]; then
    die "submodule missing at $SRC_DIR -- run: git submodule update --init --depth 1"
  fi

  local current
  current="$(git -C "$SRC_DIR" describe --tags --exact-match 2>/dev/null || echo "")"
  if [[ "$current" == "$IMMICH_VERSION" ]]; then
    log "source already at $IMMICH_VERSION"
    return
  fi

  log "checking out immich $IMMICH_VERSION in the submodule"
  if ! git -C "$SRC_DIR" rev-parse -q --verify "refs/tags/$IMMICH_VERSION" >/dev/null; then
    git -C "$SRC_DIR" fetch -q --depth=1 "$UPSTREAM" "refs/tags/$IMMICH_VERSION:refs/tags/$IMMICH_VERSION"
  fi
  git -C "$SRC_DIR" checkout -q --force "$IMMICH_VERSION"
  # -x removes ignored files too (node_modules, dist, web/build); keep
  # node_modules so a version bump does not force a full reinstall.
  git -C "$SRC_DIR" clean -qfdx -e node_modules
}

# --- local patches -----------------------------------------------------------

patch_source() {
  log "applying local patches"
  cd "$SRC_DIR"

  # Immich hardcodes Debian's postgres layout for the scheduled database
  # backup, which does not exist under nix. We have pg_dump/pg_restore on PATH,
  # so drop the directory prefix. nixpkgs patches the same line.
  # Backups are ON by default (config.ts: backup.database.enabled), so without
  # this the nightly job fails silently.
  local backup_service=server/src/services/database-backup.service.ts
  git checkout -- "$backup_service"
  python3 "$REPO_ROOT/scripts/patch-postgres-bin-path.py" "$backup_service"

  # Route each model family through the CoreML representation it can actually
  # compile, and work around ORT's multi-gigabyte MLProgram constant bug. Keep
  # MACHINE_LEARNING_DISABLE_COREML=1 as a CPU escape hatch. See UPGRADING.md
  # 5.9 for the failure modes and measurements behind this policy.
  local ml_root=machine-learning
  local ml_files=(
    immich_ml/__main__.py
    immich_ml/models/constants.py
    immich_ml/sessions/ort.py
    immich_ml/models/base.py
    immich_ml/models/clip/textual.py
    immich_ml/models/clip/visual.py
    immich_ml/models/facial_recognition/detection.py
    immich_ml/models/facial_recognition/recognition.py
    immich_ml/models/ocr/detection.py
    immich_ml/models/ocr/recognition.py
  )
  local ml_file
  for ml_file in "${ml_files[@]}"; do
    git checkout -- "$ml_root/$ml_file"
  done
  python3 "$REPO_ROOT/scripts/patch-coreml.py" "$ml_root"
}

# nix cannot read files inside a submodule (they are not tracked by the parent
# repo), so the libvips patch has to be vendored under nix/. Check it against
# the submodule so the copy cannot drift unnoticed.
check_vendored_patches() {
  local vendored="$REPO_ROOT/nix/patches/0001-put-other-loaders-ahead-of-dcrawload.patch"
  local upstream_patch="$REPO_ROOT/upstream/base-images/server/sources/libvips-patches/0001-put-other-loaders-ahead-of-dcrawload.patch"

  if [[ ! -f "$upstream_patch" ]]; then
    log "base-images submodule not checked out; skipping patch drift check"
    return 0
  fi

  if ! diff -q "$vendored" "$upstream_patch" >/dev/null; then
    die "nix/patches/ has drifted from upstream/base-images.
     Refresh it:  cp '$upstream_patch' '$vendored'
     then re-check UPGRADING.md 2.2 -- the patch may have changed meaning."
  fi
  log "vendored libvips patch matches base-images"
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

  # Upstream ships the CLI in the server image and links it onto PATH.
  log "building cli"
  pnpm --filter @immich/sdk --filter @immich/cli install --frozen-lockfile
  pnpm --filter @immich/sdk --filter @immich/cli build
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

  # pnpm reuses an already-built sharp from its store, so changing the vips in
  # nix/shell.nix does NOT by itself trigger a relink -- the deployed tree keeps
  # pointing at the old libvips. Upstream's server/Dockerfile rebuilds sharp
  # explicitly for the same reason. Do it unconditionally; it is cheap.
  log "rebuilding sharp against the current libvips"
  ( cd "$PREFIX/server/node_modules/sharp" && npm run build ) >/dev/null 2>&1 \
    || ( cd "$PREFIX/server/node_modules/sharp" && npm run build )

  local vips
  vips="$(cd "$PREFIX/server" && node -p 'require("sharp").versions.vips')" \
    || die "sharp is not loadable in the deployed tree"

  if [[ -n "${IMMICH_VIPS_VERSION:-}" && "$vips" != "$IMMICH_VIPS_VERSION" ]]; then
    die "sharp linked against libvips $vips, but the shell provides $IMMICH_VIPS_VERSION.
     sharp is probably using its own bundled libvips -- see UPGRADING.md 5.1."
  fi
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

deploy_cli() {
  log "deploying cli to $PREFIX/cli"
  rm -rf "$PREFIX/cli"

  cd "$SRC_DIR"
  pnpm --filter @immich/cli --prod --no-optional deploy "$PREFIX/cli"
}

install_wrappers() {
  log "installing wrappers in $PREFIX/bin"
  rm -rf "$PREFIX/bin"
  mkdir -p "$PREFIX/bin"

  # `immich` -- the upload/CLI tool. Upstream symlinks it onto PATH from the
  # server image.
  cat > "$PREFIX/bin/immich" <<WRAPPER
#!/usr/bin/env bash
exec "\$(command -v node)" "$PREFIX/cli/bin/immich" "\$@"
WRAPPER

  # `immich-admin` -- server maintenance commands (reset admin password, etc).
  # Same entrypoint as the server, dispatched by argv.
  cat > "$PREFIX/bin/immich-admin" <<WRAPPER
#!/usr/bin/env bash
cd "$PREFIX/server" || exit 1
export IMMICH_BUILD_DATA="$PREFIX/build"
exec "\$(command -v node)" "$PREFIX/server/dist/main" immich-admin "\$@"
WRAPPER

  chmod +x "$PREFIX/bin/immich" "$PREFIX/bin/immich-admin"
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
check_vendored_patches
patch_source
build_js
deploy_server
deploy_cli
assemble_build_data
build_ml
install_wrappers

printf '%s\n' "$IMMICH_VERSION" > "$PREFIX/immich-version"
log "built immich $IMMICH_VERSION into $PREFIX"
