"""When card money the processor is holding should reach the bank.

A card processor such as Moamalat does not pay a sale into the bank when it is
made. It closes its day at a cut-off (midnight, for Moamalat), then deposits
that day's takings on its next settlement day — and its settlement days are the
banks' working days. In Libya that is Sunday to Thursday, so Monday's takings
land on Tuesday, but Thursday's, Friday's and Saturday's all wait for Sunday.

Two questions live here, both on the **processor's** clock rather than the
app-wide UTC calendar ``apps.core.money_dates`` uses for reports:

* which processor day a payment belongs to (``processor_day``) — a sale rung up
  at 00:30 Tripoli time is the processor's *next* day, although it is still the
  previous day in UTC;
* the day that processor day's money should land (``expected_settlement_date``).

Nothing here touches the database except ``bank_closed_dates``, which reads the
shop's holiday calendar.
"""

from __future__ import annotations

from datetime import date, datetime, time, timedelta

from apps.core.timeutils import business_timezone

#: Python weekday numbers (Monday=0 .. Sunday=6) on which the processor pays
#: into the bank, written the way ``apps.attendance`` writes a work week. Sunday
#: to Thursday is the Libyan banking week.
DEFAULT_SETTLEMENT_WEEKDAYS = "6,0,1,2,3"
DEFAULT_CUTOFF = time(0, 0)
DEFAULT_LAG_DAYS = 1

# A processor day whose deposit is this far overdue is no longer "late", it is
# lost or mis-recorded; expected dates are not searched for beyond it.
_MAX_SEARCH_DAYS = 400

#: Holiday categories that close the banks. The holiday calendar also carries
#: commercial days (White Friday, Valentine's) that it keeps for forecasting;
#: those are trading days like any other and must not delay a deposit.
BANK_CLOSED_HOLIDAY_CATEGORIES = frozenset({"national", "religious"})


def parse_weekdays(value) -> frozenset[int]:
    """``"6,0,1"`` → ``{6, 0, 1}``. Anything that is not a weekday is ignored."""
    days = set()
    for part in str(value or "").split(","):
        part = part.strip()
        if part.isdigit() and 0 <= int(part) <= 6:
            days.add(int(part))
    return frozenset(days)


def format_weekdays(days) -> str:
    """The stored form of a set of weekdays, in a stable order."""
    return ",".join(str(day) for day in sorted({int(day) for day in days}))


def cutoff_offset(cutoff: time | None) -> timedelta:
    """How far a processor day is shifted from the calendar day.

    A processor that closes at midnight runs calendar days. One that closes in
    the evening (say 23:00) starts its day the evening before, so a sale at
    23:30 is already tomorrow's: the offset is negative. One that closes in the
    early morning (say 02:00) keeps yesterday open until then: positive.
    Noon is the dividing line — no processor closes its day at lunchtime.
    """
    if cutoff is None:
        return timedelta(0)
    minutes = cutoff.hour * 60 + cutoff.minute
    if minutes == 0:
        return timedelta(0)
    if minutes <= 12 * 60:
        return timedelta(minutes=minutes)
    return timedelta(minutes=minutes) - timedelta(days=1)


def processor_day(moment: datetime, *, cutoff: time | None = DEFAULT_CUTOFF) -> date:
    """The processor day an instant belongs to, on the shop's own clock."""
    local = moment.astimezone(business_timezone())
    return (local - cutoff_offset(cutoff)).date()


def day_start(day: date) -> datetime:
    """Midnight at the start of ``day`` on the shop's own clock (aware)."""
    return datetime.combine(day, time.min, tzinfo=business_timezone())


def expected_settlement_date(
    day: date,
    *,
    settlement_weekdays: frozenset[int],
    lag_days: int = DEFAULT_LAG_DAYS,
    closed_dates: frozenset[date] | set[date] = frozenset(),
) -> date:
    """The day ``day``'s takings should reach the bank.

    The ``lag_days``-th settlement day after ``day``: a day the processor pays
    on (``settlement_weekdays``) that is not a bank holiday. With the default
    lag of one and a Sunday–Thursday week, Wednesday's takings land on
    Thursday and Thursday's, Friday's and Saturday's land on Sunday.

    A schedule with no settlement weekday at all would never pay; rather than
    loop forever it is answered with the plain calendar lag.
    """
    lag = max(int(lag_days), 0)
    if not settlement_weekdays:
        return day + timedelta(days=lag)
    current = day
    remaining = lag
    for _ in range(_MAX_SEARCH_DAYS):
        if remaining <= 0:
            return current
        current += timedelta(days=1)
        if current.weekday() in settlement_weekdays and current not in closed_dates:
            remaining -= 1
    return current


def bank_closed_dates(start: date, end: date) -> frozenset[date]:
    """Bank holidays between two days, inclusive, from the holiday calendar.

    Defensive: the calendar is a convenience for a date the owner is only shown
    as "expected". If it cannot be read, no holiday is assumed rather than the
    settlement screen failing.
    """
    if end < start:
        return frozenset()
    try:
        from apps.holidays.rules import special_days_for_date
        from apps.holidays.services import get_active_definitions

        definitions = [
            definition
            for definition in get_active_definitions()
            if getattr(definition, "category", "") in BANK_CLOSED_HOLIDAY_CATEGORIES
        ]
    except Exception:  # pragma: no cover - the calendar is optional
        return frozenset()
    if not definitions:
        return frozenset()
    closed = set()
    current = start
    while current <= end:
        if special_days_for_date(current, definitions):
            closed.add(current)
        current += timedelta(days=1)
    return frozenset(closed)


__all__ = [
    "BANK_CLOSED_HOLIDAY_CATEGORIES",
    "DEFAULT_CUTOFF",
    "DEFAULT_LAG_DAYS",
    "DEFAULT_SETTLEMENT_WEEKDAYS",
    "bank_closed_dates",
    "cutoff_offset",
    "day_start",
    "expected_settlement_date",
    "format_weekdays",
    "parse_weekdays",
    "processor_day",
]
