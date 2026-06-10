# Pointy On-Prem Docker Stack

This stack is for a customer site where Windows is the host OS and Docker
Desktop runs Linux containers. Cashier devices connect to the backend over LAN;
PostgreSQL, Redis, Celery, and the connector stay inside Docker.

## First Install

1. Install Docker Desktop and enable Linux containers.
2. In Docker Desktop settings, give the VM at least 4GB memory for tiny pilots
   or 6GB+ for the recommended 8GB host profile.
3. Copy `deploy/onprem/.env.example` to `deploy/onprem/.env`.
4. Replace every secret and every `192.168.1.50` example with the Windows
   host's static LAN IP.
5. Allow inbound Windows Firewall traffic for TCP `8000` and UDP `47777`.
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
