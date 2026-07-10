"""Amortized bulk insertion for high-volume telemetry rows.

Every ``/api/`` request records a ``backend.request`` AnalyticsEvent. Writing
each row synchronously turned the whole read workload into a write workload:
one single-row INSERT — its own transaction through PgBouncer — per request,
multiplied by every POS device, exactly when the shop is busiest. Buffering
collapses those into one bulk INSERT per ``POINTY_ANALYTICS_BUFFER_SIZE``
requests, trading a few seconds of telemetry durability for it.

Telemetry-grade guarantees, by design:

- The buffer flushes when it fills, when the oldest entry outlives
  ``POINTY_ANALYTICS_BUFFER_MAX_AGE_SECONDS`` (checked on the next enqueue —
  an idle worker holds its tail until the next request), and at interpreter
  exit. A hard crash can lose the last few seconds of *telemetry*; audit
  events (``record_domain_event``) never go through here.
- A failed bulk INSERT drops the batch (logged) instead of retrying into a
  backlog, so a DB outage can never grow an unbounded queue.
- Size 0 — the default under TESTING, where request transactions roll back —
  bypasses buffering entirely and inserts synchronously.
"""

from __future__ import annotations

import atexit
import logging
import threading
import time

from django.conf import settings

logger = logging.getLogger(__name__)

_lock = threading.Lock()
_pending: list = []
_oldest_at = 0.0


def buffer_size() -> int:
    return int(getattr(settings, "POINTY_ANALYTICS_BUFFER_SIZE", 0))


def _max_age_seconds() -> float:
    return float(getattr(settings, "POINTY_ANALYTICS_BUFFER_MAX_AGE_SECONDS", 5))


def enqueue(event) -> None:
    """Queue an unsaved ``AnalyticsEvent`` for bulk insertion."""
    size = buffer_size()
    if size <= 0:
        _insert([event])
        return
    global _oldest_at
    with _lock:
        if not _pending:
            _oldest_at = time.monotonic()
        _pending.append(event)
        if len(_pending) < size and time.monotonic() - _oldest_at < _max_age_seconds():
            return
        batch = _pending.copy()
        _pending.clear()
    _insert(batch)


def flush() -> None:
    """Insert everything currently buffered (interpreter exit, tests)."""
    with _lock:
        batch = _pending.copy()
        _pending.clear()
    if batch:
        _insert(batch)


def reset() -> None:
    """Discard the buffer without inserting (test isolation only)."""
    with _lock:
        _pending.clear()


def _insert(batch) -> None:
    from .models import AnalyticsEvent

    try:
        AnalyticsEvent.objects.bulk_create(batch)
    except Exception:  # noqa: BLE001 — telemetry must never break a request
        logger.warning(
            "dropped %d buffered analytics events", len(batch), exc_info=True
        )


atexit.register(flush)
