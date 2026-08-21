# Pointy On-Prem Docker Stack

This stack is for a customer site where Windows is the host OS and Docker
Desktop runs Linux containers. Cashier devices connect to the backend over LAN;
PostgreSQL, Redis, Celery, and the connector stay inside Docker.

A `web` service (nginx) also serves the Flutter web app and reverse-proxies the
API on the same origin, so any device on the LAN can use Pointy from a browser at
`http://<server-ip>/` with no install. Native tills still connect directly to the
backend on `:8000` via discovery, so the web front door is purely additive — if
it is down, the tills are unaffected.

## First Install

1. Docker is installed for you — on Linux `install.sh` downloads and installs it
   (run as root); on Windows the bundled WSL distro already has Docker Engine
   inside it, so nothing is downloaded at all.
2. On Windows run `wsl\bootstrap-wsl.ps1` from an **elevated** PowerShell. It
   installs WSL, imports the distro, and runs `install.sh` inside it. The VM gets
   half the host's RAM capped at 8GB; 8GB of host RAM is the recommended
   profile, 4GB the floor for a tiny pilot.
3. Copy `deploy/onprem/.env.example` to `deploy/onprem/.env`.
4. Replace every secret and every `192.168.1.50` example with the Windows
   host's static LAN IP.
5. Allow inbound Windows Firewall traffic for TCP `8000` (API), UDP `47777`
   (LAN discovery), and TCP `80` (browser access).
6. Start the stack:

```sh
docker compose --env-file deploy/onprem/.env -f deploy/onprem/docker-compose.yml up -d --build
```

The backend runs migrations during startup, then starts Uvicorn against the
Django ASGI app. Celery starts only after the backend is healthy.

`:8000` — the port tills talk to — is owned by the `edge` service, a small nginx
that proxies to whichever backend container is currently live. That indirection
is what makes zero-downtime updates possible (see **Updates** below); it also
means the connector and the web app use Docker-internal `http://edge:8000`
rather than UDP discovery, and follow the same switchover the tills do.

## Health And Logs

```sh
docker compose --env-file deploy/onprem/.env -f deploy/onprem/docker-compose.yml ps
docker compose --env-file deploy/onprem/.env -f deploy/onprem/docker-compose.yml logs -f backend
curl http://127.0.0.1:8000/healthz/
curl http://127.0.0.1:8000/readyz/
```

`/healthz/` proves the web process is alive. `/readyz/` also verifies database
and Redis access.

## Updates

### Remote (no site visit)

Once `register-autostart.sh` has run, an **update agent** (`update-agent.sh`)
runs on a systemd timer alongside the watchdog — inside the WSL distro on
Windows hosts, exactly as on Linux. Each run it asks the relay which version this shop
should run (`POINTY_RELAY_PUBLIC_API_URL` in `.env`, authenticated with the shop's
connector token), and when a newer one is assigned it downloads the bundle **from
the relay**, verifies its sha256, backs up the database, applies it **live**
(no downtime — see below), health-checks `/readyz/`, and **rolls back
automatically** if the new version is unhealthy. It reports status back to the
relay (`pointy-relay fleet status`).

Because updates no longer close the tills, a rollout does not have to be timed
for after hours.

Operators drive it entirely from the relay — no shop access needed:

```sh
pointy-relay artifacts upload --version 1.4.0 --bundle pointy-onprem-1.4.0.zip
pointy-relay fleet set-version 1.4.0 --channel stable --rollout canary
pointy-relay fleet rollout 50%        # widen once the canaries look healthy
pointy-relay fleet rollout all
pointy-relay fleet pause              # kill switch: stop the rollout immediately
pointy-relay fleet pin <id> 1.3.0    # roll one shop back / hold it on a version
```

Preview what a shop would do without applying: `bash update-agent.sh --check`.
The agent needs `jq` or `python3`, plus `unzip`, on the host. A failed forward DB
migration is the one case auto-rollback can't fully heal — the agent takes a
`pg_dump` first (under `backups/`); keep migrations backward-compatible across one
version.

### Manual (offline / air-gapped)

```sh
bash update.sh /path/to/pointy-onprem-1.5.0.zip     # live; add --restart for a full restart
```

Run from the deploy directory. For development against source instead of a
bundle:

```sh
docker compose --env-file deploy/onprem/.env -f deploy/onprem/docker-compose.yml build backend connector
docker compose --env-file deploy/onprem/.env -f deploy/onprem/docker-compose.yml up -d
```

Keep the previous image tag available when doing customer updates, so rollback
is just changing `POINTY_BACKEND_IMAGE` or `POINTY_RELAY_IMAGE` and running
`up -d` again.

### Zero-downtime updates (how, and what a release must honour)

`update.sh` and the agent share one engine (`update-lib.sh`). It starts the new backend **beside** the running one, lets it
migrate and pass `/readyz/`, and only then flips the `edge` front door to it
with an `nginx -s reload` — graceful, so in-flight requests finish on the old
container and none are refused. It then rebuilds the managed `backend` container
on the new image behind the standby and hands traffic back. Failure before the
flip is invisible to the shop; failure after it rolls the backend back.

Three rules follow from that, and they are on us, not on the shop:

* **Migrations must be backward compatible across one version.** Two app
  versions share the database for about a minute during every live update.
  Expand in one release, contract in a later one. (This was already the rule
  for auto-rollback; it is now load-bearing on the happy path too.)
* **A release that cannot honour it must say so.** Ship
  `UPDATE_STRATEGY.txt` containing `restart` in the bundle and every updater
  falls back to a full restart automatically, without the operator having to
  know.
* **Infrastructure is never replaced live.** Postgres, Redis, PgBouncer and the
  front door keep running; their images stay staged in `./images` until someone
  runs `install.sh` or `update.sh --restart`. Bumping the `pointy-edge` image
  tag is therefore a maintenance-window change, not a per-release one.

The watchdog cooperates: it stands down while `.update.lock` is fresh, it
reconciles with `--no-recreate` (availability, not convergence — it will never
restart the database on its own timer to apply a drift), and if an update dies
mid-flip it points the front door back at the managed backend.

## Backup Notes

Pointy application backups can write to the internal `pointy-backups` Docker
volume and to three external mount slots exposed under `/mnt/pointy-external`.
Set the source paths in `.env` to the real connected Windows drives or folders:

```env
POINTY_BACKUP_DRIVE_1_SOURCE=/mnt/d
POINTY_BACKUP_DRIVE_2_SOURCE=/mnt/e/PointyBackups
POINTY_BACKUP_DRIVE_3_SOURCE=/mnt/f
```

On Windows the stack runs inside a WSL2 distro, which mounts the host's drives
under `/mnt` — `D:/` is `/mnt/d`. Use that form, never a drive letter: a drive
letter is not a path any Linux container can resolve, and `install.sh` rejects
it outright.

Two failure modes to know about, because neither announces itself:

- **The drive is not attached when the stack starts.** `/mnt/d` does not exist,
  and Docker creates a missing bind source as an empty directory *inside the
  virtual disk*. Backups then "succeed" into the very disk they were meant to
  survive. `install.sh` warns when a configured drive is missing — that warning
  is the whole point, so do not skip past it.
- **The drive is attached after WSL has booted.** WSL does not hot-mount it.
  Mount it by hand (`mount -t drvfs d: /mnt/d`) or restart the distro.

If a drive is mounted at its root, Pointy's backup destination picker will list
the drive slot and its writable child folders. The same mounts are attached to
the web, Celery worker, and Celery beat containers so destination listing,
manual backups, and scheduled backups all see the same paths.

For stronger recovery guarantees, pair Pointy's app backup with PostgreSQL
physical/base backups and WAL archiving.

## Hardening Notes

The Pointy backend and connector containers run as non-root users. The backend
image uses a Python virtualenv, removes `pip`, strips the shell and common
Debian package-manager commands from the final image, and runs Uvicorn against
the ASGI app. The connector runtime is `scratch` and contains only the
`pointy-relay` binary, CA certificates, time zone data, and its state directory.

Compose additionally applies a read-only root filesystem, drops all Linux
capabilities, blocks privilege escalation, and sets PID limits for the Pointy
backend, Celery, Beat, and connector containers. Writable paths are limited to
named volumes, tmpfs, and explicitly configured backup drive mounts.

The `web` (nginx) container is also read-only with tmpfs-only writable paths,
no-new-privileges, and CPU/memory/PID caps. It keeps its default Linux
capabilities on purpose — nginx needs them to bind port 80 and drop worker
process privileges — but holds no secrets and only serves the static web bundle
and proxies the API.

Every service also has a memory (`mem_limit`) and CPU (`cpus`) cap so one
runaway process — a heavy report, a worker leak, a restore — cannot starve the
host and take down the till. Defaults total well under 8GB; raise the
`POINTY_*_MEM_LIMIT` / `POINTY_*_CPUS` values in `.env` on larger hosts.

### Brute-force protection

The login, initial-admin-setup, and password-change endpoints are rate-limited
(`DJANGO_THROTTLE_*`). When the backend sits behind a reverse proxy, set
`DJANGO_NUM_PROXIES` to the number of trusted proxies so the throttle keys on
the real client IP; the default of `0` keys on the direct peer and ignores
`X-Forwarded-For` to prevent spoofing. Throttle state lives in Redis and fails
open if Redis is down, so a cache outage never locks cashiers out.

### Audit trail

Completed sales are append-only: the API exposes no edit or delete for orders,
so corrections must go through the audited void/return flow (even managers
cannot erase a sale). Domain events, stock movements, and register cash
movements are read-only in the Django admin and cannot be deleted there.

## Resilience And Failure Behavior

- **Redis down:** Sales still work — checkout, payment, stock decrements, and
  receipt jobs are written synchronously to PostgreSQL inside the sale
  transaction, so no paid receipt is lost. What pauses is asynchronous work
  (scheduled backups, notification sync, fraud scans) and rate limiting. Print
  agents keep printing queued receipts because they poll the database. Restart
  Redis to resume background jobs; queued receipts and sales need no replay.
- **Disk full:** PostgreSQL stops accepting writes and the backend's `/readyz/`
  check fails, so checkout errors out rather than silently losing data. Monitor
  free space on the Docker volume host and on backup drives; the backup
  retention count (`POINTY_BACKUP_RETENTION_COUNT`) bounds archive growth, and
  container logs are capped at 10MB × 5 files per service.
- **A service crashes:** All services use `restart: always`, so Docker restarts
  a crashed container in place immediately and brings the whole stack back when
  the Docker engine starts. Celery only starts once the backend is healthy.
- **A container is destroyed, or the host reboots:** A watchdog (`watchdog.sh`,
  registered by `register-autostart.sh` as a systemd timer) runs at boot and
  every 5 minutes. It runs `docker compose up -d` to recreate any removed or
  stopped container and restarts any container left "unhealthy" (which the
  restart policy alone will not do). On Windows a single scheduled task,
  `PointyWSL`, starts the distro on the same cadence so systemd is there to run
  that timer — and it needs **no** interactive logon, unlike the Docker Desktop
  install it replaces. See INSTALL.md > Resilience.
- **Long task hangs:** Celery enforces soft/hard time limits
  (`CELERY_TASK_*_TIME_LIMIT`) so a stuck task cannot pin a worker forever;
  backup/restore are exempted with their own higher limits.

For stronger recovery guarantees, pair Pointy's app backup with PostgreSQL
physical/base backups and WAL archiving, and monitor host disk usage.
