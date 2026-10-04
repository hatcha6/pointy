"""The processor's calendar and the deposit matcher — plain arithmetic.

The schedule under test is the one a Libyan shop described for Moamalat: it
closes its day at midnight and pays each day's card takings on the next banking
day, so Thursday's, Friday's and Saturday's all land on Sunday.
"""

from datetime import date, datetime, time
from datetime import timezone as dt_timezone
from decimal import Decimal

from django.test import SimpleTestCase

from apps.core.timeutils import business_timezone

from .settlement_calendar import (
    DEFAULT_SETTLEMENT_WEEKDAYS,
    cutoff_offset,
    expected_settlement_date,
    format_weekdays,
    parse_weekdays,
    processor_day,
)
from .settlement_match import (
    MATCH_CLOSE,
    MATCH_DUE,
    MATCH_EXACT,
    MATCH_GROSS,
    MATCH_NONE,
    PendingDay,
    suggest,
)

LIBYAN_WEEK = parse_weekdays(DEFAULT_SETTLEMENT_WEEKDAYS)

# 2026-10-04 is a Sunday.
SUNDAY = date(2026, 10, 4)
MONDAY = date(2026, 10, 5)
WEDNESDAY = date(2026, 10, 7)
THURSDAY = date(2026, 10, 8)
FRIDAY = date(2026, 10, 9)
SATURDAY = date(2026, 10, 10)
NEXT_SUNDAY = date(2026, 10, 11)


def expected(day, **kwargs):
    kwargs.setdefault("settlement_weekdays", LIBYAN_WEEK)
    return expected_settlement_date(day, **kwargs)


class ExpectedSettlementDateTests(SimpleTestCase):
    def test_the_week_lands_the_next_banking_day(self):
        self.assertEqual(expected(SUNDAY), MONDAY)
        self.assertEqual(expected(WEDNESDAY), THURSDAY)

    def test_thursday_friday_and_saturday_all_wait_for_sunday(self):
        for day in (THURSDAY, FRIDAY, SATURDAY):
            with self.subTest(day=day):
                self.assertEqual(expected(day), NEXT_SUNDAY)

    def test_a_bank_holiday_pushes_the_deposit_to_the_next_open_day(self):
        self.assertEqual(
            expected(THURSDAY, closed_dates={NEXT_SUNDAY}),
            date(2026, 10, 12),
        )

    def test_a_two_day_lag_counts_banking_days_only(self):
        self.assertEqual(expected(WEDNESDAY, lag_days=2), NEXT_SUNDAY)

    def test_a_schedule_with_no_paying_day_falls_back_to_the_calendar(self):
        self.assertEqual(
            expected(THURSDAY, settlement_weekdays=frozenset()), FRIDAY
        )

    def test_weekdays_round_trip_and_ignore_junk(self):
        self.assertEqual(parse_weekdays("6, 0,1,x,9,"), frozenset({6, 0, 1}))
        self.assertEqual(format_weekdays({3, 6, 0}), "0,3,6")


class ProcessorDayTests(SimpleTestCase):
    def local(self, day, hour, minute=0):
        return datetime.combine(day, time(hour, minute), tzinfo=business_timezone())

    def test_the_day_is_the_shops_not_utc(self):
        # 00:30 in Tripoli is still the previous day in UTC.
        moment = self.local(FRIDAY, 0, 30).astimezone(dt_timezone.utc)
        self.assertEqual(moment.date(), THURSDAY)
        self.assertEqual(processor_day(moment), FRIDAY)

    def test_an_evening_cutoff_puts_late_sales_on_tomorrow(self):
        self.assertEqual(cutoff_offset(time(23, 0)).total_seconds(), -3600)
        self.assertEqual(
            processor_day(self.local(THURSDAY, 23, 30), cutoff=time(23, 0)), FRIDAY
        )
        self.assertEqual(
            processor_day(self.local(THURSDAY, 22, 59), cutoff=time(23, 0)), THURSDAY
        )

    def test_an_early_morning_cutoff_keeps_last_night_open(self):
        self.assertEqual(
            processor_day(self.local(FRIDAY, 1, 0), cutoff=time(2, 0)), THURSDAY
        )
        self.assertEqual(
            processor_day(self.local(FRIDAY, 2, 0), cutoff=time(2, 0)), FRIDAY
        )


def held(day, gross, commission="0.00", *, expected_on=None):
    return PendingDay(
        day=day,
        expected_on=expected_on or expected(day),
        gross=Decimal(gross),
        commission=Decimal(commission),
        count=1,
    )


class SuggestTests(SimpleTestCase):
    def setUp(self):
        self.thursday = held(THURSDAY, "1000.00", "10.00")
        self.friday = held(FRIDAY, "500.00", "5.00")
        self.saturday = held(SATURDAY, "300.00", "3.00")
        self.sunday = held(NEXT_SUNDAY, "200.00", "2.00")
        self.days = [self.sunday, self.thursday, self.saturday, self.friday]

    def test_the_weekend_deposit_matches_its_three_days_exactly(self):
        result = suggest(self.days, amount=Decimal("1782.00"), settled_on=NEXT_SUNDAY)
        self.assertEqual(result.match, MATCH_EXACT)
        self.assertEqual(result.days, (THURSDAY, FRIDAY, SATURDAY))
        self.assertEqual(result.difference, Decimal("0.00"))

    def test_a_deposit_with_no_fee_taken_matches_before_the_fee(self):
        result = suggest(self.days, amount=Decimal("1800.00"), settled_on=NEXT_SUNDAY)
        self.assertEqual(result.match, MATCH_GROSS)
        self.assertEqual(result.days, (THURSDAY, FRIDAY, SATURDAY))
        self.assertEqual(result.difference, Decimal("18.00"))

    def test_a_fee_rounded_differently_is_close(self):
        result = suggest(self.days, amount=Decimal("1781.95"), settled_on=NEXT_SUNDAY)
        self.assertEqual(result.match, MATCH_CLOSE)
        self.assertEqual(result.days, (THURSDAY, FRIDAY, SATURDAY))
        self.assertEqual(result.difference, Decimal("-0.05"))

    def test_a_day_the_processor_skipped_is_found_by_combination(self):
        # Paid Thursday and Saturday, kept Friday back.
        result = suggest(self.days, amount=Decimal("1287.00"), settled_on=NEXT_SUNDAY)
        self.assertEqual(result.match, MATCH_EXACT)
        self.assertEqual(result.days, (THURSDAY, SATURDAY))

    def test_nothing_adds_up_so_the_due_days_are_proposed(self):
        result = suggest(self.days, amount=Decimal("100.00"), settled_on=NEXT_SUNDAY)
        self.assertEqual(result.match, MATCH_DUE)
        self.assertEqual(result.days, (THURSDAY, FRIDAY, SATURDAY))
        self.assertEqual(result.difference, Decimal("-1682.00"))

    def test_without_an_amount_the_due_days_are_proposed(self):
        result = suggest(self.days, amount=None, settled_on=NEXT_SUNDAY)
        self.assertEqual(result.match, MATCH_DUE)
        self.assertEqual(result.days, (THURSDAY, FRIDAY, SATURDAY))
        self.assertIsNone(result.difference)

    def test_takings_after_the_deposit_are_never_proposed(self):
        result = suggest(self.days, amount=Decimal("990.00"), settled_on=THURSDAY)
        self.assertEqual(result.days, (THURSDAY,))
        self.assertEqual(result.match, MATCH_EXACT)

    def test_nothing_due_yet_proposes_the_oldest_day(self):
        result = suggest([self.sunday], amount=None, settled_on=NEXT_SUNDAY)
        self.assertEqual(result.match, MATCH_NONE)
        self.assertEqual(result.days, (NEXT_SUNDAY,))

    def test_no_held_days_proposes_nothing(self):
        result = suggest([], amount=Decimal("10.00"), settled_on=NEXT_SUNDAY)
        self.assertEqual(result.days, ())
        self.assertEqual(result.expected, Decimal("0.00"))
