"""The Daftar wallet's shop side: the relay proxy, top-ups, and the books.

A paid top-up is booked as money moved from the bank into «محفظة دفتر» (the
wallet is an asset — see ``apps.wallet.books``), never as an expense.
"""

from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone as dt_timezone
from decimal import Decimal
from unittest import mock

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.core.cache import cache
from django.test import TestCase, override_settings
from django.utils import timezone
from rest_framework.test import APIClient

from apps.core.models import RelayInstallation, ShopSettings
from apps.core.relay import RelayControlError
from apps.core.roles import CASHIER_GROUP, MANAGER_GROUP, ensure_role_groups
from apps.expenses.models import Expense, ExpenseCategory
from apps.treasury.models import MoneyAccount, MoneyTransfer

from .books import WALLET_ACCOUNT_NAME, book_topup
from .models import WalletSettings, WalletTopUp
from .services import sync_topups

_LOCMEM = {"default": {"BACKEND": "django.core.cache.backends.locmem.LocMemCache"}}
_CLIENT = "apps.wallet.services.scoped_relay_client"


def link_relay():
    return RelayInstallation.objects.create(
        installation_id="inst-1",
        relay_public_api_url="https://relay.example",
        connector_token="c",
        access_token="access-token",
    )


def remote_topup(**overrides):
    topup = {
        "id": "topup-1",
        "invoice_no": "DFW-ABCDEFGH23",
        "method": "dafa_moamalat",
        "kind": "hosted_page",
        "payer_hint": "",
        "amount": "100.000",
        "status": "pending",
        "test_mode": False,
        "requested_by": "owner",
        "provider_transaction_id": "pay-1",
        "error_code": "",
        "confirmed_by": "",
        "created_at": "2026-09-30T08:00:00Z",
        "paid_at": None,
        "checkout_url": "https://pay.dafa.test/pay-1",
    }
    topup.update(overrides)
    return topup


def sadad_topup(**overrides):
    values = {
        "method": "dafa_sadad",
        "kind": "otp",
        "payer_hint": "091•••678",
        "otp_attempts_left": 5,
    }
    values.update(overrides)
    topup = remote_topup(**values)
    topup.pop("checkout_url", None)
    return topup


def paid(**overrides):
    values = {
        "status": "paid",
        "confirmed_by": "dafa",
        "paid_at": "2026-09-30T08:03:00Z",
    }
    values.update(overrides)
    topup = remote_topup(**values)
    topup.pop("checkout_url", None)
    return topup


def bank():
    """The shop's routed bank account, which a card or transfer payment leaves."""
    return MoneyAccount.objects.get(kind=MoneyAccount.Kind.BANK, is_default=True)


def wallet_account():
    return WalletSettings.load().money_account


def relay_refusal(status, code="", **extra):
    body = json.dumps({"error": code or "refused", "code": code, **extra}) if code else "<html>"
    return RelayControlError(f"relay {status}", status_code=status, body=body)


def wallet_payload(**overrides):
    payload = {
        "balance": "100.000",
        "currency": "LYD",
        "updated_at": "2026-09-30T08:03:00Z",
        "test_mode": False,
        "topups": {
            "available": True,
            "methods": [
                {"key": "dafa_moamalat", "gateway": "dafa", "provider": "moamalat", "kind": "hosted_page",
                 "payer": "", "birth_year": False},
                {"key": "dafa_sadad", "gateway": "dafa", "provider": "sadad", "kind": "otp",
                 "payer": "phone", "birth_year": True},
            ],
            "min_amount": "10.00",
            "max_amount": "5000.00",
            "max_decimals": 2,
            "quick_amounts": ["50", "100", "200", "500"],
            "pending_ttl": 1800,
            "max_otp_attempts": 5,
        },
        "recent_topups": [paid()],
        "recent_entries": [
            {"id": "e1", "kind": "topup", "amount": "100.000", "balance_after": "100.000",
             "created_at": "2026-09-30T08:03:00Z"},
        ],
    }
    payload.update(overrides)
    return payload


@override_settings(CACHES=_LOCMEM)
class WalletApiTests(TestCase):
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
        patcher = mock.patch(_CLIENT, return_value=self.relay)
        patcher.start()
        self.addCleanup(patcher.stop)
        link_relay()

    def start(self, **overrides):
        """Start a top-up the way the app does, so the shop knows it is its own."""
        self.relay.create_wallet_topup.return_value = {
            "top_up": remote_topup(**overrides),
            "next_action": "hosted_page",
            "checkout_url": "https://pay.dafa.test/pay-1",
        }
        resp = self.api.post("/api/wallet/topups/", {"amount": "100"}, format="json")
        self.assertEqual(resp.status_code, 201, resp.content)
        return resp

    def start_sadad(self):
        self.relay.create_wallet_topup.return_value = {
            "top_up": sadad_topup(),
            "next_action": "otp",
            "replayed": False,
        }
        resp = self.api.post(
            "/api/wallet/topups/",
            {"amount": "100", "method": "dafa_sadad", "user_identifier": "0912345678", "birth_year": "1995"},
            format="json",
        )
        self.assertEqual(resp.status_code, 201, resp.content)
        return resp

    # --- reading ---------------------------------------------------------------

    def test_overview_books_a_paid_topup_once(self):
        self.start()
        self.relay.get_wallet.return_value = wallet_payload()
        for _ in range(3):
            resp = self.api.get("/api/wallet/")
            self.assertEqual(resp.status_code, 200, resp.content)
        self.assertTrue(resp.data["available"])
        self.assertEqual(resp.data["balance"], "100.000")
        self.assertEqual(resp.data["topups"]["min_amount"], "10.00")
        topup = resp.data["recent_topups"][0]
        self.assertEqual(MoneyTransfer.objects.count(), 1, "three reads, one booking")
        self.assertFalse(Expense.objects.exists(), "money moved, nothing spent")
        transfer = MoneyTransfer.objects.select_related("to_account").get()
        self.assertEqual(topup["transfer_id"], transfer.pk)
        self.assertIsNone(topup["expense_id"])
        self.assertEqual(transfer.amount, Decimal("100.00"))
        self.assertEqual(transfer.from_account, bank())
        self.assertEqual(transfer.to_account.name, WALLET_ACCOUNT_NAME)
        self.assertEqual(transfer.to_account.kind, MoneyAccount.Kind.PROVIDER)
        self.assertFalse(transfer.to_account.is_default)
        self.assertEqual(transfer.reason, "شحن محفظة دفتر — بطاقة مصرفية محلية")
        self.assertEqual(transfer.reference, "DFW-ABCDEFGH23")
        self.assertEqual(
            transfer.moved_at,
            timezone.localdate(datetime(2026, 9, 30, 8, 3, tzinfo=dt_timezone.utc)),
        )
        self.assertEqual(wallet_account(), transfer.to_account)
        self.assertEqual(resp.data["settings"]["money_account"]["name"], WALLET_ACCOUNT_NAME)

    def test_a_topup_first_seen_already_paid_is_not_back_dated_into_the_books(self):
        # After a factory reset (or an old backup restored) the shop's copy is
        # gone while the relay still lists the payments made before it. They
        # were paid before these books existed; booking them now would put old
        # expenses into books the owner just emptied.
        self.relay.get_wallet.return_value = wallet_payload()
        resp = self.api.get("/api/wallet/")
        self.assertEqual(resp.status_code, 200, resp.content)
        topup = resp.data["recent_topups"][0]
        self.assertEqual(topup["status"], "paid")
        self.assertIsNone(topup["transfer_id"])
        self.assertFalse(topup["record_as_expense"])
        self.assertFalse(MoneyTransfer.objects.exists())

    def test_a_topup_first_seen_while_open_follows_the_setting(self):
        # Pending when first seen: the payment, if it comes, is new money
        # leaving the shop, so the books follow the switch.
        self.relay.get_wallet.return_value = wallet_payload(recent_topups=[remote_topup()])
        self.api.get("/api/wallet/")
        self.assertTrue(WalletTopUp.objects.get(relay_id="topup-1").record_as_expense)
        self.relay.get_wallet_topup.return_value = {"top_up": paid()}
        resp = self.api.get("/api/wallet/topups/topup-1/")
        self.assertIsNotNone(resp.data["top_up"]["transfer_id"])

    def test_an_unreachable_relay_still_shows_the_shops_own_history(self):
        WalletTopUp.objects.create(
            relay_id="topup-9",
            invoice_no="DFW-LOCALCOPY9",
            method="dafa_moamalat",
            amount=Decimal("50"),
            status="paid",
            relay_created_at=timezone.now(),
        )
        self.relay.get_wallet.side_effect = RelayControlError("down")
        resp = self.api.get("/api/wallet/")
        self.assertEqual(resp.status_code, 200)
        self.assertFalse(resp.data["available"])
        self.assertEqual(resp.data["error"]["code"], "relay_unreachable")
        self.assertIsNone(resp.data["balance"])
        self.assertEqual(resp.data["recent_topups"][0]["invoice_no"], "DFW-LOCALCOPY9")

    def test_a_shop_not_linked_to_the_relay_is_told_so(self):
        RelayInstallation.objects.all().delete()
        cache.clear()
        resp = self.api.get("/api/wallet/")
        self.assertEqual(resp.status_code, 200)
        self.assertFalse(resp.data["available"])
        self.assertEqual(resp.data["error"]["code"], "not_configured")
        self.relay.get_wallet.assert_not_called()

    def test_cashiers_cannot_see_or_spend_the_wallet(self):
        self.api.force_authenticate(self.cashier)
        self.assertEqual(self.api.get("/api/wallet/").status_code, 403)
        self.assertEqual(self.api.post("/api/wallet/topups/", {"amount": "50"}, format="json").status_code, 403)
        self.relay.create_wallet_topup.assert_not_called()

    def test_statement_pages_come_from_the_relay(self):
        self.relay.list_wallet_entries.return_value = {"entries": [{"id": "e2"}], "has_more": True}
        resp = self.api.get("/api/wallet/entries/?limit=1&before=e1&kind=charge")
        self.assertEqual(resp.status_code, 200)
        self.assertTrue(resp.data["has_more"])
        self.relay.list_wallet_entries.assert_called_once_with(
            access_token="access-token", limit=1, before="e1", kind="charge", account=""
        )

    # --- starting a top-up ------------------------------------------------------

    def test_starting_a_topup_returns_the_checkout_and_remembers_who(self):
        self.relay.create_wallet_topup.return_value = {
            "top_up": remote_topup(),
            "next_action": "hosted_page",
            "checkout_url": "https://pay.dafa.test/pay-1",
            "replayed": False,
        }
        resp = self.api.post(
            "/api/wallet/topups/",
            {"amount": "100.00", "idempotency_key": "app-key-1"},
            format="json",
        )
        self.assertEqual(resp.status_code, 201, resp.content)
        self.assertEqual(resp.data["checkout_url"], "https://pay.dafa.test/pay-1")
        self.assertEqual(resp.data["next_action"], "hosted_page")
        self.assertEqual(resp.data["top_up"]["status"], "pending")
        self.assertTrue(resp.data["top_up"]["record_as_expense"])
        call = self.relay.create_wallet_topup.call_args.kwargs
        self.assertEqual(call["amount"], Decimal("100.00"))
        self.assertEqual(call["idempotency_key"], "app-key-1")
        self.assertEqual(call["method"], "dafa_moamalat", "no method means bank cards")
        self.assertEqual(call["requested_by"], "owner")
        self.assertGreater(call["timeout"], 20, "starting a payment outlasts the relay's gateway call")
        mirrored = WalletTopUp.objects.get(relay_id="topup-1")
        self.assertEqual(mirrored.requested_by, self.manager)
        self.assertEqual(mirrored.status, "pending")
        self.assertFalse(MoneyTransfer.objects.exists(), "nothing is booked before it is paid")

    def test_an_app_from_before_dafa_still_tops_up_with_a_card(self):
        # It sends Plutu's method name; the relay serves it as Dafa's bank cards.
        self.relay.create_wallet_topup.return_value = {
            "top_up": remote_topup(),
            "next_action": "hosted_page",
            "checkout_url": "https://pay.dafa.test/pay-1",
        }
        resp = self.api.post(
            "/api/wallet/topups/",
            {"amount": "100.00", "method": "plutu_localbankcards", "idempotency_key": "old-app"},
            format="json",
        )
        self.assertEqual(resp.status_code, 201, resp.content)
        self.assertEqual(resp.data["checkout_url"], "https://pay.dafa.test/pay-1")
        self.assertEqual(self.relay.create_wallet_topup.call_args.kwargs["method"], "plutu_localbankcards")

    # --- a code-confirmed method --------------------------------------------------

    def test_an_otp_topup_passes_the_payer_on_and_keeps_only_the_hint(self):
        resp = self.start_sadad()
        self.assertEqual(resp.data["next_action"], "otp")
        self.assertNotIn("checkout_url", resp.data["top_up"])
        self.assertEqual(resp.data["top_up"]["payer_hint"], "091•••678")
        self.assertEqual(resp.data["top_up"]["otp_attempts_left"], 5)
        call = self.relay.create_wallet_topup.call_args.kwargs
        self.assertEqual(call["method"], "dafa_sadad")
        self.assertEqual(call["user_identifier"], "0912345678")
        self.assertEqual(call["birth_year"], "1995")
        mirrored = WalletTopUp.objects.get(relay_id="topup-1")
        self.assertEqual(mirrored.payer_hint, "091•••678")
        stored = " ".join(str(value) for value in WalletTopUp.objects.values().get().values())
        self.assertNotIn("0912345678", stored, "the full number is never stored here")
        self.assertNotIn("1995", stored)

    def test_the_right_code_pays_and_books_a_transfer_at_once(self):
        self.start_sadad()
        self.relay.confirm_wallet_topup.return_value = {"top_up": paid(**sadad_topup())}
        self.relay.confirm_wallet_topup.return_value["top_up"].update(status="paid", confirmed_by="dafa")
        resp = self.api.post("/api/wallet/topups/topup-1/confirm/", {"otp": "111111"}, format="json")
        self.assertEqual(resp.status_code, 200, resp.content)
        self.assertEqual(resp.data["top_up"]["status"], "paid")
        call = self.relay.confirm_wallet_topup.call_args.kwargs
        self.assertEqual((call["topup_id"], call["otp"]), ("topup-1", "111111"))
        self.assertGreater(call["timeout"], 40, "a confirm may be followed by reading the payment back")
        transfer = MoneyTransfer.objects.get()
        self.assertEqual(resp.data["top_up"]["transfer_id"], transfer.pk)
        self.assertEqual(transfer.reason, "شحن محفظة دفتر — سداد")
        self.assertFalse(Expense.objects.exists())

    def test_a_wrong_code_reaches_the_app_with_what_is_left(self):
        self.start_sadad()
        self.relay.confirm_wallet_topup.side_effect = relay_refusal(
            422,
            "otp_rejected",
            attempts_left=4,
            gateway_code="PAYER_OTP_WRONG",
            gateway_message="رمز التحقق غير صحيح، يرجى إعادة إدخاله.",
            detail="400 PAYER_OTP_WRONG simulated: wrong otp",
            top_up=sadad_topup(otp_attempts_left=4),
        )
        resp = self.api.post("/api/wallet/topups/topup-1/confirm/", {"otp": "123456"}, format="json")
        self.assertEqual(resp.status_code, 422)
        self.assertEqual(resp.data["code"], "otp_rejected")
        self.assertEqual(resp.data["attempts_left"], 4)
        self.assertEqual(resp.data["gateway_message"], "رمز التحقق غير صحيح، يرجى إعادة إدخاله.")
        self.assertEqual(resp.data["detail"], "رمز التحقق غير صحيح. أعد إدخاله.", "the relay's English detail stays out")
        self.assertEqual(resp.data["top_up"]["status"], "pending")
        self.assertFalse(Expense.objects.exists())

    def test_a_declined_payment_is_mirrored_as_failed(self):
        self.start_sadad()
        self.relay.confirm_wallet_topup.side_effect = relay_refusal(
            422,
            "declined",
            gateway_code="PAYER_INSUFFICIENT_FUNDS",
            gateway_message="تعذّر إتمام العملية، يرجى مراجعة المصرف.",
            top_up=sadad_topup(status="failed", error_code="declined"),
        )
        resp = self.api.post("/api/wallet/topups/topup-1/confirm/", {"otp": "222222"}, format="json")
        self.assertEqual(resp.status_code, 422)
        self.assertEqual(resp.data["code"], "declined")
        self.assertEqual(resp.data["gateway_code"], "PAYER_INSUFFICIENT_FUNDS")
        topup = WalletTopUp.objects.get(relay_id="topup-1")
        self.assertEqual((topup.status, topup.error_code), ("failed", "declined"))

    def test_a_code_taken_without_a_verdict_is_accepted_and_polled(self):
        self.start_sadad()
        self.relay.confirm_wallet_topup.return_value = {"top_up": sadad_topup(), "code": "awaiting_gateway"}
        resp = self.api.post("/api/wallet/topups/topup-1/confirm/", {"otp": "111111"}, format="json")
        self.assertEqual(resp.status_code, 202, resp.content)
        self.assertEqual(resp.data["code"], "awaiting_gateway")

    def test_a_confirm_needs_a_code_and_the_owners_permission(self):
        self.start_sadad()
        self.assertEqual(self.api.post("/api/wallet/topups/topup-1/confirm/", {}, format="json").status_code, 400)
        self.api.force_authenticate(self.cashier)
        resp = self.api.post("/api/wallet/topups/topup-1/confirm/", {"otp": "111111"}, format="json")
        self.assertEqual(resp.status_code, 403)
        self.relay.confirm_wallet_topup.assert_not_called()

    def test_backing_out_before_the_code_cancels_it(self):
        self.start_sadad()
        self.relay.cancel_wallet_topup.return_value = {
            "top_up": sadad_topup(status="canceled", error_code="canceled"),
            "applied": True,
        }
        resp = self.api.post("/api/wallet/topups/topup-1/cancel/", format="json")
        self.assertEqual(resp.status_code, 200, resp.content)
        self.assertEqual(resp.data["top_up"]["status"], "canceled")
        self.assertEqual(WalletTopUp.objects.get(relay_id="topup-1").status, "canceled")
        self.relay.cancel_wallet_topup.side_effect = relay_refusal(409, "not_otp_method")
        resp = self.api.post("/api/wallet/topups/topup-1/cancel/", format="json")
        self.assertEqual((resp.status_code, resp.data["code"]), (409, "not_otp_method"))

    def test_the_sheet_switch_decides_this_topup_and_becomes_the_default(self):
        self.relay.create_wallet_topup.return_value = {"top_up": remote_topup(), "checkout_url": "x"}
        resp = self.api.post(
            "/api/wallet/topups/",
            {"amount": "100", "record_as_expense": False},
            format="json",
        )
        self.assertEqual(resp.status_code, 201, resp.content)
        self.assertFalse(WalletSettings.load().record_topups_as_expenses)
        topup = WalletTopUp.objects.get(relay_id="topup-1")
        self.assertFalse(topup.record_as_expense)
        # Paid later: the owner said no, so nothing is booked anywhere.
        self.relay.get_wallet_topup.return_value = {"top_up": paid()}
        resp = self.api.get("/api/wallet/topups/topup-1/")
        self.assertEqual(resp.status_code, 200)
        self.assertIsNone(resp.data["top_up"]["transfer_id"])
        self.assertFalse(MoneyTransfer.objects.exists())
        self.assertFalse(Expense.objects.exists())

    def test_flipping_the_setting_later_does_not_change_a_topup_under_way(self):
        self.relay.create_wallet_topup.return_value = {"top_up": remote_topup(), "checkout_url": "x"}
        self.api.post("/api/wallet/topups/", {"amount": "100"}, format="json")
        self.api.patch("/api/wallet/settings/", {"record_topups_as_expenses": False}, format="json")
        self.relay.get_wallet_topup.return_value = {"top_up": paid()}
        resp = self.api.get("/api/wallet/topups/topup-1/")
        self.assertIsNotNone(resp.data["top_up"]["transfer_id"])
        self.assertEqual(MoneyTransfer.objects.count(), 1)

    def test_relay_refusals_reach_the_app_as_codes(self):
        self.relay.create_wallet_topup.side_effect = relay_refusal(
            422, "invalid_amount", min_amount="10.00", max_amount="5000.00"
        )
        resp = self.api.post("/api/wallet/topups/", {"amount": "5"}, format="json")
        self.assertEqual(resp.status_code, 422)
        self.assertEqual(resp.data["code"], "invalid_amount")
        self.assertEqual(resp.data["min_amount"], "10.00")
        self.assertTrue(resp.data["detail"])

        failed = remote_topup(status="failed", error_code="gateway_unauthorized")
        failed.pop("checkout_url")
        self.relay.create_wallet_topup.side_effect = relay_refusal(
            502, "gateway_unauthorized", top_up=failed
        )
        resp = self.api.post("/api/wallet/topups/", {"amount": "50"}, format="json")
        self.assertEqual(resp.status_code, 502)
        self.assertEqual(resp.data["code"], "gateway_unauthorized")
        self.assertEqual(resp.data["top_up"]["status"], "failed")
        self.assertEqual(WalletTopUp.objects.get(relay_id="topup-1").status, "failed")

        self.relay.create_wallet_topup.side_effect = RelayControlError("unreachable")
        resp = self.api.post("/api/wallet/topups/", {"amount": "50"}, format="json")
        self.assertEqual(resp.status_code, 503)
        self.assertEqual(resp.data["code"], "relay_unreachable")

    def test_amounts_the_gateway_cannot_take_are_refused_before_the_relay(self):
        # Two places, not the dirham's three: the expense keeps two.
        for amount in ("0", "-5", "12.345", "abc"):
            resp = self.api.post("/api/wallet/topups/", {"amount": amount}, format="json")
            self.assertEqual(resp.status_code, 400, amount)
        self.relay.create_wallet_topup.assert_not_called()

    # --- the books ----------------------------------------------------------------

    def test_polling_books_the_payment_once(self):
        self.start()
        self.relay.get_wallet_topup.return_value = {"top_up": paid()}
        first = self.api.get("/api/wallet/topups/topup-1/")
        second = self.api.get("/api/wallet/topups/topup-1/")
        self.assertEqual(first.status_code, 200, first.content)
        self.assertEqual(first.data["top_up"]["transfer_id"], second.data["top_up"]["transfer_id"])
        self.assertEqual(MoneyTransfer.objects.count(), 1)

    def test_a_deleted_booking_is_not_booked_again(self):
        self.start()
        self.relay.get_wallet_topup.return_value = {"top_up": paid()}
        self.api.get("/api/wallet/topups/topup-1/")
        MoneyTransfer.objects.all().delete()
        self.api.get("/api/wallet/topups/topup-1/")
        self.assertFalse(MoneyTransfer.objects.exists())

    def test_a_test_payment_says_so_in_the_books(self):
        self.start(test_mode=True)
        self.relay.get_wallet_topup.return_value = {"top_up": paid(test_mode=True)}
        self.api.get("/api/wallet/topups/topup-1/")
        self.assertIn("تجريبي", MoneyTransfer.objects.get().reason)

    def test_a_shop_without_a_bank_account_paid_from_outside(self):
        MoneyAccount.objects.filter(kind=MoneyAccount.Kind.BANK).update(is_active=False)
        self.start()
        self.relay.get_wallet_topup.return_value = {"top_up": paid()}
        self.api.get("/api/wallet/topups/topup-1/")
        self.assertIsNone(MoneyTransfer.objects.get().from_account)

    def test_the_owners_category_is_kept_for_the_wallets_spending(self):
        category = ExpenseCategory.objects.create(name="اشتراكات")
        resp = self.api.patch("/api/wallet/settings/", {"expense_category": category.pk}, format="json")
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.data["expense_category"]["name"], "اشتراكات")
        self.assertEqual(WalletSettings.load().expense_category, category)

    def test_a_topup_booked_as_an_expense_before_stays_as_it_was(self):
        legacy = WalletTopUp.objects.create(
            relay_id="topup-old", invoice_no="DFW-OLD", method="dafa_sadad",
            amount=Decimal("40"), status="paid", paid_at=timezone.now(),
            relay_created_at=timezone.now(), expense_booked_at=timezone.now(),
        )
        book_topup(legacy.pk)
        legacy.refresh_from_db()
        self.assertIsNone(legacy.transfer)
        self.assertFalse(MoneyTransfer.objects.exists())

    def test_a_payment_dated_in_a_closed_period_is_booked_today(self):
        paid_at = timezone.now() - timedelta(days=40)
        settings = ShopSettings.load()
        settings.books_locked_through = timezone.localdate(paid_at)
        settings.save()
        cache.clear()
        self.start()
        self.relay.get_wallet_topup.return_value = {"top_up": paid(paid_at=paid_at.isoformat())}
        self.api.get("/api/wallet/topups/topup-1/")
        transfer = MoneyTransfer.objects.get()
        self.assertEqual(transfer.moved_at, timezone.localdate())
        self.assertIn("فترة مغلقة", transfer.reason)

    def test_when_today_is_closed_too_nothing_is_booked_and_the_reason_is_kept(self):
        settings = ShopSettings.load()
        settings.books_locked_through = timezone.localdate() + timedelta(days=1)
        settings.save()
        cache.clear()
        self.start()
        self.relay.get_wallet_topup.return_value = {"top_up": paid()}
        resp = self.api.get("/api/wallet/topups/topup-1/")
        self.assertEqual(resp.data["top_up"]["expense_error"], "period_locked")
        self.assertFalse(MoneyTransfer.objects.exists())


@override_settings(CACHES=_LOCMEM)
class WalletSyncTests(TestCase):
    def setUp(self):
        cache.clear()
        link_relay()
        self.relay = mock.Mock()
        patcher = mock.patch(_CLIENT, return_value=self.relay)
        patcher.start()
        self.addCleanup(patcher.stop)

    def _mirror(self, **overrides):
        values = dict(
            relay_id="topup-1",
            invoice_no="DFW-ABCDEFGH23",
            method="dafa_moamalat",
            amount=Decimal("100"),
            status="pending",
            relay_created_at=timezone.now() - timedelta(minutes=5),
        )
        values.update(overrides)
        return WalletTopUp.objects.create(**values)

    def test_nothing_open_means_no_relay_call(self):
        self._mirror(status="canceled")
        result = sync_topups()
        self.assertFalse(result["asked_relay"])
        self.relay.list_wallet_topups.assert_not_called()

    def test_a_payment_nobody_was_watching_reaches_the_books(self):
        self._mirror(status="expired")
        self.relay.list_wallet_topups.return_value = {"topups": [paid()], "has_more": False}
        result = sync_topups()
        self.assertTrue(result["asked_relay"])
        topup = WalletTopUp.objects.get(relay_id="topup-1")
        self.assertEqual(topup.status, "paid")
        self.assertIsNotNone(topup.transfer)
        # The next sweep finds nothing open and asks nothing.
        self.relay.list_wallet_topups.reset_mock()
        self.assertFalse(sync_topups()["asked_relay"])

    def test_an_owed_booking_is_retried_without_the_relay(self):
        topup = self._mirror(
            status="paid", paid_at=timezone.now(), expense_error="booking_failed"
        )
        sync_topups()
        topup.refresh_from_db()
        self.assertIsNotNone(topup.transfer)
        self.assertEqual(topup.expense_error, "")

    def test_a_relay_outage_is_not_an_error(self):
        self._mirror()
        self.relay.list_wallet_topups.side_effect = RelayControlError("down")
        result = sync_topups()
        self.assertEqual(result["error"], "relay_unreachable")

    def test_a_paid_plutu_topup_from_before_dafa_is_still_named_a_card(self):
        topup = self._mirror(method="plutu_localbankcards", status="paid", paid_at=timezone.now())
        book_topup(topup.pk)
        self.assertEqual(MoneyTransfer.objects.get().reason, "شحن محفظة دفتر — بطاقة مصرفية محلية")

    def test_booking_is_idempotent_even_when_called_directly(self):
        topup = self._mirror(status="paid", paid_at=timezone.now())
        book_topup(topup.pk)
        book_topup(topup.pk)
        self.assertEqual(MoneyTransfer.objects.count(), 1)
