"""The plans a shop pays for from its Daftar wallet, and the SMS balance, as
the shop's backend mirrors them from the relay."""

from __future__ import annotations

from datetime import timedelta
from decimal import Decimal
from unittest import mock

from django.core.cache import cache
from django.test import TestCase, override_settings
from django.utils import timezone

from apps.core.models import RelayInstallation
from apps.core.relay import (
    mirror_sms_wallet,
    plan_coverage,
    relay_ai_available,
    relay_sms_available,
    relay_status_payload,
    sync_relay_installation,
)

_LOCMEM = {"default": {"BACKEND": "django.core.cache.backends.locmem.LocMemCache"}}


def installation(**fields):
    return RelayInstallation(
        installation_id="inst-1",
        relay_public_api_url="https://relay.example",
        connector_token="c",
        access_token="a",
        **fields,
    )


class PlanCoverageTests(TestCase):
    """The same rule as the relay's Installation.PlanCoverage."""

    def test_the_subscription_or_the_wallet_whichever_runs_longer(self):
        now = timezone.now()
        past, soon, later = now - timedelta(hours=1), now + timedelta(days=1), now + timedelta(days=30)
        cases = [
            ("nothing", {}, False, None, False),
            ("operator, no end", {"relay_enabled": True, "subscription_active": True}, True, None, True),
            ("operator until soon", {"relay_enabled": True, "subscription_active": True, "subscription_ends_at": soon}, True, soon, False),
            ("operator lapsed", {"relay_enabled": True, "subscription_active": True, "subscription_ends_at": past}, False, None, False),
            ("subscription without the flag", {"subscription_active": True}, False, None, False),
            ("paid", {"remote_access_paid_until": later}, True, later, False),
            ("paid, expired", {"remote_access_paid_until": past}, False, None, False),
            ("paid beyond the operator's end",
             {"relay_enabled": True, "subscription_active": True, "subscription_ends_at": soon, "remote_access_paid_until": later},
             True, later, False),
            ("operator beyond what was paid",
             {"relay_enabled": True, "subscription_active": True, "subscription_ends_at": later, "remote_access_paid_until": soon},
             True, later, False),
            ("another plan paid", {"ai_paid_until": later}, False, None, False),
        ]
        for name, fields, active, until, indefinite in cases:
            with self.subTest(name):
                row = installation(**fields)
                coverage = plan_coverage(row, "remote_access", now=now)
                self.assertEqual((coverage.active, coverage.until, coverage.indefinite), (active, until, indefinite))
                self.assertEqual(row.remote_access_supported, active)

    def test_the_assistant_runs_on_its_own_clock(self):
        paid = installation(ai_paid_until=timezone.now() + timedelta(days=3))
        self.assertTrue(relay_ai_available(paid))
        self.assertFalse(paid.remote_access_supported)
        self.assertFalse(relay_ai_available(installation(ai_paid_until=timezone.now() - timedelta(seconds=1))))
        self.assertTrue(relay_ai_available(installation(ai_enabled=True, subscription_active=True)))

    def test_the_status_says_when_each_plan_stops(self):
        until = timezone.now() + timedelta(days=30)
        payload = relay_status_payload(installation(ai_paid_until=until, sms_balance=Decimal("0.3"), sms_price=Decimal("0.15")))
        self.assertTrue(payload["ai_available"])
        self.assertEqual(payload["ai_until"], until)
        self.assertEqual(payload["ai_paid_until"], until)
        self.assertFalse(payload["remote_access_supported"])
        self.assertIsNone(payload["remote_access_until"])
        self.assertTrue(payload["sms_available"])
        self.assertEqual((payload["sms_balance"], payload["sms_price"]), ("0.300", "0.150"))


class SmsBalanceGateTests(TestCase):
    def test_a_prepaid_shop_sends_while_its_balance_pays_for_a_message(self):
        self.assertTrue(relay_sms_available(installation(sms_balance=Decimal("0.150"), sms_price=Decimal("0.150"))))
        self.assertFalse(relay_sms_available(installation(sms_balance=Decimal("0.149"), sms_price=Decimal("0.150"))))
        # The subscription has nothing to do with it.
        self.assertFalse(relay_sms_available(installation(
            subscription_active=True, sms_balance=Decimal("0"), sms_price=Decimal("0.150"),
        )))

    def test_nothing_is_sent_until_the_relay_reports_a_price(self):
        self.assertFalse(relay_sms_available(installation(subscription_active=True, sms_balance=Decimal("5"))))
        self.assertFalse(relay_sms_available(None))


@override_settings(CACHES=_LOCMEM)
class WalletMirrorTests(TestCase):
    def setUp(self):
        cache.clear()
        self.row = installation()
        self.row.save()
        self.relay = mock.Mock()
        self.relay.config = mock.Mock(public_api_url="", connector_address="")

    def status(self, **overrides):
        status = {"shop_name": "", "relay_enabled": False, "subscription_active": False,
                  "ai_enabled": False}
        status.update(overrides)
        return status

    def test_the_sync_mirrors_the_paid_dates_and_the_sms_balance(self):
        until = (timezone.now() + timedelta(days=30)).replace(microsecond=0)
        self.relay.get_installation.return_value = self.status(
            remote_access_paid_until=until.isoformat(),
            sms={"balance": "4.500", "price": "0.150", "messages_left": 30, "available": True},
        )
        with mock.patch("apps.core.caching.bump_perm_version") as bump:
            sync_relay_installation(self.row, client=self.relay, push_shop_name=False)
        self.row.refresh_from_db()
        self.assertEqual(self.row.remote_access_paid_until, until)
        self.assertTrue(self.row.remote_access_supported)
        self.assertEqual(self.row.sms_balance, Decimal("4.500"))
        self.assertEqual(self.row.sms_price, Decimal("0.150"))
        bump.assert_called_once()

    def test_a_balance_that_moves_without_flipping_sms_bumps_nothing(self):
        self.relay.get_installation.return_value = self.status(sms={"balance": "4.500", "price": "0.150"})
        sync_relay_installation(self.row, client=self.relay, push_shop_name=False)
        self.relay.get_installation.return_value = self.status(sms={"balance": "4.350", "price": "0.150"})
        with mock.patch("apps.core.caching.bump_perm_version") as bump:
            sync_relay_installation(self.row, client=self.relay, push_shop_name=False)
        bump.assert_not_called()
        self.row.refresh_from_db()
        self.assertEqual(self.row.sms_balance, Decimal("4.350"))

    def test_a_relay_without_an_sms_block_leaves_the_balance_alone(self):
        RelayInstallation.objects.filter(pk=self.row.pk).update(sms_balance=Decimal("3"), sms_price=Decimal("0.15"))
        self.row.refresh_from_db()
        self.relay.get_installation.return_value = self.status()
        sync_relay_installation(self.row, client=self.relay, push_shop_name=False)
        self.row.refresh_from_db()
        self.assertEqual(self.row.sms_balance, Decimal("3.000"))

    def test_mirroring_a_balance_bumps_only_when_sms_flips(self):
        with mock.patch("apps.core.caching.bump_perm_version") as bump:
            mirror_sms_wallet({"balance": "0.300", "price": "0.150"}, installation=self.row)
            bump.assert_called_once()
            bump.reset_mock()
            mirror_sms_wallet({"balance": "0.150", "price": "0.150"}, installation=self.row)
            bump.assert_not_called()
            mirror_sms_wallet({"balance": "0.000"}, installation=self.row)
            bump.assert_called_once()
            mirror_sms_wallet({"balance": "not a number"}, installation=self.row)
        self.row.refresh_from_db()
        self.assertEqual(self.row.sms_balance, Decimal("0"))
        self.assertFalse(relay_sms_available(self.row))
