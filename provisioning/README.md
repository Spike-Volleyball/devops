# Server Provisioning

Tracks the previously-untracked `/opt/volleyspike/setup.sh` (SPI-5711) plus the
day-0 OS setup and firewall it always depended on but never version-controlled.

## Run order

1. **`bootstrap.sh`** (as root) — day-0 OS setup: purges `ufw`, installs
   nftables/Docker/WireGuard tools, pins Docker's firewall backend to
   nftables, installs and applies `nftables.conf` to `/etc/nftables.conf`,
   creates the `deploy` user, provisions swap. Idempotent — safe to re-run.
2. **`nftables.conf`** — installed and applied automatically by
   `bootstrap.sh`, before WireGuard's `wg0` interface needs to exist:
   `iifname "wg0"` is a plain string match, not an interface lookup, so the
   rule loads fine with no such interface yet. To re-apply by hand after
   editing the file, use `nft -f nftables.conf` (or `nft -c -f nftables.conf`
   to check syntax without applying) — never `systemctl restart nftables`,
   see the warnings in the file's header comment.
3. **WireGuard** — bring up `wg0` whenever convenient; the ruleset's
   SSH-over-VPN and `iifname "wg0" accept` rules are already active from
   bootstrap and start matching the moment the interface exists.
4. **`setup.sh`** — interactive script (run on the box at
   `/opt/volleyspike/setup.sh`) that prompts for credentials, writes the
   per-service `.env.*` files, and starts the Docker stack.

## Before running `setup.sh`

`setup.sh` only generates secrets and starts the stack — it creates
`$DEPLOY_PATH/{caddy,init,migrations,backups}` but does not populate them,
and it does not fetch the compose files or telemetry config it then runs.
Docker fills in any missing bind-mount *source* by materializing an empty
root-owned directory at that path, so a missing file fails quietly: `caddy`
crash-loops on "Caddyfile is a directory" while `setup.sh` itself still
prints "Setup Complete" and exits 0. None of this is synced by the
per-service CI/CD pipeline (`deploy-service.yml` only ships migration
bundles to `$DEPLOY_PATH/migrations`) — get all of the following onto the
box, out of band, before the first `setup.sh` run:

- **Compose files** — `docker-compose.yml`, `docker-compose.<environment>.yml`,
  `docker-compose.exporters.yml`, from this repo's `docker/`, directly at
  `$DEPLOY_PATH` (`setup.sh` runs `docker compose` from there with bare
  `-f docker-compose.yml` filenames).
- **`caddy/Caddyfile.production`** — from this repo's `caddy/`, at
  `$DEPLOY_PATH/caddy/Caddyfile.production`.
- **`caddy/certs/origin.pem` and `origin.key`** — the Cloudflare Origin CA
  cert. Never committed (`caddy/certs/` is gitignored) — issue it in
  Cloudflare and place both files at `$DEPLOY_PATH/caddy/certs/` by hand.
- **`init/`** — Postgres init scripts, from this repo's `docker/init/`, at
  `$DEPLOY_PATH/init/`.
- **`alloy/config.alloy`** — from this repo's `docker/alloy/`, at
  `$DEPLOY_PATH/alloy/config.alloy` (only needed if running
  `docker-compose.exporters.yml`).
- **`otel-collector/otel-collector-config.yml`** — from this repo's
  `docker/otel-collector/`, at `$DEPLOY_PATH/otel-collector/`.
- **Monitor scripts** — `provisioning/scripts/docker-monitor.sh` and
  `provisioning/systemd/docker-monitor.service` from this repo, copied
  **flat** to `$DEPLOY_PATH/docker-monitor.sh` and
  `$DEPLOY_PATH/docker-monitor.service` (no `provisioning/` prefix —
  `setup.sh` reads them straight from `$DEPLOY_PATH`; it skips installing the
  monitor with a warning, rather than aborting, if they're missing). Also
  copy `provisioning/scripts/docker-stats-collector.sh` the same way — it
  feeds node-exporter's textfile collector but isn't installed by either
  script, so schedule it yourself (cron or a systemd timer).

## Migrating an existing environment

When provisioning a **replacement** server for an environment that already
has live secrets, copy the existing `.env*` files into `/opt/volleyspike/`
first, then run:

```bash
SKIP_SECRET_GENERATION=1 ./setup.sh --force
```

**Both flags are required, and neither substitutes for the other — they gate
two independent checks:**

- `--force` bypasses `setup.sh`'s top-of-file guard, which otherwise exits 1
  as soon as it sees `$DEPLOY_PATH/.env` already present (which it will be,
  since you just copied it there).
- `SKIP_SECRET_GENERATION=1` bypasses the actual secret/env-file **write**
  steps (10, 11, 12, 12b, 13, 13b) further down the script, so the copied
  files are left alone instead of being regenerated.

**`--force` alone is the dangerous case.** It only clears the guard; without
`SKIP_SECRET_GENERATION=1` the script proceeds straight into regenerating
`POSTGRES_PASSWORD`, `REDIS_PASSWORD`, `RABBITMQ_PASSWORD`, and `JWT_SECRET`
and overwriting every per-service env file — desyncing from a restored
database (still using the old Postgres password) and invalidating every
issued JWT. This is exactly what the guard's own error text warns about if
you hit it without `SKIP_SECRET_GENERATION=1` set.

Every write step guarded by `SKIP_SECRET_GENERATION=1` logs that it's
reusing the copied file instead of overwriting it.

## Firewall

- `ufw` must stay purged. `bootstrap.sh` removes it
  (`apt-get remove --purge -y ufw`); nftables is the only firewall on this
  box. Reinstalling `ufw` enables `default deny incoming` and severs
  80/443/51820.
- `nftables.conf`'s forward chain is deliberately empty with `policy accept`
  — Docker's own `docker-bridges` table already enforces container
  isolation. Do not add "defensive" rules there: a second forward chain at
  `policy drop` is what silently blackholed every Prometheus scrape for 17
  days on the previous iptables-based setup. See the comments in the file.
- `net.ipv4.ip_forward=1` **must be persisted before Docker's first start** —
  `bootstrap.sh` writes `/etc/sysctl.d/99-docker-ip-forward.conf` ahead of
  the Docker install for exactly this reason. Do not remove that file. If
  forwarding isn't already enabled when Docker starts, two things go wrong:
  Docker refuses to create its default bridge network at all (confirmed by
  rebooting the target box: `dockerd` fails outright with "IPv4 forwarding
  is disabled"), and on any run where Docker *does* enable forwarding itself,
  it also sets the legacy `filter-FORWARD` chain to `policy drop` — the exact
  failure mode this task exists to eliminate. `daemon.json`'s
  `ip-forward-no-drop: true` is a second, independent layer against that same
  policy-drop chain in case this sysctl file is ever lost.

## WireGuard IPs

- `10.10.0.2` — production
- `10.10.0.3` — staging
- `docker-compose.production.yml` binds its monitoring/debug ports to
  `${WG_BIND_IP:-10.10.0.2}` rather than the literal address, so the stack
  can start on a host that doesn't (yet) own `10.10.0.2`. Set `WG_BIND_IP` in
  that server's `.env` to override the default.

## Telemetry exporters

`docker/docker-compose.exporters.yml` runs the host-network telemetry agents
— `node-exporter`, `postgres-exporter`, `redis-exporter`, `alloy` — alongside
the main stack. Start it with both env files:

```bash
docker compose -f docker-compose.exporters.yml --env-file .env --env-file .env.monitoring up -d
```

Its four bind addresses (`--web.listen-address` on the three exporters,
`--server.http.listen-addr` on `alloy`) use the same
`${WG_BIND_IP:-10.10.0.2}` convention as `docker-compose.production.yml`, for
the same reason: this file previously hardcoded `10.10.0.2` and crash-looped
on any host that isn't the origin server (`bind: cannot assign requested
address`).

## Backups

Production databases are backed up hourly to S3 and restore-tested daily by
`scripts/spike-backup.sh` and the `systemd/spike-db-*` units. Install steps
and the restore runbook are in [BACKUPS.md](BACKUPS.md). A rebuilt box has no
backups until they are installed again.
