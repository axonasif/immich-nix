#!/usr/bin/env bash
# Run the immich stack (postgres, redis, machine-learning, server) built by
# scripts/build.sh. Expects to run inside the flake devShell.
#
#   scripts/immich.sh {start|stop|restart|status|logs}
#
# Defaults keep everything under .local/ so a fresh checkout never touches an
# existing install. Point IMMICH_PGDATA and IMMICH_MEDIA_DIR at real data
# deliberately -- immich runs irreversible schema migrations on first start.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PREFIX="${IMMICH_PREFIX:-$REPO_ROOT/.local/immich-app}"
STATE="${IMMICH_STATE_DIR:-$REPO_ROOT/.local/immich-run}"

RUN_DIR="$STATE/run"
LOG_DIR="$STATE/log"
REDIS_DIR="$STATE/redis"
PGDATA="${IMMICH_PGDATA:-$STATE/postgres}"
MEDIA_DIR="${IMMICH_MEDIA_DIR:-$STATE/media}"
CACHE_DIR="${IMMICH_CACHE_DIR:-$MEDIA_DIR/cache}"
PGSOCKET_DIR="${IMMICH_PGSOCKET_DIR:-${TMPDIR:-/tmp}/immich-native-pgsocket}"

HTTP_HOST="${IMMICH_HTTP_HOST:-127.0.0.1}"
HTTP_PORT="${IMMICH_HTTP_PORT:-2283}"
ML_HOST="${IMMICH_ML_HOST:-127.0.0.1}"
ML_PORT="${IMMICH_ML_PORT:-3003}"
PG_PORT="${IMMICH_PG_PORT:-5433}"
REDIS_HOST="${IMMICH_REDIS_HOST:-127.0.0.1}"
REDIS_PORT="${IMMICH_REDIS_PORT:-6380}"
DB_VECTOR_EXTENSION="${IMMICH_DB_VECTOR_EXTENSION:-}"
DB_STORAGE_TYPE="${IMMICH_DB_STORAGE_TYPE:-${DB_STORAGE_TYPE:-SSD}}"
ML_WORKERS="${IMMICH_ML_WORKERS:-1}"
ML_WORKER_TIMEOUT="${IMMICH_ML_WORKER_TIMEOUT:-300}"

SERVER_PIDFILE="$RUN_DIR/server.pid"
ML_PIDFILE="$RUN_DIR/machine-learning.pid"
REDIS_PIDFILE="$RUN_DIR/redis.pid"

log() { printf '\033[1;36m[immich]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[immich]\033[0m %s\n' "$*" >&2; exit 1; }

[[ -d "$PREFIX/server" ]] || die "no build at $PREFIX -- run scripts/build.sh first"
command -v postgres >/dev/null || die "run inside the devShell: nix develop"

case "$DB_STORAGE_TYPE" in
  SSD|ssd) DB_STORAGE_TYPE=SSD ;;
  HDD|hdd) DB_STORAGE_TYPE=HDD ;;
  *) die "IMMICH_DB_STORAGE_TYPE (or DB_STORAGE_TYPE) must be SSD or HDD" ;;
esac

case "$DB_VECTOR_EXTENSION" in
  ""|pgvector|vectorchord) ;;
  *) die "IMMICH_DB_VECTOR_EXTENSION must be pgvector or vectorchord" ;;
esac

mkdir -p "$RUN_DIR" "$LOG_DIR" "$REDIS_DIR" "$PGSOCKET_DIR" "$MEDIA_DIR" "$CACHE_DIR"

# --- process group helpers ---------------------------------------------------
# Services are started in their own session so a single kill takes down the
# whole tree (node and gunicorn both fork workers).

pgid_running() { kill -0 -- "-$1" >/dev/null 2>&1; }

service_running() {
  local pidfile="$1" pgid
  [[ -f "$pidfile" ]] || return 1
  pgid="$(cat "$pidfile" 2>/dev/null || true)"
  [[ -n "$pgid" ]] || return 1
  if pgid_running "$pgid"; then return 0; fi
  rm -f "$pidfile"
  return 1
}

start_service() {
  local name="$1" pidfile="$2" logfile="$3"
  shift 3

  if service_running "$pidfile"; then
    log "$name already running"
    return 0
  fi

  log "starting $name"
  nohup perl -MPOSIX=setsid \
    -e 'setsid() or die "setsid: $!"; exec @ARGV or die "exec: $!";' \
    -- "$@" >>"$logfile" 2>&1 </dev/null &
  echo "$!" >"$pidfile"
}

stop_service() {
  local name="$1" pidfile="$2" pgid

  [[ -f "$pidfile" ]] || return 0
  pgid="$(cat "$pidfile" 2>/dev/null || true)"
  if [[ -z "$pgid" ]] || ! pgid_running "$pgid"; then
    rm -f "$pidfile"
    return 0
  fi

  log "stopping $name"
  kill -TERM -- "-$pgid" >/dev/null 2>&1 || true
  for _ in $(seq 1 30); do
    pgid_running "$pgid" || { rm -f "$pidfile"; return 0; }
    sleep 1
  done

  log "$name ignored SIGTERM, sending SIGKILL"
  kill -KILL -- "-$pgid" >/dev/null 2>&1 || true
  rm -f "$pidfile"
}

wait_for_http() {
  local url="$1" name="$2" pidfile="$3" tries="${4:-90}"
  for _ in $(seq 1 "$tries"); do
    curl -fsS "$url" >/dev/null 2>&1 && return 0
    sleep 1
    if ! service_running "$pidfile"; then
      log "$name exited before becoming healthy (see $LOG_DIR)"
      return 1
    fi
  done
  log "$name did not become healthy in time (see $LOG_DIR)"
  return 1
}

# --- postgres ----------------------------------------------------------------

start_postgres() {
  local postgres_options
  postgres_options="-c listen_addresses=127.0.0.1 -c port=$PG_PORT -c unix_socket_directories=$PGSOCKET_DIR"
  postgres_options+=" -c shared_preload_libraries=vchord"
  postgres_options+=" -c 'search_path=\"\$user\", public'"
  postgres_options+=" -c max_wal_size=5GB -c shared_buffers=512MB -c wal_compression=on -c work_mem=16MB"
  postgres_options+=" -c autovacuum_vacuum_scale_factor=0.1 -c autovacuum_analyze_scale_factor=0.05 -c autovacuum_vacuum_cost_limit=1000"
  if [[ "$DB_STORAGE_TYPE" == SSD ]]; then
    postgres_options+=" -c random_page_cost=1.2"
    if [[ "$(uname -s)" == Darwin ]]; then
      # PostgreSQL rejects nonzero values without posix_fadvise(), which Darwin
      # does not provide. random_page_cost still reflects SSD access costs.
      postgres_options+=" -c effective_io_concurrency=0"
    else
      postgres_options+=" -c effective_io_concurrency=200"
    fi
  fi

  if [[ ! -e "$PGDATA/PG_VERSION" ]]; then
    log "initializing postgres cluster at $PGDATA"
    mkdir -p "$PGDATA"
    # External volumes often carry .Spotlight-V100 / .fseventsd, which initdb
    # refuses to write into; initialize elsewhere and copy the cluster in.
    if [[ -n "$(find "$PGDATA" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
      local tmp
      tmp="$(mktemp -d "$STATE/initdb.XXXXXX")"
      initdb -D "$tmp" --username=postgres --encoding=UTF8 --locale=C --auth=trust --data-checksums >/dev/null
      cp -R "$tmp"/. "$PGDATA"/
      rm -rf "$tmp"
    else
      initdb -D "$PGDATA" --username=postgres --encoding=UTF8 --locale=C --auth=trust --data-checksums >/dev/null
    fi
  fi

  if ! pg_ctl -D "$PGDATA" status >/dev/null 2>&1; then
    log "starting postgres on port $PG_PORT ($DB_STORAGE_TYPE storage)"
    pg_ctl -D "$PGDATA" -l "$LOG_DIR/postgres.log" \
      -o "$postgres_options" \
      start >/dev/null
  fi

  local postgres_ready=false
  for _ in $(seq 1 30); do
    if pg_isready -h 127.0.0.1 -p "$PG_PORT" -U postgres >/dev/null 2>&1; then
      postgres_ready=true
      break
    fi
    sleep 1
  done
  [[ "$postgres_ready" == true ]] || die "postgres did not become ready (see $LOG_DIR/postgres.log)"

  # The upstream postgres entrypoint creates only the configured database.
  # Immich itself creates and updates extensions, then runs schema migrations.
  log "ensuring immich database"
  psql -v ON_ERROR_STOP=1 -h 127.0.0.1 -p "$PG_PORT" -U postgres postgres >/dev/null <<'SQL'
SELECT 'CREATE DATABASE immich OWNER postgres'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'immich') \gexec
SQL
}

stop_postgres() {
  if [[ -e "$PGDATA/PG_VERSION" ]] && pg_ctl -D "$PGDATA" status >/dev/null 2>&1; then
    log "stopping postgres"
    pg_ctl -D "$PGDATA" stop -m fast >/dev/null || true
  fi
}

# --- redis -------------------------------------------------------------------

start_redis() {
  if [[ -f "$REDIS_PIDFILE" ]] && kill -0 "$(cat "$REDIS_PIDFILE")" >/dev/null 2>&1; then
    log "redis already running"
    return 0
  fi

  log "starting redis on port $REDIS_PORT"
  redis-server \
    --bind "$REDIS_HOST" --port "$REDIS_PORT" \
    --save '' --appendonly no --daemonize yes \
    --dir "$REDIS_DIR" --pidfile "$REDIS_PIDFILE" \
    --logfile "$LOG_DIR/redis.log"

  for _ in $(seq 1 30); do
    redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" ping >/dev/null 2>&1 && return 0
    sleep 1
  done
  die "redis did not become ready"
}

stop_redis() {
  if [[ -f "$REDIS_PIDFILE" ]] && kill -0 "$(cat "$REDIS_PIDFILE")" >/dev/null 2>&1; then
    log "stopping redis"
    redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" shutdown nosave >/dev/null 2>&1 || true
    rm -f "$REDIS_PIDFILE"
  fi
}

# --- machine learning --------------------------------------------------------

start_ml() {
  start_service "machine-learning on $ML_HOST:$ML_PORT" "$ML_PIDFILE" \
    "$LOG_DIR/machine-learning.log" \
    env -C "$PREFIX/machine-learning" \
    PATH="$PREFIX/machine-learning/.venv/bin:$PATH" \
    VIRTUAL_ENV="$PREFIX/machine-learning/.venv" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    TRANSFORMERS_CACHE="$CACHE_DIR" \
    MACHINE_LEARNING_CACHE_FOLDER="$CACHE_DIR" \
    MACHINE_LEARNING_WORKERS="$ML_WORKERS" \
    MACHINE_LEARNING_WORKER_TIMEOUT="$ML_WORKER_TIMEOUT" \
    XDG_CACHE_HOME="$CACHE_DIR" \
    IMMICH_HOST="$ML_HOST" \
    IMMICH_PORT="$ML_PORT" \
    `# huggingface's xet transfer backend is unreliable on darwin` \
    HF_HUB_DISABLE_XET=1 \
    "$PREFIX/machine-learning/.venv/bin/python" -m immich_ml

  wait_for_http "http://$ML_HOST:$ML_PORT/ping" "machine-learning" "$ML_PIDFILE"
}

# --- server ------------------------------------------------------------------

start_server() {
  local vector_extension_env=()
  if [[ -n "$DB_VECTOR_EXTENSION" ]]; then
    vector_extension_env+=("DB_VECTOR_EXTENSION=$DB_VECTOR_EXTENSION")
  fi

  start_service "immich server on $HTTP_HOST:$HTTP_PORT" "$SERVER_PIDFILE" \
    "$LOG_DIR/server.log" \
    env -C "$PREFIX/server" \
    NODE_ENV=production \
    IMMICH_BUILD_DATA="$PREFIX/build" \
    IMMICH_MEDIA_LOCATION="$MEDIA_DIR" \
    IMMICH_HOST="$HTTP_HOST" \
    IMMICH_PORT="$HTTP_PORT" \
    IMMICH_MACHINE_LEARNING_URL="http://$ML_HOST:$ML_PORT" \
    DB_URL="postgresql://postgres@127.0.0.1:$PG_PORT/immich" \
    "${vector_extension_env[@]}" \
    REDIS_HOSTNAME="$REDIS_HOST" \
    REDIS_PORT="$REDIS_PORT" \
    node "$PREFIX/server/dist/main"

  wait_for_http "http://$HTTP_HOST:$HTTP_PORT/api/server/ping" "immich server" "$SERVER_PIDFILE"
}

# --- commands ----------------------------------------------------------------

do_start() {
  start_postgres
  start_redis
  start_ml
  start_server
  do_status
}

do_stop() {
  stop_service "immich server" "$SERVER_PIDFILE"
  stop_service "machine-learning" "$ML_PIDFILE"
  stop_redis
  stop_postgres
}

do_status() {
  printf '\n'
  log "build:   $PREFIX ($(cat "$PREFIX/immich-version" 2>/dev/null || echo unknown))"
  log "state:   $STATE"
  log "pgdata:  $PGDATA"
  log "storage: $DB_STORAGE_TYPE"
  log "media:   $MEDIA_DIR"
  log "logs:    $LOG_DIR"
  printf '\n'

  local server_ping ml_ping
  server_ping="$(curl -fsS "http://$HTTP_HOST:$HTTP_PORT/api/server/ping" 2>/dev/null || echo 'down')"
  ml_ping="$(curl -fsS "http://$ML_HOST:$ML_PORT/ping" 2>/dev/null || echo 'down')"

  log "server   http://$HTTP_HOST:$HTTP_PORT  -> $server_ping"
  log "ml       http://$ML_HOST:$ML_PORT  -> $ml_ping"
  printf '\n'
}

case "${1:-start}" in
  start) do_start ;;
  stop) do_stop ;;
  restart) do_stop; do_start ;;
  status) do_status ;;
  logs) tail -n "${2:-50}" -F "$LOG_DIR"/*.log ;;
  *) die "usage: $0 {start|stop|restart|status|logs}" ;;
esac
