"""The dashboard period picker: «اليوم» (days=1) plus the rolling 7/30/90."""

from datetime import datetime, timedelta
from types import SimpleNamespace
from unittest import mock

from django.test import SimpleTestCase, override_settings
from django.utils import timezone

from apps.core.dashboard.view import _period_from_request


def _period(days):
    return _period_from_request(SimpleNamespace(query_params={"days": str(days)}))


@override_settings(TIME_ZONE="Africa/Tripoli")
class DashboardPeriodTests(SimpleTestCase):
    def test_today_starts_at_local_midnight_and_compares_with_yesterday_so_far(self):
        # 01:30 in Tripoli is still the previous day in UTC — the window must
        # follow the shop's clock, not UTC's.
        now = timezone.make_aware(datetime(2026, 10, 11, 1, 30))
        with mock.patch("apps.core.dashboard.view.timezone.now", return_value=now):
            period = _period(1)

        self.assertEqual(period["days"], 1)
        self.assertEqual(period["start"], timezone.make_aware(datetime(2026, 10, 11)))
        self.assertEqual(period["end"], now)
        self.assertEqual(period["start"].date(), period["end"].date())
        self.assertEqual(period["previous_start"], timezone.make_aware(datetime(2026, 10, 10)))
        self.assertEqual(period["previous_end"], now - timedelta(days=1))

    def test_rolling_periods_are_unchanged(self):
        for days in (7, 30, 90):
            period = _period(days)
            self.assertEqual(period["days"], days)
            self.assertEqual(period["end"] - period["start"], timedelta(days=days))
            self.assertEqual(period["previous_end"], period["start"])

    def test_out_of_range_values_still_clamp(self):
        self.assertEqual(_period(0)["days"], 7)
        self.assertEqual(_period(3)["days"], 7)
        self.assertEqual(_period(365)["days"], 90)
        self.assertEqual(_period("x")["days"], 30)
