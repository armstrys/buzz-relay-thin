# Self-hosting a buzz relay

One command. No Rust toolchain, no systemd, no bare-metal build, no host port
collisions.

```
./install.sh --host relay.lan
```

That's it. The relay is up at `ws://relay.lan:3000`, and nothing else on your
box sees a single extra port.

## What it does

1. Clones `block/buzz` and uses its `deploy/compose/` bundle
2. Generates all secrets (`openssl rand`) and writes a complete `.env`
3. Runs `docker compose up -d --wait`

The relay, Postgres, Redis, and MinIO all run as containers on a shared Docker
bridge network. **Only the relay port (default 3000) is published to the host.**
The datastores are invisible — no 5432, 6379, 9000, or 9001 to collide with
anything.

## Before you start

You need a Linux server with:

- `git` and `openssl` installed
- Docker + the Compose plugin (`docker compose version`)
- The Docker daemon running

That's it. No `sudo` unless your install dir is outside your home directory
(default `/opt/buzz-relay`).

## Install

```bash
git clone https://github.com/armstrys/buzz-relay-thin.git
cd buzz-relay-thin
./install.sh --host relay.lan
```

Clients connect to `ws://relay.lan:3000`.

### With TLS (public server)

```bash
./install.sh --host buzz.example.com --tls
```

This adds Caddy, which terminates HTTPS on 80/443 and proxies to the relay
container internally. The relay port is not published to the host — only 80
and 443.

## Choosing a hostname

`--host` is the single most important decision. Every client must connect
using exactly this hostname. The relay identifies communities by the `Host`
header, so `relay.lan`, `relay.lan.`, an IP address, and a different DNS name
are all different communities.

- Use a stable DNS name, not a DHCP IP.
- Switching to TLS later: re-run with `--tls --host <new-hostname>`.

## Options

| Flag | Default | What it does |
|---|---|---|
| `--host` | *(required)* | Canonical hostname clients use |
| `--port` | 3000 | Relay port on the host |
| `--tls` | off | Add Caddy reverse proxy with automatic HTTPS |
| `--update` | off | Pull latest image and restart (keeps `.env`) |
| `--down` | off | Stop and remove containers (volumes preserved) |
| `--force` | off | Overwrite existing `.env` (regenerates secrets) |
| `--image-tag` | `main` | `ghcr.io/block/buzz` tag to use |
| `--dir` | `/opt/buzz-relay` | Install root |
| `--user` | invoking user | Owner/runtime user |

## Ports

Only one port is published to the host by default:

| Port | What it is |
|---|---|
| 3000 | Relay (WS + REST) — the only port clients use |

Postgres, Redis, and MinIO run on an internal Docker bridge network. They
are not published to the host. This means:

- No port collisions with other services on the box
- No `!override` compose tricks
- No loopback binding to manage

With `--tls`, the published ports are 80 and 443 (Caddy), and the relay port
is container-internal only.

## Day-to-day

```bash
# View logs
cd /opt/buzz-relay/src/deploy/compose
docker compose --env-file .env -f compose.yml logs -f relay

# Restart the relay
docker compose --env-file .env -f compose.yml restart relay

# Stop everything (keeps data)
./install.sh --down

# Update to latest image
./install.sh --host relay.lan --update

# Full status
docker compose --env-file .env -f compose.yml ps
```

## Before you expose it to the internet

Fresh installs come up as an **open relay** (`BUZZ_REQUIRE_AUTH_TOKEN=false`).
Anyone who can reach the port can connect. Set it to `true` in `.env` and
restart with `--update` if your relay is reachable beyond a trusted LAN.

## What changed from the old install

This repo previously deployed the relay as a bare-metal binary under systemd,
with datastores in Docker containers bound to loopback. That required:

- A Rust toolchain (Hermit) and a long first build
- systemd + root access
- 7 host port bindings with collision avoidance flags
- A `docker-compose.override.yml` using the `!override` tag (Compose v2.24+)

None of that is needed anymore. The upstream `block/buzz` project now ships a
pre-built Docker image (`ghcr.io/block/buzz:main`) and a production compose
bundle (`deploy/compose/`). This repo is now a **bootstrap wrapper** that
generates secrets and configures that bundle in one command.

## What's in this repo

| File | What it does |
|---|---|
| `install.sh` | Clones upstream, generates `.env`, starts the stack |

That's it. The compose files, image, Caddyfile, and `run.sh` all come from
upstream `block/buzz/deploy/compose/`.
