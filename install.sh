#!/usr/bin/env bash
#
# install.sh (thin) — deploy buzz-relay by reusing the repo's own scripts.
#
# Delegates to upstream wherever upstream has a working path:
#   .env            <- cp .env.example, then patch (inherits new upstream vars)
#   datastores      <- repo docker-compose.yml + our override, named services only
#   migrate + seed  <- `just migrate`, which is upstream _ensure-migrations
#                      (cargo run -p buzz-admin -- migrate; scripts/seed-local-community.sh)
#
# Deliberately does NOT use:
#   `just setup`  -> runs scripts/dev-setup.sh, which also does `pnpm install`
#                    for desktop deps and starts all six compose services.
#   `just build`  -> `cargo build --workspace`, builds the desktop and agent
#                    crates you do not need on a relay box.
#
# Both .env and docker-compose.override.yml are gitignored or untracked, so
# `git pull` will not clobber them.

set -euo pipefail

REPO_URL="https://github.com/block/buzz.git"
INSTALL_DIR="/opt/buzz-relay"
RELAY_HOST=""
RUN_USER="${SUDO_USER:-$(id -un)}"
DO_SYSTEMD=1
DO_UPDATE=0

# Port defaults for a FRESH install. On a re-run the value already in .env wins,
# so ports edited by hand on the box survive; a port only changes on re-run if
# its flag is passed explicitly. The flag vars start empty ("not passed") and
# are resolved to these defaults only when first creating .env.
DEFAULT_RELAY_PORT=3000
DEFAULT_HEALTH_PORT=8080
DEFAULT_METRICS_PORT=9102
DEFAULT_PG_PORT=5432
DEFAULT_REDIS_PORT=6379
DEFAULT_MINIO_PORT=9000
DEFAULT_MINIO_CONSOLE_PORT=9001
RELAY_PORT=""
HEALTH_PORT=""
METRICS_PORT=""
PG_PORT=""
REDIS_PORT=""
MINIO_PORT=""
MINIO_CONSOLE_PORT=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
log()  { printf '\033[1;33m[relay]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;35m[relay] warn:\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[relay] error:\033[0m %s\n' "$*" >&2; exit 1; }

# Set KEY=VALUE in an env file: patch the line in place if present, else append
# it. Runs file ops as $RUN_USER so ownership stays correct. Value must not
# contain a literal '|' (sed delimiter); ports and localhost URLs never do.
ensure_kv() {
  local file="$1" key="$2" val="$3"
  if sudo -u "$RUN_USER" grep -q "^${key}=" "$file"; then
    sudo -u "$RUN_USER" sed -i -e "s|^${key}=.*|${key}=${val}|" "$file"
  else
    printf '%s=%s\n' "$key" "$val" | sudo -u "$RUN_USER" tee -a "$file" >/dev/null
  fi
}

usage() {
  cat <<EOF
Usage: sudo ./install.sh --host HOST [port options] [--update] [--dir PATH] [--user NAME] [--no-systemd]

--host is required: the canonical authority every client will use. It becomes
RELAY_URL and the seeded community host. Each authority is a separate community.

Port options (every listener the stack binds on the host — override any that
collide on a shared box; all bind loopback except the relay). Defaults apply to
a fresh install; on a re-run the value already in .env is kept unless you pass
the flag again, so ports you edit directly in .env on the box persist:
  --port N                relay listener (RELAY_URL / BUZZ_BIND_ADDR), default 3000
  --health-port N         relay health probe (BUZZ_HEALTH_PORT),       default 8080
  --metrics-port N        relay Prometheus (BUZZ_METRICS_PORT),        default 9102
  --pg-port N             Postgres host port,                          default 5432
  --redis-port N          Redis host port,                             default 6379
  --minio-port N          MinIO S3 API host port,                      default 9000
  --minio-console-port N  MinIO console host port,                     default 9001

Other options:
  --update                git pull the upstream buzz checkout before rebuilding
  --dir PATH              install root (default /opt/buzz-relay)
  --user NAME             owner/runtime user (default: invoking user)
  --no-systemd            skip installing the systemd unit
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) RELAY_HOST="$2"; shift 2 ;;
    --port) RELAY_PORT="$2"; shift 2 ;;
    --health-port)  HEALTH_PORT="$2"; shift 2 ;;
    --metrics-port) METRICS_PORT="$2"; shift 2 ;;
    --pg-port)            PG_PORT="$2"; shift 2 ;;
    --redis-port)         REDIS_PORT="$2"; shift 2 ;;
    --minio-port)         MINIO_PORT="$2"; shift 2 ;;
    --minio-console-port) MINIO_CONSOLE_PORT="$2"; shift 2 ;;
    --dir)  INSTALL_DIR="$2"; shift 2 ;;
    --user) RUN_USER="$2"; shift 2 ;;
    --no-systemd) DO_SYSTEMD=0; shift ;;
    --update) DO_UPDATE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done
[[ -z "$RELAY_HOST" ]] && { usage; die "--host is required."; }

for cmd in git docker openssl; do
  command -v "$cmd" >/dev/null 2>&1 || die "$cmd not found."
done
docker info >/dev/null 2>&1 || die "Docker daemon not reachable."
docker compose version >/dev/null 2>&1 || die "Docker Compose plugin not found."
[[ "$DO_SYSTEMD" -eq 1 && "$(id -u)" -ne 0 ]] && die "Need root for systemd. Use sudo or --no-systemd."
id "$RUN_USER" >/dev/null 2>&1 || die "User '$RUN_USER' does not exist."
[[ -f "$SCRIPT_DIR/docker-compose.override.yml" ]] || die "docker-compose.override.yml missing."

SRC="$INSTALL_DIR/src"
mkdir -p "$INSTALL_DIR"

# ---- clone -----------------------------------------------------------------
# --update pulls the upstream buzz source ($SRC), not this deploy repo. To pick
# up changes to install.sh / the unit / the override, git pull this repo and
# re-run. The clone is shallow, so a plain ff-only pull is enough.
if [[ -d "$SRC/.git" ]]; then
  log "Existing checkout at $SRC"
  if [[ "$DO_UPDATE" -eq 1 ]]; then
    log "Updating upstream checkout (git pull --ff-only)"
    sudo -u "$RUN_USER" git -C "$SRC" pull --ff-only
  fi
else
  log "Cloning"
  sudo -u "$RUN_USER" git clone --depth 1 "$REPO_URL" "$SRC"
fi
chown -R "$RUN_USER":"$RUN_USER" "$INSTALL_DIR" 2>/dev/null || true

# ---- .env: start from upstream, then patch ---------------------------------
# Copying .env.example rather than templating it means new upstream variables
# are inherited on future re-installs instead of silently missing.
if [[ -f "$SRC/.env" ]]; then
  log ".env exists; re-applying host, keeping ports unless a flag overrides"
  # The relay port lives in both RELAY_URL and BUZZ_BIND_ADDR alongside the host.
  # --host is re-applied every run, so preserve the existing relay port (unless
  # --port was passed) instead of resetting it: read it back from BUZZ_BIND_ADDR.
  cur_relay_port="$(sudo -u "$RUN_USER" sed -n 's|^BUZZ_BIND_ADDR=0\.0\.0\.0:\([0-9]\{1,\}\).*|\1|p' "$SRC/.env" | head -1)"
  rp="${RELAY_PORT:-${cur_relay_port:-$DEFAULT_RELAY_PORT}}"
  RELAY_PORT="$rp"   # the effective relay port, for the log/summary lines below
  ensure_kv "$SRC/.env" RELAY_URL      "ws://${RELAY_HOST}:${rp}"
  ensure_kv "$SRC/.env" BUZZ_BIND_ADDR "0.0.0.0:${rp}"
  # Every other port is only touched when its flag is passed, so hand edits in
  # .env survive a re-run.
  [[ -n "$HEALTH_PORT"  ]] && ensure_kv "$SRC/.env" BUZZ_HEALTH_PORT  "$HEALTH_PORT"
  [[ -n "$METRICS_PORT" ]] && ensure_kv "$SRC/.env" BUZZ_METRICS_PORT "$METRICS_PORT"
  if [[ -n "$PG_PORT" ]]; then
    ensure_kv "$SRC/.env" PGPORT        "$PG_PORT"
    ensure_kv "$SRC/.env" POSTGRES_PORT "$PG_PORT"
    # DATABASE_URL carries the PG password, so swap only its port, not the line.
    sudo -u "$RUN_USER" sed -i -e "s|^\(DATABASE_URL=postgres://[^@]*@localhost:\)[0-9]*|\1${PG_PORT}|" "$SRC/.env"
  fi
  if [[ -n "$REDIS_PORT" ]]; then
    ensure_kv "$SRC/.env" REDIS_URL  "redis://localhost:${REDIS_PORT}"
    ensure_kv "$SRC/.env" REDIS_PORT "$REDIS_PORT"
  fi
  if [[ -n "$MINIO_PORT" ]]; then
    ensure_kv "$SRC/.env" BUZZ_S3_ENDPOINT "http://localhost:${MINIO_PORT}"
    ensure_kv "$SRC/.env" MINIO_PORT       "$MINIO_PORT"
  fi
  [[ -n "$MINIO_CONSOLE_PORT" ]] && ensure_kv "$SRC/.env" MINIO_CONSOLE_PORT "$MINIO_CONSOLE_PORT"
else
  log "Creating .env from upstream .env.example and patching"
  # Fresh install: resolve each port to its flag value or the default.
  RELAY_PORT="${RELAY_PORT:-$DEFAULT_RELAY_PORT}"
  HEALTH_PORT="${HEALTH_PORT:-$DEFAULT_HEALTH_PORT}"
  METRICS_PORT="${METRICS_PORT:-$DEFAULT_METRICS_PORT}"
  PG_PORT="${PG_PORT:-$DEFAULT_PG_PORT}"
  REDIS_PORT="${REDIS_PORT:-$DEFAULT_REDIS_PORT}"
  MINIO_PORT="${MINIO_PORT:-$DEFAULT_MINIO_PORT}"
  MINIO_CONSOLE_PORT="${MINIO_CONSOLE_PORT:-$DEFAULT_MINIO_CONSOLE_PORT}"
  PG="$(openssl rand -hex 24)"
  S3="$(openssl rand -hex 24)"
  KEY="$(openssl rand -hex 32)"

  sudo -u "$RUN_USER" cp "$SRC/.env.example" "$SRC/.env"

  # Replace the upstream dev values that exist in .env.example.
  sudo -u "$RUN_USER" sed -i \
    -e "s|^RELAY_URL=.*|RELAY_URL=ws://${RELAY_HOST}:${RELAY_PORT}|" \
    -e "s|^BUZZ_BIND_ADDR=.*|BUZZ_BIND_ADDR=0.0.0.0:${RELAY_PORT}|" \
    -e "s|^DATABASE_URL=.*|DATABASE_URL=postgres://buzz:${PG}@localhost:${PG_PORT}/buzz|" \
    -e "s|^PGPASSWORD=.*|PGPASSWORD=${PG}|" \
    -e "s|^PGPORT=.*|PGPORT=${PG_PORT}|" \
    -e "s|^REDIS_URL=.*|REDIS_URL=redis://localhost:${REDIS_PORT}|" \
    -e "s|^RUST_LOG=.*|RUST_LOG=buzz_relay=info,buzz_db=info,buzz_auth=info,buzz_pubsub=info,tower_http=warn|" \
    "$SRC/.env"

  # Append what .env.example does not define. The S3 and relay-key variables
  # default to dev values IN CODE, so omitting them keeps dev creds silently.
  sudo -u "$RUN_USER" tee -a "$SRC/.env" >/dev/null <<EOF

# ---- added by install.sh ----
POSTGRES_USER=buzz
POSTGRES_PASSWORD=${PG}
POSTGRES_DB=buzz

BUZZ_S3_ENDPOINT=http://localhost:${MINIO_PORT}
BUZZ_S3_ACCESS_KEY=buzzrelay
BUZZ_S3_SECRET_KEY=${S3}
BUZZ_S3_BUCKET=buzz-media
BUZZ_S3_REGION=us-east-1

BUZZ_RELAY_PRIVATE_KEY=${KEY}
BUZZ_REQUIRE_AUTH_TOKEN=false

# Auxiliary relay listeners. Defaults (8080, 9102) collide easily on a shared
# host; set with --health-port / --metrics-port, or edit and restart the service.
BUZZ_HEALTH_PORT=${HEALTH_PORT}
BUZZ_METRICS_PORT=${METRICS_PORT}

# Host-published datastore ports. docker-compose.override.yml interpolates these
# to decide what each container binds on the host; the container-internal ports
# stay fixed, so inter-container DNS (e.g. minio:9000) is unaffected. Override
# with --pg-port / --redis-port / --minio-port / --minio-console-port.
POSTGRES_PORT=${PG_PORT}
REDIS_PORT=${REDIS_PORT}
MINIO_PORT=${MINIO_PORT}
MINIO_CONSOLE_PORT=${MINIO_CONSOLE_PORT}
EOF
fi
chmod 600 "$SRC/.env"
chown "$RUN_USER":"$RUN_USER" "$SRC/.env"

# ---- compose override ------------------------------------------------------
log "Installing docker-compose.override.yml"
cp -f "$SCRIPT_DIR/docker-compose.override.yml" "$SRC/docker-compose.override.yml"
chown "$RUN_USER":"$RUN_USER" "$SRC/docker-compose.override.yml"

# ---- build only the relay --------------------------------------------------
log "Building buzz-relay and buzz-admin (release)"
sudo -u "$RUN_USER" bash -lc "
  cd '$SRC' &&
  if [[ -f ./bin/activate-hermit ]]; then . ./bin/activate-hermit; fi &&
  cargo build --release -p buzz-relay -p buzz-admin
" || die "Build failed."

# ---- datastores: repo compose + override, named services only --------------
log "Starting datastores (repo compose + override)"
sudo -u "$RUN_USER" bash -lc "
  cd '$SRC' && docker compose up -d postgres redis minio minio-init
" || die "Compose failed."

log "Waiting for Postgres"
for _ in $(seq 1 60); do
  s="$(docker inspect -f '{{.State.Health.Status}}' buzz-postgres 2>/dev/null || echo starting)"
  [[ "$s" == "healthy" ]] && break; sleep 2
done
[[ "${s:-}" == "healthy" ]] || die "Postgres unhealthy. docker logs buzz-postgres"

# ---- migrate + seed: upstream target --------------------------------------
# `just migrate` == _ensure-migrations == buzz-admin migrate + seed-local-community.sh
log "Running 'just migrate' (upstream migrate + community host seed)"
sudo -u "$RUN_USER" bash -lc "
  cd '$SRC' &&
  if [[ -f ./bin/activate-hermit ]]; then . ./bin/activate-hermit; fi &&
  just migrate
" || die "'just migrate' failed."

# ---- systemd ---------------------------------------------------------------
if [[ "$DO_SYSTEMD" -eq 1 ]]; then
  log "Installing unit"
  sed -e "s|__INSTALL_DIR__|${INSTALL_DIR}|g" -e "s|__RUN_USER__|${RUN_USER}|g" \
    "$SCRIPT_DIR/buzz-relay.service" > /etc/systemd/system/buzz-relay.service
  chmod 644 /etc/systemd/system/buzz-relay.service
  systemctl daemon-reload
  systemctl enable buzz-relay
  systemctl restart buzz-relay
  sleep 3
  systemctl --no-pager --lines=0 status buzz-relay || true
fi

cat <<EOF

------------------------------------------------------------------------
Relay installed (thin / upstream-reusing variant).

  Clients:  ws://${RELAY_HOST}:${RELAY_PORT}
  Checkout: ${SRC}
  Env:      ${SRC}/.env  (0600, gitignored)
  Override: ${SRC}/docker-compose.override.yml

Verify:
  journalctl -u buzz-relay -n 200 | grep -E 'Config loaded|Deployment community ensured'

Upstream targets you can now use directly from ${SRC}:
  just migrate     migrate + seed community host
  just ps          compose ps
  just logs        compose logs -f
  just down        stop the datastore stack

Updating:
  cd ${SRC} && git pull && cargo build --release -p buzz-relay -p buzz-admin \\
    && sudo systemctl restart buzz-relay
  (.env and the override are gitignored/untracked, so the pull leaves them alone.)

Still yours to do: firewall port ${RELAY_PORT}, and TLS if this leaves a trusted LAN.
------------------------------------------------------------------------
EOF
