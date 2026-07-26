#!/usr/bin/env bash
#
# install.sh — one-command buzz relay bootstrap.
#
# Pulls the upstream block/buzz deploy/compose bundle, generates all secrets,
# writes a complete .env, and starts the stack with docker compose. No Rust
# toolchain, no systemd, no bare-metal build, no host port collisions.
#
# Only one port is published to the host: the relay (default 3000). Postgres,
# Redis, and MinIO live on an internal Docker bridge network and are invisible
# to the host.
#
# Usage:
#   ./install.sh --host relay.lan
#   ./install.sh --host relay.lan --port 3001 --tls
#   ./install.sh --host relay.lan --update   # pull latest image + restart
#   ./install.sh --host relay.lan --down      # stop the stack

set -euo pipefail

REPO_URL="https://github.com/block/buzz.git"
INSTALL_DIR="${BUZZ_INSTALL_DIR:-/opt/buzz-relay}"
RELAY_HOST=""
RELAY_PORT=""
DO_TLS=0
DO_UPDATE=0
DO_DOWN=0
DO_FORCE=0
IMAGE_TAG="${BUZZ_IMAGE_TAG:-main}"
RUN_USER="${SUDO_USER:-$(id -un)}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
log()  { printf '\033[1;33m[relay]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;35m[relay] warn:\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[relay] error:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: ./install.sh --host HOST [options]

Required:
  --host HOST        Canonical hostname clients will use (e.g. relay.lan)

Options:
  --port N           Relay port on the host (default 3000)
  --tls              Include Caddy reverse proxy with automatic HTTPS
                     (requires a public DNS name; ports 80/443 published)
  --update           Pull latest image and restart (skips secret generation)
  --down             Stop and remove containers (volumes preserved)
  --force            Overwrite an existing .env (destructive — regenerates secrets)
  --image-tag TAG    ghcr.io/block/buzz tag (default: main)
  --dir PATH         Install root (default: /opt/buzz-relay)
  --user NAME        Owner user (default: invoking user)
  -h, --help         Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)        RELAY_HOST="$2"; shift 2 ;;
    --port)        RELAY_PORT="$2"; shift 2 ;;
    --tls)         DO_TLS=1; shift ;;
    --update)      DO_UPDATE=1; shift ;;
    --down)        DO_DOWN=1; shift ;;
    --force)       DO_FORCE=1; shift ;;
    --image-tag)   IMAGE_TAG="$2"; shift 2 ;;
    --dir)         INSTALL_DIR="$2"; shift 2 ;;
    --user)        RUN_USER="$2"; shift 2 ;;
    -h|--help)     usage; exit 0 ;;
    *)             die "Unknown option: $1" ;;
  esac
done

# ---- down doesn't need --host -----------------------------------------------
if [[ "$DO_DOWN" -eq 1 ]]; then
  if [[ ! -d "$INSTALL_DIR/src/deploy/compose" ]]; then
    die "No install found at $INSTALL_DIR. Nothing to stop."
  fi
  log "Stopping buzz relay stack"
  sudo -u "$RUN_USER" bash -lc "cd '$INSTALL_DIR/src/deploy/compose' && docker compose --env-file .env -f compose.yml down"
  exit 0
fi

[[ -z "$RELAY_HOST" ]] && { usage; die "--host is required." }

for cmd in git docker openssl; do
  command -v "$cmd" >/dev/null 2>&1 || die "$cmd not found."
done
docker info >/dev/null 2>&1 || die "Docker daemon not reachable."
docker compose version >/dev/null 2>&1 || die "Docker Compose plugin not found."

SRC="$INSTALL_DIR/src"
COMPOSE_DIR="$SRC/deploy/compose"
ENV_FILE="$COMPOSE_DIR/.env"

# ---- clone or update upstream -----------------------------------------------
if [[ -d "$SRC/.git" ]]; then
  log "Existing checkout at $SRC"
  if [[ "$DO_UPDATE" -eq 1 ]]; then
    log "Pulling latest upstream"
    sudo -u "$RUN_USER" git -C "$SRC" pull --ff-only
  fi
else
  log "Cloning upstream block/buzz"
  mkdir -p "$INSTALL_DIR"
  sudo -u "$RUN_USER" git clone --depth 1 "$REPO_URL" "$SRC"
fi
chown -R "$RUN_USER":"$RUN_USER" "$INSTALL_DIR" 2>/dev/null || true

# ---- .env -------------------------------------------------------------------
if [[ "$DO_UPDATE" -eq 1 && -f "$ENV_FILE" ]]; then
  log "Update mode: keeping existing .env"
  # Just pull the image and restart
  log "Pulling image ghcr.io/block/buzz:$IMAGE_TAG"
  sudo -u "$RUN_USER" docker pull "ghcr.io/block/buzz:$IMAGE_TAG"

  log "Restarting stack"
  COMPOSE_ARGS=(--env-file .env -f compose.yml)
  [[ "$DO_TLS" -eq 1 ]] && COMPOSE_ARGS+=(-f compose.caddy.yml)
  sudo -u "$RUN_USER" bash -lc "cd '$COMPOSE_DIR' && docker compose ${COMPOSE_ARGS[*]} up -d --wait --force-recreate"
  exit 0
fi

if [[ -f "$ENV_FILE" && "$DO_FORCE" -ne 1 ]]; then
  die ".env already exists at $ENV_FILE. Use --force to overwrite (regenerates secrets) or --update to restart with existing config."
fi

log "Generating .env with fresh secrets"

RELAY_PORT="${RELAY_PORT:-3000}"
PG_PASS="$(openssl rand -hex 24)"
REDIS_PASS="$(openssl rand -hex 24)"
S3_ACCESS="$(openssl rand -hex 12)"
S3_SECRET="$(openssl rand -hex 24)"
RELAY_KEY="$(openssl rand -hex 32)"
HMAC_SECRET="$(openssl rand -hex 32)"

# Determine scheme and URL based on TLS
if [[ "$DO_TLS" -eq 1 ]]; then
  SCHEME="wss"
  HTTP_SCHEME="https"
  BIND_PORT=3000  # internal — Caddy terminates TLS
else
  SCHEME="ws"
  HTTP_SCHEME="http"
  BIND_PORT="$RELAY_PORT"
fi

cat > "$ENV_FILE" <<EOF
# Generated by buzz-relay-thin install.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Do not edit by hand unless you know what you're doing — re-run install.sh
# with --update to restart with these values preserved.

# ---- image ------------------------------------------------------------------
BUZZ_IMAGE=ghcr.io/block/buzz:$IMAGE_TAG

# ---- host & URL -------------------------------------------------------------
BUZZ_DOMAIN=$RELAY_HOST
RELAY_URL=${SCHEME}://${RELAY_HOST}:$RELAY_PORT
BUZZ_MEDIA_BASE_URL=${HTTP_SCHEME}://${RELAY_HOST}:$RELAY_PORT/media
BUZZ_MEDIA_SERVER_DOMAIN=$RELAY_HOST
BUZZ_CORS_ORIGINS=${HTTP_SCHEME}://${RELAY_HOST}:$RELAY_PORT

# ---- relay ------------------------------------------------------------------
BUZZ_REQUIRE_AUTH_TOKEN=false
BUZZ_REQUIRE_RELAY_MEMBERSHIP=false
BUZZ_ALLOW_NIP_OA_AUTH=false
BUZZ_AUTO_MIGRATE=true
BUZZ_GIT_CONFORMANCE_PROBE=true
RUST_LOG=buzz_relay=info,buzz_db=info,buzz_auth=info,buzz_pubsub=info,tower_http=info

# Stable secrets — back these up
BUZZ_RELAY_PRIVATE_KEY=$RELAY_KEY
BUZZ_GIT_HOOK_HMAC_SECRET=$HMAC_SECRET

# ---- Postgres ---------------------------------------------------------------
POSTGRES_DB=buzz
POSTGRES_USER=buzz
POSTGRES_PASSWORD=$PG_PASS

# ---- Redis ------------------------------------------------------------------
REDIS_PASSWORD=$REDIS_PASS

# ---- MinIO / S3 -------------------------------------------------------------
BUZZ_S3_ACCESS_KEY=$S3_ACCESS
BUZZ_S3_SECRET_KEY=$S3_SECRET
BUZZ_S3_BUCKET=buzz-media

# ---- host ports -------------------------------------------------------------
BUZZ_HTTP_PORT=$RELAY_PORT

# ---- Caddy (only used with --tls / compose.caddy.yml) -----------------------
CADDY_HTTP_PORT=80
CADDY_HTTPS_PORT=443
EOF

chmod 600 "$ENV_FILE"
chown "$RUN_USER":"$RUN_USER" "$ENV_FILE"

# ---- start ------------------------------------------------------------------
log "Starting buzz relay stack"

COMPOSE_ARGS=(--env-file .env -f compose.yml)
if [[ "$DO_TLS" -eq 1 ]]; then
  COMPOSE_ARGS+=(-f compose.caddy.yml)
  log "TLS enabled: Caddy will terminate HTTPS on ports 80/443"
  warn "Ensure $RELAY_HOST resolves to this machine and ports 80/443 are open."
fi

sudo -u "$RUN_USER" bash -lc "cd '$COMPOSE_DIR' && docker compose ${COMPOSE_ARGS[*]} up -d --wait"

# ---- summary ----------------------------------------------------------------
echo ""
echo "------------------------------------------------------------------------"
echo "Buzz relay is up."
echo ""
echo "  Clients:  ${SCHEME}://${RELAY_HOST}:${RELAY_PORT}"
echo "  Install:  $INSTALL_DIR/src"
echo "  Env:      $ENV_FILE  (0600)"
echo "  Image:    ghcr.io/block/buzz:$IMAGE_TAG"
echo ""
if [[ "$DO_TLS" -eq 1 ]]; then
echo "  Caddy:    HTTPS on :443 → relay:3000"
echo "  Ports:    80, 443 (host)"
else
echo "  Ports:    $RELAY_PORT (host) — the only published port"
echo "           Postgres, Redis, MinIO are container-internal only"
fi
echo ""
echo "Verify:"
echo "  curl -fsS http://${RELAY_HOST}:${RELAY_PORT}/_liveness"
echo ""
echo "Manage:"
echo "  $INSTALL_DIR/src/deploy/compose && docker compose --env-file .env -f compose.yml logs -f"
echo ""
echo "Update to latest image:"
echo "  ./install.sh --host $RELAY_HOST --update"
echo ""
echo "Stop:"
echo "  ./install.sh --down"
echo ""
echo "Still yours to do:"
if [[ "$DO_TLS" -eq 0 ]]; then
echo "  - Firewall port $RELAY_PORT"
echo "  - TLS: re-run with --tls --host <public-domain> when ready"
else
echo "  - Ensure DNS + firewall for ports 80/443"
fi
echo "  - If this relay is internet-reachable, set BUZZ_REQUIRE_AUTH_TOKEN=true"
echo "    in $ENV_FILE and restart with --update"
echo "------------------------------------------------------------------------"
