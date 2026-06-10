import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import wait_for_services


def main():
    command = sys.argv[1] if len(sys.argv) > 1 else "web"
    args = sys.argv[2:]

    if command == "web":
        require_secret("DJANGO_SECRET_KEY")
        wait_for_dependencies()
        run_migrations()
        collect_static()
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


def require_secret(name):
    value = os.environ.get(name, "")
    if not value:
        raise SystemExit(f"{name} is required for the production container.")
    if value in {"change-me", "dev-only-change-me"}:
        raise SystemExit(f"{name} must be changed from the development placeholder.")


def wait_for_dependencies():
    wait_for_services.main()


def run_migrations():
    subprocess.check_call(["python", "manage.py", "migrate", "--noinput"])


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
        "--limit-max-requests",
        os.environ.get("POINTY_ASGI_MAX_REQUESTS", "1000"),
        "--limit-max-requests-jitter",
        os.environ.get("POINTY_ASGI_MAX_REQUESTS_JITTER", "100"),
        "--ws",
        "auto",
    ]
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
