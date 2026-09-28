"""The FTP service's heartbeat, so the web backend can say whether it is up.

The service writes a small dict to the cache every few seconds with a short
TTL; the backend reads it. No heartbeat means no service — a setup screen that
shows credentials for a server that is not running is worse than one that
says so.
"""

from __future__ import annotations

import logging

from django.conf import settings
from django.core.cache import cache

logger = logging.getLogger(__name__)

CACHE_KEY = "surveillance:ftp:status:v1"
TTL_SECONDS = 45


def publish(payload: dict) -> None:
    try:
        cache.set(CACHE_KEY, payload, TTL_SECONDS)
    except Exception as exc:  # noqa: BLE001 - a heartbeat is never worth a crash
        logger.debug("could not publish FTP status: %s", exc)


def read() -> dict | None:
    try:
        value = cache.get(CACHE_KEY)
    except Exception:  # noqa: BLE001
        return None
    return value if isinstance(value, dict) else None


def clear() -> None:
    try:
        cache.delete(CACHE_KEY)
    except Exception:  # noqa: BLE001
        pass


def summary() -> dict:
    """What the setup screen needs to know about the FTP service itself."""
    heartbeat = read() or {}
    running = bool(heartbeat)
    return {
        "running": running,
        "port": int(getattr(settings, "POINTY_FTP_PUBLIC_PORT", 21)),
        "passive_ports": str(getattr(settings, "POINTY_FTP_PASSIVE_PORTS", "") or ""),
        "accepting": bool(heartbeat.get("accepting", True)) if running else False,
        "refusing_reason": heartbeat.get("refusing_reason", "") if running else "",
        "recent_unknown_logins": heartbeat.get("recent_unknown_logins", []) if running else [],
    }
