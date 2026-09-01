"""One answer to "which days is this report about?".

Before this module the reports screen offered Today / Week / Month / Custom,
where "Month" meant month-*to-date* — so the two windows every close is built
on, "last month" and "the year", were the two you had to pick by hand, twice,
for every report. An accountant closing September on 3 October did that nine
times.

Three things live here, and only here:

* **Presets.** Named windows an accountant actually asks for, resolved on the
  shop's own calendar rather than re-derived in the client. The client sends
  ``preset``; the server decides what days that means, so the PDF, the CSV and
  the on-screen table can never disagree about where September ended.

* **The fiscal year.** ``ShopSettings.fiscal_year_start_month`` anchors "this
  year" and "last year". A shop whose year ends in June asks for the year and
  gets its year, not January-to-December.

* **The comparison window.** Every figure in a month-end pack is read as a
  comparison — the first question anyone asks about a number is whether it is
  up or down. ``previous_period`` is the window of the same length immediately
  before; ``previous_year`` is the same dates a year earlier.

Days are calendar days on the app-wide clock, inclusive at both ends — the same
clock ``apps.core.money_dates`` slices money by, deliberately (see that module's
docstring for why it is UTC and not the shop timezone).
"""

from calendar import monthrange
from dataclasses import dataclass, replace
from datetime import date, datetime, time, timedelta

from django.db import models
from django.utils import timezone
from django.utils.dateparse import parse_date

MAX_PERIOD_DAYS = 366


class PeriodValidationError(ValueError):
    """A period the caller asked for cannot be built."""


class Preset(models.TextChoices):
    TODAY = "today", "Today"
    YESTERDAY = "yesterday", "Yesterday"
    WEEK = "week", "This week"
    MONTH = "month", "This month to date"
    LAST_MONTH = "last_month", "Last month"
    QUARTER = "quarter", "This quarter to date"
    LAST_QUARTER = "last_quarter", "Last quarter"
    YEAR = "year", "This year to date"
    LAST_YEAR = "last_year", "Last year"
    CUSTOM = "custom", "Custom"


class Granularity(models.TextChoices):
    """How much of the report to build.

    ``SUMMARY`` is the headline plus short supporting tables. ``DAILY`` adds a
    day-by-day breakdown to every report whose subject moves over time.
    ``DETAILED`` keeps the breakdown and raises the row caps, for the copy that
    goes in the file rather than on the wall.
    """

    SUMMARY = "summary", "Summary"
    DAILY = "daily", "Daily breakdown"
    DETAILED = "detailed", "Detailed"


class Comparison(models.TextChoices):
    NONE = "none", "No comparison"
    PREVIOUS_PERIOD = "previous_period", "Previous period"
    PREVIOUS_YEAR = "previous_year", "Same period last year"


# What each granularity multiplies the section row caps by. ``DETAILED`` is
# deliberately bounded rather than unlimited: the payload is stored in a JSON
# column and re-read on every view of the run, so an unbounded "detailed" would
# put a shop's whole stock history into one row of the database. The CSV export
# is the unbounded path (see ``csv_export``) and it stores nothing.
GRANULARITY_ROW_SCALE = {
    Granularity.SUMMARY: 1,
    Granularity.DAILY: 1,
    Granularity.DETAILED: 8,
}


@dataclass(frozen=True)
class ReportPeriod:
    """The days a report covers, and how to read them."""

    start_date: date
    end_date: date
    preset: str = Preset.CUSTOM
    granularity: str = Granularity.SUMMARY
    comparison: str = Comparison.NONE
    #: The window this one is compared against, or ``None``. Never carries a
    #: comparison of its own — one level only, so a report cannot ask for the
    #: previous period of the previous period.
    compared_to: "ReportPeriod | None" = None

    @property
    def start(self) -> datetime:
        return _localize(datetime.combine(self.start_date, time.min))

    @property
    def end(self) -> datetime:
        """Exclusive upper bound covering all of ``end_date``."""
        return _localize(datetime.combine(self.end_date + timedelta(days=1), time.min))

    @property
    def day_count(self) -> int:
        return (self.end_date - self.start_date).days + 1

    @property
    def wants_daily_breakdown(self) -> bool:
        return self.granularity in (Granularity.DAILY, Granularity.DETAILED)

    def row_limit(self, base_limit: int) -> int:
        return base_limit * GRANULARITY_ROW_SCALE.get(self.granularity, 1)

    def days(self):
        """Every calendar day in the window, in order."""
        for offset in range(self.day_count):
            yield self.start_date + timedelta(days=offset)

    def as_payload(self):
        payload = {
            "start_date": self.start_date.isoformat(),
            "end_date": self.end_date.isoformat(),
            "preset": self.preset,
            "granularity": self.granularity,
            "day_count": self.day_count,
        }
        if self.compared_to is not None:
            payload["comparison"] = self.comparison
            payload["compared_to"] = {
                "start_date": self.compared_to.start_date.isoformat(),
                "end_date": self.compared_to.end_date.isoformat(),
            }
        return payload


def resolve_period(params, *, today=None, fiscal_year_start_month=None):
    """Build the period a report should cover from its request parameters.

    ``preset`` wins when it names a window; ``start_date``/``end_date`` are read
    when it is ``custom`` or absent. A preset always resolves server-side so the
    stored run records the days it actually covered, not the client's idea of
    them.
    """
    params = params or {}
    today = today or timezone.localdate()
    preset = _clean_choice(params.get("preset"), Preset, default=None)
    granularity = _clean_choice(
        params.get("granularity"), Granularity, default=Granularity.SUMMARY
    )
    comparison = _clean_choice(
        params.get("comparison"), Comparison, default=Comparison.NONE
    )
    if fiscal_year_start_month is None:
        fiscal_year_start_month = _fiscal_year_start_month()

    if preset and preset != Preset.CUSTOM:
        start_date, end_date = _preset_bounds(
            preset, today, fiscal_year_start_month
        )
    else:
        preset = Preset.CUSTOM
        end_date = _parse_date_param(params.get("end_date"), default=today)
        start_date = _parse_date_param(
            params.get("start_date"),
            default=end_date - timedelta(days=29),
        )

    _validate_bounds(start_date, end_date)
    period = ReportPeriod(
        start_date=start_date,
        end_date=end_date,
        preset=preset,
        granularity=granularity,
        comparison=comparison,
    )
    if comparison == Comparison.NONE:
        return period
    return replace(period, compared_to=_comparison_window(period))


def _preset_bounds(preset, today, fiscal_year_start_month):
    if preset == Preset.TODAY:
        return today, today
    if preset == Preset.YESTERDAY:
        yesterday = today - timedelta(days=1)
        return yesterday, yesterday
    if preset == Preset.WEEK:
        return today - timedelta(days=today.weekday()), today
    if preset == Preset.MONTH:
        return today.replace(day=1), today
    if preset == Preset.LAST_MONTH:
        first_of_this = today.replace(day=1)
        last_of_previous = first_of_this - timedelta(days=1)
        return last_of_previous.replace(day=1), last_of_previous
    if preset == Preset.QUARTER:
        return _quarter_start(today), today
    if preset == Preset.LAST_QUARTER:
        this_quarter = _quarter_start(today)
        last_day = this_quarter - timedelta(days=1)
        return _quarter_start(last_day), last_day
    if preset == Preset.YEAR:
        return _fiscal_year_start(today, fiscal_year_start_month), today
    if preset == Preset.LAST_YEAR:
        this_year = _fiscal_year_start(today, fiscal_year_start_month)
        last_day = this_year - timedelta(days=1)
        return _fiscal_year_start(last_day, fiscal_year_start_month), last_day
    raise PeriodValidationError(f"Unknown period preset '{preset}'.")


def _quarter_start(value: date) -> date:
    return value.replace(month=((value.month - 1) // 3) * 3 + 1, day=1)


def _fiscal_year_start(value: date, start_month: int) -> date:
    """The first day of the fiscal year ``value`` falls in.

    A January start is the calendar year; any other start month means the year
    labelled 2026 begins in 2025 for dates before the start month.
    """
    year = value.year if value.month >= start_month else value.year - 1
    return date(year, start_month, 1)


def _comparison_window(period: ReportPeriod) -> ReportPeriod:
    if period.comparison == Comparison.PREVIOUS_YEAR:
        return ReportPeriod(
            start_date=_shift_years(period.start_date, -1),
            end_date=_shift_years(period.end_date, -1),
            preset=period.preset,
            granularity=period.granularity,
        )
    # A whole calendar month compares against the whole previous month rather
    # than "the same number of days before it" — otherwise a 31-day month is
    # measured against 31 days that straddle two others, and February is never
    # comparable to anything.
    if _is_whole_month(period):
        previous_end = period.start_date - timedelta(days=1)
        return ReportPeriod(
            start_date=previous_end.replace(day=1),
            end_date=previous_end,
            preset=period.preset,
            granularity=period.granularity,
        )
    length = timedelta(days=period.day_count)
    return ReportPeriod(
        start_date=period.start_date - length,
        end_date=period.start_date - timedelta(days=1),
        preset=period.preset,
        granularity=period.granularity,
    )


def _is_whole_month(period: ReportPeriod) -> bool:
    if period.start_date.day != 1:
        return False
    last_day = monthrange(period.end_date.year, period.end_date.month)[1]
    return (
        period.end_date.day == last_day
        and period.start_date.month == period.end_date.month
        and period.start_date.year == period.end_date.year
    )


def _shift_years(value: date, years: int) -> date:
    try:
        return value.replace(year=value.year + years)
    except ValueError:
        # 29 February in a year that has none.
        return value.replace(year=value.year + years, day=28)


def _validate_bounds(start_date, end_date):
    if start_date > end_date:
        raise PeriodValidationError("Start date must be before end date.")
    if (end_date - start_date).days >= MAX_PERIOD_DAYS:
        raise PeriodValidationError(
            f"Report period cannot be longer than {MAX_PERIOD_DAYS} days."
        )


def _parse_date_param(value, *, default):
    if value in (None, ""):
        return default
    parsed = parse_date(str(value))
    if parsed is None:
        raise PeriodValidationError("Dates must use YYYY-MM-DD format.")
    return parsed


def _clean_choice(value, choices, *, default):
    if value in (None, ""):
        return default
    value = str(value)
    if value not in choices.values:
        raise PeriodValidationError(
            f"'{value}' is not one of: {', '.join(choices.values)}."
        )
    return value


def _fiscal_year_start_month() -> int:
    from apps.core.models import ShopSettings

    return ShopSettings.load().fiscal_year_start_month


def _localize(naive: datetime) -> datetime:
    return timezone.make_aware(naive, timezone.get_current_timezone())


__all__ = [
    "Comparison",
    "Granularity",
    "MAX_PERIOD_DAYS",
    "PeriodValidationError",
    "Preset",
    "ReportPeriod",
    "resolve_period",
]
