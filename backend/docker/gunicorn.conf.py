"""Gunicorn for the `web` role: one master imports Django, the workers fork from it.

The workers used to be `uvicorn --workers N`, which *spawns* each one: every
worker imported Django and the whole project on its own, ~120 MB apiece with
almost nothing shared. Forking from a master that has already imported
everything lets the workers share those pages copy-on-write. Measured under a
till-like load: ~125 MB -> ~57 MB unique per worker, about 110 MB less for the
backend container with three workers. Each worker is still uvicorn (the
`uvicorn-worker` class), so the protocol, the streaming behaviour and every
knob below are the ones the shop already had.

Read by path (`gunicorn -c /app/backend/docker/gunicorn.conf.py`), which is why
it lives here: `docker/` is never compiled.
"""

import gc
import logging
import os

from uvicorn_worker import UvicornWorker

logger = logging.getLogger("gunicorn.error")


def _int(name, default):
    value = os.environ.get(name, "")
    return int(value) if value.strip() else default


bind = "0.0.0.0:" + os.environ.get("POINTY_BACKEND_PORT", "8000")
workers = _int("POINTY_ASGI_WORKERS", _int("POINTY_WEB_WORKERS", 3))
preload_app = True
keepalive = _int("POINTY_ASGI_KEEP_ALIVE", 5)
graceful_timeout = _int("POINTY_ASGI_GRACEFUL_TIMEOUT", 30)
# How long a worker may go without heartbeating before the master replaces it.
# The heartbeat comes from the worker's event loop, which Django's sync views
# never block (they run in a thread), so this only fires on a wedged process.
timeout = _int("POINTY_ASGI_WORKER_TIMEOUT", 120)
# Worker recycling is OFF by default: with steady POS polling all workers hit
# the request limit near-simultaneously (the small jitter cannot separate
# them), taking the whole API down at fixed wall-clock intervals — observed in
# the field as the backend "going down every N minutes". install.sh pins it to
# 0. Opt back in explicitly (with a LARGE jitter) only if a leak ever forces it.
max_requests = _int("POINTY_ASGI_MAX_REQUESTS", 0)
max_requests_jitter = _int("POINTY_ASGI_MAX_REQUESTS_JITTER", 0)
# uvicorn always honours X-Forwarded-* from the addresses it trusts; the flag
# only widened that trust past localhost. The edge proxy in front sets them.
if os.environ.get("POINTY_ASGI_PROXY_HEADERS", "0") == "1":
    forwarded_allow_ips = os.environ.get("POINTY_ASGI_FORWARDED_ALLOW_IPS", "127.0.0.1")
else:
    forwarded_allow_ips = "127.0.0.1"
# uvicorn logs requests itself when asked; gunicorn's access log stays off as
# uvicorn's was.
accesslog = None
errorlog = "-"
# gunicorn 24+ opens a control socket under $HOME by default; the root
# filesystem is read-only, so it only ever logged an error. Nothing uses it.
control_socket_disable = True


class PointyUvicornWorker(UvicornWorker):
    CONFIG_KWARGS = {
        **UvicornWorker.CONFIG_KWARGS,
        "ws": "auto",
        "timeout_graceful_shutdown": graceful_timeout,
    }
    _limit = _int("POINTY_ASGI_LIMIT_CONCURRENCY", 0)
    if _limit:
        CONFIG_KWARGS["limit_concurrency"] = _limit


worker_class = PointyUvicornWorker


def _warm_and_detach():
    """Finish importing in the master, then drop anything a fork must not share.

    Django imports the URLconf, and through it every view, serializer and
    filter module, on the first request. Left to that, each worker imports its
    own copy after the fork and the sharing above buys half of what it could.
    """
    from django.core.cache import caches
    from django.db import connections
    from django.urls import get_resolver

    get_resolver().url_patterns  # noqa: B018 - forces the lazy import
    # A socket opened here would be inherited by every worker and driven by all
    # of them at once. Nothing at import time should connect, but make sure.
    connections.close_all()
    caches.close_all()


def when_ready(server):
    try:
        _warm_and_detach()
    except Exception:  # noqa: BLE001 - a cold first request beats a dead backend
        logger.exception("could not import the URLconf before forking workers")
    # Move everything allocated so far into the permanent generation: the cyclic
    # GC then never walks (and so never dirties) those pages in a worker.
    gc.freeze()


def pre_fork(server, worker):
    # A worker replaced later forks from the same master; freeze again so
    # anything the master allocated since is shared too.
    gc.freeze()
