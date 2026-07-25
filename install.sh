#!/usr/bin/env bash
#
# install.sh — stand up buzz-relay on a fresh server, relay only, no agents.
#
# Does:
#   1. Prereq checks (git, docker, docker compose, openssl, curl).
#   2. Clone block/buzz into <dir>/src.
#   3. Build ONLY buzz-relay and buzz-admin (not the desktop, not the agents).
#   4. Render <dir>/src/.env from env.template with freshly generated secrets.
#   5. Start the minimal datastore stack (postgres, redis, minio).
#   6. Run migrations, then seed the host->community row for RELAY_URL.
#   7. Optionally install and enable the systemd unit.
#
# The rendered .env lives at <dir>/src/.env on purpose: the repo's own
# seed-local-community.sh sources .env from the repo root with allexport, so a
# second copy elsewhere would be silently overridden by whatever is there.
# One file, one source of truth.
#
# Idempotent: re-running will not regenerate secrets if .env already exists.

set -euo pipefail

REPO_URL="https://github.com/block/buzz.git"
INSTALL_DIR="/opt/buzz-relay"
RELAY_HOST=""
RELAY_PORT="3000"
RUN_USER="${SUDO_USER:-$(id -un)}"
DO_SYSTEMD=1
DO_UPDATE=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()  { printf '\033[1;33m[relay]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;35m[relay] warn:\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[relay] error:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: sudo ./install.sh --host HOST [options]

Required:
  --host HOST       Canonical host clients will use (DNS name or IP).
                    Becomes RELAY_URL=ws://HOST:PORT and the seeded community
                    host. Every client must use this exact authority.

Options:
  --port N          Relay port (default: 3000)
  --dir PATH        Install root (default: /opt/buzz-relay)
  --user NAME       User to own files and run the service (default: invoking user)
  --no-systemd      Skip unit installation; print the run command instead
  --update          git pull an existing checkout before building
  -h, --help        Show this help

Example:
  sudo ./install.sh --host relay.lan --port 3000
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)       RELAY_HOST="$2"; shift 2 ;;
    --port)       RELAY_PORT="$2"; shift 2 ;;
    --dir)        INSTALL_DIR="$2"; shift 2 ;;
    --user)       RUN_USER="$2"; shift 2 ;;
    --no-systemd) DO_SYSTEMD=0; shift ;;
    --update)     DO_UPDATE=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    *) die "Unknown option: $1 (see --help)" ;;
  esac
done

[[ -z "$RELAY_HOST" ]] && { usage; die "--host is required."; }

# ---- prereqs ---------------------------------------------------------------
log "Checking prerequisites"
for cmd in git docker openssl curl; do
  command -v "$cmd" >/dev/null 2>&1 || die "$cmd not found. Install it and re-run."
done
docker info >/dev/null 2>&1 || die "Docker daemon not reachable. Start it and re-run."
docker compose version >/dev/null 2>&1 \
  || command -v docker-compose >/dev/null 2>&1 \
  || die "Docker Compose not found. Install the compose plugin and re-run."

compose() {
  if docker compose version >/dev/null 2>&1; then
    docker compose "$@"
  else
    docker-compose "$@"
  fi
}

if [[ "$DO_SYSTEMD" -eq 1 && "$(id -u)" -ne 0 ]]; then
  die "Installing the systemd unit needs root. Re-run with sudo, or pass --no-systemd."
fi

id "$RUN_USER" >/dev/null 2>&1 || die "User '$RUN_USER' does not exist. Create it or pass --user."

[[ -f "$SCRIPT_DIR/env.template" ]]  || die "env.template not found next to install.sh"
[[ -f "$SCRIPT_DIR/docker-compose.yml" ]] || die "docker-compose.yml not found next to install.sh"

# ---- layout ----------------------------------------------------------------
SRC_DIR="$INSTALL_DIR/src"
ENV_FILE="$SRC_DIR/.env"

log "Install root: $INSTALL_DIR (owner: $RUN_USER)"
mkdir -p "$INSTALL_DIR"

# ---- clone -----------------------------------------------------------------
if [[ -d "$SRC_DIR/.git" ]]; then
  log "Existing checkout at $SRC_DIR"
  if [[ "$DO_UPDATE" -eq 1 ]]; then
    log "Updating (git pull)"
    sudo -u "$RUN_USER" git -C "$SRC_DIR" pull --ff-only
  fi
else
  [[ -e "$SRC_DIR" ]] && die "$SRC_DIR exists but is not a git checkout. Move it aside."
  log "Cloning $REPO_URL"
  sudo -u "$RUN_USER" git clone --depth 1 "$REPO_URL" "$SRC_DIR"
fi

chown -R "$RUN_USER":"$RUN_USER" "$INSTALL_DIR" 2>/dev/null || true

# ---- render .env (before compose, which interpolates from it) --------------
if [[ -f "$ENV_FILE" ]]; then
  log ".env already exists; leaving secrets untouched"
  # Keep RELAY_URL/bind in sync with the flags even on re-run.
  sudo -u "$RUN_USER" sed -i.bak \
    -e "s|^RELAY_URL=.*|RELAY_URL=ws://${RELAY_HOST}:${RELAY_PORT}|" \
    -e "s|^BUZZ_BIND_ADDR=.*|BUZZ_BIND_ADDR=0.0.0.0:${RELAY_PORT}|" \
    "$ENV_FILE"
  rm -f "${ENV_FILE}.bak"
else
  log "Generating secrets and rendering .env"
  PG_PASSWORD="$(openssl rand -hex 24)"
  S3_SECRET="$(openssl rand -hex 24)"
  RELAY_PRIVKEY="$(openssl rand -hex 32)"   # 32-byte nostr secret key

  sed -e "s|__RELAY_HOST__|${RELAY_HOST}|g" \
      -e "s|__RELAY_PORT__|${RELAY_PORT}|g" \
      -e "s|__PG_PASSWORD__|${PG_PASSWORD}|g" \
      -e "s|__S3_SECRET__|${S3_SECRET}|g" \
      -e "s|__RELAY_PRIVKEY__|${RELAY_PRIVKEY}|g" \
      "$SCRIPT_DIR/env.template" > "$ENV_FILE"

  chown "$RUN_USER":"$RUN_USER" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  log "Wrote $ENV_FILE (chmod 600)"
fi

# Compose reads .env from its own directory, so keep the stack file beside it.
cp -f "$SCRIPT_DIR/docker-compose.yml" "$SRC_DIR/docker-compose.relay.yml"
chown "$RUN_USER":"$RUN_USER" "$SRC_DIR/docker-compose.relay.yml"

# ---- build (relay + migrator only) ----------------------------------------
log "Building buzz-relay and buzz-admin (release). This takes a while."
sudo -u "$RUN_USER" bash -lc "
  cd '$SRC_DIR' &&
  if [[ -f ./bin/activate-hermit ]]; then . ./bin/activate-hermit; fi &&
  cargo build --release -p buzz-relay -p buzz-admin
" || die "Build failed. If cargo is missing, the Hermit activation may have failed."

RELAY_BIN="$SRC_DIR/target/release/buzz-relay"
ADMIN_BIN="$SRC_DIR/target/release/buzz-admin"
[[ -x "$RELAY_BIN" ]] || die "Expected binary not found: $RELAY_BIN"

# ---- datastores ------------------------------------------------------------
log "Starting datastores (postgres, redis, minio)"
sudo -u "$RUN_USER" bash -lc "
  cd '$SRC_DIR' &&
  $(command -v docker) compose --env-file .env -f docker-compose.relay.yml up -d
" || die "Compose failed to start the datastore stack."

log "Waiting for Postgres to report healthy"
for _ in $(seq 1 60); do
  status="$(docker inspect -f '{{.State.Health.Status}}' buzz-postgres 2>/dev/null || echo starting)"
  [[ "$status" == "healthy" ]] && break
  sleep 2
done
[[ "${status:-}" == "healthy" ]] || die "Postgres did not become healthy. Check: docker logs buzz-postgres"

# ---- migrate + seed --------------------------------------------------------
log "Running database migrations"
sudo -u "$RUN_USER" bash -lc "cd '$SRC_DIR' && set -o allexport && . ./.env && set +o allexport && '$ADMIN_BIN' migrate"

log "Seeding community host row for ${RELAY_HOST}:${RELAY_PORT}"
if [[ -x "$SRC_DIR/scripts/seed-local-community.sh" ]]; then
  sudo -u "$RUN_USER" bash -lc "cd '$SRC_DIR' && ./scripts/seed-local-community.sh"
else
  warn "scripts/seed-local-community.sh missing. Seed manually or the relay fails closed."
fi

# ---- systemd ---------------------------------------------------------------
if [[ "$DO_SYSTEMD" -eq 1 ]]; then
  UNIT=/etc/systemd/system/buzz-relay.service
  log "Installing $UNIT"
  sed -e "s|__INSTALL_DIR__|${INSTALL_DIR}|g" \
      -e "s|__RUN_USER__|${RUN_USER}|g" \
      "$SCRIPT_DIR/buzz-relay.service" > "$UNIT"
  chmod 644 "$UNIT"
  systemctl daemon-reload
  systemctl enable buzz-relay
  systemctl restart buzz-relay
  sleep 3
  systemctl --no-pager --lines=0 status buzz-relay || true
fi

cat <<EOF

------------------------------------------------------------------------
Relay installed.

  URL for ALL clients:  ws://${RELAY_HOST}:${RELAY_PORT}
  Checkout:             ${SRC_DIR}
  Env (secrets, 0600):  ${ENV_FILE}

Verify the two lines that actually matter:
  journalctl -u buzz-relay -n 200 | grep -E 'Config loaded|Deployment community ensured'

  relay_url must be ws://${RELAY_HOST}:${RELAY_PORT}
  host must be ${RELAY_HOST}:${RELAY_PORT}

If a client gets a fail-closed error, its Host header has no community row:
  cd ${SRC_DIR} && RELAY_URL=ws://${RELAY_HOST}:${RELAY_PORT} ./scripts/seed-local-community.sh

Service:
  systemctl {status,restart,stop} buzz-relay
  journalctl -u buzz-relay -f

Datastores:
  cd ${SRC_DIR} && docker compose -f docker-compose.relay.yml ps

REMAINING WORK (not done for you):
  * Open port ${RELAY_PORT} in the host firewall. Datastore ports are bound to
    127.0.0.1 and should stay that way.
  * Traffic is plain ws://. For anything beyond a trusted LAN, terminate TLS in
    a reverse proxy, serve wss://, and set RELAY_URL to the wss:// authority,
    then re-seed that host.
------------------------------------------------------------------------
EOF
