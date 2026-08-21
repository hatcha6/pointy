import os
import sys
import time
from urllib.parse import urlparse

import psycopg
from redis import Redis


DEFAULT_TIMEOUT_SECONDS = 60


def main():
    deadline = time.monotonic() + int(
        os.environ.get("POINTY_STARTUP_WAIT_SECONDS", DEFAULT_TIMEOUT_SECONDS)
    )
    # Postgres is the system of record: without it nothing can serve and the
    # migration step cannot run, so refusing to start is the honest outcome.
    wait_for_postgres(os.environ.get("DATABASE_URL", ""), deadline)
    # Redis is not. Every path that reads it is fail-open by design (see
    # apps.core.caching / sessions / throttling) and every broker publish is
    # bounded (apps.core.dispatch), so a till can sell all day without it.
    # Blocking the boot on it turned a survivable Redis outage into a POS that
    # never comes back: a shop rebooting after a power cut onto a Redis whose
    # dump is corrupt would exit 75 here, forever, with a perfectly good
    # database sitting behind it. Wait for it — a slow Redis is the common
    # case, and starting with a warm cache is worth a few seconds — then come
    # up anyway and let the fail-open paths do their job.
    wait_for_redis(os.environ.get("REDIS_URL", ""), deadline)
    return 0


def wait_for_postgres(database_url, deadline):
    if not database_url or database_url.startswith("sqlite:"):
        return
    parsed = urlparse(database_url)
    if parsed.scheme not in {"postgres", "postgresql"}:
        return
    wait_until("postgres", deadline, lambda: _postgres_ready(database_url))


def wait_for_redis(redis_url, deadline):
    if not redis_url:
        return
    wait_until("redis", deadline, lambda: _redis_ready(redis_url), required=False)


def wait_until(name, deadline, probe, *, required=True):
    last_error = None
    while time.monotonic() < deadline:
        try:
            probe()
            print(f"{name} is ready", flush=True)
            return
        except Exception as exc:
            last_error = exc
            time.sleep(1)
    if required:
        print(f"Timed out waiting for {name}: {last_error}", file=sys.stderr)
        raise SystemExit(75)
    # Optional dependency: say so loudly in the container log — an operator
    # reading it has to know the shop is running without a cache — and carry on.
    print(
        f"Timed out waiting for {name}: {last_error}; starting without it",
        file=sys.stderr,
        flush=True,
    )


def _postgres_ready(database_url):
    with psycopg.connect(database_url, connect_timeout=5) as connection:
        with connection.cursor() as cursor:
            cursor.execute("SELECT 1")
            cursor.fetchone()


def _redis_ready(redis_url):
    client = Redis.from_url(redis_url, socket_connect_timeout=5, socket_timeout=5)
    try:
        client.ping()
    finally:
        client.close()


if __name__ == "__main__":
    raise SystemExit(main())
