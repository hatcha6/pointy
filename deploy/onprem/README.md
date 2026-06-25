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

1. Install Docker Desktop and enable Linux containers.
2. In Docker Desktop settings, give the VM at least 4GB memory for tiny pilots
   or 6GB+ for the recommended 8GB host profile.
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
Django ASGI app. Celery starts
only after the backend is healthy. The connector uses Docker-internal
`http://backend:8000`, so it does not depend on container UDP discovery.

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

```sh
docker compose --env-file deploy/onprem/.env -f deploy/onprem/docker-compose.yml build backend connector
docker compose --env-file deploy/onprem/.env -f deploy/onprem/docker-compose.yml up -d
```

Keep the previous image tag available when doing customer updates, so rollback
is just changing `POINTY_BACKEND_IMAGE` or `POINTY_RELAY_IMAGE` and running
`up -d` again.

## Backup Notes

Pointy application backups can write to the internal `pointy-backups` Docker
volume and to three external mount slots exposed under `/mnt/pointy-external`.
Set the source paths in `.env` to the real connected Windows drives or folders:

```env
POINTY_BACKUP_DRIVE_1_SOURCE=D:/
POINTY_BACKUP_DRIVE_2_SOURCE=E:/PointyBackups
POINTY_BACKUP_DRIVE_3_SOURCE=F:/
```

Docker Desktop runs Linux containers inside a small Linux VM. A Windows drive
letter such as `D:/` is a host path, not something the image can see by itself.
Docker Desktop must allow that host path to be shared with the VM before Docker
can bind-mount it into a container. This cannot be enabled from inside the
Docker image because image code starts only after the Docker daemon has already
accepted or rejected the mount.

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
- **A container is destroyed, or the host reboots:** A watchdog
  (`watchdog.ps1` / `watchdog.sh`, registered via `register-autostart.*`) runs at
  boot and every 5 minutes. It runs `docker compose up -d` to recreate any
  removed/stopped container and restarts any container left "unhealthy" (which
  the restart policy alone will not do). See INSTALL.md > Resilience — on Windows
  this also requires automatic logon so Docker Desktop starts unattended.
- **Long task hangs:** Celery enforces soft/hard time limits
  (`CELERY_TASK_*_TIME_LIMIT`) so a stuck task cannot pin a worker forever;
  backup/restore are exempted with their own higher limits.

For stronger recovery guarantees, pair Pointy's app backup with PostgreSQL
physical/base backups and WAL archiving, and monitor host disk usage.
