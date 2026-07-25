# buzz-relay server deploy

Relay only. No desktop, no agents, no harness. Drop this folder on a fresh
Linux server and run `install.sh`.

## Files

| File | Purpose |
|---|---|
| `install.sh` | Bootstrap: clone, build, render env, start datastores, migrate, seed, install unit |
| `docker-compose.yml` | Minimal stack: Postgres, Redis, MinIO. Datastore ports bound to loopback |
| `env.template` | Every variable the relay reads. Rendered to `src/.env` with generated secrets |
| `buzz-relay.service` | systemd unit with hardening directives |

## Install

```
scp -r buzz-relay-deploy/ user@server:~/
ssh user@server
cd buzz-relay-deploy
sudo ./install.sh --host relay.lan --port 3000
```

Use a stable DNS name for `--host` if you can. See the warning below about why.

Verify:

```
journalctl -u buzz-relay -n 200 | grep -E 'Config loaded|Deployment community ensured'
```

`relay_url` and `host` must both show your chosen authority. If `relay_url` says
`ws://localhost:3000`, the env did not take effect.

## The one thing that will bite you: host binding

The relay resolves a community from the request's **Host header** and fails
closed when there is no matching row in the `communities` table. That table
holds **one row per host**, so each authority is a *separate community* with its
own channels and members.

Consequences:

- `localhost:3000` and `192.168.1.50:3000` are two different communities.
- Pointing your desktop at one and your phone at the other puts them in
  different places, and neither sees the other's messages.
- Changing the host later does not move your community. It creates a new empty
  one at the new address.
- A DHCP lease change on an IP-based host orphans your community.

So: pick one authority, use it on every client, and prefer a name you control.

To add an authority (for example when moving to `wss://`):

```
cd /opt/buzz-relay/src
RELAY_URL=wss://relay.example.com ./scripts/seed-local-community.sh
```

That creates the row. It does not migrate anything into it.

## What is deliberately not automated

**TLS.** Traffic is plain `ws://`. Acceptable on a trusted LAN, not otherwise.
For real exposure, put Caddy or nginx in front, serve `wss://`, then set
`RELAY_URL` to the `wss://` authority and seed that host.

**Firewall.** Open the relay port yourself. Datastore ports publish to
`127.0.0.1` only and should stay that way; the relay reaches them over loopback.

**Backups.** Postgres holds every event. `postgres-data` and `minio-data` are
named Docker volumes. Snapshot them or run `pg_dump` on a schedule.

## Secrets

`install.sh` generates the Postgres password, the MinIO secret, and the relay's
nostr private key with `openssl rand`, then writes `src/.env` at mode 0600. It
will not regenerate them on a re-run.

Two variables matter more than they look:

- `BUZZ_RELAY_PRIVATE_KEY` — without it the relay falls back to a **hardcoded
  dev keypair** and says so at startup.
- `BUZZ_S3_ACCESS_KEY` / `BUZZ_S3_SECRET_KEY` — these default to
  `buzz_dev` / `buzz_dev_secret` **in code**, so omitting them silently keeps
  dev credentials rather than failing.

The Postgres password appears twice in `.env`, once as `POSTGRES_PASSWORD` for
compose and once inline in `DATABASE_URL` for the relay. systemd does not expand
`${VAR}` in an `EnvironmentFile`, so it cannot be factored out. `install.sh`
renders both from one generated value. **If you rotate by hand, change both.**

## Attaching agents later

The relay does not know agents exist; they are ordinary clients. To run one
headless, on this box or another:

```
BUZZ_RELAY_URL=ws://relay.lan:3000 \
BUZZ_PRIVATE_KEY=<agent nostr secret> \
BUZZ_ACP_AGENT_OWNER=<your pubkey> \
BUZZ_ACP_AGENT_COMMAND=buzz-agent \
buzz-acp --agents 1 --respond-to owner-only
```

Note `BUZZ_RELAY_URL` is the *agent's* variable; the relay itself reads plain
`RELAY_URL`. Build the agent binaries with
`cargo build --release -p buzz-acp -p buzz-agent`.

Skill discovery in `buzz-agent` is working-directory relative (`.agents/skills`,
`.goose/skills`, `.claude/skills`, walking from git root down to cwd, plus
`$HOME`), so one process per agent with its own working directory gives each
agent its own skill set.

## Known upstream bug

As of late July 2026, agents can log `discovered 0 channel(s)` and sit idle even
when the client shows them as channel members
([block/buzz#2641](https://github.com/block/buzz/issues/2641)). It affects both
the `buzz-agent` and Claude Code harnesses and is not caused by relay config.
`--channels` (`BUZZ_ACP_CHANNELS`) takes an explicit channel list and may work
around it, untested. The relay itself is unaffected.
