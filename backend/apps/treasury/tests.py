"""The money position has one job: agree with reality.

These tests are written against the two ways it could quietly lie — counting a
refund or a drawer-paid expense twice, and drifting away from the register's own
``expected_cash`` arithmetic — plus the routing rules that decide which account
a payment method lands in.
"""

from datetime import timedelta
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.urls import reverse
from django.utils import timezone
from rest_framework.test import APIClient

from apps.core.roles import ACCOUNTANT_GROUP, ensure_role_groups
from apps.expenses.models import Expense, ExpenseCategory
from apps.expenses.services import create_expense
from apps.payments.models import Payment
from apps.purchasing.models import Supplier, SupplierPayment
from apps.sales.models import Order, RegisterCashMovement, RegisterSession
from apps.treasury.models import MoneyAccount, MoneyTransfer
from apps.treasury.movements import account_movements
from apps.treasury.position import (
    COMPONENT_DRAWER_OUT,
    COMPONENT_EXPENSES,
    COMPONENT_SALES,
    record_count,
    treasury_position,
)

User = get_user_model()


def money(value):
    return Decimal(value).quantize(Decimal("0.01"))


class TreasuryTestCase(TestCase):
    def setUp(self):
        super().setUp()
        self.user = User.objects.create_user(username="owner", password="pw")
        self.today = timezone.localdate()
        # Every shop is migrated with a cash box and a bank account already
        # seeded and defaulted; using them here exercises that seed too.
        self.cash = MoneyAccount.objects.get(kind=MoneyAccount.Kind.CASH)
        self.bank = MoneyAccount.objects.get(kind=MoneyAccount.Kind.BANK)
        self._open_account(self.cash, "100.00")
        self._open_account(self.bank, "500.00")
        self.session = RegisterSession.objects.create(
            owner=self.user,
            owner_key=f"user:{self.user.pk}",
            opening_cash=Decimal("50.00"),
        )

    # --- helpers ---------------------------------------------------------

    def _open_account(self, account, opening_balance):
        account.opening_balance = Decimal(opening_balance)
        account.opening_at = self.today - timedelta(days=30)
        account.save(update_fields=["opening_balance", "opening_at"])

    def position_for(self, account):
        position = treasury_position()
        for entry in position["accounts"]:
            if entry["account"].pk == account.pk:
                return entry
        raise AssertionError("account missing from the position")

    def balance_of(self, account):
        return self.position_for(account)["expected_balance"]

    def component(self, account, code):
        for part in self.position_for(account)["components"]:
            if part["code"] == code:
                return part["amount"]
        return Decimal("0.00")

    def make_order(self):
        return Order.objects.create(
            status=Order.Status.PAID,
            register_session=self.session,
            subtotal=Decimal("0.00"),
            total=Decimal("0.00"),
        )

    def pay(self, amount, method=Payment.Method.CASH, **kwargs):
        return Payment.objects.create(
            order=self.make_order(),
            method=method,
            amount=Decimal(amount),
            register_session=self.session,
            **kwargs,
        )


class OpeningBalanceTests(TreasuryTestCase):
    def test_a_shop_with_no_activity_holds_its_opening_balance(self):
        self.assertEqual(self.balance_of(self.cash), money("100.00"))
        self.assertEqual(self.balance_of(self.bank), money("500.00"))

    def test_money_moved_before_the_opening_day_is_not_counted_twice(self):
        """The opening balance already contains it; replaying it would double."""
        # Dated at creation: when a payment happened is part of what it says,
        # and a payment says it the moment it exists.
        stale = self.pay("40.00", paid_at=timezone.now() - timedelta(days=60))

        self.assertEqual(self.balance_of(self.cash), money("100.00"))


class RoutingTests(TreasuryTestCase):
    def test_cash_sales_reach_the_cash_box_and_card_sales_reach_the_bank(self):
        self.pay("30.00", Payment.Method.CASH)
        self.pay("70.00", Payment.Method.CARD)
        self.pay("20.00", Payment.Method.TRANSFER)

        self.assertEqual(self.balance_of(self.cash), money("130.00"))
        self.assertEqual(self.balance_of(self.bank), money("590.00"))

    def test_card_commission_is_kept_by_the_processor(self):
        self.pay(
            "100.00",
            Payment.Method.CARD,
            commission_percent=Decimal("2.00"),
            commission_amount=Decimal("2.00"),
        )
        self.assertEqual(self.balance_of(self.bank), money("598.00"))

    def test_a_second_bank_account_receives_only_its_own_transfers(self):
        """Derived flows route to the default account of a kind, never to both."""
        other = MoneyAccount.objects.create(
            name="مصرف الوحدة",
            kind=MoneyAccount.Kind.BANK,
            opening_balance=Decimal("0.00"),
            opening_at=self.today,
        )
        self.pay("80.00", Payment.Method.CARD)

        self.assertEqual(self.balance_of(self.bank), money("580.00"))
        self.assertEqual(self.balance_of(other), money("0.00"))

    def test_supplier_credit_moves_no_money(self):
        supplier = Supplier.objects.create(name="مورد")
        SupplierPayment.objects.create(
            supplier=supplier,
            amount=Decimal("25.00"),
            method=SupplierPayment.Method.SUPPLIER_CREDIT,
        )
        self.assertEqual(self.balance_of(self.cash), money("100.00"))
        self.assertEqual(self.balance_of(self.bank), money("500.00"))


class DoubleCountingTests(TreasuryTestCase):
    """The two ways this could silently deduct the same money twice."""

    def test_a_refund_is_deducted_once(self):
        self.pay("100.00", Payment.Method.CASH)
        # record_adjustment writes the refund as a negative payment per tender.
        self.pay("-40.00", Payment.Method.CASH)

        self.assertEqual(self.balance_of(self.cash), money("160.00"))

    def test_a_drawer_paid_expense_is_deducted_once(self):
        category, _ = ExpenseCategory.objects.get_or_create(name="إيجار")
        create_expense(
            user=self.user,
            pay_from_register=True,
            category=category,
            description="كهرباء",
            amount=Decimal("30.00"),
            payment_method=Expense.PaymentMethod.CASH,
        )
        # One expense + one linked drawer pay-out, but only 30.00 left the box.
        self.assertEqual(
            RegisterCashMovement.objects.filter(
                movement_type=RegisterCashMovement.MovementType.PAY_OUT
            ).count(),
            1,
        )
        self.assertEqual(self.balance_of(self.cash), money("70.00"))
        self.assertEqual(self.component(self.cash, COMPONENT_EXPENSES), money("-30.00"))
        self.assertEqual(self.component(self.cash, COMPONENT_DRAWER_OUT), money("0.00"))

    def test_a_standalone_drawer_payout_is_still_counted(self):
        RegisterCashMovement.objects.create(
            register_session=self.session,
            movement_type=RegisterCashMovement.MovementType.PAY_OUT,
            amount=Decimal("15.00"),
            reason="سلفة",
        )
        self.assertEqual(self.balance_of(self.cash), money("85.00"))


class TransferTests(TreasuryTestCase):
    def test_a_bank_deposit_moves_money_without_creating_or_destroying_it(self):
        self.pay("200.00", Payment.Method.CASH)
        before = self.balance_of(self.cash) + self.balance_of(self.bank)

        MoneyTransfer.objects.create(
            from_account=self.cash,
            to_account=self.bank,
            amount=Decimal("250.00"),
            reason="إيداع",
        )

        self.assertEqual(self.balance_of(self.cash), money("50.00"))
        self.assertEqual(self.balance_of(self.bank), money("750.00"))
        self.assertEqual(self.balance_of(self.cash) + self.balance_of(self.bank), before)

    def test_an_owner_withdrawal_leaves_the_shop(self):
        MoneyTransfer.objects.create(
            from_account=self.cash,
            amount=Decimal("60.00"),
            reason="سحب المالك",
        )
        self.assertEqual(self.balance_of(self.cash), money("40.00"))

    def test_capital_put_in_arrives(self):
        MoneyTransfer.objects.create(
            to_account=self.cash,
            amount=Decimal("60.00"),
            reason="رأس مال",
        )
        self.assertEqual(self.balance_of(self.cash), money("160.00"))


class CountTests(TreasuryTestCase):
    def test_a_count_snapshots_the_variance_it_found(self):
        self.pay("100.00", Payment.Method.CASH)
        count = record_count(
            account=self.cash,
            counted_amount=Decimal("195.00"),
            created_by=self.user,
        )
        self.assertEqual(count.expected_amount, money("200.00"))
        self.assertEqual(count.variance, money("-5.00"))
        self.assertTrue(count.has_variance)

    def test_a_later_backdated_expense_does_not_rewrite_a_past_variance(self):
        count = record_count(account=self.cash, counted_amount=Decimal("100.00"))
        self.assertEqual(count.variance, money("0.00"))

        category, _ = ExpenseCategory.objects.get_or_create(name="صيانة")
        Expense.objects.create(
            category=category,
            description="سباك",
            amount=Decimal("20.00"),
            payment_method=Expense.PaymentMethod.CASH,
            spent_at=self.today - timedelta(days=2),
        )

        count.refresh_from_db()
        self.assertEqual(count.variance, money("0.00"))
        self.assertEqual(self.balance_of(self.cash), money("80.00"))


class ComponentTests(TreasuryTestCase):
    def test_components_sum_to_the_balance(self):
        self.pay("120.00", Payment.Method.CASH)
        RegisterCashMovement.objects.create(
            register_session=self.session,
            movement_type=RegisterCashMovement.MovementType.PAY_IN,
            amount=Decimal("10.00"),
            reason="إيداع",
        )
        MoneyTransfer.objects.create(
            from_account=self.cash,
            to_account=self.bank,
            amount=Decimal("50.00"),
        )

        position = self.position_for(self.cash)
        total = sum((part["amount"] for part in position["components"]), Decimal("0.00"))
        self.assertEqual(total, position["expected_balance"])

    def test_zero_components_are_left_out_of_the_breakdown(self):
        self.pay("10.00", Payment.Method.CASH)
        codes = {part["code"] for part in self.position_for(self.cash)["components"]}
        self.assertIn(COMPONENT_SALES, codes)
        self.assertNotIn(COMPONENT_DRAWER_OUT, codes)


class RegisterAgreementTests(TreasuryTestCase):
    """The shop-wide cash figure must not drift from the drawer's own."""

    def test_cash_box_matches_the_register_expected_cash_for_one_shift(self):
        cash_only = MoneyAccount.objects.get(pk=self.cash.pk)
        cash_only.opening_balance = self.session.opening_cash
        cash_only.save(update_fields=["opening_balance"])

        self.pay("80.00", Payment.Method.CASH)
        RegisterCashMovement.objects.create(
            register_session=self.session,
            movement_type=RegisterCashMovement.MovementType.PAY_IN,
            amount=Decimal("5.00"),
            reason="إيداع",
        )
        RegisterCashMovement.objects.create(
            register_session=self.session,
            movement_type=RegisterCashMovement.MovementType.PAY_OUT,
            amount=Decimal("12.00"),
            reason="سلفة",
        )

        self.session.refresh_from_db()
        self.assertEqual(self.balance_of(cash_only), self.session.expected_cash)


class MovementsTests(TreasuryTestCase):
    def test_the_drill_down_rows_add_up_to_the_flows_they_explain(self):
        self.pay("90.00", Payment.Method.CASH)
        RegisterCashMovement.objects.create(
            register_session=self.session,
            movement_type=RegisterCashMovement.MovementType.PAY_OUT,
            amount=Decimal("20.00"),
            reason="سلفة",
        )
        MoneyTransfer.objects.create(
            from_account=self.cash, to_account=self.bank, amount=Decimal("30.00")
        )

        result = account_movements(
            self.cash, start=self.today - timedelta(days=1), end=self.today
        )
        moved = sum((row["amount"] for row in result["rows"]), Decimal("0.00"))
        # Opening balance is not a movement; everything else is.
        self.assertEqual(
            moved, self.balance_of(self.cash) - self.cash.opening_balance
        )

    def test_a_drawer_paid_expense_appears_once_in_the_drill_down(self):
        category, _ = ExpenseCategory.objects.get_or_create(name="إيجار")
        create_expense(
            user=self.user,
            pay_from_register=True,
            category=category,
            description="كهرباء",
            amount=Decimal("30.00"),
            payment_method=Expense.PaymentMethod.CASH,
        )
        result = account_movements(
            self.cash, start=self.today - timedelta(days=1), end=self.today
        )
        sources = [row["source"] for row in result["rows"]]
        self.assertEqual(sources.count(COMPONENT_EXPENSES), 1)
        self.assertEqual(sources.count(COMPONENT_DRAWER_OUT), 0)


class TreasuryApiTests(TreasuryTestCase):
    def setUp(self):
        super().setUp()
        ensure_role_groups()
        self.accountant = User.objects.create_user(username="acc", password="pw")
        self.accountant.groups.add(Group.objects.get(name=ACCOUNTANT_GROUP))
        self.client = APIClient()
        self.client.force_authenticate(self.accountant)

    def test_position_endpoint_reports_totals(self):
        self.pay("40.00", Payment.Method.CASH)
        response = self.client.get(reverse("treasury-position"))

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data["totals"]["cash"], "140.00")
        self.assertEqual(response.data["totals"]["bank"], "500.00")
        self.assertEqual(response.data["totals"]["total"], "640.00")

    def test_recording_a_count_stores_the_expected_balance_the_screen_showed(self):
        self.pay("40.00", Payment.Method.CASH)
        response = self.client.post(
            reverse("money-count-list"),
            {"account": self.cash.pk, "counted_amount": "138.00"},
            format="json",
        )
        self.assertEqual(response.status_code, 201)
        self.assertEqual(response.data["expected_amount"], "140.00")
        self.assertEqual(response.data["variance"], "-2.00")

    def test_a_transfer_needs_at_least_one_side(self):
        response = self.client.post(
            reverse("money-transfer-list"),
            {"amount": "10.00"},
            format="json",
        )
        self.assertEqual(response.status_code, 400)

    def test_a_cashier_cannot_read_the_money_position(self):
        cashier = User.objects.create_user(username="till", password="pw")
        client = APIClient()
        client.force_authenticate(cashier)
        self.assertEqual(client.get(reverse("treasury-position")).status_code, 403)

    def test_movements_endpoint_rejects_a_backwards_period(self):
        url = reverse("treasury-account-movements", args=[self.cash.pk])
        response = self.client.get(
            url, {"start": self.today.isoformat(), "end": "2020-01-01"}
        )
        self.assertEqual(response.status_code, 400)


class MoneyAccountEditTests(TreasuryTestCase):
    """Editing an account that is not its kind's default.

    DRF turned the conditional "one default per kind" constraint into a plain
    uniqueness check on ``kind``, so every edit to a second cash box or a second
    bank came back 400 — whatever was typed. It surfaced on an imported
    "الخزينة الرئيسية" whose opening balance the owner tried to set to zero.
    """

    def setUp(self):
        super().setUp()
        ensure_role_groups()
        accountant = User.objects.create_user(username="acc", password="pw")
        accountant.groups.add(Group.objects.get(name=ACCOUNTANT_GROUP))
        self.client = APIClient()
        self.client.force_authenticate(accountant)
        self.second = MoneyAccount.objects.create(
            name="الخزينة الرئيسية",
            kind=MoneyAccount.Kind.CASH,
            opening_balance=Decimal("71751.50"),
            opening_at=self.today - timedelta(days=400),
        )

    def _patch(self, account, **changes):
        # The editor sends the whole form, not just what changed.
        payload = {
            "name": account.name,
            "kind": account.kind,
            "bank_name": "",
            "bank_slug": "",
            "account_number": "",
            "iban": "",
            "opening_balance": str(account.opening_balance),
            "opening_at": account.opening_at.isoformat(),
            "is_default": account.is_default,
            "is_active": account.is_active,
            "display_order": account.display_order,
            "notes": account.notes,
        }
        payload.update(changes)
        return self.client.patch(
            reverse("money-account-detail", args=[account.pk]), payload, format="json"
        )

    def test_a_second_cash_box_can_have_its_opening_balance_zeroed(self):
        response = self._patch(self.second, opening_balance="0.00")

        self.assertEqual(response.status_code, 200, response.data)
        self.second.refresh_from_db()
        self.assertEqual(self.second.opening_balance, Decimal("0.00"))
        # The seeded box is still the default; nothing else moved.
        self.cash.refresh_from_db()
        self.assertTrue(self.cash.is_default)

    def test_making_the_second_box_the_default_moves_the_flag(self):
        """Not a 400 and not an IntegrityError: the flag changes hands."""
        response = self._patch(self.second, is_default=True)

        self.assertEqual(response.status_code, 200, response.data)
        self.second.refresh_from_db()
        self.cash.refresh_from_db()
        self.assertTrue(self.second.is_default)
        self.assertFalse(self.cash.is_default)

    def test_a_new_default_takes_the_flag_on_create(self):
        response = self.client.post(
            reverse("money-account-list"),
            {"name": "مصرف الجمهورية", "kind": "bank", "is_default": True},
            format="json",
        )

        self.assertEqual(response.status_code, 201, response.data)
        self.bank.refresh_from_db()
        self.assertFalse(self.bank.is_default)
        self.assertEqual(
            MoneyAccount.objects.filter(kind="bank", is_default=True).count(), 1
        )
