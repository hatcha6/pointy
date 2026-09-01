"""The windows an accountant actually asks for.

Before this, the reports screen offered Today / Week / Month / Custom, where
"Month" meant month-*to-date* — so "last month" and "the year", the two windows
every close is built on, were the two you had to pick by hand. These tests pin
the presets, the fiscal year, and the comparison window they resolve against.
"""

from datetime import date

from django.test import TestCase

from .periods import (
    Comparison,
    Granularity,
    MAX_PERIOD_DAYS,
    PeriodValidationError,
    Preset,
    resolve_period,
)

# A Tuesday, mid-month, mid-quarter — so every preset below resolves to a window
# with a real inside and a real outside rather than landing on a boundary.
TODAY = date(2026, 9, 15)


def period(**params):
    return resolve_period(params, today=TODAY, fiscal_year_start_month=1)


class PresetTests(TestCase):
    def test_last_month_is_the_whole_previous_month(self):
        window = period(preset=Preset.LAST_MONTH)
        self.assertEqual(window.start_date, date(2026, 8, 1))
        self.assertEqual(window.end_date, date(2026, 8, 31))

    def test_month_is_to_date_and_last_month_is_not(self):
        """Both are useful and they are not the same question."""
        self.assertEqual(period(preset=Preset.MONTH).end_date, TODAY)
        self.assertLess(period(preset=Preset.LAST_MONTH).end_date, TODAY)

    def test_quarter_and_last_quarter(self):
        self.assertEqual(period(preset=Preset.QUARTER).start_date, date(2026, 7, 1))
        last = period(preset=Preset.LAST_QUARTER)
        self.assertEqual(last.start_date, date(2026, 4, 1))
        self.assertEqual(last.end_date, date(2026, 6, 30))

    def test_yesterday_and_today_are_single_days(self):
        self.assertEqual(period(preset=Preset.TODAY).day_count, 1)
        self.assertEqual(period(preset=Preset.YESTERDAY).end_date, date(2026, 9, 14))

    def test_a_preset_resolves_on_the_server_not_the_client(self):
        """Dates sent alongside a preset are ignored.

        The stored run has to record the days it actually covered. A client that
        computes "last month" on a device with a wrong clock must not be able to
        label a window as September that the server built from August.
        """
        window = period(
            preset=Preset.LAST_MONTH, start_date="2020-01-01", end_date="2020-01-31"
        )
        self.assertEqual(window.start_date, date(2026, 8, 1))

    def test_custom_dates_are_honoured(self):
        window = period(start_date="2026-03-05", end_date="2026-03-09")
        self.assertEqual(window.preset, Preset.CUSTOM)
        self.assertEqual(window.day_count, 5)


class FiscalYearTests(TestCase):
    """A shop whose year ends in June asks for "the year" and gets its year."""

    def test_a_january_start_is_the_calendar_year(self):
        window = resolve_period(
            {"preset": Preset.YEAR}, today=TODAY, fiscal_year_start_month=1
        )
        self.assertEqual(window.start_date, date(2026, 1, 1))

    def test_a_july_start_moves_the_year_boundary(self):
        window = resolve_period(
            {"preset": Preset.YEAR}, today=TODAY, fiscal_year_start_month=7
        )
        self.assertEqual(window.start_date, date(2026, 7, 1))

    def test_before_the_start_month_the_year_began_last_calendar_year(self):
        window = resolve_period(
            {"preset": Preset.YEAR},
            today=date(2026, 3, 1),
            fiscal_year_start_month=7,
        )
        self.assertEqual(window.start_date, date(2025, 7, 1))

    def test_last_fiscal_year_is_the_twelve_months_before_this_one(self):
        window = resolve_period(
            {"preset": Preset.LAST_YEAR}, today=TODAY, fiscal_year_start_month=7
        )
        self.assertEqual(window.start_date, date(2025, 7, 1))
        self.assertEqual(window.end_date, date(2026, 6, 30))


class ComparisonTests(TestCase):
    def test_a_whole_month_compares_against_the_whole_previous_month(self):
        """Not "the same number of days before it".

        August has 31 days; measuring it against the 31 days before 1 August
        straddles two months and makes February incomparable to anything.
        """
        window = period(
            preset=Preset.LAST_MONTH, comparison=Comparison.PREVIOUS_PERIOD
        )
        self.assertEqual(window.compared_to.start_date, date(2026, 7, 1))
        self.assertEqual(window.compared_to.end_date, date(2026, 7, 31))

    def test_a_partial_window_compares_against_one_of_the_same_length(self):
        window = period(
            start_date="2026-09-08",
            end_date="2026-09-14",
            comparison=Comparison.PREVIOUS_PERIOD,
        )
        self.assertEqual(window.compared_to.start_date, date(2026, 9, 1))
        self.assertEqual(window.compared_to.end_date, date(2026, 9, 7))

    def test_previous_year_is_the_same_dates_a_year_earlier(self):
        window = period(
            preset=Preset.LAST_MONTH, comparison=Comparison.PREVIOUS_YEAR
        )
        self.assertEqual(window.compared_to.start_date, date(2025, 8, 1))
        self.assertEqual(window.compared_to.end_date, date(2025, 8, 31))

    def test_a_comparison_window_never_carries_one_of_its_own(self):
        window = period(
            preset=Preset.LAST_MONTH, comparison=Comparison.PREVIOUS_PERIOD
        )
        self.assertIsNone(window.compared_to.compared_to)

    def test_no_comparison_by_default(self):
        self.assertIsNone(period(preset=Preset.LAST_MONTH).compared_to)


class ValidationTests(TestCase):
    def test_a_reversed_range_is_refused_with_a_readable_reason(self):
        with self.assertRaises(PeriodValidationError) as caught:
            period(start_date="2026-09-10", end_date="2026-09-01")
        self.assertIn("before", str(caught.exception))

    def test_a_range_longer_than_a_year_is_refused(self):
        with self.assertRaises(PeriodValidationError) as caught:
            period(start_date="2024-01-01", end_date="2026-01-01")
        self.assertIn(str(MAX_PERIOD_DAYS), str(caught.exception))

    def test_a_whole_leap_year_still_fits(self):
        window = period(start_date="2024-01-01", end_date="2024-12-31")
        self.assertEqual(window.day_count, 366)

    def test_an_unknown_preset_names_the_ones_that_exist(self):
        with self.assertRaises(PeriodValidationError) as caught:
            period(preset="fortnight")
        self.assertIn(Preset.LAST_MONTH, str(caught.exception))

    def test_a_malformed_date_says_what_shape_it_wanted(self):
        with self.assertRaises(PeriodValidationError) as caught:
            period(start_date="05/03/2026")
        self.assertIn("YYYY-MM-DD", str(caught.exception))


class GranularityTests(TestCase):
    def test_detail_raises_the_row_caps_and_summary_does_not(self):
        summary = period(preset=Preset.LAST_MONTH, granularity=Granularity.SUMMARY)
        detailed = period(preset=Preset.LAST_MONTH, granularity=Granularity.DETAILED)
        self.assertEqual(summary.row_limit(120), 120)
        self.assertGreater(detailed.row_limit(120), 120)

    def test_only_daily_and_detailed_ask_for_a_day_by_day_breakdown(self):
        self.assertFalse(period(granularity=Granularity.SUMMARY).wants_daily_breakdown)
        self.assertTrue(period(granularity=Granularity.DAILY).wants_daily_breakdown)
        self.assertTrue(period(granularity=Granularity.DETAILED).wants_daily_breakdown)

    def test_days_enumerates_the_window_inclusively(self):
        window = period(start_date="2026-09-01", end_date="2026-09-03")
        self.assertEqual(
            list(window.days()),
            [date(2026, 9, 1), date(2026, 9, 2), date(2026, 9, 3)],
        )
