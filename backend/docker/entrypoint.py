import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import wait_for_services


def log_phase(name, seconds):
    """Emit a one-line boot-phase timing so the startup window is measurable in
    the container logs (grep 'boot-phase'). The sum of these is the time from
    container start to uvicorn taking over."""
    print(f"[boot-phase] {name}: {seconds:.2f}s", flush=True)


def timed(name, func):
    start = time.monotonic()
    result = func()
    log_phase(name, time.monotonic() - start)
    return result


def main():
    command = sys.argv[1] if len(sys.argv) > 1 else "web"
    args = sys.argv[2:]

    if command == "web":
        boot_started = time.monotonic()
        require_secret("DJANGO_SECRET_KEY")
        sweep_stale_temp_files()
        timed("wait_for_dependencies", wait_for_dependencies)
        timed("run_migrations", run_migrations)
        timed("collect_static", collect_static)
        # Enrollment is best-effort and only matters for first-boot promptness
        # (the periodic core.ensure_relay_enrollment task covers every case
        # afterwards). Kick it off in the BACKGROUND so a slow/unreachable relay
        # can never stall the till coming online — it races uvicorn instead of
        # blocking it.
        start_enrollment_in_background()
        log_phase("total_before_uvicorn", time.monotonic() - boot_started)
        exec_process(web_command(args))
    if command == "worker":
        require_secret("DJANGO_SECRET_KEY")
        wait_for_dependencies()
        exec_process(worker_command(args))
    if command == "beat":
        require_secret("DJANGO_SECRET_KEY")
        wait_for_dependencies()
        exec_process(beat_command(args))
    if command == "migrate":
        require_secret("DJANGO_SECRET_KEY")
        wait_for_dependencies()
        run_migrations()
        return
    if command == "check":
        require_secret("DJANGO_SECRET_KEY")
        wait_for_dependencies()
        exec_process(["python", "manage.py", "check", "--deploy", *args])
    if command == "shell":
        require_secret("DJANGO_SECRET_KEY")
        wait_for_dependencies()
        exec_process(["python", "manage.py", "shell", *args])

    exec_process([command, *args])


#: How long a temporary file has to be untouched before boot treats it as debris.
#: Comfortably longer than the slowest thing that legitimately holds one open —
#: a multi-gigabyte restore upload — so a sweep can never pull the floor out
#: from under a request that is still running in another container.
_TEMP_FILE_MAX_AGE_SECONDS = 24 * 60 * 60


def sweep_stale_temp_files():
    """Delete leftovers in TMPDIR that no live process is still using.

    TMPDIR is a volume now, not the tmpfs it used to be, because request bodies
    and upload spools are measured in gigabytes and RAM is what a shop's server
    has least of. The cost of that move is that nothing clears it any more: a
    tmpfs came up empty after every restart, and an attachment upload that is
    interrupted between spooling its file and moving it leaves that file behind
    for good. One a week is invisible and permanent.

    Anonymous spools — the ones Django's ASGI handler makes — never appear here
    at all; POSIX unlinks them at creation, so the kernel reclaims them when the
    process dies. This is only for the named ones.

    Never fatal: a sweep that cannot run is not a reason a shop's till does not
    come up.
    """
    root = os.environ.get("TMPDIR", "").strip()
    if not root:
        return
    directory = Path(root)
    cutoff = time.time() - _TEMP_FILE_MAX_AGE_SECONDS
    removed = 0
    try:
        entries = list(directory.iterdir())
    except OSError:
        return
    for entry in entries:
        try:
            if entry.stat().st_mtime >= cutoff:
                continue
            if entry.is_dir():
                shutil.rmtree(entry, ignore_errors=True)
            else:
                entry.unlink()
            removed += 1
        except OSError:
            continue
    if removed:
        print(f"[boot] cleared {removed} stale temporary file(s) from {directory}", flush=True)


def require_secret(name):
    value = os.environ.get(name, "")
    if not value:
        raise SystemExit(f"{name} is required for the production container.")
    if value in {"change-me", "dev-only-change-me"}:
        raise SystemExit(f"{name} must be changed from the development placeholder.")


def wait_for_dependencies():
    wait_for_services.main()


def run_migrations():
    # Run schema migrations straight against Postgres, bypassing PgBouncer: Django's
    # migrate holds a session-scoped advisory lock (and issues SET statements) that a
    # transaction-pooled PgBouncer would break across pooled backends. App traffic
    # still flows through the pooler via DATABASE_URL; only this step uses the direct
    # URL, and only when one is provided (blank -> migrate over DATABASE_URL as before).
    child_env = os.environ.copy()
    direct_url = os.environ.get("POINTY_DATABASE_DIRECT_URL", "").strip()
    if direct_url:
        child_env["DATABASE_URL"] = direct_url
    subprocess.check_call(["python", "manage.py", "migrate", "--noinput"], env=child_env)


def start_enrollment_in_background():
    """Best-effort: redeem the configured license key so the shop's relay
    subscription activates. Launched as a detached child that runs CONCURRENTLY
    with uvicorn — never fatal and never on the critical path: if the relay is
    slow or unreachable the container still serves immediately, and the periodic
    ``core.ensure_relay_enrollment`` task keeps retrying afterwards. ``init:true``
    (tini) in the compose file reaps the child once it exits.

    Runs whenever enrollment credentials are configured, independent of
    POINTY_REQUIRE_LICENSE: the gate only decides whether an *unlicensed* backend
    blocks the API, not whether we try to enroll. (A require-license shop briefly
    serves 503 on gated paths until this lands — health/readyz stay open — which
    self-heals in seconds instead of stalling every boot on a network round trip.)
    """
    require_license = os.environ.get("POINTY_REQUIRE_LICENSE", "").lower() in {
        "1",
        "true",
        "yes",
        "on",
    }
    has_enrollment_credentials = bool(
        os.environ.get("POINTY_RELAY_ENROLLMENT_TOKEN", "").strip()
        or (
            os.environ.get("POINTY_RELAY_ACCESS_TOKEN", "").strip()
            and os.environ.get("POINTY_RELAY_INSTALLATION_ID", "").strip()
        )
    )
    if not require_license and not has_enrollment_credentials:
        return
    try:
        subprocess.Popen(  # noqa: S603 — detached, non-blocking; do not wait()
            ["python", "manage.py", "relay_enroll"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except Exception as exc:  # noqa: BLE001 — startup must never block on enrollment
        print(f"relay_enroll launch skipped: {exc}", file=sys.stderr)


def collect_static():
    if os.environ.get("POINTY_COLLECTSTATIC", "1") == "1":
        subprocess.check_call(["python", "manage.py", "collectstatic", "--noinput"])


def web_command(extra_args):
    command = [
        "uvicorn",
        "pointy.asgi:application",
        "--host",
        "0.0.0.0",
        "--port",
        os.environ.get("POINTY_BACKEND_PORT", "8000"),
        "--workers",
        os.environ.get("POINTY_ASGI_WORKERS", os.environ.get("POINTY_WEB_WORKERS", "3")),
        "--timeout-keep-alive",
        os.environ.get("POINTY_ASGI_KEEP_ALIVE", "5"),
        "--timeout-graceful-shutdown",
        os.environ.get("POINTY_ASGI_GRACEFUL_TIMEOUT", "30"),
        "--ws",
        "auto",
    ]
    # Worker recycling is OFF by default: with steady POS polling all workers
    # hit the request limit near-simultaneously (the small jitter cannot
    # separate them), taking the whole API down for a Django cold start at
    # fixed wall-clock intervals — observed in the field as the backend
    # "going down every N minutes". Opt back in explicitly (with a LARGE
    # jitter) only if a leak ever forces it.
    max_requests = os.environ.get("POINTY_ASGI_MAX_REQUESTS", "")
    if max_requests and max_requests != "0":
        command.extend(["--limit-max-requests", max_requests])
        jitter = os.environ.get("POINTY_ASGI_MAX_REQUESTS_JITTER", "")
        if jitter and jitter != "0":
            command.extend(["--limit-max-requests-jitter", jitter])
    limit_concurrency = os.environ.get("POINTY_ASGI_LIMIT_CONCURRENCY", "")
    if limit_concurrency:
        command.extend(["--limit-concurrency", limit_concurrency])
    if os.environ.get("POINTY_ASGI_PROXY_HEADERS", "0") == "1":
        command.extend(
            [
                "--proxy-headers",
                "--forwarded-allow-ips",
                os.environ.get("POINTY_ASGI_FORWARDED_ALLOW_IPS", "127.0.0.1"),
            ]
        )
    command.extend(extra_args)
    return command


def worker_command(extra_args):
    return [
        "celery",
        "-A",
        "pointy",
        "worker",
        "--loglevel",
        os.environ.get("CELERY_LOG_LEVEL", "info"),
        "--concurrency",
        os.environ.get("CELERY_WORKER_CONCURRENCY", "2"),
        "--hostname",
        "worker@%h",
        *extra_args,
    ]


def beat_command(extra_args):
    return [
        "celery",
        "-A",
        "pointy",
        "beat",
        "--loglevel",
        os.environ.get("CELERY_LOG_LEVEL", "info"),
        "--schedule",
        "/var/lib/pointy/celerybeat/celerybeat-schedule",
        *extra_args,
    ]


def exec_process(command):
    os.execvp(command[0], command)


if __name__ == "__main__":
    main()
