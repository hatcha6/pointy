"""Which stretches of an upload are worth keeping: the invoice moments.

An invoice rung up at ``t`` wants ``[t − pre, t + post]`` — the same window the
invoice player opens — plus ``MARGIN`` either side, so that a shop lengthening
its pre/post roll next month does not find last month's footage already
trimmed to the old length.

The moments are every order a till rings up (standard, quotation, credit) and
every return or void: money leaving the drawer is exactly the moment an owner
comes back to re-watch.
"""

from __future__ import annotations

from datetime import datetime, timedelta

from apps.core.models import ShopSettings

from ..services import DEFAULT_POST_ROLL_SECONDS, DEFAULT_PRE_ROLL_SECONDS

#: Kept either side of the shop's own pre/post roll.
MARGIN = timedelta(seconds=10)
#: How long after an upload lands before it is decided on, beyond the pre-roll:
#: an order row becomes visible when its transaction commits, a moment after
#: its ``created_at``.
COMMIT_GRACE = timedelta(seconds=60)
#: A transfer that broke off is held this much longer, for the DVR to resume.
PARTIAL_GRACE = timedelta(minutes=15)
#: Two kept stretches closer than this are kept as one — cutting a file into
#: slivers a few seconds apart costs more than the seconds between them.
MERGE_GAP = timedelta(seconds=15)

Interval = tuple[datetime, datetime]


def rolls(settings: ShopSettings | None = None) -> tuple[timedelta, timedelta]:
    """(pre, post), each including the margin."""
    settings = settings or ShopSettings.load()
    pre = int(getattr(settings, "surveillance_pre_roll_seconds", DEFAULT_PRE_ROLL_SECONDS))
    post = int(getattr(settings, "surveillance_post_roll_seconds", DEFAULT_POST_ROLL_SECONDS))
    return timedelta(seconds=pre) + MARGIN, timedelta(seconds=post) + MARGIN


def decide_after(received_at: datetime, pre: timedelta, *, partial: bool = False) -> datetime:
    """When every invoice that could want this upload exists.

    The last such invoice is rung up at ``end + pre``, and ``end`` is never
    later than ``received_at`` — a file cannot be uploaded before it was
    recorded — so this is safe whatever the device's clock says.
    """
    moment = received_at + pre + COMMIT_GRACE
    if partial:
        moment += PARTIAL_GRACE
    return moment


def moments_between(start: datetime, end: datetime) -> list[datetime]:
    """Every invoice moment in ``[start, end]``, sorted."""
    from apps.sales.models import Order, OrderAdjustment

    orders = Order.objects.filter(
        created_at__gte=start,
        created_at__lte=end,
        sale_type__in=Order.CHECKOUT_SALE_TYPES,
    ).values_list("created_at", flat=True)
    adjustments = OrderAdjustment.objects.filter(
        created_at__gte=start, created_at__lte=end
    ).values_list("created_at", flat=True)
    return sorted([*orders, *adjustments])


def windows_for(moments: list[datetime], pre: timedelta, post: timedelta) -> list[Interval]:
    return merge([(moment - pre, moment + post) for moment in moments], gap=timedelta(0))


def merge(intervals: list[Interval], *, gap: timedelta = MERGE_GAP) -> list[Interval]:
    """Overlapping (or nearly touching) intervals as one, sorted."""
    ordered = sorted(interval for interval in intervals if interval[1] > interval[0])
    merged: list[Interval] = []
    for start, end in ordered:
        if merged and start - merged[-1][1] <= gap:
            if end > merged[-1][1]:
                merged[-1] = (merged[-1][0], end)
            continue
        merged.append((start, end))
    return merged


def clip_to(windows: list[Interval], start: datetime, end: datetime) -> list[Interval]:
    """The parts of ``windows`` inside ``[start, end]``."""
    kept = []
    for window_start, window_end in windows:
        lo = max(window_start, start)
        hi = min(window_end, end)
        if hi > lo:
            kept.append((lo, hi))
    return kept


def covers(windows: list[Interval], moment: datetime) -> bool:
    return any(start <= moment <= end for start, end in windows)


def coverage(windows: list[Interval], start: datetime, end: datetime) -> float:
    """What share of ``[start, end]`` the windows cover, 0..1."""
    span = (end - start).total_seconds()
    if span <= 0:
        return 0.0
    covered = sum((hi - lo).total_seconds() for lo, hi in clip_to(windows, start, end))
    return max(0.0, min(1.0, covered / span))
