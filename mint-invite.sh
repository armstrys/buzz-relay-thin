#!/usr/bin/env bash
#
# mint-invite.sh — generate a buzz relay invite code for the deployed community.
#
# A buzz invite is a STATELESS, HMAC-signed token (no server-side storage):
#
#   code = base64url(payload) . base64url(HMAC-SHA256(key, payload))
#   payload = {"c":"<community uuid>","r":"member","e":<expiry unix>,"n":"<nonce>"}
#   key     = sha256( relay_secret_key_bytes || "buzz-invite-v1" )
#
# So this script needs only the relay's private key (from .env) and the
# community's UUID (from the DB). The relay verifies the same HMAC on claim and
# admits the joining pubkey — the invitee never has to know their own pubkey,
# and nobody has to paste the relay's private key into a client.
#
# Hand the printed URL to a new user; they paste it into the desktop app's
# "Join a community" field. Codes are multi-use until they expire (default 72h);
# rotating BUZZ_RELAY_PRIVATE_KEY invalidates all outstanding invites.

set -euo pipefail

INSTALL_DIR="/opt/buzz-relay"
TTL_HOURS=72
COMMUNITY_OVERRIDE=""     # skip the DB lookup (mainly for testing)

log()  { printf '\033[1;33m[invite]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[invite] error:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: ./mint-invite.sh [--dir PATH] [--ttl-hours N] [--community UUID]

  --dir PATH        Install root (default: /opt/buzz-relay)
  --ttl-hours N     Invite lifetime in hours (default: 72, max: 720)
  --community UUID  Use this community UUID instead of looking it up in the DB
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir)        INSTALL_DIR="$2"; shift 2 ;;
    --ttl-hours)  TTL_HOURS="$2"; shift 2 ;;
    --community)  COMMUNITY_OVERRIDE="$2"; shift 2 ;;
    -h|--help)    usage; exit 0 ;;
    *) die "Unknown option: $1 (see --help)" ;;
  esac
done

command -v python3 >/dev/null 2>&1 || die "python3 not found (needed for HMAC)."

ENV_FILE="$INSTALL_DIR/src/.env"
[[ -f "$ENV_FILE" ]] || die "$ENV_FILE not found. Pass --dir if you installed elsewhere."

# Load .env (RELAY_URL, BUZZ_RELAY_PRIVATE_KEY, PG* for the lookup).
set -o allexport
# shellcheck disable=SC1090
. "$ENV_FILE"
set +o allexport

: "${BUZZ_RELAY_PRIVATE_KEY:?not set in .env}"
: "${RELAY_URL:?not set in .env}"
[[ "$BUZZ_RELAY_PRIVATE_KEY" =~ ^[0-9a-fA-F]{64}$ ]] \
  || die "BUZZ_RELAY_PRIVATE_KEY must be 64 hex chars."

# Authority = host[:port] the relay binds its community to, derived from
# RELAY_URL exactly like the seed does: drop the scheme, and drop the port only
# when it is the scheme default (ws:80 / wss:443).
authority_from_relay_url() {
  local url="$1" scheme rest host port
  scheme="${url%%://*}"; rest="${url#*://}"; rest="${rest%%/*}"
  host="${rest%%:*}"; port=""
  [[ "$rest" == *:* ]] && port="${rest##*:}"
  if [[ -z "$port" ]] \
     || { [[ "$scheme" == "ws"  && "$port" == "80"  ]]; } \
     || { [[ "$scheme" == "wss" && "$port" == "443" ]]; }; then
    printf '%s' "$host"
  else
    printf '%s:%s' "$host" "$port"
  fi
}
AUTHORITY="$(authority_from_relay_url "$RELAY_URL")"
[[ -n "$AUTHORITY" ]] || die "Could not derive a host from RELAY_URL=$RELAY_URL"

# HTTP form of the relay, for the paste-able invite URL. The desktop parser maps
# http->ws and https->wss and keeps host:port.
case "$RELAY_URL" in
  wss://*) HTTP_BASE="https://${RELAY_URL#wss://}" ;;
  ws://*)  HTTP_BASE="http://${RELAY_URL#ws://}" ;;
  *)       die "RELAY_URL must start with ws:// or wss://" ;;
esac
HTTP_BASE="${HTTP_BASE%/}"

# Community UUID: explicit override, or look it up by host in Postgres.
if [[ -n "$COMMUNITY_OVERRIDE" ]]; then
  COMMUNITY_ID="$COMMUNITY_OVERRIDE"
else
  q="SELECT id FROM communities WHERE lower(host) = lower('${AUTHORITY}') LIMIT 1;"
  if command -v psql >/dev/null 2>&1; then
    COMMUNITY_ID="$(PGPASSWORD="${PGPASSWORD:-}" psql -h "${PGHOST:-localhost}" \
      -p "${PGPORT:-5432}" -U "${PGUSER:-buzz}" -d "${PGDATABASE:-buzz}" \
      -tAc "$q" 2>/dev/null | tr -d '[:space:]')"
  else
    COMMUNITY_ID="$(docker exec -e PGPASSWORD="${PGPASSWORD:-}" buzz-postgres \
      psql -U "${PGUSER:-buzz}" -d "${PGDATABASE:-buzz}" -tAc "$q" 2>/dev/null \
      | tr -d '[:space:]')"
  fi
fi
[[ -n "$COMMUNITY_ID" ]] \
  || die "No community row for host '${AUTHORITY}'. Is the relay seeded/running?"

# Mint: derive the HMAC key from the relay secret, sign a compact payload, and
# emit base64url(payload).base64url(mac). Done in python3 for clean byte handling.
# Python source kept in a single-quoted var (no single quotes inside) so it is
# portable across bash versions — a heredoc inside $() breaks on old bash.
PY_MINT='
import sys, os, json, hmac, hashlib, base64, secrets, time
community, keyhex = sys.argv[1], sys.argv[2].lower()
ttl_h = int(os.environ.get("TTL_HOURS", "72"))
ttl = max(60, min(ttl_h * 3600, 30 * 24 * 3600))   # clamp to relay range [60s, 30d]
exp = int(time.time()) + ttl
key = hashlib.sha256(bytes.fromhex(keyhex) + b"buzz-invite-v1").digest()
b64u = lambda b: base64.urlsafe_b64encode(b).rstrip(b"=").decode()
nonce = b64u(secrets.token_bytes(16))
payload = json.dumps({"c": community, "r": "member", "e": exp, "n": nonce},
                     separators=(",", ":")).encode()
mac = hmac.new(key, payload, hashlib.sha256).digest()
print(b64u(payload) + "." + b64u(mac) + " " + str(exp))
'
MINT_OUT="$(TTL_HOURS="$TTL_HOURS" python3 -c "$PY_MINT" "$COMMUNITY_ID" "$BUZZ_RELAY_PRIVATE_KEY")" \
  || die "Minting failed."
CODE="${MINT_OUT%% *}"
EXPIRES="${MINT_OUT##* }"
[[ -n "${CODE:-}" && "$CODE" == *.* ]] || die "Minting produced no code."

INVITE_URL="${HTTP_BASE}/invite/${CODE}"
WHEN="$(date -d "@${EXPIRES}" '+%Y-%m-%d %H:%M %Z' 2>/dev/null \
        || date -r "${EXPIRES}" '+%Y-%m-%d %H:%M %Z' 2>/dev/null || echo "unix ${EXPIRES}")"

cat <<EOF

------------------------------------------------------------------------
Invite for community host: ${AUTHORITY}
Expires: ${WHEN}  (multi-use until then)

Paste THIS into the desktop app's "Join a community" field:

  ${INVITE_URL}

(The new user creates their identity in the app first; claiming the invite
registers their pubkey automatically — they never need to know it.)

Raw code (if a field asks only for the code, with the relay set separately):
  ${CODE}
------------------------------------------------------------------------
EOF
