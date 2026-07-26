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

After install, this repo is done. Everything from then on is upstream's
`run.sh` — see [Managing the relay](#managing-the-relay).

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

## Managing the relay

Everything after install is upstream's `run.sh`, which lives beside the config:

```bash
cd /opt/buzz-relay/src/deploy/compose
./run.sh help
```

| Command | |
|---|---|
| `./run.sh status` | container status |
| `./run.sh logs [svc]` | follow logs (default: `relay`) |
| `./run.sh restart` | recreate the relay after editing `.env` |
| `./run.sh upgrade` | pull the latest image, restart, print backup reminders |
| `./run.sh stop` | stop containers, keep volumes |
| `./run.sh add-member <npub-or-hex>` | add a member to a closed relay |
| `./run.sh list-members` | list members |

Full reference: [`deploy/compose/README.md`](https://github.com/block/buzz/blob/main/deploy/compose/README.md)
in the upstream repo.

### If you installed with `--tls`, prefix every command

`run.sh` decides which compose files to load from the `BUZZ_COMPOSE_TLS`
environment variable. It does **not** read this from `.env`, so it has no
memory of how you installed:

```bash
BUZZ_COMPOSE_TLS=true ./run.sh upgrade
```

Forget the prefix and `run.sh` loads only `compose.yml` — Caddy drops out of
the stack and the relay republishes port 3000 directly, unencrypted. Verify
with `./run.sh config | grep published`: you should see `80` and `443`, never
`3000`. Consider adding `export BUZZ_COMPOSE_TLS=true` to your shell profile on
a TLS host.

### Upgrades

```bash
cd /opt/buzz-relay/src/deploy/compose
./run.sh upgrade          # add BUZZ_COMPOSE_TLS=true if you installed with --tls
```

That pulls the image named by `BUZZ_IMAGE` in `.env`, recreates containers, and
prints the backup checklist. Your `.env` is untouched, so secrets and relay
identity survive. `BUZZ_AUTO_MIGRATE=true` means schema migrations run on
startup.

Two things worth knowing:

- **`main` is a moving tag.** A fresh install pins `BUZZ_IMAGE=ghcr.io/block/buzz:main`,
  so `upgrade` pulls whatever upstream built most recently, untested against
  your data. For anything you care about, edit `BUZZ_IMAGE` in `.env` to a
  `sha-<7>` or semver tag and bump it deliberately.
- **Back up before upgrading**, not after. Run `./run.sh backup-hint` for the
  checklist — it covers `.env`, Postgres, MinIO, and the git volume.

To roll back, set `BUZZ_IMAGE` to the previous tag and `./run.sh upgrade`
again. Note that a migration applied by the newer image is not undone by
downgrading, which is the other reason to snapshot Postgres first.

## Uninstall / start over

Tear down containers, volumes, and network, then remove the files. The
subshell keeps your own shell out of a directory that's about to be deleted:

```bash
(cd /opt/buzz-relay/src/deploy/compose \
  && sudo docker compose --env-file .env -f compose.yml -f compose.caddy.yml \
       down -v --remove-orphans)

sudo rm -rf /opt/buzz-relay
```

Both `-f` flags are intentional — without `compose.caddy.yml` the two Caddy
volumes survive. `-v` destroys all relay data. Order matters: Compose needs
`.env` and the compose files, so tear down before deleting.

If the install died partway and `.env` is missing or broken, Compose can't
parse the files at all. Remove by project label instead:

```bash
sudo docker rm -f $(docker ps -aq --filter label=com.docker.compose.project=buzz-prod) 2>/dev/null
docker volume ls -q --filter name=buzz-prod | xargs -r sudo docker volume rm
docker network ls -q --filter name=buzz-prod | xargs -r sudo docker network rm
```

Everything this creates lives under the Compose project `buzz-prod`, so that
label is the complete handle. Confirm you're clean:

```bash
docker ps -a --filter name=buzz --format '{{.Names}}'
docker volume ls | grep buzz
sudo ss -lntp | grep -E ':(80|443|3000)\b'
```

## Troubleshooting

**`port is already allocated` on startup.** Something else holds the port. Find
it with `sudo ss -lntp | grep :3000`. The usual culprit is an older bare-metal
install whose systemd unit is still running — note that deleting the binary
does not stop a running process:

```bash
sudo systemctl disable --now buzz-relay
sudo rm -f /etc/systemd/system/buzz-relay.service
sudo systemctl daemon-reload
```

Then start the stack directly — **don't re-run `install.sh`**, which refuses
when `.env` exists:

```bash
cd /opt/buzz-relay/src/deploy/compose && ./run.sh start
```

**`couldn't find env file`.** You're in the wrong directory. Every `run.sh` and
`docker compose` command has to run from `/opt/buzz-relay/src/deploy/compose`.

**Certificate errors with `--tls`.** Public CAs only issue for publicly
resolvable names. A single-label host like `myserver` doesn't qualify, so Caddy
falls back to its internal CA and clients reject the self-signed cert. Either
use a real DNS name or drop `--tls`. Check with `./run.sh logs caddy`.

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
