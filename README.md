# Self-hosting a buzz relay

Scripts to run one [buzz](https://github.com/block/buzz) relay on one server, for
one community.

The relay itself is compiled from the upstream source and runs directly on the
machine under systemd. Its three datastores — Postgres, Redis, and MinIO — run
as Docker containers alongside it. Nothing else from the buzz project (desktop
app, agents, dev tooling) is installed.

## Before you start

You need a Linux server with:

- `git`, `docker`, and `openssl` installed, and the Docker daemon running
- the Docker Compose plugin, **version 2.24 or newer** (`docker compose version`)
- `sudo` access

The relay is compiled from source, so expect the first install to take a while.
You don't need to install Rust yourself — upstream ships its own toolchain via
Hermit, which the installer activates if it's there, falling back to a
system-installed `cargo` otherwise.

You also need to decide on a hostname before installing — see
[Choosing a hostname](#choosing-a-hostname).

## Install

Copy this directory to the server and run the installer:

```
scp -r buzz-relay-thin/ user@server:~/
ssh user@server 'cd buzz-relay-thin && sudo ./install.sh --host relay.lan'
```

The installer clones the upstream buzz source into `/opt/buzz-relay/src`,
generates an `.env` file with fresh random passwords, builds the relay, starts
the datastore containers, sets up the database, and installs a systemd service
that starts on boot.

When it finishes, clients connect to `ws://relay.lan:3000`.

Running the installer again is safe. It keeps your generated passwords and any
settings you've edited on the server. Add `--update` to pull the latest upstream
code and rebuild.

## Choosing a hostname

`--host` is the single most important decision here. **Every client must connect
using exactly the hostname you pass.**

The relay figures out which community a request belongs to by looking at the
`Host` header. It only knows about the one hostname you seeded at install time,
and refuses connections for anything else. So `relay.lan`, `relay.lan.`, an IP
address, and a different DNS name are four different things as far as the relay
is concerned — only one of them will work.

Practical advice:

- Use a stable DNS name, not a DHCP-assigned IP address.
- If you later put the relay behind a TLS proxy and switch clients to `wss://`,
  re-run `install.sh --host <new-hostname>` to register the new one.

## Before you expose it to the internet

Fresh installs come up as an **open relay** — `BUZZ_REQUIRE_AUTH_TOKEN=false` in
`.env` means anyone who can reach the port can connect. That's convenient on a
trusted LAN and wrong anywhere else. Set it to `true` and restart the service if
your relay is reachable more widely.

Two other things the installer deliberately leaves to you:

- **Firewall.** Open the relay port (3000 by default). Leave the datastore ports
  closed — they're bound to loopback and should stay that way.
- **TLS.** Traffic is plain `ws://`. Outside a trusted network, terminate TLS in
  a reverse proxy, serve `wss://`, and re-run the installer with `--host` set to
  the new hostname.

## Ports

Seven ports in total. Only the relay port is meant to be reachable from other
machines; the rest bind to loopback.

| Flag | Default | What it is |
|---|---|---|
| `--port` | 3000 | the relay — **the only port clients use** |
| `--health-port` | 8080 | relay health check |
| `--metrics-port` | 9102 | relay Prometheus metrics |
| `--pg-port` | 5432 | Postgres |
| `--redis-port` | 6379 | Redis |
| `--minio-port` | 9000 | MinIO (S3 API) |
| `--minio-console-port` | 9001 | MinIO web console |

If something on the box already uses one of these, move it at install time:

```
sudo ./install.sh --host relay.lan --port 3001 --health-port 8180
```

Only the host-side port changes; the ports inside the containers stay fixed, so
the services can still find each other.

**These flags only set defaults on a fresh install.** After that,
`/opt/buzz-relay/src/.env` on the server is the source of truth. To change a
port later, either pass the flag again or edit `.env` directly and restart:

```
sudo systemctl restart buzz-relay                    # relay ports
cd /opt/buzz-relay/src && docker compose up -d       # datastore ports
```

Either way, your changes survive the next `sudo ./install.sh --update`.

## Check that it worked

Confirm the relay started cleanly:

```
journalctl -u buzz-relay -n 200 | grep -E 'Config loaded|Deployment community ensured'
```

`Config loaded` should show your relay URL and ports. `Deployment community
ensured` should show `host=<your-host>:<port>`.

Then confirm the datastores aren't exposed to the network:

```
cd /opt/buzz-relay/src && docker compose config | grep -A3 ports
```

Every published port must start with `127.0.0.1:`. If any is a bare port number,
the Compose override didn't apply — almost always because Docker Compose is
older than 2.24, which is the first version that understands the `!override` tag
the override file uses. Without it, Compose *adds* the loopback binding next to
upstream's `0.0.0.0` one instead of replacing it, and **your database is open to
the network.** Upgrade Compose and re-run the installer.

## Day-to-day

```
systemctl status buzz-relay
systemctl restart buzz-relay
journalctl -u buzz-relay -f
```

To update to the latest upstream code, re-run the installer with `--update`, or
do it by hand:

```
cd /opt/buzz-relay/src
git pull && cargo build --release -p buzz-relay -p buzz-admin
sudo systemctl restart buzz-relay
```

Your `.env` and the Compose override are untracked, so a pull leaves them alone.

## What's in this repo

| File | What it does |
|---|---|
| `install.sh` | Does everything above: clone, generate `.env`, build, start datastores, migrate, install the service. |
| `docker-compose.override.yml` | Layered over upstream's `docker-compose.yml` to bind the datastores to loopback and read ports and passwords from `.env`. |
| `buzz-relay.service` | The systemd unit — applies migrations, then runs the relay. |

`.env` is generated on the server, not tracked here.

## Notes on how it's put together

Useful if you're modifying this, skippable otherwise.

**Only two crates are built** — `buzz-relay` and `buzz-admin`, in release mode.
Building the whole workspace would drag in the desktop app and agent crates that
a relay box has no use for.

**Only four containers start** — `postgres`, `redis`, `minio`, and a one-shot
`minio-init` that creates the storage bucket. Upstream's dev-only services
(Keycloak, Adminer, Prometheus) never come up.

**The systemd unit runs the binary directly** (`Type=simple`), so the relay is
the main process and signal handling stays clean. `ExecStartPre` re-applies
migrations on every start using the compiled `buzz-admin migrate` rather than
upstream's `just migrate` — `just` comes from Hermit, which wants a writable
`$HOME/.cache` that the unit's sandboxing (`ProtectHome`, `ProtectSystem`)
blocks. Migrations are idempotent, so a restart with nothing to do costs
nothing.
