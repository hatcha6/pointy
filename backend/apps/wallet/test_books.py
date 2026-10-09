"""The Daftar wallet in the shop's own books (``apps.wallet.books``).

The wallet is an asset: a paid top-up moves money from the bank into «محفظة
دفتر»; spending it (SMS, plans) is an expense paid from it; money moved into
the voucher balance moves into the «كروت دفتر» float. And the switch-over from
the old rule — a top-up booked as an expense — books nothing twice.
"""

from __future__ import annotations

from datetime import timedelta
from decimal import Decimal
from unittest import mock

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.core.cache import cache
from django.test import TestCase, override_settings
from django.utils import timezone
from rest_framework.test import APIClient

from apps.core.relay import RelayControlError
from apps.core.roles import MANAGER_GROUP, ensure_role_groups
from apps.expenses.models import Expense
from apps.integrations.models import IntegrationAccount
from apps.treasury.models import MoneyAccount, MoneyTransfer
from apps.treasury.movements import account_movements
from apps.treasury.position import (
    COMPONENT_EXPENSES,
    COMPONENT_TRANSFER_IN,
    COMPONENT_TRANSFER_OUT,
    treasury_position,
    treasury_statement,
)

from . import books
from .models import WalletSettings, WalletSpend, WalletTopUp
from .services import sync_topups
from .tests import _CLIENT, _LOCMEM, link_relay


def paid_topup(amount, *, relay_id, expensed=False):
    """A paid top-up as the shop mirrors it; ``expensed`` = booked the old way."""
    now = timezone.now()
    return WalletTopUp.objects.create(
        relay_id=relay_id,
        invoice_no=f"DFW-{relay_id}",
        method="dafa_moamalat",
        amount=Decimal(amount),
        status=WalletTopUp.Status.PAID,
        paid_at=now,
        relay_created_at=now,
        expense_booked_at=now if expensed else None,
    )


def spend(kind, amount, reference, **kwargs):
    kwargs.setdefault("happened_on", timezone.localdate())
    return books.record_spend(
        kind=kind,
        relay_reference=reference,
        amount=Decimal(amount),
        description={"sms": "رصيد الرسائل", "plan": "اشتراك المساعد الذكي", "vouchers": "تحويل"}[
            kind
        ],
        **kwargs,
    )


@override_settings(CACHES=_LOCMEM)
class SwitchOverTests(TestCase):
    """Money already booked as an expense when it was paid in is never booked again."""

    def setUp(self):
        cache.clear()
        link_relay()
        self.relay = mock.Mock()
        patcher = mock.patch(_CLIENT, return_value=self.relay)
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_legacy_expensed_money_is_spent_first_and_not_booked_again(self):
        paid_topup("60", relay_id="old-1", expensed=True)
        paid_topup("40", relay_id="old-2", expensed=True)
        # 70 was in the wallet before this 30 went into the SMS balance.
        first = spend("sms", "30", "transfer:a", main_balance=Decimal("40"))
        settings = WalletSettings.load()
        self.assertIsNotNone(settings.books_switched_at)
        self.assertEqual(first.prebooked_amount, Decimal("30"))
        self.assertIsNone(first.expense, "all of it was booked when it was paid in")
        self.assertIsNotNone(first.booked_at)
        self.assertEqual(settings.prebooked_balance, Decimal("40"))
        # A plan of 50: the 40 left is consumed, only 10 is new spending.
        second = spend("plan", "50", "plan:b", main_balance=Decimal("0"))
        self.assertEqual(second.prebooked_amount, Decimal("40"))
        self.assertEqual(second.expense.amount, Decimal("10.00"))
        self.assertIn("سُجّل مصروفاً عند شحن المحفظة", second.expense.notes)
        self.assertEqual(WalletSettings.load().prebooked_balance, Decimal("0"))
        self.relay.get_wallet.assert_not_called()

    def test_the_prebooked_part_is_never_more_than_the_wallet_held(self):
        paid_topup("500", relay_id="old-1", expensed=True)
        spend("sms", "20", "transfer:a", main_balance=Decimal("80"))
        # Only 100 was there: 80 left + the 20 just moved.
        self.assertEqual(WalletSettings.load().prebooked_balance, Decimal("80"))

    def test_money_moved_into_the_voucher_balance_never_consumes_it(self):
        paid_topup("100", relay_id="old-1", expensed=True)
        moved = spend("vouchers", "25", "transfer:v", main_balance=Decimal("75"))
        self.assertEqual(moved.prebooked_amount, Decimal("0"))
        self.assertEqual(moved.transfer.amount, Decimal("25.00"))
        self.assertEqual(WalletSettings.load().prebooked_balance, Decimal("100"))

    def test_the_voucher_float_is_funded_even_with_the_wallet_out_of_the_books(self):
        # Every card sold books its cost against the float, so the money that
        # paid for it must arrive there too — from outside the books, here.
        settings = WalletSettings.load()
        settings.record_topups_as_expenses = False
        settings.save()
        skipped = spend("sms", "10", "transfer:s", main_balance=Decimal("90"))
        self.assertIsNone(skipped.booked_at)
        self.assertIsNone(skipped.expense)
        moved = spend("vouchers", "25", "transfer:v", main_balance=Decimal("65"))
        self.assertIsNotNone(moved.booked_at)
        self.assertIsNone(moved.transfer.from_account)
        self.assertEqual(moved.transfer.amount, Decimal("25.00"))
        self.assertIn("من خارج دفاتر المحل", moved.transfer.reason)
        float_account = IntegrationAccount.objects.get(provider="pointy").money_account
        self.assertEqual(moved.transfer.to_account, float_account)

    def test_a_topup_reads_the_wallet_when_it_must(self):
        paid_topup("100", relay_id="old-1", expensed=True)
        new = paid_topup("50", relay_id="new-1")
        # The relay's balance includes the new 50, which was never expensed.
        self.relay.get_wallet.return_value = {"balance": "120.000"}
        books.book_topup(new.pk)
        new.refresh_from_db()
        self.assertIsNotNone(new.transfer)
        self.assertEqual(WalletSettings.load().prebooked_balance, Decimal("70"))

    def test_an_unreadable_wallet_defers_the_booking_to_the_sync(self):
        paid_topup("100", relay_id="old-1", expensed=True)
        new = paid_topup("50", relay_id="new-1")
        self.relay.get_wallet.side_effect = RelayControlError("down")
        books.book_topup(new.pk)
        new.refresh_from_db()
        self.assertIsNone(new.transfer)
        self.assertEqual(new.expense_error, "books_switching")
        self.assertIsNone(WalletSettings.load().books_switched_at)
        self.relay.get_wallet.side_effect = None
        self.relay.get_wallet.return_value = {"balance": "120.000"}
        sync_topups()
        new.refresh_from_db()
        self.assertIsNotNone(new.transfer)
        self.assertEqual(new.expense_error, "")

    def test_a_shop_that_never_expensed_a_topup_has_nothing_to_remember(self):
        new = paid_topup("50", relay_id="new-1")
        books.book_topup(new.pk)
        self.assertEqual(WalletSettings.load().prebooked_balance, Decimal("0"))
        self.relay.get_wallet.assert_not_called()

    def test_a_failed_spend_booking_is_retried_by_the_sync(self):
        with mock.patch.object(books, "create_expense", side_effect=RuntimeError("disk full")):
            failed = spend("sms", "15", "transfer:a", main_balance=Decimal("85"))
        self.assertEqual(failed.error, "booking_failed")
        self.assertIsNone(failed.booked_at)
        sync_topups()
        failed.refresh_from_db()
        self.assertIsNotNone(failed.expense)
        self.assertEqual(failed.error, "")

    def test_a_spend_in_a_closed_day_is_booked_today_and_today_closed_waits(self):
        from apps.core.models import ShopSettings

        settings = ShopSettings.load()
        settings.books_locked_through = timezone.localdate() - timedelta(days=1)
        settings.save()
        cache.clear()
        moved = spend(
            "sms",
            "15",
            "transfer:a",
            main_balance=Decimal("85"),
            happened_on=timezone.localdate() - timedelta(days=3),
        )
        self.assertEqual(moved.expense.spent_at, timezone.localdate())
        self.assertIn("فترة مغلقة", moved.expense.notes)
        settings.books_locked_through = timezone.localdate()
        settings.save()
        cache.clear()
        waiting = spend("plan", "30", "plan:b", main_balance=Decimal("55"))
        self.assertEqual(waiting.error, "period_locked")
        self.assertIsNone(waiting.expense)


@override_settings(CACHES=_LOCMEM)
class WalletInTheTreasuryTests(TestCase):
    """«محفظة دفتر» = top-ups − SMS/plan spending − money moved to the voucher float."""

    def setUp(self):
        cache.clear()
        link_relay()
        patcher = mock.patch(_CLIENT, return_value=mock.Mock())
        patcher.start()
        self.addCleanup(patcher.stop)
        self.bank = MoneyAccount.objects.get(kind=MoneyAccount.Kind.BANK, is_default=True)
        self.today = timezone.localdate()

    def positions(self):
        return {row["account"].pk: row for row in treasury_position(as_of=self.today)["accounts"]}

    def test_the_wallet_is_an_asset_and_its_spending_leaves_it_not_the_bank(self):
        bank_before = self.positions()[self.bank.pk]["expected_balance"]
        books.book_topup(paid_topup("100", relay_id="t-1").pk)
        spend("sms", "15", "transfer:s", main_balance=Decimal("85"))
        spend("plan", "30", "plan:p", main_balance=Decimal("55"))
        spend("vouchers", "25", "transfer:v", main_balance=Decimal("30"))

        wallet = WalletSettings.load().money_account
        voucher_float = IntegrationAccount.objects.get(provider="pointy").money_account
        positions = self.positions()
        self.assertEqual(positions[wallet.pk]["expected_balance"], Decimal("30.00"))
        components = {part["code"]: part["amount"] for part in positions[wallet.pk]["components"]}
        self.assertEqual(
            components,
            {
                COMPONENT_TRANSFER_IN: Decimal("100.00"),
                COMPONENT_EXPENSES: Decimal("-45.00"),
                COMPONENT_TRANSFER_OUT: Decimal("-25.00"),
            },
        )
        self.assertEqual(positions[voucher_float.pk]["expected_balance"], Decimal("25.00"))
        # The bank paid the top-up, and nothing else: the wallet's expenses
        # name the wallet, and no bank owns them.
        self.assertEqual(
            positions[self.bank.pk]["expected_balance"], bank_before - Decimal("100.00")
        )
        totals = treasury_position(as_of=self.today)["totals"]
        self.assertEqual(totals["provider_float"], Decimal("55.00"))

        # The drill-down lists the same money the balance sums.
        rows = account_movements(wallet, start=self.today, end=self.today)["rows"]
        self.assertEqual(sum(row["amount"] for row in rows), Decimal("30.00"))
        self.assertEqual(
            sorted(row["amount"] for row in rows if row["source"] == COMPONENT_EXPENSES),
            [Decimal("-30.00"), Decimal("-15.00")],
        )

        # And the statement foots.
        statement = treasury_statement(start=self.today, end=self.today)
        for row in statement["accounts"]:
            with self.subTest(account=row["account"].name):
                self.assertEqual(
                    row["opening_balance"] + row["movement_total"], row["closing_balance"]
                )
        wallet_row = next(row for row in statement["accounts"] if row["account"].pk == wallet.pk)
        self.assertEqual(wallet_row["movement_total"], Decimal("30.00"))

    def test_a_cash_expense_or_a_bank_one_never_touches_the_wallet(self):
        books.book_topup(paid_topup("100", relay_id="t-1").pk)
        wallet = WalletSettings.load().money_account
        category = books.expense_category()
        Expense.objects.create(
            category=category,
            description="إيجار",
            amount=Decimal("40"),
            payment_method=Expense.PaymentMethod.TRANSFER,
        )
        Expense.objects.create(
            category=category,
            description="نظافة",
            amount=Decimal("5"),
            payment_method=Expense.PaymentMethod.CASH,
        )
        self.assertEqual(self.positions()[wallet.pk]["expected_balance"], Decimal("100.00"))


class WalletExpenseEditTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        manager = get_user_model().objects.create_user(username="mgr", password="x")
        manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.api = APIClient()
        self.api.force_authenticate(manager)
        with mock.patch.object(books, "ensure_switched_over", return_value=True):
            self.spent = spend("sms", "15", "transfer:s")

    def test_editing_a_wallet_expense_keeps_the_account_it_was_paid_from(self):
        expense = self.spent.expense
        wallet = expense.money_account
        resp = self.api.patch(
            f"/api/expenses/{expense.pk}/",
            {"description": "رصيد رسائل أكتوبر", "money_account": wallet.pk},
            format="json",
        )
        self.assertEqual(resp.status_code, 200, resp.content)
        expense.refresh_from_db()
        self.assertEqual(expense.money_account, wallet)
        self.assertEqual(expense.description, "رصيد رسائل أكتوبر")

    def test_naming_another_non_bank_account_is_still_refused(self):
        other = MoneyAccount.objects.create(name="رصيد آخر", kind=MoneyAccount.Kind.PROVIDER)
        resp = self.api.patch(
            f"/api/expenses/{self.spent.expense.pk}/", {"money_account": other.pk}, format="json"
        )
        self.assertEqual(resp.status_code, 400)

    def test_a_spend_row_is_one_per_relay_movement(self):
        again = spend("sms", "15", "transfer:s")
        self.assertEqual(again.pk, self.spent.pk)
        self.assertEqual(WalletSpend.objects.count(), 1)
        self.assertEqual(Expense.objects.count(), 1)
        self.assertTrue(MoneyTransfer.objects.count() == 0)
