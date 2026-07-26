# buzz-relay-thin

A one-time bootstrap for a self-hosted [buzz](https://github.com/block/buzz)
relay.

```bash
git clone https://github.com/armstrys/buzz-relay-thin.git
cd buzz-relay-thin
sudo ./install.sh --host relay.lan
```

The relay comes up at `ws://relay.lan:3000`.

## What this is (and isn't)

Upstream `block/buzz` already ships everything needed to run a relay: a
published image (`ghcr.io/block/buzz`), a production compose bundle
(`deploy/compose/`), and a lifecycle script (`run.sh`) with `start`, `stop`,
`logs`, `upgrade`, `backup-hint`, and member management.

The one gap is first-time setup. Upstream's `.env.example` needs 8 secrets
filled in by hand and one hostname copied into 5 fields with 3 different
shapes. Miss one and you get a silently split community or a CORS failure
rather than a startup error.

**That gap is all this script closes.** It generates the secrets, fans the
hostname out correctly, optionally mints an owner keypair, and hands off to
upstream's `run.sh`. It does not wrap, replace, or shadow anything else.

After install, this repo is done. Manage the relay with upstream's tooling:

```bash
cd /opt/buzz-relay/src/deploy/compose
./run.sh logs      # follow relay logs
./run.sh status    # container status
./run.sh upgrade   # pull latest image and restart
./run.sh stop      # stop, keeping volumes
./run.sh help      # everything else, incl. add-member / list-members
```

## Requirements

A Linux host with `git`, `openssl`, Docker, and the Compose plugin. Use `sudo`
if installing to the default `/opt/buzz-relay`, or pass `--dir` to somewhere
you own. TLS additionally needs Compose 2.24.4+ (checked at install time).

## Open vs closed

By default the relay is **open** — no auth token, no membership check. Anyone
who can reach the port can connect. That's the right default for a trusted LAN
and the wrong one for the public internet.

For a closed relay, give it an owner:

```bash
# You already have a Nostr identity (64-char hex pubkey, not an npub):
sudo ./install.sh --host buzz.example.com --tls --owner <hex>

# You don't, and want one generated:
sudo ./install.sh --host buzz.example.com --tls --generate-owner
```

Either sets `RELAY_OWNER_PUBKEY` and turns on `BUZZ_REQUIRE_AUTH_TOKEN`,
`BUZZ_REQUIRE_RELAY_MEMBERSHIP`, and `BUZZ_ALLOW_NIP_OA_AUTH`.

`--generate-owner` prints the private key **once** and does not store it. Save
it immediately, then import it into your Nostr client — that key is how you
administer the relay.

## TLS

```bash
sudo ./install.sh --host buzz.example.com --tls --generate-owner
```

This pulls in upstream's `compose.caddy.yml`. Caddy terminates HTTPS on 80/443
with automatic Let's Encrypt certificates and proxies to the relay over the
internal network; the relay port is not published to the host. Clients connect
to `wss://buzz.example.com` with no port.

The hostname must resolve to this machine publicly and 80/443 must be open, or
certificate issuance fails.

## Ports

Only the relay port is published:

| Mode | Published |
|---|---|
| default | 3000 (or `--port N`) |
| `--tls` | 80, 443 (Caddy only) |

Postgres, Redis, and MinIO sit on an internal Docker bridge network with no
host bindings at all — that's how upstream's `compose.yml` is written, so
there's nothing to configure and nothing to collide with.

## Choosing `--host`

This is the decision to get right. The relay identifies communities by the
`Host` header, so `relay.lan`, an IP address, and a different DNS name are all
different communities. Every client must use exactly the hostname you install
with. Prefer a stable DNS name over a DHCP address.

Changing it later means reinstalling.

## Options

| Flag | Default | What it does |
|---|---|---|
| `--host HOST` | *(required)* | Hostname clients connect to |
| `--port N` | 3000 | Relay port (ignored with `--tls`) |
| `--tls` | off | Caddy reverse proxy, automatic HTTPS |
| `--owner HEX` | — | 64-char hex Nostr pubkey; closed relay |
| `--generate-owner` | off | Mint an owner keypair; closed relay |
| `--image-tag TAG` | `main` | `ghcr.io/block/buzz` tag |
| `--dir PATH` | `/opt/buzz-relay` | Install root |

Pin `--image-tag` to a `sha-<7>` or semver tag for production; `main` tracks
upstream's pre-release builds.

## Back this up

`/opt/buzz-relay/src/deploy/compose/.env` (mode 0600) holds every generated
secret. They must stay stable across restarts — losing them means losing the
relay identity. Run `./run.sh backup-hint` for the full checklist, which also
covers the Postgres, MinIO, and git volumes.

Re-running `install.sh` on an existing install is refused rather than
regenerating secrets, because new credentials against the surviving Postgres
volume would just fail to authenticate.

## What's in this repo

| File | |
|---|---|
| `install.sh` | Clone upstream, write `.env`, call `run.sh start` |

Compose files, the image, the Caddyfile, and `run.sh` all come from upstream.
Upstream's own compose README notes that a bootstrap script "should eventually
replace manual `.env` editing" — if that lands, this repo stops being needed,
which is the intent.
