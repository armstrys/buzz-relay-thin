#!/usr/bin/env bash
#
# install.sh — bootstrap a buzz relay.
#
# Upstream block/buzz ships a production compose bundle (deploy/compose/) and a
# lifecycle script (run.sh). The only thing missing for a normal self-hoster is
# the one-time setup: generating secrets and filling in a .env. That is all this
# script does.
#
#   1. Clone block/buzz
#   2. Write deploy/compose/.env — secrets generated, hostname fanned out
#   3. Hand off to upstream's ./run.sh start
#
# After install, manage the relay with upstream's run.sh. This script is not
# involved again:
#
#   cd /opt/buzz-relay/src/deploy/compose
#   ./run.sh logs | status | upgrade | stop | backup-hint

set -euo pipefail

REPO_URL="https://github.com/block/buzz.git"
INSTALL_DIR="${BUZZ_INSTALL_DIR:-/opt/buzz-relay}"
IMAGE_TAG="${BUZZ_IMAGE_TAG:-main}"
RELAY_HOST=""
RELAY_PORT=3000
DO_TLS=0
GEN_OWNER=0
OWNER_PUBKEY=""

log()  { printf '\033[1;33m[relay]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[relay] error:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: ./install.sh --host HOST [options]

Required:
  --host HOST        Hostname clients will connect to (e.g. relay.lan)

Options:
  --port N           Relay port on the host (default 3000, ignored with --tls)
  --tls              Add Caddy for automatic HTTPS on 80/443
  --owner HEX        64-char hex Nostr pubkey; makes this a closed relay
  --generate-owner   Generate an owner keypair and make this a closed relay
  --image-tag TAG    ghcr.io/block/buzz tag (default: main)
  --dir PATH         Install root (default: /opt/buzz-relay)
  -h, --help         Show this help

Without --owner or --generate-owner the relay comes up OPEN: anyone who can
reach the port can connect. That is fine on a trusted LAN and wrong on the
public internet.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)           RELAY_HOST="$2"; shift 2 ;;
    --port)           RELAY_PORT="$2"; shift 2 ;;
    --tls)            DO_TLS=1; shift ;;
    --owner)          OWNER_PUBKEY="$2"; shift 2 ;;
    --generate-owner) GEN_OWNER=1; shift ;;
    --image-tag)      IMAGE_TAG="$2"; shift 2 ;;
    --dir)            INSTALL_DIR="$2"; shift 2 ;;
    -h|--help)        usage; exit 0 ;;
    *)                die "Unknown option: $1" ;;
  esac
done

[[ -n "$RELAY_HOST" ]] || { usage; die "--host is required."; }

if [[ -n "$OWNER_PUBKEY" && "$GEN_OWNER" -eq 1 ]]; then
  die "Use either --owner or --generate-owner, not both."
fi

if [[ -n "$OWNER_PUBKEY" ]]; then
  case "$OWNER_PUBKEY" in
    npub1*) die "--owner needs a 64-char hex pubkey, not an npub. Convert it first." ;;
  esac
  [[ "$OWNER_PUBKEY" =~ ^[0-9a-fA-F]{64}$ ]] || die "--owner must be 64 hex characters."
  OWNER_PUBKEY="$(printf '%s' "$OWNER_PUBKEY" | tr 'A-F' 'a-f')"
fi

# ---- preflight ---------------------------------------------------------------
for cmd in git docker openssl; do
  command -v "$cmd" >/dev/null 2>&1 || die "$cmd not found."
done
docker compose version >/dev/null 2>&1 || die "Docker Compose plugin not found."
docker info >/dev/null 2>&1 || die "Docker daemon not reachable."

# compose.caddy.yml uses the !reset tag, which needs Compose v2.24.4+.
if [[ "$DO_TLS" -eq 1 ]]; then
  cv="$(docker compose version --short 2>/dev/null | tr -d 'v')"
  if [[ -n "$cv" ]] && [[ "$(printf '%s\n2.24.4\n' "$cv" | sort -V | head -1)" != "2.24.4" ]]; then
    die "--tls needs Docker Compose 2.24.4+ (found $cv)."
  fi
fi

SRC="$INSTALL_DIR/src"
COMPOSE_DIR="$SRC/deploy/compose"
ENV_FILE="$COMPOSE_DIR/.env"

if [[ -e "$ENV_FILE" ]]; then
  die "$ENV_FILE already exists — this relay is already set up.
Manage it with: cd $COMPOSE_DIR && ./run.sh status
To start over, remove $INSTALL_DIR first (this destroys the config, not the
Docker volumes; see 'docker volume ls' for those)."
fi

# ---- owner keypair -----------------------------------------------------------
# Nostr pubkeys are BIP340 x-only: the x coordinate of privkey * G.
OWNER_PRIVKEY=""
if [[ "$GEN_OWNER" -eq 1 ]]; then
  dump="$(openssl ecparam -name secp256k1 -genkey -noout 2>/dev/null \
          | openssl ec -text -noout 2>/dev/null)" \
    || die "openssl could not generate a secp256k1 key. Pass --owner instead."
  priv="$(printf '%s\n' "$dump" | sed -n '/^priv:/,/^pub:/p' | sed '1d;$d' | tr -cd '0-9a-f')"
  pub="$( printf '%s\n' "$dump" | sed -n '/^pub:/,/^ASN1/p'  | sed '1d;$d' | tr -cd '0-9a-f')"
  while [[ "${#priv}" -lt 64 ]]; do priv="0$priv"; done   # openssl trims leading zero bytes
  [[ "${#priv}" -eq 64 && "${#pub}" -eq 130 && "${pub:0:2}" == "04" ]] \
    || die "Unexpected openssl key output; pass --owner instead."
  OWNER_PRIVKEY="$priv"
  OWNER_PUBKEY="${pub:2:64}"
fi

# ---- clone -------------------------------------------------------------------
if [[ -d "$SRC/.git" ]]; then
  log "Using existing checkout at $SRC"
else
  log "Cloning block/buzz into $SRC"
  mkdir -p "$INSTALL_DIR" 2>/dev/null \
    || die "Cannot create $INSTALL_DIR. Re-run with sudo, or pick --dir."
  git clone --depth 1 "$REPO_URL" "$SRC"
fi
[[ -f "$COMPOSE_DIR/run.sh" ]] || die "Upstream has no deploy/compose bundle at $COMPOSE_DIR."

# ---- .env --------------------------------------------------------------------
if [[ "$DO_TLS" -eq 1 ]]; then
  WS_URL="wss://$RELAY_HOST"        # Caddy terminates TLS on 443; no port suffix
  HTTP_URL="https://$RELAY_HOST"
else
  WS_URL="ws://$RELAY_HOST:$RELAY_PORT"
  HTTP_URL="http://$RELAY_HOST:$RELAY_PORT"
fi

if [[ -n "$OWNER_PUBKEY" ]]; then
  RELAY_MODE="closed"; AUTH=true;  MEMBERSHIP=true;  NIP_OA=true
else
  RELAY_MODE="open";   AUTH=false; MEMBERSHIP=false; NIP_OA=false
fi

log "Writing $ENV_FILE ($RELAY_MODE relay)"
umask 077
cat > "$ENV_FILE" <<EOF
# Generated by buzz-relay-thin install.sh.
# Back this file up: the secrets below must stay stable across restarts.

BUZZ_IMAGE=ghcr.io/block/buzz:$IMAGE_TAG

# Every URL below is derived from --host $RELAY_HOST. The relay keys communities
# off the Host header, so these must all agree and must match what clients use.
BUZZ_DOMAIN=$RELAY_HOST
RELAY_URL=$WS_URL
BUZZ_MEDIA_BASE_URL=$HTTP_URL/media
BUZZ_MEDIA_SERVER_DOMAIN=$RELAY_HOST
BUZZ_CORS_ORIGINS=$HTTP_URL

BUZZ_REQUIRE_AUTH_TOKEN=$AUTH
BUZZ_REQUIRE_RELAY_MEMBERSHIP=$MEMBERSHIP
BUZZ_ALLOW_NIP_OA_AUTH=$NIP_OA
BUZZ_AUTO_MIGRATE=true
BUZZ_GIT_CONFORMANCE_PROBE=true
RUST_LOG=buzz_relay=info,buzz_db=info,buzz_auth=info,buzz_pubsub=info,tower_http=info
EOF

if [[ -n "$OWNER_PUBKEY" ]]; then
  printf 'RELAY_OWNER_PUBKEY=%s\n' "$OWNER_PUBKEY" >> "$ENV_FILE"
fi

cat >> "$ENV_FILE" <<EOF

BUZZ_RELAY_PRIVATE_KEY=$(openssl rand -hex 32)
BUZZ_GIT_HOOK_HMAC_SECRET=$(openssl rand -hex 32)
POSTGRES_DB=buzz
POSTGRES_USER=buzz
POSTGRES_PASSWORD=$(openssl rand -hex 24)
REDIS_PASSWORD=$(openssl rand -hex 24)
BUZZ_S3_ACCESS_KEY=$(openssl rand -hex 12)
BUZZ_S3_SECRET_KEY=$(openssl rand -hex 24)
BUZZ_S3_BUCKET=buzz-media
# Upstream ships this in .env.example; no service in compose.yml consumes it yet.
TYPESENSE_API_KEY=$(openssl rand -hex 24)

BUZZ_HTTP_PORT=$RELAY_PORT
CADDY_HTTP_PORT=80
CADDY_HTTPS_PORT=443
EOF
chmod 600 "$ENV_FILE"

# ---- hand off to upstream ----------------------------------------------------
log "Starting the stack via upstream run.sh"
if [[ "$DO_TLS" -eq 1 ]]; then
  log "TLS on — make sure $RELAY_HOST resolves here and 80/443 are open."
  export BUZZ_COMPOSE_TLS=true
fi
"$COMPOSE_DIR/run.sh" start

cat <<EOF

------------------------------------------------------------------------
Buzz relay is up ($RELAY_MODE).

  Clients:  $WS_URL
  Config:   $ENV_FILE  (0600 — back this up)
  Manage:   cd $COMPOSE_DIR && ./run.sh help
------------------------------------------------------------------------
EOF

if [[ -n "$OWNER_PRIVKEY" ]]; then
  cat <<EOF
Owner keypair — SHOWN ONCE, NOT STORED. Save the private key now.

  public  (in .env): $OWNER_PUBKEY
  private (yours):   $OWNER_PRIVKEY

Import the private key into your Nostr client to administer this relay.

EOF
fi

if [[ "$RELAY_MODE" == "open" ]]; then
  cat <<EOF
This relay is OPEN — no auth, no membership check. Fine on a trusted LAN.
Before exposing it to the internet, re-install with --generate-owner (or
--owner <hex>) to get a closed relay.

EOF
fi
