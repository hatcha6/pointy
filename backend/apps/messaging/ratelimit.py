"""Per-gateway send pacing, backed by the Django cache (Redis in production).

A single consumer SIM is the bottleneck: blasting it gets the number flagged as
spam (plan R4). Two limiters cooperate:

* a per-minute throttle (atomic fixed-window counter) — retries reconsume slots,
  but the window refills every minute, so this only shapes rate;
* a per-day cap counted on *successful* sends (``note_sent``) — retries don't
  inflate it, and it's read before each send via ``within_daily_cap``.

The day boundary is shop-local (Africa/Tripoli) so "200/day" means the merchant's
day, not UTC's.
"""

from __future__ import annotations

from django.core.cache import cache
from django.utils import timezone

from apps.core.timeutils import business_local_date

_MINUTE_TTL = 120
_DAY_TTL = 60 * 60 * 26


def _incr(key: str, ttl: int) -> int:
    """Atomically increment ``key`` (creating it at 1), returning the new value."""
    if cache.add(key, 1, ttl):
        return 1
    try:
        return cache.incr(key)
    except ValueError:
        # Key expired between add() and incr(); re-seed.
        cache.add(key, 1, ttl)
        return 1


def _minute_key(gateway, now) -> str:
    return f"msg:rate:{gateway.pk}:{now:%Y%m%d%H%M}"


def _day_key(gateway, now) -> str:
    return f"msg:cap:{gateway.pk}:{business_local_date(now):%Y%m%d}"


def take_minute_slot(gateway, *, now=None) -> bool:
    """Reserve one per-minute send slot; ``False`` if this minute is full."""
    per_min = gateway.max_messages_per_minute or 0
    if per_min <= 0:
        return True
    now = now or timezone.now()
    return _incr(_minute_key(gateway, now), _MINUTE_TTL) <= per_min


def within_daily_cap(gateway, *, now=None) -> bool:
    """Whether the gateway is still under its daily cap (read-only check)."""
    if not gateway.daily_cap:
        return True
    now = now or timezone.now()
    return cache.get(_day_key(gateway, now), 0) < gateway.daily_cap


def note_sent(gateway, *, now=None) -> None:
    """Record one successful send against the daily cap."""
    if not gateway.daily_cap:
        return
    now = now or timezone.now()
    _incr(_day_key(gateway, now), _DAY_TTL)
