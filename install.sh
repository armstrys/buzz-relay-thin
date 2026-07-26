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
EXTERNAL_TLS=0
GEN_OWNER=0
DO_OPEN=0
OWNER_PUBKEY=""
CORS_ORIGINS=""

log()  { printf '\033[1;33m[relay]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[relay] error:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: ./install.sh --host HOST [options]

Required:
  --host HOST        Hostname clients will connect to (e.g. relay.lan)

Options:
  --port N           Relay port on the host (default 3000, ignored with --tls)
  --tls              Add Caddy for automatic HTTPS on 80/443 (needs a public
                     DNS name reachable from the internet on 80/443)
  --external-tls     TLS is terminated by something else (Tailscale, an
                     existing reverse proxy). Publishes the relay port as
                     normal but writes wss:// URLs. Use this for LAN + mobile.
  --owner HEX        64-char hex Nostr pubkey; makes this a closed relay
  --generate-owner   Generate an owner keypair and make this a closed relay
  --open             Run with NO access control (see the warning below)
  --cors-origins CSV Restrict CORS to these origins (default: allow any).
                     Only set this if a browser app on a known origin is your
                     only client — the Tauri desktop app's origin is
                     tauri://localhost, not the relay URL, so pinning this to
                     the relay URL blocks it.
  --image-tag TAG    ghcr.io/block/buzz tag (default: main)
  --dir PATH         Install root (default: /opt/buzz-relay)
  -h, --help         Show this help

You must choose an access model: --owner / --generate-owner (closed), or --open.

--open does NOT just mean "anyone can connect". It means anyone who can reach
the port can generate a throwaway keypair and then:

  * create channels
  * join any public channel
  * add other people to public channels
  * grant themselves owner/admin on a public channel, because the relay only
    enforces the elevated-role check on PRIVATE channels
  * once owner/admin: kick members and delete messages

There is no identity to revoke, because there is no identity. Use --open only
on a network where you would be comfortable handing every device admin over
every channel.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)           RELAY_HOST="$2"; shift 2 ;;
    --port)           RELAY_PORT="$2"; shift 2 ;;
    --tls)            DO_TLS=1; shift ;;
    --external-tls)   EXTERNAL_TLS=1; shift ;;
    --owner)          OWNER_PUBKEY="$2"; shift 2 ;;
    --generate-owner) GEN_OWNER=1; shift ;;
    --open)           DO_OPEN=1; shift ;;
    --cors-origins)   CORS_ORIGINS="$2"; shift 2 ;;
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

# Open mode grants channel admin to any anonymous key, so it must be explicit —
# never something you get by forgetting an argument.
if [[ "$DO_OPEN" -eq 1 && ( -n "$OWNER_PUBKEY" || "$GEN_OWNER" -eq 1 ) ]]; then
  die "--open conflicts with --owner/--generate-owner."
fi
if [[ "$DO_OPEN" -eq 0 && -z "$OWNER_PUBKEY" && "$GEN_OWNER" -eq 0 ]]; then
  die "Choose an access model.

  --generate-owner   closed relay, mint an owner keypair   (recommended)
  --owner <hex>      closed relay, use a key you already have
  --open             NO access control

--open is not just 'anyone can connect'. Any anonymous key can create channels,
add people to public channels, and grant itself owner/admin on a public channel
(the relay only enforces the elevated-role check on private channels).
Run ./install.sh --help for the full description."
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

if [[ "$DO_TLS" -eq 1 && "$EXTERNAL_TLS" -eq 1 ]]; then
  die "--tls and --external-tls are mutually exclusive."
fi

# Let's Encrypt only issues for publicly resolvable names. Caddy silently falls
# back to its internal CA for anything else, and mobile platforms will not trust
# that: Android ignores user-installed CAs unless the app opts in.
if [[ "$DO_TLS" -eq 1 && "$RELAY_HOST" != *.* ]]; then
  die "--tls needs a public DNS name; '$RELAY_HOST' has no dot.

Let's Encrypt cannot issue for a single-label name, so Caddy would fall back to
a self-signed internal CA that phones reject.

For a LAN relay that mobile clients must reach, terminate TLS elsewhere and use
--external-tls (see the README's 'TLS on a LAN' section)."
fi

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

# Docker volumes outlive `rm -rf` of the install dir. This install generates new
# secrets, which will not match the credentials already baked into a surviving
# Postgres volume — the relay starts, fails to authenticate, and reports only
# "container buzz-prod-relay-1 is unhealthy". Refuse instead.
STALE="$(docker volume ls -q --filter name=buzz-prod_ 2>/dev/null || true)"
if [[ -n "$STALE" ]]; then
  die "Volumes from a previous install are still present:

$(printf '  %s\n' $STALE)
Fresh secrets will not match the credentials stored in them, so the relay
would come up unhealthy. Remove them first (this destroys the old data):

  docker volume rm $(printf '%s ' $STALE)

If a previous stack is still running, tear it down properly instead:

  (cd $COMPOSE_DIR && docker compose --env-file .env -f compose.yml down -v)"
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
if [[ "$DO_TLS" -eq 1 || "$EXTERNAL_TLS" -eq 1 ]]; then
  # Caddy (or the external terminator) serves 443; no port suffix in the URLs.
  # With --external-tls the relay still publishes $RELAY_PORT for the
  # terminator to forward to — that port just is not what clients dial.
  WS_URL="wss://$RELAY_HOST"
  HTTP_URL="https://$RELAY_HOST"
else
  WS_URL="ws://$RELAY_HOST:$RELAY_PORT"
  HTTP_URL="http://$RELAY_HOST:$RELAY_PORT"
fi

# The relay treats an empty BUZZ_CORS_ORIGINS as permissive and a non-empty one
# as a strict allowlist. Default to permissive: the desktop client is Tauri, so
# its origin is tauri://localhost (macOS) or http://tauri.localhost (elsewhere)
# — never the relay's own URL. Pinning the relay URL here blocks the app, which
# surfaces in the client as a bare "Load failed".
if [[ -n "$CORS_ORIGINS" ]]; then
  CORS_LINE="BUZZ_CORS_ORIGINS=$CORS_ORIGINS"
else
  CORS_LINE="# Empty = permissive (any origin). The Tauri desktop client's origin is
# tauri://localhost, not $HTTP_URL, so an allowlist must include it.
# Re-run with --cors-origins to restrict this.
BUZZ_CORS_ORIGINS="
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
$CORS_LINE

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

# Print the owner key BEFORE starting anything. The private key exists only in
# this process; if the stack fails to come up and we exit first, it is gone.
if [[ -n "$OWNER_PRIVKEY" ]]; then
  cat <<EOF

------------------------------------------------------------------------
Owner keypair — SHOWN ONCE, NOT STORED. Save the private key now.

  public  (in .env): $OWNER_PUBKEY
  private (yours):   $OWNER_PRIVKEY

Import the private key into your Nostr client to administer this relay.
------------------------------------------------------------------------

EOF
fi

# ---- hand off to upstream ----------------------------------------------------
# run.sh picks its compose files from BUZZ_COMPOSE_TLS in the environment, not
# from .env — so a TLS install must set it on every later invocation too, or
# Caddy silently drops out of the stack and the relay republishes its port.
PREFIX=""
if [[ "$DO_TLS" -eq 1 ]]; then
  log "TLS on — make sure $RELAY_HOST resolves here and 80/443 are open."
  export BUZZ_COMPOSE_TLS=true
  PREFIX="BUZZ_COMPOSE_TLS=true "
fi

if [[ "$EXTERNAL_TLS" -eq 1 ]]; then
  log "External TLS: point your terminator at 127.0.0.1:$RELAY_PORT"
  log "Clients will use $WS_URL — it must send Host: $RELAY_HOST"
fi

log "Starting the stack via upstream run.sh"
if ! "$COMPOSE_DIR/run.sh" start; then
  cat >&2 <<EOF

------------------------------------------------------------------------
The stack failed to start, but $ENV_FILE is written and valid.

Do NOT re-run install.sh — it refuses when .env exists. Fix the problem and
retry the start directly:

  cd $COMPOSE_DIR && ${PREFIX}./run.sh start

If a host port is already taken (the usual cause), find the holder with:

  sudo ss -lntp | grep -E ':(80|443|$RELAY_PORT)\b'

An older bare-metal install leaves a systemd unit holding the relay port:

  sudo systemctl disable --now buzz-relay
------------------------------------------------------------------------
EOF
  exit 1
fi

cat <<EOF

------------------------------------------------------------------------
Buzz relay is up ($RELAY_MODE).

  Clients:  $WS_URL
  Config:   $ENV_FILE  (0600 — back this up)
  Manage:   cd $COMPOSE_DIR && ${PREFIX}./run.sh help
------------------------------------------------------------------------
EOF

if [[ "$RELAY_MODE" == "open" ]]; then
  cat <<EOF
!! THIS RELAY HAS NO ACCESS CONTROL !!

Anyone who can reach $RELAY_HOST:$RELAY_PORT can generate a keypair and:
  - create channels
  - join any public channel, and add other people to it
  - make themselves owner/admin of any PUBLIC channel (the relay only enforces
    the elevated-role check on private channels)
  - then kick members and delete messages

Nothing here is revocable, because there are no identities to revoke. Treat
every device that can route to this port as a full administrator.

To close it, reinstall with --generate-owner and add members explicitly:
  ./run.sh add-member <npub-or-hex>

EOF
fi
