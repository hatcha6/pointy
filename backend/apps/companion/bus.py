"""How a till learns that its phone sent something, without polling the database.

The obvious implementations are both wrong for this stack. Polling Postgres a
few times a second per open till burns a pooled connection all shift for a query
that almost always returns nothing. Redis pub/sub means a dedicated blocking
connection per stream, outside the bounded-timeout pool the rest of the codebase
is careful to use, that has to be nursed through every reconnect.

So Redis holds one integer per till — the id of the newest event on its channel.
An idle stream reads that integer (sub-millisecond, no database at all) and goes
back to sleep; it touches Postgres only in the moment the number actually moves.
Redis is a *hint*, never the record: the event row is committed before the
cursor is published, so if Redis is down, restarted, or evicted the stream falls
back to reading the table directly and no scan is ever lost — only delayed.
"""

import logging

from django.core.cache import cache

logger = logging.getLogger(__name__)

CURSOR_KEY_PREFIX = "companion:cursor:"
# Comfortably longer than any shift. The cursor is a cache of the table's own
# max(id), so expiry costs a database read, not correctness.
CURSOR_TTL_SECONDS = 60 * 60 * 24


def _cursor_key(till_key: str) -> str:
    return f"{CURSOR_KEY_PREFIX}{till_key}"


def publish(till_key: str, event_id: int) -> None:
    """Announce the newest event id for a till. Never raises."""
    try:
        cache.set(_cursor_key(till_key), int(event_id), CURSOR_TTL_SECONDS)
    except Exception:  # pragma: no cover - cache outage
        logger.debug("companion cursor publish failed", exc_info=True)


def latest_cursor(till_key: str):
    """The newest published event id, or ``None`` when Redis cannot say.

    ``None`` means "ask the database" — it is not the same as zero, which would
    mean "there is definitely nothing new".
    """
    try:
        value = cache.get(_cursor_key(till_key))
    except Exception:  # pragma: no cover - cache outage
        logger.debug("companion cursor read failed", exc_info=True)
        return None
    if value is None:
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None
