# buzz-relay server deploy (thin)

Stand up a single-community [buzz](https://github.com/block/buzz) relay on one
server. The relay is compiled from upstream and run **natively** under systemd;
its datastores — Postgres, Redis, MinIO — run as Docker containers. The rest of
the buzz monorepo (desktop app, agents, the extra dev services) is left out.

Three tracked files plus a generated `.env`:

| File | Role |
|---|---|
| `install.sh` | Clones upstream, renders `.env`, builds the relay, starts the datastores, migrates + seeds, installs the systemd unit. |
| `docker-compose.override.yml` | Merged over upstream's `docker-compose.yml` to bind the datastores to loopback and read their credentials and ports from `.env`. |
| `buzz-relay.service` | systemd unit: apply migrations, then run the release binary as the main process. |

## Install

```
scp -r buzz-relay-thin/ user@server:~/
ssh user@server 'cd buzz-relay-thin && sudo ./install.sh --host relay.lan'
```

`--host` is required and load-bearing: it becomes `RELAY_URL` and the seeded
community host, and every client must connect with that exact authority (see
[One host, one community](#one-host-one-community)).

Re-running is safe. Generated secrets in `.env` are left untouched; only the
host and ports are re-applied. Add `--update` to `git pull` the checkout before
rebuilding.

## Ports

The relay binds three ports on the host, and the datastores publish four more on
loopback. On a shared box any of these can collide with something already
running, so each is overridable. `install.sh` writes the value into `.env` and
keeps the relay's own config and the published container ports in sync.

| Flag | Default | Service |
|---|---|---|
| `--port` | 3000 | relay (`RELAY_URL` / `BUZZ_BIND_ADDR`) — the only port meant to be reachable off-box |
| `--health-port` | 8080 | relay health probe |
| `--metrics-port` | 9102 | relay Prometheus exporter |
| `--pg-port` | 5432 | Postgres |
| `--redis-port` | 6379 | Redis |
| `--minio-port` | 9000 | MinIO S3 API |
| `--minio-console-port` | 9001 | MinIO console |

On a crowded host, move the ones that clash:

```
sudo ./install.sh --host relay.lan --port 3001 --health-port 8180
```

Only the host-side port changes; container-internal ports stay fixed, so
inter-container references such as MinIO's `minio:9000` keep working.

## What it builds and starts

- **Builds** only `buzz-relay` and `buzz-admin` in release — not the workspace,
  so no desktop or agent crates compile.
- **Starts** only `postgres`, `redis`, `minio`, and the one-shot `minio-init`
  bucket step. Upstream's dev-only services (Keycloak, Adminer, Prometheus) are
  never brought up.
- **Migrates and seeds** at install time via upstream's `just migrate`
  (`buzz-admin migrate` plus the community-host seed script).

## One host, one community

The relay resolves a community from the incoming `Host` header and **fails
closed** when no row matches — one row per host, one community per authority.
So a single hostname has to agree everywhere: the value you pass to `--host`,
the `ws://…` URL entered in every client, and the desktop app. Prefer a stable
DNS name over a DHCP address. If you later front the relay with a TLS proxy and
serve `wss://`, re-run `install.sh` with `--host` set to the new authority to
seed that host.

## The systemd unit

`Type=simple`, running `target/release/buzz-relay` directly so the relay is the
main PID and restart/signal handling stays clean. `ExecStartPre` re-applies
migrations on every start using the compiled `buzz-admin migrate` binary —
deliberately **not** `just migrate`, because `just` comes from Hermit, which
needs a writable `$HOME/.cache` that this unit's hardening
(`ProtectHome`/`ProtectSystem`) denies. Migrations are idempotent and the relay
ensures its own community row at startup, so a boot with nothing to do is a
no-op.

Day-two operations:

```
systemctl {status,restart,stop} buzz-relay
journalctl -u buzz-relay -f
```

## Verify

Two log lines confirm a healthy start:

```
journalctl -u buzz-relay -n 200 | grep -E 'Config loaded|Deployment community ensured'
```

`Config loaded` should show your `relay_url` and the three relay ports;
`Deployment community ensured` should show `host=<your-host>:<port>`.

Then confirm the override actually merged. It relies on the `!override` YAML tag,
which needs **Docker Compose v2.24+**: without it, Compose *appends* port lists
and the upstream `0.0.0.0` binding survives right next to the loopback one.

```
cd /opt/buzz-relay/src && docker compose config | grep -A3 ports
```

Every published datastore port must carry a `127.0.0.1:` prefix. A bare binding
means the override did not apply and your datastores are exposed to the network.

## Left to you

- Open the relay port in the host firewall. The datastore ports are bound to
  loopback — keep them there.
- Traffic is plain `ws://`. Off a trusted LAN, terminate TLS in a reverse proxy,
  serve `wss://`, and re-run with `--host` set to the `wss://` authority.
