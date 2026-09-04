# On-prem hardening notes (internal)

**Not shipped in the release bundle.** This file documents what the deployment
protects, what it does not, and why — including its known gaps. That is exactly
the reading an attacker wants, so it stays in the repository; the bundle carries
only the operational README.

See also `CODE_PROTECTION_PLAN.md` and `CYTHON_FEASIBILITY.md` at the repo root.

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

### Image archives are not kept

`images/pointy-*.tar` is the softest reverse-engineering target a deployment
has: two plain `tar xf` calls, with no Docker and no root involved, and our
whole source tree is sitting in a directory. Docker's image store is a much
harder target and it is the only copy the stack actually needs, so `install.sh`
and the update engine shred every `pointy-*.tar` the moment `docker load` has
taken it — along with any bundle zip the updater downloaded or unpacked itself —
and a committed update removes the superseded `pointy-backend`, `pointy-relay`
and `pointy-web` images. That removal is never forced: an image a container
still holds is kept and logged.

Third-party archives (postgres/redis/pgbouncer) stay, since they carry none of
our code and are what the next maintenance restart loads.

This buys the offline case only — a copied deploy directory, a stolen disk, a
bundle left in a Downloads folder. Root on the host still reaches the running
container's filesystem with `docker cp`, and no amount of image deletion changes
that; deleting the *loaded* backend image would only leave `compose up` unable
to recreate the container, with no registry to pull from. Raising the bar
further is an image-content problem (obfuscated or compiled Python), not an
image-lifecycle one.

Trade-off: the machine can no longer re-install from its own deploy directory if
Docker's image store is destroyed, and rollback needs the previous bundle.
`POINTY_KEEP_IMAGE_ARCHIVES=1` disables the whole behaviour.

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
