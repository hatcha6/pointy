"""Relay rate sync: reconciliation, resilience, and the rules that protect the shop.

The behaviours pinned here are the ones that decide whether a shop can trust the
feed: that a number the owner typed is never overwritten, that an unreachable
relay costs nothing, and that a rate is a historical fact rather than a mutable
current value.
"""

from datetime import timedelta
from decimal import Decimal

from django.core.exceptions import ImproperlyConfigured
from django.test import TestCase
from django.utils import timezone

from apps.core.models import RelayInstallation, ShopSettings
from apps.core.relay import RelayControlError
from apps.fx import currencies as ref
from apps.fx.models import ExchangeRate
from apps.fx.rates import invalidate_rate_cache, rate_on
from apps.fx.services import (
    ensure_builtin_currencies,
    record_manual_rate,
    sync_exchange_rates,
)


class FakeRelayClient:
    """Stands in for ``RelayControlClient``; records what it was asked for."""

    def __init__(self, rates=None, error=None):
        self._rates = rates or []
        self._error = error
        self.calls = []

    def get_exchange_rates(self, *, access_token, since=None):
        self.calls.append({"access_token": access_token, "since": since})
        if self._error is not None:
            raise self._error
        return {"rates": self._rates}


class SyncTestCase(TestCase):
    def setUp(self):
        super().setUp()
        ensure_builtin_currencies()
        invalidate_rate_cache()
        self.now = timezone.now().replace(microsecond=0)
        RelayInstallation.objects.create(
            installation_id="inst-1",
            relay_public_api_url="https://relay.example/api/",
            connector_token="c",
            access_token="tok",
            relay_enabled=True,
            subscription_active=True,
        )

    def row(self, rate, *, at=None, frm="USD", to="LYD", instrument="cash",
            bank_code=None, row_id="r1"):
        payload = {
            "id": row_id,
            "from": frm,
            "to": to,
            "rate": str(rate),
            "instrument": instrument,
            "effective_at": (at or self.now).isoformat(),
        }
        if bank_code is not None:
            payload["bank_code"] = bank_code
        return payload


class SyncHappyPathTests(SyncTestCase):
    def test_rates_are_inserted(self):
        client = FakeRelayClient([self.row("6.85")])
        result = sync_exchange_rates(client=client)
        self.assertEqual(result["synced"], 1)
        self.assertEqual(rate_on("USD", "LYD").rate, Decimal("6.85000000"))

    def test_sync_is_idempotent(self):
        client = FakeRelayClient([self.row("6.85")])
        sync_exchange_rates(client=client)
        sync_exchange_rates(client=client)
        self.assertEqual(ExchangeRate.objects.count(), 1)

    def test_bank_rates_keep_their_bank_and_stay_separate_from_cash(self):
        client = FakeRelayClient([
            self.row("6.85", instrument="cash", row_id="c1"),
            self.row("6.90", instrument="bank", bank_code="NCB", row_id="b1"),
        ])
        sync_exchange_rates(client=client)
        self.assertEqual(ExchangeRate.objects.count(), 2)
        bank = ExchangeRate.objects.get(instrument=ref.INSTRUMENT_BANK)
        self.assertEqual(bank.bank_code, "ncb")

    def test_a_new_rate_is_added_not_an_update_of_the_old_one(self):
        # A rate is a historical fact. Overwriting yesterday's would make a
        # document that froze it unresolvable.
        client = FakeRelayClient([self.row("6.85", at=self.now - timedelta(hours=2))])
        sync_exchange_rates(client=client)
        client = FakeRelayClient([self.row("7.11", at=self.now - timedelta(hours=1))])
        sync_exchange_rates(client=client)
        self.assertEqual(ExchangeRate.objects.count(), 2)
        self.assertEqual(
            rate_on("USD", "LYD", at=self.now - timedelta(hours=2)).rate,
            Decimal("6.85000000"),
        )

    def test_relay_id_is_recorded(self):
        sync_exchange_rates(client=FakeRelayClient([self.row("6.85", row_id="abc")]))
        self.assertEqual(ExchangeRate.objects.get().relay_id, "abc")

    def test_the_feed_is_asked_only_for_what_is_new(self):
        client = FakeRelayClient([self.row("6.85", at=self.now - timedelta(hours=5))])
        sync_exchange_rates(client=client)
        follow_up = FakeRelayClient([])
        sync_exchange_rates(client=follow_up)
        self.assertIsNotNone(follow_up.calls[0]["since"])

    def test_the_first_sync_asks_for_a_lookback_window(self):
        client = FakeRelayClient([])
        sync_exchange_rates(client=client)
        self.assertIsNotNone(client.calls[0]["since"])


class ManualRatesAreNeverOverwrittenTests(SyncTestCase):
    def test_the_feed_does_not_correct_a_number_the_owner_typed(self):
        record_manual_rate(
            from_code="USD", to_code="LYD", rate="7.50", effective_at=self.now
        )
        sync_exchange_rates(client=FakeRelayClient([self.row("6.85", at=self.now)]))
        row = ExchangeRate.objects.get()
        self.assertEqual(row.source, ref.SOURCE_MANUAL)
        self.assertEqual(row.rate, Decimal("7.50000000"))

    def test_but_the_feed_may_add_a_rate_at_a_different_instant(self):
        record_manual_rate(
            from_code="USD",
            to_code="LYD",
            rate="7.50",
            effective_at=self.now - timedelta(hours=2),
        )
        sync_exchange_rates(
            client=FakeRelayClient([self.row("6.85", at=self.now - timedelta(hours=1))])
        )
        self.assertEqual(ExchangeRate.objects.count(), 2)

    def test_a_manual_only_shop_skips_the_feed_entirely(self):
        row = ShopSettings.load()
        ShopSettings.objects.filter(pk=row.pk).update(fx_manual_only=True)
        client = FakeRelayClient([self.row("6.85")])
        result = sync_exchange_rates(client=client)
        self.assertTrue(result["skipped"])
        self.assertEqual(client.calls, [])
        self.assertEqual(ExchangeRate.objects.count(), 0)


class SyncResilienceTests(SyncTestCase):
    def test_an_unreachable_relay_is_a_soft_no_op(self):
        ExchangeRate.objects.create(
            from_currency_id="USD",
            to_currency_id="LYD",
            instrument=ref.INSTRUMENT_CASH,
            effective_at=self.now - timedelta(hours=1),
            rate=Decimal("6.85"),
            source=ref.SOURCE_RELAY,
        )
        result = sync_exchange_rates(
            client=FakeRelayClient(error=RelayControlError("connection refused"))
        )
        self.assertIn("error", result)
        # The shop keeps pricing off the last thing it knew.
        self.assertEqual(rate_on("USD", "LYD").rate, Decimal("6.85"))

    def test_a_misconfigured_relay_is_also_soft(self):
        result = sync_exchange_rates(
            client=FakeRelayClient(error=ImproperlyConfigured("no control url"))
        )
        self.assertIn("error", result)

    def test_no_installation_means_no_sync_and_no_crash(self):
        RelayInstallation.objects.all().delete()
        RelayInstallation.load.__self__  # touch the classmethod owner harmlessly
        from apps.core import caching

        caching.invalidate_relay_installation()
        result = sync_exchange_rates(client=FakeRelayClient([self.row("6.85")]))
        self.assertTrue(result["skipped"])

    def test_one_bad_row_does_not_abort_the_batch(self):
        client = FakeRelayClient([
            {"from": "USD", "to": "LYD", "rate": "nonsense",
             "effective_at": self.now.isoformat(), "id": "bad"},
            self.row("6.85", row_id="good"),
        ])
        result = sync_exchange_rates(client=client)
        self.assertEqual(result["synced"], 1)

    def test_a_non_positive_rate_is_refused(self):
        client = FakeRelayClient([self.row("0", row_id="zero")])
        result = sync_exchange_rates(client=client)
        self.assertEqual(result["synced"], 0)
        self.assertEqual(ExchangeRate.objects.count(), 0)

    def test_an_unknown_currency_is_skipped_not_auto_created(self):
        client = FakeRelayClient([self.row("1.5", frm="XYZ", row_id="x")])
        result = sync_exchange_rates(client=client)
        self.assertEqual(result["skipped_unknown_currency"], 1)
        self.assertEqual(ExchangeRate.objects.count(), 0)

    def test_a_row_without_an_instant_is_skipped(self):
        client = FakeRelayClient([
            {"from": "USD", "to": "LYD", "rate": "6.85", "id": "no-date"}
        ])
        self.assertEqual(sync_exchange_rates(client=client)["synced"], 0)

    def test_an_empty_payload_is_fine(self):
        self.assertEqual(sync_exchange_rates(client=FakeRelayClient([]))["synced"], 0)


class DailyAllowanceTests(SyncTestCase):
    """A shop without the FX entitlement gets one fetch a day, not zero.

    Being throttled is the NORMAL state for most of the day on the free tier —
    it is not a failure, and it must never disturb the rates already on the
    shelf.
    """

    def test_a_spent_allowance_is_reported_as_throttled_not_failed(self):
        client = FakeRelayClient(
            error=RelayControlError("relay control returned 429: allowance used")
        )
        result = sync_exchange_rates(client=client)
        self.assertTrue(result["throttled"])
        self.assertNotIn("error", result)

    def test_a_throttled_sync_leaves_existing_rates_alone(self):
        ExchangeRate.objects.create(
            from_currency_id="USD",
            to_currency_id="LYD",
            instrument=ref.INSTRUMENT_CASH,
            effective_at=self.now - timedelta(hours=2),
            rate=Decimal("6.85"),
            source=ref.SOURCE_RELAY,
        )
        sync_exchange_rates(
            client=FakeRelayClient(
                error=RelayControlError("relay control returned 429: allowance used")
            )
        )
        self.assertEqual(rate_on("USD", "LYD").rate, Decimal("6.85"))

    def test_a_real_failure_is_still_reported_as_an_error(self):
        result = sync_exchange_rates(
            client=FakeRelayClient(error=RelayControlError("connection refused"))
        )
        self.assertIn("error", result)
        self.assertNotIn("throttled", result)

    def test_the_access_tier_is_surfaced_from_the_payload(self):
        class TieredClient(FakeRelayClient):
            def get_exchange_rates(self, *, access_token, since=None):
                return {"rates": [], "access": "daily", "entitled": False}

        result = sync_exchange_rates(client=TieredClient())
        self.assertEqual(result["access"], "daily")
        self.assertFalse(result["entitled"])

    def test_an_entitled_shop_is_reported_as_such(self):
        class TieredClient(FakeRelayClient):
            def get_exchange_rates(self, *, access_token, since=None):
                return {"rates": [], "access": "full", "entitled": True}

        result = sync_exchange_rates(client=TieredClient())
        self.assertTrue(result["entitled"])
