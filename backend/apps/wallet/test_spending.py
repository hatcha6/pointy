"""Spending the Daftar wallet: money into the SMS balance, and the plans paid
from the main wallet."""

from __future__ import annotations

from datetime import datetime, timezone as dt_timezone
from decimal import Decimal
from unittest import mock

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.core.cache import cache
from django.test import TestCase, override_settings
from rest_framework.test import APIClient

from apps.analytics.models import AnalyticsEvent
from apps.core.models import RelayInstallation
from apps.core.relay import relay_ai_available, relay_sms_available
from apps.core.roles import CASHIER_GROUP, MANAGER_GROUP, ensure_role_groups
from apps.expenses.models import Expense

from .tests import _CLIENT, _LOCMEM, link_relay, relay_refusal, wallet_payload


def sms_block(balance="15.000", price="0.150"):
    left = int(Decimal(balance) // Decimal(price))
    return {
        "balance": balance,
        "price": price,
        "messages_left": left,
        "configured": True,
        "available": left > 0,
    }


def relay_status(**overrides):
    """The installation as the relay's status read returns it."""
    status = {
        "id": "inst-1",
        "shop_name": "محل النور",
        "relay_enabled": False,
        "subscription_active": False,
        "ai_enabled": False,
        "sms_enabled": False,
        "subscription_ends_at": None,
        "remote_access_paid_until": None,
        "ai_paid_until": None,
        "integrations_disabled": [],
    }
    status.update(overrides)
    return status


@override_settings(CACHES=_LOCMEM)
class WalletSpendingTests(TestCase):
    def setUp(self):
        cache.clear()
        ensure_role_groups()
        User = get_user_model()
        self.manager = User.objects.create_user(username="owner", password="x")
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.cashier = User.objects.create_user(username="csh", password="x")
        self.cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.api = APIClient()
        self.api.force_authenticate(self.manager)
        self.relay = mock.Mock()
        # The entitlement re-read after a purchase copies the relay's addresses
        # from the client's config when set; these leave the row's own.
        self.relay.config = mock.Mock(public_api_url="", connector_address="")
        patcher = mock.patch(_CLIENT, return_value=self.relay)
        patcher.start()
        self.addCleanup(patcher.stop)
        link_relay()

    def installation(self):
        return RelayInstallation.objects.get()

    # --- reading ---------------------------------------------------------------

    def test_the_overview_carries_the_sms_balance_and_the_plans(self):
        plans = [
            {"key": "remote_access", "available": True, "price": "50.000", "period_days": 30,
             "max_periods": 12, "active": False, "until": None, "included": False},
        ]
        self.relay.get_wallet.return_value = wallet_payload(sms=sms_block("4.500"), plans=plans)
        resp = self.api.get("/api/wallet/")
        self.assertEqual(resp.status_code, 200, resp.content)
        self.assertEqual(resp.data["sms"]["balance"], "4.500")
        self.assertEqual(resp.data["sms"]["messages_left"], 30)
        self.assertEqual(resp.data["plans"], plans)
        # Reading the wallet also keeps the shop's copy of the SMS balance.
        installation = self.installation()
        self.assertEqual(installation.sms_balance, Decimal("4.500"))
        self.assertEqual(installation.sms_price, Decimal("0.150"))
        self.assertTrue(relay_sms_available(installation))

    def test_a_relay_from_before_the_sms_balance_sends_neither(self):
        self.relay.get_wallet.return_value = wallet_payload()
        resp = self.api.get("/api/wallet/")
        self.assertIsNone(resp.data["sms"])
        self.assertEqual(resp.data["plans"], [])
        self.assertEqual(self.installation().sms_price, Decimal("0"))

    def test_the_sms_statement_is_its_own_account(self):
        self.relay.list_wallet_entries.return_value = {"entries": [], "has_more": False}
        resp = self.api.get("/api/wallet/entries/?account=sms&limit=20")
        self.assertEqual(resp.status_code, 200, resp.content)
        self.relay.list_wallet_entries.assert_called_once_with(
            access_token="access-token", limit=20, before="", kind="", account="sms"
        )

    # --- money into the SMS balance ------------------------------------------------

    def test_moving_money_into_the_sms_balance(self):
        self.relay.allocate_wallet_sms.return_value = {
            "balance": "85.000",
            "sms": sms_block("15.000"),
            "transfer": {"out": {"amount": "-15.000"}, "in": {"amount": "15.000"}},
            "replayed": False,
        }
        with self.captureOnCommitCallbacks(execute=True):
            resp = self.api.post(
                "/api/wallet/sms/allocations/", {"amount": "15", "idempotency_key": "alloc-1"}, format="json"
            )
        self.assertEqual(resp.status_code, 201, resp.content)
        self.assertEqual(resp.data["balance"], "85.000")
        self.assertEqual(resp.data["sms"]["messages_left"], 100)
        self.relay.allocate_wallet_sms.assert_called_once_with(
            access_token="access-token",
            amount=Decimal("15.000"),
            idempotency_key="alloc-1",
            requested_by="owner",
            timeout=mock.ANY,
        )
        self.assertTrue(relay_sms_available(self.installation()))
        self.assertTrue(AnalyticsEvent.objects.filter(name="wallet.sms.allocated").exists())
        # Nothing is booked: the money left the shop when it was paid in.
        self.assertFalse(Expense.objects.exists())

    def test_a_replayed_allocation_answers_ok_and_is_not_counted_again(self):
        self.relay.allocate_wallet_sms.return_value = {
            "balance": "85.000", "sms": sms_block(), "transfer": {}, "replayed": True,
        }
        with self.captureOnCommitCallbacks(execute=True):
            resp = self.api.post("/api/wallet/sms/allocations/", {"amount": "15"}, format="json")
        self.assertEqual(resp.status_code, 200, resp.content)
        self.assertFalse(AnalyticsEvent.objects.filter(name="wallet.sms.allocated").exists())

    def test_an_allocation_the_wallet_cannot_cover_says_what_it_holds(self):
        self.relay.allocate_wallet_sms.side_effect = relay_refusal(
            409, "insufficient_balance", balance="5.000", amount="15.000"
        )
        resp = self.api.post("/api/wallet/sms/allocations/", {"amount": "15"}, format="json")
        self.assertEqual(resp.status_code, 409, resp.content)
        self.assertEqual(resp.data["code"], "insufficient_balance")
        self.assertEqual(resp.data["balance"], "5.000")
        self.assertEqual(resp.data["amount"], "15.000")
        self.assertIn("رصيد المحفظة لا يكفي", resp.data["detail"])

    def test_less_than_one_message_is_the_relays_refusal(self):
        self.relay.allocate_wallet_sms.side_effect = relay_refusal(
            422, "invalid_amount", min_amount="0.150", max_decimals=3
        )
        resp = self.api.post("/api/wallet/sms/allocations/", {"amount": "0.1"}, format="json")
        self.assertEqual(resp.status_code, 422, resp.content)
        self.assertEqual(resp.data["min_amount"], "0.150")

    def test_amounts_are_checked_before_the_relay(self):
        for amount in ("0", "-5", "1.2345", "abc"):
            with self.subTest(amount=amount):
                resp = self.api.post("/api/wallet/sms/allocations/", {"amount": amount}, format="json")
                self.assertEqual(resp.status_code, 400, resp.content)
        self.relay.allocate_wallet_sms.assert_not_called()

    def test_cashiers_cannot_spend_the_wallet(self):
        self.api.force_authenticate(self.cashier)
        self.assertEqual(
            self.api.post("/api/wallet/sms/allocations/", {"amount": "15"}, format="json").status_code, 403
        )
        self.assertEqual(
            self.api.post("/api/wallet/subscriptions/", {"plan": "ai"}, format="json").status_code, 403
        )
        self.relay.allocate_wallet_sms.assert_not_called()
        self.relay.purchase_wallet_plan.assert_not_called()

    # --- plans -----------------------------------------------------------------

    def test_paying_for_the_assistant_turns_it_on_here_at_once(self):
        until = datetime(2026, 11, 1, 9, 0, tzinfo=dt_timezone.utc)
        self.relay.purchase_wallet_plan.return_value = {
            "plan": {"key": "ai", "active": True, "until": until.isoformat(), "included": False},
            "balance": "70.000",
            "entry": {"amount": "-30.000", "service": "ai"},
            "replayed": False,
        }
        self.relay.get_installation.return_value = relay_status(ai_paid_until=until.isoformat())
        self.assertFalse(relay_ai_available(self.installation()))
        with mock.patch("apps.core.caching.bump_perm_version") as bump, self.captureOnCommitCallbacks(execute=True):
            resp = self.api.post(
                "/api/wallet/subscriptions/", {"plan": "ai", "periods": 1, "idempotency_key": "buy-1"},
                format="json",
            )
        self.assertEqual(resp.status_code, 201, resp.content)
        self.assertEqual(resp.data["balance"], "70.000")
        self.assertTrue(resp.data["plan"]["active"])
        self.relay.purchase_wallet_plan.assert_called_once_with(
            access_token="access-token", plan="ai", periods=1, idempotency_key="buy-1",
            requested_by="owner", timeout=mock.ANY,
        )
        installation = self.installation()
        self.assertEqual(installation.ai_paid_until, until)
        self.assertTrue(relay_ai_available(installation))
        bump.assert_called()  # every device re-reads ai_available now
        event = AnalyticsEvent.objects.get(name="wallet.plan.purchased")
        self.assertEqual(event.attributes["plan"], "ai")

    def test_a_purchase_whose_reread_fails_is_still_paid(self):
        self.relay.purchase_wallet_plan.return_value = {
            "plan": {"key": "remote_access", "active": True}, "balance": "0.000", "entry": {}, "replayed": False,
        }
        self.relay.get_installation.side_effect = relay_refusal(503)
        resp = self.api.post("/api/wallet/subscriptions/", {"plan": "remote_access"}, format="json")
        self.assertEqual(resp.status_code, 201, resp.content)

    def test_plan_refusals_reach_the_app_as_codes(self):
        cases = [
            (relay_refusal(409, "plan_included"), 409, "plan_included"),
            (relay_refusal(422, "plan_unavailable"), 422, "plan_unavailable"),
            (relay_refusal(409, "insufficient_balance", balance="10.000", amount="50.000"), 409, "insufficient_balance"),
        ]
        for refusal, status, code in cases:
            with self.subTest(code=code):
                self.relay.purchase_wallet_plan.side_effect = refusal
                resp = self.api.post("/api/wallet/subscriptions/", {"plan": "remote_access"}, format="json")
                self.assertEqual(resp.status_code, status, resp.content)
                self.assertEqual(resp.data["code"], code)
                self.assertTrue(resp.data["detail"])

    def test_a_plan_or_period_count_the_app_cannot_buy_is_refused_here(self):
        for body in ({"plan": "gold"}, {"plan": "ai", "periods": 0}, {"plan": "ai", "periods": 13}, {}):
            with self.subTest(body=body):
                self.assertEqual(self.api.post("/api/wallet/subscriptions/", body, format="json").status_code, 400)
        self.relay.purchase_wallet_plan.assert_not_called()
