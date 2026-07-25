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
RELAY_PORT="3000"
RUN_USER="${SUDO_USER:-$(id -un)}"
DO_SYSTEMD=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
log()  { printf '\033[1;33m[relay]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;35m[relay] warn:\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[relay] error:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: sudo ./install.sh --host HOST [--port N] [--dir PATH] [--user NAME] [--no-systemd]

--host is required: the canonical authority every client will use. It becomes
RELAY_URL and the seeded community host. Each authority is a separate community.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) RELAY_HOST="$2"; shift 2 ;;
    --port) RELAY_PORT="$2"; shift 2 ;;
    --dir)  INSTALL_DIR="$2"; shift 2 ;;
    --user) RUN_USER="$2"; shift 2 ;;
    --no-systemd) DO_SYSTEMD=0; shift ;;
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
if [[ -d "$SRC/.git" ]]; then
  log "Existing checkout at $SRC"
else
  log "Cloning"
  sudo -u "$RUN_USER" git clone --depth 1 "$REPO_URL" "$SRC"
fi
chown -R "$RUN_USER":"$RUN_USER" "$INSTALL_DIR" 2>/dev/null || true

# ---- .env: start from upstream, then patch ---------------------------------
# Copying .env.example rather than templating it means new upstream variables
# are inherited on future re-installs instead of silently missing.
if [[ -f "$SRC/.env" ]]; then
  log ".env exists; patching host only, leaving secrets alone"
  sudo -u "$RUN_USER" sed -i \
    -e "s|^RELAY_URL=.*|RELAY_URL=ws://${RELAY_HOST}:${RELAY_PORT}|" \
    -e "s|^BUZZ_BIND_ADDR=.*|BUZZ_BIND_ADDR=0.0.0.0:${RELAY_PORT}|" \
    "$SRC/.env"
else
  log "Creating .env from upstream .env.example and patching"
  PG="$(openssl rand -hex 24)"
  S3="$(openssl rand -hex 24)"
  KEY="$(openssl rand -hex 32)"

  sudo -u "$RUN_USER" cp "$SRC/.env.example" "$SRC/.env"

  # Replace the upstream dev values that exist in .env.example.
  sudo -u "$RUN_USER" sed -i \
    -e "s|^RELAY_URL=.*|RELAY_URL=ws://${RELAY_HOST}:${RELAY_PORT}|" \
    -e "s|^BUZZ_BIND_ADDR=.*|BUZZ_BIND_ADDR=0.0.0.0:${RELAY_PORT}|" \
    -e "s|^DATABASE_URL=.*|DATABASE_URL=postgres://buzz:${PG}@localhost:5432/buzz|" \
    -e "s|^PGPASSWORD=.*|PGPASSWORD=${PG}|" \
    -e "s|^RUST_LOG=.*|RUST_LOG=buzz_relay=info,buzz_db=info,buzz_auth=info,buzz_pubsub=info,tower_http=warn|" \
    "$SRC/.env"

  # Append what .env.example does not define. The S3 and relay-key variables
  # default to dev values IN CODE, so omitting them keeps dev creds silently.
  sudo -u "$RUN_USER" tee -a "$SRC/.env" >/dev/null <<EOF

# ---- added by install.sh ----
POSTGRES_USER=buzz
POSTGRES_PASSWORD=${PG}
POSTGRES_DB=buzz

BUZZ_S3_ENDPOINT=http://localhost:9000
BUZZ_S3_ACCESS_KEY=buzzrelay
BUZZ_S3_SECRET_KEY=${S3}
BUZZ_S3_BUCKET=buzz-media
BUZZ_S3_REGION=us-east-1

BUZZ_RELAY_PRIVATE_KEY=${KEY}
BUZZ_REQUIRE_AUTH_TOKEN=true
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
