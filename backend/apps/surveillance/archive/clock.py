"""The recorder's clock, measured from its own uploads.

A direct recorder is asked what time it thinks it is. An FTP recorder cannot
be asked anything — but every upload is a measurement. A file cannot arrive
before the footage in it was recorded, so for any upload whose name says when
it ended::

    device_end_wall − received_at_utc  =  offset − upload latency

Latency is never negative, so each upload is a reading at or below the true
offset. Snapped to the quarter hour (every real timezone is a multiple of 15
minutes, and that absorbs the latency), the largest reading is the offset.

Which way a new reading points decides how much evidence it needs:

* **Higher** is proven by a single upload and adopted at once.
* **Lower** is also what a DVR catching up on a backlog looks like — every file
  late, every reading low — so it is adopted only once it has held for
  ``LOWER_AFTER`` with no punctual upload contradicting it. A real change the
  other way (an installer fixing a timezone) is rare, and six hours of footage
  landing a quarter hour off is the lesser failure next to a backlog dragging
  every clip hours out.
* The **first** reading is adopted outright: before it the offset is only the
  shop's own timezone, assumed.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta, timezone as dt_timezone

QUANTUM_MINUTES = 15
LOWER_AFTER = timedelta(hours=6)

#: Every timezone on Earth sits inside this. A reading outside it is a DVR
#: whose clock reset to 2000-01-01 after a power cut, not a timezone.
MIN_OFFSET_MINUTES = -12 * 60
MAX_OFFSET_MINUTES = 14 * 60


@dataclass(frozen=True)
class ClockState:
    offset_minutes: int
    measured: bool
    lower_minutes: int | None = None
    lower_since: datetime | None = None


def wall_as_naive(value: datetime) -> datetime:
    """A stored wall-clock value back to the naive device time it was."""
    if value.tzinfo is not None:
        value = value.astimezone(dt_timezone.utc).replace(tzinfo=None)
    return value


def reading(wall_end: datetime, received_at: datetime) -> int | None:
    """One upload's reading of the offset, snapped, or ``None`` if absurd."""
    naive_end = wall_as_naive(wall_end)
    received = received_at.astimezone(dt_timezone.utc).replace(tzinfo=None)
    minutes = (naive_end - received).total_seconds() / 60.0
    snapped = int(round(minutes / QUANTUM_MINUTES)) * QUANTUM_MINUTES
    if not MIN_OFFSET_MINUTES <= snapped <= MAX_OFFSET_MINUTES:
        return None
    return snapped


def advance(state: ClockState, readings: list[int], now: datetime) -> ClockState:
    """The offset after one batch of readings."""
    usable = [value for value in readings if value is not None]
    if not usable:
        return state
    best = max(usable)
    if not state.measured or best >= state.offset_minutes:
        return ClockState(offset_minutes=best, measured=True)
    # Lower than we believe. Hold it as a proposal until it has lasted.
    if state.lower_minutes is None or state.lower_since is None:
        return ClockState(
            offset_minutes=state.offset_minutes,
            measured=True,
            lower_minutes=best,
            lower_since=now,
        )
    proposal = max(state.lower_minutes, best)
    if now - state.lower_since >= LOWER_AFTER:
        return ClockState(offset_minutes=proposal, measured=True)
    return ClockState(
        offset_minutes=state.offset_minutes,
        measured=True,
        lower_minutes=proposal,
        lower_since=state.lower_since,
    )


def to_utc(wall: datetime, offset_minutes: int) -> datetime:
    """Device wall clock -> an aware UTC instant."""
    naive = wall_as_naive(wall)
    return (naive - timedelta(minutes=offset_minutes)).replace(tzinfo=dt_timezone.utc)


def assumed_offset_minutes(now: datetime | None = None) -> int:
    """The shop's own UTC offset — what an unmeasured recorder is assumed on.

    Nearly every recorder in this market is set to local time, so this is
    right before the first upload has proved anything. The shop's zone, not
    Django's: the server keeps ``TIME_ZONE = "UTC"`` (see core.timeutils).
    """
    from django.utils import timezone

    from apps.core.timeutils import business_timezone

    moment = now or timezone.now()
    offset = moment.astimezone(business_timezone()).utcoffset() or timedelta(0)
    return int(offset.total_seconds() // 60)
