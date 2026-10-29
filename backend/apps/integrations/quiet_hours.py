"""When the shop's background jobs leave the providers' portals alone.

LNET and HD Box are websites Pointy drives as a browser would, from the shop's
own address. A person uses them while the shop trades; a script reads them at
four in the morning. Annaseem's export (2026-10-28) showed Pointy logging in
to LNET at 01:05, 02:05, 03:05… every night, which is the pattern a portal's
anti-bot rules are built to catch — and an agency account blocked for it
cannot sell at all. So unattended reads keep to the trading day:

* the hourly float refresh skips the quiet hours entirely;
* the daily reconciliation runs once, at :20 past the hour the quiet hours end
  (09:20 by default), proving yesterday's sales before the shop opens.

Anything a person starts — a lookup, a sale, opening a screen — still reaches
the provider at any hour. Only the jobs nobody is waiting for keep to this.
"""

from __future__ import annotations

from datetime import datetime

from django.conf import settings
from django.utils import timezone

from apps.core.timeutils import business_timezone


def _window() -> tuple[int, int] | None:
    """``(start, end)`` local hours, end exclusive, or ``None`` when off."""
    raw = str(getattr(settings, "POINTY_PROVIDER_QUIET_HOURS", "") or "").strip()
    start, sep, end = raw.partition("-")
    if not sep:
        return None
    try:
        start_hour, end_hour = int(start) % 24, int(end) % 24
    except ValueError:
        return None
    if start_hour == end_hour:
        return None
    return start_hour, end_hour


def _local_hour(now: datetime | None) -> int:
    return timezone.localtime(now or timezone.now(), business_timezone()).hour


def in_quiet_hours(now: datetime | None = None) -> bool:
    """Whether an unattended job should leave the portals alone right now."""
    window = _window()
    if window is None:
        return False
    start, end = window
    hour = _local_hour(now)
    if start < end:
        return start <= hour < end
    # A window across midnight, e.g. 23-7.
    return hour >= start or hour < end


def reconciliation_due(now: datetime | None = None) -> bool:
    """Whether this hour is the one the daily reconciliation runs in.

    The first hour after the quiet window, so it is the trading day's first
    read rather than a 04:00 one. With no quiet hours configured it keeps the
    old 02:00 slot.
    """
    window = _window()
    due = window[1] if window is not None else 2
    return _local_hour(now) == due
