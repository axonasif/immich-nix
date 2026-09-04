#!/usr/bin/env bash
# Exercise the native deployment boundary without depending on upstream's
# Docker-oriented E2E harness.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFIX="${IMMICH_PREFIX:-$REPO_ROOT/.local/immich-app}"
TEST_ROOT="${IMMICH_TEST_ROOT:-$REPO_ROOT/.local/immich-test}"
TEST_RUNTIME="$TEST_ROOT/runtime"
FIXTURES="$TEST_ROOT/fixtures"
TEST_HOME="$TEST_ROOT/home"
REAL_HOME="$HOME"
MODE="${1:-full}"

log() { printf '\033[1;36m[test]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[test]\033[0m %s\n' "$*" >&2; exit 1; }

case "$MODE" in
  quick|full) ;;
  *) die "usage: $0 [quick|full]" ;;
esac

[[ -n "${IN_NIX_SHELL:-}${IMMICH_GEODATA:-}" ]] \
  || die "run inside the devShell: nix develop --command scripts/test.sh"
[[ "$TEST_ROOT" == "$REPO_ROOT/.local/immich-test" || -n "${IMMICH_TEST_ROOT:-}" ]] \
  || die "refusing an unresolved test root"

export IMMICH_STATE_DIR="$TEST_RUNTIME"
export IMMICH_PGDATA="$TEST_RUNTIME/postgres"
export IMMICH_PGSOCKET_DIR="$TEST_RUNTIME/postgres-socket"
export IMMICH_MEDIA_DIR="$TEST_RUNTIME/media"
export IMMICH_CACHE_DIR="$TEST_ROOT/model-cache"
export IMMICH_HTTP_HOST=127.0.0.1
export IMMICH_HTTP_PORT=2285
export IMMICH_ML_HOST=127.0.0.1
export IMMICH_ML_PORT=3005
export IMMICH_PG_PORT=5435
export IMMICH_REDIS_HOST=127.0.0.1
export IMMICH_REDIS_PORT=6385
export IMMICH_IGNORE_MOUNT_CHECK_ERRORS=true
if [[ "$MODE" == full ]]; then
  export IMMICH_MACHINE_LEARNING_ENABLED=true
  export IMMICH_TEST_FULL=true
  export IMMICH_TEST_TIMEOUT=1200
else
  export IMMICH_MACHINE_LEARNING_ENABLED=false
  export IMMICH_TEST_FULL=false
fi
export IMMICH_TEST_SMART_SEARCH_MODEL=ViT-SO400M-16-SigLIP2-384__webli
export IMMICH_TEST_FACE_MODEL=buffalo_l
export IMMICH_TEST_OCR_MODEL=PP-OCRv5_server

# Everything launched by this script sees a disposable, repository-local home.
export HOME="$TEST_HOME"
export XDG_CACHE_HOME="$HOME/.cache"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_STATE_HOME="$HOME/.local/state"
export PNPM_HOME="$XDG_DATA_HOME/pnpm"
export COREPACK_HOME="$XDG_CACHE_HOME/node/corepack"
export npm_config_cache="$HOME/.npm"
export UV_CACHE_DIR="$XDG_CACHE_HOME/uv"
export HF_HOME="$XDG_CACHE_HOME/huggingface"

export IMMICH_TEST_BASE_URL="http://$IMMICH_HTTP_HOST:$IMMICH_HTTP_PORT/api"
export IMMICH_TEST_CLI="$PREFIX/bin/immich"
export IMMICH_TEST_FIXTURES="$FIXTURES"
export IMMICH_TEST_STATE="$TEST_ROOT/smoke-state.json"
export IMMICH_SMOKE_IMAGE="$REPO_ROOT/upstream/immich/design/immich-screenshots.png"
export IMMICH_ML_URL="http://$IMMICH_ML_HOST:$IMMICH_ML_PORT"

cleanup() {
  local status=$?
  set +e
  "$REPO_ROOT/scripts/immich.sh" stop >/dev/null 2>&1
  if (( status != 0 )); then
    log "FAILED; logs and disposable state are in $TEST_ROOT"
  fi
  return "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

reset_state() {
  if [[ -d "$TEST_RUNTIME" ]]; then
    "$REPO_ROOT/scripts/immich.sh" stop >/dev/null 2>&1 || true
  fi
  # Keep downloaded ML models while replacing every mutable test fixture and
  # service data directory. The database and media store are always fresh.
  rm -rf "$TEST_RUNTIME" "$FIXTURES" "$TEST_HOME" "$IMMICH_TEST_STATE" "$TEST_ROOT/cli-config"
  mkdir -p "$TEST_RUNTIME" "$FIXTURES" "$TEST_HOME" "$IMMICH_CACHE_DIR"
  touch "$TEST_ROOT/started-at"
}

ensure_build() {
  local expected actual
  expected="$(cat "$REPO_ROOT/immich-version")"
  actual="$(cat "$PREFIX/immich-version" 2>/dev/null || true)"
  if [[ "$actual" != "$expected" ]]; then
    log "building Immich $expected"
    "$REPO_ROOT/scripts/build.sh"
  else
    log "using existing Immich $actual build"
  fi
}

create_fixtures() {
  log "creating disposable photo and video fixtures"
  magick -size 640x480 plasma:fractal \
    -colorspace sRGB -quality 90 "$FIXTURES/native-photo.jpg"
  cp "$IMMICH_SMOKE_IMAGE" "$FIXTURES/immich-screenshot.png"
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i 'testsrc2=size=320x240:rate=15' -t 2 \
    -c:v mpeg4 -q:v 5 "$FIXTURES/native-video.mp4"
}

assert_build_contract() {
  local expected_vips actual_vips formats providers cli_version
  expected_vips="${IMMICH_VIPS_VERSION:-}"
  actual_vips="$(cd "$PREFIX/server" && node -p 'require("sharp").versions.vips')"
  [[ -z "$expected_vips" || "$actual_vips" == "$expected_vips" ]] \
    || die "sharp uses libvips $actual_vips; expected $expected_vips"

  formats="$(cd "$PREFIX/server" && node -p \
    'const s=require("sharp");[!!s.format.heif,!!s.format.jxl,!!s.format.webp].join()')"
  [[ "$formats" == true,true,true ]] || die "sharp is missing HEIC, JXL, or WebP support: $formats"

  providers="$("$PREFIX/machine-learning/.venv/bin/python" -c \
    'import onnxruntime; print(",".join(onnxruntime.get_available_providers()))')"
  [[ "$providers" == *CPUExecutionProvider* ]] || die "ONNX Runtime has no CPU provider: $providers"
  if [[ "$(uname -s)" == Darwin ]]; then
    [[ "$providers" == *CoreMLExecutionProvider* ]] || die "ONNX Runtime has no CoreML provider: $providers"
  fi

  cli_version="$("$PREFIX/bin/immich" --version)"
  [[ "v$cli_version" == "$(cat "$PREFIX/immich-version")" ]] \
    || die "deployed CLI version $cli_version does not match the build"
  [[ -r "$PREFIX/build/www/index.html" ]] || die "deployed web application is missing"
  [[ -r "$PREFIX/build/geodata/geodata-date.txt" ]] || die "deployed geodata is missing"
  [[ -r "$PREFIX/build/plugins/immich-plugin-core/dist/plugin.wasm" ]] \
    || die "deployed core plugin is missing"

  python3 -m unittest discover -s "$REPO_ROOT/tests" -p 'test_*.py'
  log "build contract passed (libvips $actual_vips; ONNX: $providers)"
}

assert_runtime_contract() {
  local http_code checksum extensions indexes
  curl -fsS "$IMMICH_TEST_BASE_URL/server/ping" >/dev/null
  [[ "$(curl -fsS "http://$IMMICH_ML_HOST:$IMMICH_ML_PORT/ping")" == pong ]]
  http_code="$(curl -sS -o /dev/null -w '%{http_code}' "http://$IMMICH_HTTP_HOST:$IMMICH_HTTP_PORT/")"
  [[ "$http_code" == 200 ]] || die "web application returned HTTP $http_code"
  [[ "$(valkey-cli -h "$IMMICH_REDIS_HOST" -p "$IMMICH_REDIS_PORT" ping)" == PONG ]]

  extensions="$(psql -h 127.0.0.1 -p "$IMMICH_PG_PORT" -U postgres immich -Atc \
    "SELECT extname FROM pg_extension WHERE extname = 'vchord'")"
  [[ "$extensions" == vchord ]] || die "VectorChord extension is not installed"
  [[ "$(psql -h 127.0.0.1 -p "$IMMICH_PG_PORT" -U postgres immich -Atc \
    'SHOW shared_preload_libraries')" == *vchord* ]] || die "VectorChord is not preloaded"
  indexes="$(psql -h 127.0.0.1 -p "$IMMICH_PG_PORT" -U postgres immich -Atc \
    "SELECT count(*) FROM pg_indexes WHERE indexname IN ('clip_index', 'face_index') AND indexdef LIKE '%vchordrq%'")"
  [[ "$indexes" == 2 ]] || die "VectorChord search indexes are missing"
  checksum="$(psql -h 127.0.0.1 -p "$IMMICH_PG_PORT" -U postgres immich -Atc \
    'SELECT COALESCE(SUM(checksum_failures), 0) FROM pg_stat_database')"
  [[ "$checksum" == 0 ]] || die "PostgreSQL reported $checksum checksum failures"

  for _ in $(seq 1 30); do
    grep -qi 'Imported plugin immich-plugin-core' "$TEST_RUNTIME/log/server.log" && break
    sleep 1
  done
  grep -qi 'Imported plugin immich-plugin-core' "$TEST_RUNTIME/log/server.log" \
    || die "core plugin was not imported"
  log "native service contract passed"
}

assert_no_host_pollution() {
  local path changed=false
  for path in \
    "$REAL_HOME/.cache/huggingface" \
    "$REAL_HOME/.cache/uv" \
    "$REAL_HOME/.cache/corepack" \
    "$REAL_HOME/.local/share/uv" \
    "$REAL_HOME/.local/share/pnpm" \
    "$REAL_HOME/.npm" \
    "$REAL_HOME/.config/immich"; do
    [[ -d "$path" ]] || continue
    if find "$path" -type f -newer "$TEST_ROOT/started-at" -print -quit 2>/dev/null | grep -q .; then
      log "unexpected host-home write under $path"
      changed=true
    fi
  done
  [[ "$changed" == false ]] || die "test tools wrote outside the repository-local home"
}

reset_state
ensure_build
create_fixtures
assert_build_contract

log "starting fresh native stack"
"$REPO_ROOT/scripts/immich.sh" start
assert_runtime_contract

log "exercising authentication, CLI upload, metadata, thumbnails, and video playback"
"$PREFIX/machine-learning/.venv/bin/python" "$REPO_ROOT/tests/native-smoke.py" create

log "restarting the complete stack and verifying persisted media"
"$REPO_ROOT/scripts/immich.sh" restart
assert_runtime_contract
"$PREFIX/machine-learning/.venv/bin/python" "$REPO_ROOT/tests/native-smoke.py" verify

if [[ "$MODE" == full ]]; then
  log "running real CLIP, face, and OCR inference (model downloads may take a while)"
  "$PREFIX/machine-learning/.venv/bin/python" "$REPO_ROOT/tests/ml-smoke.py"
fi

log "deleting uploaded assets and checking physical cleanup"
"$PREFIX/machine-learning/.venv/bin/python" "$REPO_ROOT/tests/native-smoke.py" delete

log "stopping the native stack"
"$REPO_ROOT/scripts/immich.sh" stop
for port in "$IMMICH_HTTP_PORT" "$IMMICH_ML_PORT" "$IMMICH_PG_PORT" "$IMMICH_REDIS_PORT"; do
  [[ -z "$(lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null || true)" ]] \
    || die "port $port is still held after shutdown"
done
assert_no_host_pollution

trap - EXIT INT TERM
log "all $MODE native integration tests passed"
