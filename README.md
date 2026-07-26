# buzz-relay-thin

A one-time bootstrap for a self-hosted [buzz](https://github.com/block/buzz)
relay.

```bash
git clone https://github.com/armstrys/buzz-relay-thin.git
cd buzz-relay-thin
sudo ./install.sh --host relay.lan --generate-owner
```

The relay comes up at `ws://relay.lan:3000`, closed, with you as the owner.
Save the private key it prints — it appears once.

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

## Open vs closed — read this before choosing

`install.sh` refuses to run until you pick one. There is no default, because
the wrong choice is not recoverable.

### Closed (recommended)

```bash
# Mint an owner keypair:
sudo ./install.sh --host relay.lan --generate-owner

# Or use a Nostr identity you already have (64-char hex, not an npub):
sudo ./install.sh --host relay.lan --owner <hex>
```

Sets `RELAY_OWNER_PUBKEY` and turns on `BUZZ_REQUIRE_AUTH_TOKEN`,
`BUZZ_REQUIRE_RELAY_MEMBERSHIP`, and `BUZZ_ALLOW_NIP_OA_AUTH`. Everyone else
must be added explicitly:

```bash
cd /opt/buzz-relay/src/deploy/compose
./run.sh add-member <npub-or-hex>
```

`--generate-owner` prints the private key **once** and never stores it. Save it
before you close the terminal — that key is how you administer the relay.

### Open — no access control at all

```bash
sudo ./install.sh --host relay.lan --open
```

This does **not** merely mean "anyone can connect". With no membership
requirement, "authenticated" means nothing more than completing NIP-42 AUTH,
which anyone can do with a keypair generated on the spot. That key can then:

- **create channels** — `validate_admin_event` returns `Ok(())` for kind 9007
  before performing any check
- **join any public channel**, and **add other people to it** — the relay's own
  comment reads *"open channels allow any authenticated user"*
- **grant itself `owner` or `admin` on any public channel** — the
  "only owners/admins may grant elevated roles" check runs only inside the
  `if channel.visibility == "private"` branch
- **kick members and delete messages**, once it holds one of those roles

None of it is revocable, because there is no identity to revoke. Anyone who can
route a packet to the port is effectively an administrator of every public
channel.

Use `--open` only where you would be comfortable handing every device on the
network admin over every channel. Private channels are meaningfully protected;
public ones are not.

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

## TLS on a LAN (required for mobile)

The mobile app cannot use `ws://`, and that's the operating system, not the
app: Android denies cleartext by default since API 28 (the manifest sets no
`usesCleartextTraffic`), and iOS ATS denies it with no exception in
`Info.plist`. The invite-link path additionally accepts only `https`/`wss`.

`--tls` does **not** solve this on a LAN. It uses Let's Encrypt, which must
reach your box from the internet on 80/443. `install.sh` now refuses `--tls`
for a hostname with no dot, because Caddy would quietly fall back to a
self-signed internal CA — and phones reject that. Android ignores
user-installed CAs unless an app explicitly opts in, so "just install the root
cert" does not work there.

What does work is terminating TLS with something that already holds a publicly
trusted certificate, then pointing it at the relay:

```bash
sudo ./install.sh --host <public-name> --port 3001 --external-tls --generate-owner
```

`--external-tls` still publishes the relay on `--port` for your terminator to
forward to, but writes `wss://` / `https://` URLs with no port, since clients
dial 443.

### Tailscale (easiest, no domain needed)

Tailscale issues real Let's Encrypt certificates for `*.ts.net` names, so
phones on your tailnet trust them with nothing installed, and nothing is
exposed to the internet.

```bash
tailscale up
tailscale cert "$(tailscale status --json | jq -r .Self.DNSName | sed 's/\.$//')"
tailscale serve --bg --https=443 http://127.0.0.1:3001
```

Then install with that name:

```bash
sudo ./install.sh --host <machine>.<tailnet>.ts.net --port 3001 \
  --external-tls --generate-owner
```

Requires HTTPS enabled for your tailnet (admin console → DNS → HTTPS
Certificates). Clients connect to `wss://<machine>.<tailnet>.ts.net`.

### Your own domain, DNS-01

If you own a domain, point a record at the LAN IP (a private address in public
DNS is fine) and issue via the DNS-01 challenge, which needs no inbound
reachability. Caddy can do this, but `caddy:2-alpine` ships without DNS
provider plugins, so it means building a custom Caddy image rather than using
upstream's `compose.caddy.yml` — then run the relay with `--external-tls`.

### Whatever you pick, the name is the identity

The relay keys communities off the `Host` header, so the hostname you install
with must be exactly what clients dial, and your terminator must forward that
`Host` through unchanged. Switching names later means reinstalling.

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
| *(access model)* | *(required)* | One of `--generate-owner`, `--owner`, `--open` |
| `--port N` | 3000 | Relay port (ignored with `--tls`) |
| `--tls` | off | Caddy reverse proxy, automatic HTTPS (public DNS name only) |
| `--external-tls` | off | TLS terminated elsewhere; write `wss://` URLs |
| `--owner HEX` | — | 64-char hex Nostr pubkey; closed relay |
| `--generate-owner` | — | Mint an owner keypair; closed relay |
| `--open` | — | **No access control.** Required to opt in; see above |
| `--cors-origins CSV` | *(unset = any)* | Restrict CORS to these origins |
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

### Adding agents and other non-desktop clients

The relay's invite flow is HTTP-only: an owner or admin mints a code with
`POST /api/invites` and the joiner redeems it with `POST /api/invites/claim`,
both NIP-98 signed. The desktop app drives both ends (Settings → community
members → Invite → *Copy link*), but `buzz` the CLI exposes **neither** — there
is no `buzz invite` or `buzz join`. So anything headless that authenticates with
`BUZZ_PRIVATE_KEY` — bridge agents, bots, CI — cannot claim an invite today.

Until that lands, add them from the relay host instead:

```bash
sudo /opt/buzz-relay/src/deploy/compose/run.sh add-member <npub-or-hex>
```

`run.sh` `cd`s to its own directory first, so the absolute path works from
anywhere; no need to `cd` yourself. This path bypasses the invite system
entirely — it `exec`s `buzz-admin` inside the relay container, so it needs no
admin key at all, only root on the box. You do need the client's pubkey
out-of-band, which is the one thing invites exist to avoid. The CLI has no
`whoami`, so have the agent's operator read it off the key they configured
(`BUZZ_PRIVATE_KEY` accepts hex or nsec).

Add `--role admin` to let that identity mint invites of its own. `--role owner`
is rejected; ownership only moves by changing `RELAY_OWNER_PUBKEY`.

When adding several, put `sleep 1` between calls and do not parallelize — the
kind:13534 roster event upstream publishes on each add is timestamped to the
second, and same-second adds collide.

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

**`container buzz-prod-relay-1 is unhealthy` after reinstalling.** Docker
volumes outlive `rm -rf /opt/buzz-relay`. If a previous install's
`buzz-prod_buzz-postgres-data` survived, Postgres still holds the *old*
password while the new `.env` has a freshly generated one — the relay starts,
can't authenticate, and fails its readiness probe with nothing useful in the
compose output. `install.sh` now refuses to start in this state, but if you hit
it on an older version:

```bash
(cd /opt/buzz-relay/src/deploy/compose \
  && docker compose --env-file .env -f compose.yml down -v --remove-orphans)
```

Always tear down with `down -v` before removing the install directory, not
after — Compose needs the files to know what to delete.

**Client says "Load failed" but `curl http://host:port/_liveness` returns
`ok`.** That's CORS. The relay treats an empty `BUZZ_CORS_ORIGINS` as permissive
and a non-empty one as a strict allowlist. The desktop app is Tauri, so its
browser origin is `tauri://localhost` (macOS) or `http://tauri.localhost`
(Windows/Linux) — never the relay's own URL. Fresh installs leave the variable
empty for this reason; if yours has a value that doesn't include the client's
origin, clear it:

```bash
cd /opt/buzz-relay/src/deploy/compose
sed -i 's|^BUZZ_CORS_ORIGINS=.*|BUZZ_CORS_ORIGINS=|' .env
./run.sh restart
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
