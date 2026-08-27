"""Capacity isolation for telemetry ingestion.

On 2026-08-17 at 11:38 a signed-in till flushed a queued telemetry backlog.
Accepted ingest requests went 5 → 292 → 495 → 2,123 → 2,101 per minute and then
stopped dead. For those four minutes the shop's own traffic queued behind it:
``product-list`` took **104 seconds**, ``backup-operations`` 7.9s, and sales at
the till stopped for four minutes in the middle of a trading day.

It was not the database — ingest spent 1.1% of its time there, and fewer than one
query per request, because the rows go through the amortising buffer. It was
capacity. The backend runs three uvicorn workers; 37 requests a second of
nested-serializer validation leaves nothing for anything else.

Two separate guards, because they fail differently:

``AnalyticsIngestRateThrottle``
    Ingest gets its own scope instead of sharing the per-user
    ``authenticated_ceiling`` with every other endpoint. Sharing it is why the
    storm's 429s also landed on ``backup-destinations`` and
    ``backup-operations`` — the till burned its whole budget on history and its
    real work was refused. Now a telemetry flood can only ever refuse telemetry.

``ingest_capacity``
    A rate limit still admits bursts inside its window, and a burst is exactly
    what hurt. This bounds how many ingest requests may be *in flight* at once,
    so the endpoint can never occupy more than its share of the workers however
    fast callers arrive. Over the limit, callers are refused immediately rather
    than queueing behind a worker the till needs.

The client is also paced (see AnalyticsEngine.flush), but a shop must survive a
misbehaving client without depending on the client behaving.
"""

import logging
import threading
from contextlib import contextmanager

from django.conf import settings
from rest_framework.throttling import SimpleRateThrottle

from apps.core.throttling import _FailOpenThrottleMixin

logger = logging.getLogger(__name__)


class AnalyticsIngestRateThrottle(_FailOpenThrottleMixin, SimpleRateThrottle):
    """Rate-limit telemetry uploads in their own bucket.

    Keyed by device where the client identifies itself, so one till flushing a
    backlog cannot spend another till's allowance, and by user otherwise.
    """

    scope = "analytics_ingest"

    def get_cache_key(self, request, view):
        headers = getattr(request, "headers", None)
        device_id = ""
        if headers is not None:
            device_id = str(headers.get("X-Pointy-Device-Id", "") or "").strip()[:96]
        if device_id:
            ident = f"device:{device_id}"
        else:
            user = getattr(request, "user", None)
            ident = (
                f"user:{user.pk}"
                if user is not None and getattr(user, "is_authenticated", False)
                else f"ip:{self.get_ident(request)}"
            )
        return self.cache_format % {"scope": self.scope, "ident": ident}


class IngestCapacityExceeded(Exception):
    """Too many ingest requests already in flight."""


def _limit():
    return int(getattr(settings, "POINTY_ANALYTICS_INGEST_CONCURRENCY", 2) or 0)


_semaphore = None
_semaphore_limit = None
_semaphore_lock = threading.Lock()


def _get_semaphore():
    """One bounded semaphore per worker process, rebuilt if the limit changes.

    Per-process is the honest scope: with three uvicorn workers the real ceiling
    is three times the limit, which is still a fixed, small share of the box
    rather than "as many as arrive". Rebuilding on a changed limit is what lets
    a test override the setting.
    """
    global _semaphore, _semaphore_limit
    limit = _limit()
    if limit <= 0:
        return None
    with _semaphore_lock:
        if _semaphore is None or _semaphore_limit != limit:
            _semaphore = threading.BoundedSemaphore(limit)
            _semaphore_limit = limit
    return _semaphore


@contextmanager
def ingest_capacity():
    """Hold one of this worker's ingest slots, or refuse immediately.

    Deliberately non-blocking: waiting for a slot would still tie up the worker
    thread, which is the resource being protected. A refused upload costs the
    client nothing — the events stay queued on the device and ship on its next
    flush.
    """
    semaphore = _get_semaphore()
    if semaphore is None:
        yield
        return
    if not semaphore.acquire(blocking=False):
        raise IngestCapacityExceeded()
    try:
        yield
    finally:
        semaphore.release()
