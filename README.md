# buzz-relay server deploy (thin / upstream-reusing variant)

Same outcome as the self-contained package, but leans on the repo's own scripts
instead of reimplementing them. Three files instead of five, and about a quarter
of the hand-written config.

## What is reused from upstream

| Concern | Upstream artifact |
|---|---|
| Datastore stack | the repo's `docker-compose.yml` (images, healthchecks, volumes, bucket init) |
| Migrations + community seed | `just migrate` = `_ensure-migrations` = `buzz-admin migrate` + `scripts/seed-local-community.sh` |
| Env baseline | `.env.example`, copied then patched, so new upstream variables are inherited |
| Toolchain | `bin/activate-hermit` |
| Day-two ops | `just ps`, `just logs`, `just down` |

## What is still ours, and why it cannot be avoided

**`docker-compose.override.yml`** exists for two reasons. The repo publishes
ports bare (`"5432:5432"`), which binds `0.0.0.0` and would expose Postgres,
Redis, and MinIO to the whole network on a server, with `buzz_dev` credentials.
And the repo hardcodes those credentials, so rotation needs an override rather
than edits to a tracked file. Compose merges the override automatically, so
`git pull` leaves it alone.

**`buzz-relay.service`** has no upstream equivalent. The repo's runner is
`just relay` (debug build via `cargo run`) or `just relay-release`. Both are
foreground dev commands, and running `cargo run` under systemd makes cargo the
main PID rather than the relay, which muddies restart and signal handling. The
unit runs `target/release/buzz-relay` directly and uses `ExecStartPre` to call
`just migrate`, so migrate-and-seed stays upstream logic while process
supervision stays clean.

**`install.sh`** is orchestration only. About 90 lines, mostly argument parsing
and the `.env` patch.

## What is deliberately skipped from upstream

`just setup` calls `scripts/dev-setup.sh`, which runs `pnpm install` for desktop
dependencies and brings up all six compose services including Keycloak
(`admin`/`admin`), Adminer, and Prometheus. `just build` runs
`cargo build --workspace`, compiling the desktop and agent crates a relay box
does not need. This installer starts four named services and builds two crates.

## Install

```
scp -r buzz-relay-thin/ user@server:~/
ssh user@server 'cd buzz-relay-thin && sudo ./install.sh --host relay.lan'
```

## Prerequisite worth checking first

The override uses the `!override` tag, which needs Docker Compose v2.24+.
It is load-bearing: Compose's default merge for a `ports` list is to *append*,
so without it you would keep the `0.0.0.0` binding next to the loopback one.

```
docker compose version
cd /opt/buzz-relay/src && docker compose config | grep -A3 ports
```

Every published port should show a `127.0.0.1:` prefix. If any is bare, the
override did not apply and your datastores are network-exposed.

## Tradeoff against the self-contained package

Reuse wins on drift: an upstream fix to a healthcheck, a new service the relay
starts depending on, or a new required variable in `.env.example` all arrive with
`git pull`. The self-contained version would silently go stale.

Reuse costs you explicitness. Reading these three files does not tell you what
the stack is; you have to read the repo's compose too. And you inherit upstream's
choices, including the dev-oriented defaults the override has to fight.

Pick reuse if you intend to track upstream. Pick self-contained if you want a
frozen, auditable deployment that does not change under you.

## Same caveat as before

Each authority is its own community. The relay resolves a community from the
Host header and fails closed when there is no matching row, one row per host.
Pick one hostname and use it on every client, including the desktop.
