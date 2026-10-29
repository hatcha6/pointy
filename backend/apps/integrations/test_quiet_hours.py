"""Unattended reads keep to the shop's trading day.

Annaseem's export (2026-10-28) showed Pointy logging in to LNET at 01:05,
02:05, 03:05… every night: a half-hourly payments sync, an hourly float
refresh and a 04:20 reconciliation. That is how a script looks to a portal,
and an agency account blocked for it cannot sell at all.
"""

from __future__ import annotations

from datetime import datetime, timedelta
from datetime import timezone as dt_timezone
from decimal import Decimal
from unittest import mock

from django.conf import settings
from django.test import SimpleTestCase, TestCase, override_settings
from django.utils import timezone

from apps.core.timeutils import business_timezone

from .providers.base import ProbeResult
from .quiet_hours import in_quiet_hours, reconciliation_due
from .services import refresh_float_balances
from .tasks import reconcile_providers_task
from .tests import lnet_account, make_account


def shop_time(hour: int, minute: int = 0) -> datetime:
    return datetime(2026, 10, 29, hour, minute, tzinfo=business_timezone())


@override_settings(POINTY_PROVIDER_QUIET_HOURS="1-9")
class QuietHoursTests(SimpleTestCase):
    def test_the_night_is_quiet_and_the_trading_day_is_not(self):
        self.assertTrue(in_quiet_hours(shop_time(1)))
        self.assertTrue(in_quiet_hours(shop_time(4, 20)))
        self.assertTrue(in_quiet_hours(shop_time(8, 59)))
        self.assertFalse(in_quiet_hours(shop_time(9)))
        self.assertFalse(in_quiet_hours(shop_time(18)))
        # Just after midnight a shop is still closing up.
        self.assertFalse(in_quiet_hours(shop_time(0, 30)))

    def test_the_hours_are_the_shops_not_utc(self):
        # 07:30 UTC is 09:30 in Tripoli: open, though 07:30 is inside 1-9.
        at = datetime(2026, 10, 29, 7, 30, tzinfo=dt_timezone.utc)
        self.assertFalse(in_quiet_hours(at))

    @override_settings(POINTY_PROVIDER_QUIET_HOURS="23-7")
    def test_a_window_across_midnight(self):
        self.assertTrue(in_quiet_hours(shop_time(23, 30)))
        self.assertTrue(in_quiet_hours(shop_time(3)))
        self.assertFalse(in_quiet_hours(shop_time(7)))
        self.assertFalse(in_quiet_hours(shop_time(22)))

    @override_settings(POINTY_PROVIDER_QUIET_HOURS="")
    def test_empty_turns_it_off(self):
        self.assertFalse(in_quiet_hours(shop_time(3)))

    @override_settings(POINTY_PROVIDER_QUIET_HOURS="nonsense")
    def test_a_malformed_setting_turns_it_off_rather_than_crashing(self):
        self.assertFalse(in_quiet_hours(shop_time(3)))

    def test_reconciliation_runs_in_the_hour_the_quiet_hours_end(self):
        self.assertTrue(reconciliation_due(shop_time(9, 20)))
        self.assertFalse(reconciliation_due(shop_time(4, 20)))
        self.assertFalse(reconciliation_due(shop_time(10, 20)))

    @override_settings(POINTY_PROVIDER_QUIET_HOURS="")
    def test_without_quiet_hours_reconciliation_keeps_its_old_slot(self):
        self.assertTrue(reconciliation_due(shop_time(2, 20)))


class QuietFloatRefreshTests(TestCase):
    def _probe(self):
        return mock.patch(
            "apps.integrations.services.probe_account",
            return_value=ProbeResult(ok=True, balance=Decimal("5.00")),
        )

    @override_settings(POINTY_PROVIDER_QUIET_HOURS="1-9")
    def test_nothing_is_read_at_night(self):
        make_account()
        lnet_account()
        with self._probe() as probe:
            result = refresh_float_balances(now=shop_time(3, 50))
        probe.assert_not_called()
        self.assertTrue(result["quiet_hours"])

    @override_settings(POINTY_PROVIDER_QUIET_HOURS="1-9")
    def test_the_trading_day_is_read(self):
        lnet_account()
        with self._probe() as probe:
            result = refresh_float_balances(now=shop_time(11, 50))
        self.assertEqual(probe.call_count, 1)
        self.assertEqual(result, {"checked": 1, "connected": 1})

    def test_a_float_a_sale_just_reported_is_not_read_again(self):
        # An LNET top-up's own reply carries the new float; logging in to be
        # told it again an hour later buys nothing.
        account = lnet_account()
        now = timezone.now()
        account.balance = Decimal("300.00")
        account.balance_at = now - timedelta(minutes=10)
        account.save(update_fields=["balance", "balance_at"])
        with self._probe() as probe:
            result = refresh_float_balances(now=now)
        probe.assert_not_called()
        self.assertEqual(result, {"checked": 0, "connected": 0})

    def test_last_hours_reading_is_read_again(self):
        account = lnet_account()
        now = timezone.now()
        account.balance_at = now - timedelta(minutes=60)
        account.save(update_fields=["balance_at"])
        with self._probe() as probe:
            refresh_float_balances(now=now)
        self.assertEqual(probe.call_count, 1)


class QuietReconciliationTests(TestCase):
    def test_outside_its_hour_the_task_reads_nothing(self):
        with (
            mock.patch("apps.integrations.quiet_hours.reconciliation_due", return_value=False),
            mock.patch("apps.integrations.reconciliation.reconcile_all") as run,
        ):
            self.assertEqual(reconcile_providers_task.apply().get(), {"skipped": "not_due"})
        run.assert_not_called()

    def test_in_its_hour_it_runs(self):
        with (
            mock.patch("apps.integrations.quiet_hours.reconciliation_due", return_value=True),
            mock.patch(
                "apps.integrations.reconciliation.reconcile_all",
                return_value={"accounts": []},
            ) as run,
        ):
            self.assertEqual(reconcile_providers_task.apply().get(), {"accounts": []})
        run.assert_called_once()


class ProviderScheduleTests(SimpleTestCase):
    def test_the_payments_report_is_not_on_a_timer(self):
        tasks = {entry["task"] for entry in settings.CELERY_BEAT_SCHEDULE.values()}
        self.assertNotIn("integrations.sync_payment_reports", tasks)

    def test_reconciliation_is_offered_every_hour_and_picks_its_own(self):
        entry = settings.CELERY_BEAT_SCHEDULE["integrations.reconcile-providers"]
        self.assertEqual(entry["schedule"].hour, set(range(24)))
