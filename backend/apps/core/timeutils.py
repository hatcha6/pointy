"""Business-local calendar helpers.

Pointy stores every timestamp in UTC (``TIME_ZONE = "UTC"``). The holidays
calendar, however, asks a calendar-date question: *which day* is a given instant
in the shop's own timezone? A New-Year sale rung up at 00:30 Tripoli time is
Jan 1 locally even though it is still Dec 31 in UTC, and it must be tagged
``new_year``.

This helper is deliberately scoped to the holidays feature. It does **not**
change the app-wide ``django.utils.timezone.localdate()`` behaviour that reports,
fraud lookback, and payroll rely on (those keep using the UTC calendar date).
Promoting the whole app to Tripoli time is a separate, deliberate migration.
"""

from __future__ import annotations

from datetime import date, datetime
from datetime import timezone as dt_timezone
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from django.conf import settings
from django.utils import timezone

DEFAULT_BUSINESS_TIMEZONE = "Africa/Tripoli"


def business_timezone() -> ZoneInfo:
    """Return the configured shop timezone, falling back to Africa/Tripoli."""
    name = getattr(settings, "POINTY_BUSINESS_TIMEZONE", DEFAULT_BUSINESS_TIMEZONE)
    try:
        return ZoneInfo(str(name))
    except (ZoneInfoNotFoundError, ValueError):
        return ZoneInfo(DEFAULT_BUSINESS_TIMEZONE)


def business_local_date(moment: datetime | None = None) -> date:
    """Return the shop-local calendar date for ``moment`` (default: now).

    ``moment`` may be naive or aware; naive datetimes are assumed UTC (the
    project default). The result is the calendar date in
    ``POINTY_BUSINESS_TIMEZONE``.
    """
    if moment is None:
        moment = timezone.now()
    if timezone.is_naive(moment):
        moment = moment.replace(tzinfo=dt_timezone.utc)
    return moment.astimezone(business_timezone()).date()
