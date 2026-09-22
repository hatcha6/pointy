"""Two banks, two terminals, and money that lands where it actually landed.

A shop with one card machine never had this problem: every card payment was
"the bank", and "the bank" was one account. A shop with a Jumhouria terminal on
the left of the counter and an Aman terminal on the right has both totals mixed
into whichever account happened to be the default, and no way to see it.

The tests below are written against the three ways the fix could go wrong:

* it could change what an existing shop sees (nothing is tagged, so nothing may
  move — the first class);
* it could send tagged money to the default anyway, or untagged money to a
  tagged account (the second);
* it could route the sale correctly and then refund it out of the wrong bank,
  which would leave the two accounts permanently out by the value of every
  return (the third).
"""

from datetime import timedelta
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.utils import timezone

from apps.expenses.models import Expense, ExpenseCategory
from apps.payments import terminals
from apps.payments.models import CardTerminal, Payment
from apps.purchasing.models import Supplier, SupplierPayment
from apps.sales.models import Order, RegisterSession
from apps.treasury.models import MoneyAccount
from apps.treasury.movements import account_movements
from apps.treasury.position import (
    COMPONENT_EXPENSES,
    COMPONENT_SALES,
    treasury_position,
)

User = get_user_model()


def money(value):
    return Decimal(value).quantize(Decimal("0.01"))


class TwoBankShopTestCase(TestCase):
    def setUp(self):
        super().setUp()
        self.user = User.objects.create_user(username="owner", password="pw")
        self.today = timezone.localdate()
        self.cash = MoneyAccount.objects.get(kind=MoneyAccount.Kind.CASH)
        self.primary = MoneyAccount.objects.get(kind=MoneyAccount.Kind.BANK)
        self.primary.name = "الجمهورية"
        self.primary.bank_slug = "jbank"
        self.primary.opening_balance = Decimal("500.00")
        self.primary.opening_at = self.today - timedelta(days=30)
        self.primary.save()
        self.second = MoneyAccount.objects.create(
            name="الأمان",
            kind=MoneyAccount.Kind.BANK,
            bank_slug="aman",
            opening_balance=Decimal("200.00"),
            opening_at=self.today - timedelta(days=30),
        )
        self.session = RegisterSession.objects.create(
            owner=self.user,
            owner_key=f"user:{self.user.pk}",
            opening_cash=Decimal("0.00"),
        )

    # --- helpers ---------------------------------------------------------

    def balance_of(self, account):
        for entry in treasury_position()["accounts"]:
            if entry["account"].pk == account.pk:
                return entry["expected_balance"]
        raise AssertionError("account missing from the position")

    def component(self, account, code):
        for entry in treasury_position()["accounts"]:
            if entry["account"].pk != account.pk:
                continue
            for part in entry["components"]:
                if part["code"] == code:
                    return part["amount"]
        return Decimal("0.00")

    def make_order(self, total="0.00"):
        return Order.objects.create(
            status=Order.Status.PAID,
            register_session=self.session,
            subtotal=Decimal(total),
            total=Decimal(total),
        )

    def pay(self, amount, method=Payment.Method.CARD, account=None, order=None):
        return Payment.objects.create(
            order=order or self.make_order(),
            method=method,
            amount=Decimal(amount),
            money_account=account,
            register_session=self.session,
        )


class NothingChangesForAShopThatNamesNoAccountTests(TwoBankShopTestCase):
    def test_untagged_card_money_still_lands_in_the_default_account(self):
        self.pay("70.00")
        self.pay("30.00", Payment.Method.TRANSFER)

        self.assertEqual(self.balance_of(self.primary), money("600.00"))
        self.assertEqual(self.balance_of(self.second), money("200.00"))

    def test_a_second_account_starts_at_its_opening_balance_and_no_more(self):
        """The takings of the account that was already there are not shared."""
        self.pay("1000.00")

        self.assertEqual(self.balance_of(self.second), money("200.00"))

    def test_an_untagged_bank_expense_still_leaves_the_default_account(self):
        _expense(Decimal("40.00"))

        self.assertEqual(self.balance_of(self.primary), money("460.00"))
        self.assertEqual(self.balance_of(self.second), money("200.00"))

    def test_an_untagged_supplier_payment_still_leaves_the_default_account(self):
        supplier = Supplier.objects.create(name="مورد")
        SupplierPayment.objects.create(
            supplier=supplier,
            amount=Decimal("50.00"),
            method=SupplierPayment.Method.TRANSFER,
        )

        self.assertEqual(self.balance_of(self.primary), money("450.00"))
        self.assertEqual(self.balance_of(self.second), money("200.00"))


class TaggedMoneyReachesItsOwnAccountTests(TwoBankShopTestCase):
    def test_a_card_payment_tagged_to_the_second_bank_lands_there(self):
        self.pay("70.00", account=self.second)

        self.assertEqual(self.balance_of(self.primary), money("500.00"))
        self.assertEqual(self.balance_of(self.second), money("270.00"))

    def test_the_default_account_does_not_also_claim_a_tagged_payment(self):
        """The bug this whole feature exists to stop: money counted twice."""
        self.pay("70.00", account=self.second)

        self.assertEqual(self.component(self.primary, COMPONENT_SALES), money("0.00"))
        self.assertEqual(self.component(self.second, COMPONENT_SALES), money("70.00"))

    def test_tagged_and_untagged_money_of_the_same_method_split_correctly(self):
        self.pay("70.00", account=self.second)
        self.pay("30.00")

        self.assertEqual(self.balance_of(self.primary), money("530.00"))
        self.assertEqual(self.balance_of(self.second), money("270.00"))

    def test_a_supplier_payment_leaves_the_account_it_named(self):
        supplier = Supplier.objects.create(name="مورد")
        SupplierPayment.objects.create(
            supplier=supplier,
            amount=Decimal("50.00"),
            method=SupplierPayment.Method.TRANSFER,
            money_account=self.second,
        )

        self.assertEqual(self.balance_of(self.primary), money("500.00"))
        self.assertEqual(self.balance_of(self.second), money("150.00"))

    def test_an_expense_leaves_the_account_it_named(self):
        _expense(Decimal("40.00"), account=self.second)

        self.assertEqual(self.balance_of(self.primary), money("500.00"))
        self.assertEqual(self.balance_of(self.second), money("160.00"))

    def test_the_default_account_does_not_also_claim_a_tagged_expense(self):
        _expense(Decimal("40.00"), account=self.second)

        self.assertEqual(
            self.component(self.primary, COMPONENT_EXPENSES), money("0.00")
        )
        self.assertEqual(
            self.component(self.second, COMPONENT_EXPENSES), money("-40.00")
        )

    def test_the_drill_down_shows_a_tagged_expense_on_its_own_account(self):
        _expense(Decimal("40.00"), account=self.second)

        rows = account_movements(
            self.second, start=self.today - timedelta(days=1), end=self.today
        )["rows"]
        self.assertEqual(
            [row["amount"] for row in rows if row["source"] == COMPONENT_EXPENSES],
            [money("-40.00")],
        )

    def test_the_second_account_totals_still_foot_to_the_shop_wide_bank_total(self):
        self.pay("70.00", account=self.second)
        self.pay("30.00")

        totals = treasury_position()["totals"]
        self.assertEqual(totals["bank"], money("800.00"))

    def test_the_drill_down_shows_a_tagged_payment_on_its_own_account(self):
        self.pay("70.00", account=self.second)

        rows = account_movements(
            self.second, start=self.today - timedelta(days=1), end=self.today
        )["rows"]
        self.assertEqual(
            [row["amount"] for row in rows if row["source"] == COMPONENT_SALES],
            [money("70.00")],
        )

    def test_the_drill_down_does_not_show_it_on_the_default_account(self):
        """A tapped total and the rows behind it must describe the same money."""
        self.pay("70.00", account=self.second)

        rows = account_movements(
            self.primary, start=self.today - timedelta(days=1), end=self.today
        )["rows"]
        self.assertEqual([row for row in rows if row["source"] == COMPONENT_SALES], [])


class TerminalMappingTests(TwoBankShopTestCase):
    def test_a_slip_from_a_mapped_terminal_routes_itself(self):
        CardTerminal.objects.create(
            terminal_id="0JA8Y13W", money_account=self.second
        )

        account = terminals.account_for_receipt({"terminal_id": "0JA8Y13W"})

        self.assertEqual(account, self.second)

    def test_an_ocr_misread_still_reaches_the_right_bank(self):
        """The routing matcher is the trust matcher, to the letter."""
        CardTerminal.objects.create(
            terminal_id="0JA8Y13W", money_account=self.second
        )

        account = terminals.account_for_receipt(
            {"terminal_id": "OJA8YI3W", "validation_method": "rendered_receipt_ocr"}
        )

        self.assertEqual(account, self.second)

    def test_an_unregistered_terminal_routes_nowhere_rather_than_somewhere(self):
        CardTerminal.objects.create(
            terminal_id="0JA8Y13W", money_account=self.second
        )

        self.assertIsNone(terminals.account_for_receipt({"terminal_id": "9XQQPL42"}))

    def test_a_terminal_with_no_account_yet_routes_nowhere(self):
        CardTerminal.objects.create(terminal_id="0JA8Y13W")

        self.assertIsNone(terminals.account_for_receipt({"terminal_id": "0JA8Y13W"}))

    def test_a_deactivated_terminal_stops_routing(self):
        CardTerminal.objects.create(
            terminal_id="0JA8Y13W", money_account=self.second, is_active=False
        )

        self.assertIsNone(terminals.account_for_receipt({"terminal_id": "0JA8Y13W"}))

    def test_the_trust_list_mirrors_the_registry(self):
        from apps.core.models import ShopSettings

        CardTerminal.objects.create(terminal_id="0JA8Y13W")
        terminals.refresh_settings_mirror()

        self.assertEqual(
            ShopSettings.load().trusted_card_terminal_ids, ["0JA8Y13W"]
        )

    def test_an_old_client_writing_the_bare_list_keeps_the_bank_mapping(self):
        """The whole point of deactivating rather than deleting."""
        CardTerminal.objects.create(
            terminal_id="0JA8Y13W", money_account=self.second
        )

        terminals.sync_from_id_list(["0JA8Y13W", "9XQQPL42"])

        mapped = CardTerminal.objects.get(terminal_id="0JA8Y13W")
        self.assertEqual(mapped.money_account, self.second)
        self.assertTrue(
            CardTerminal.objects.filter(terminal_id="9XQQPL42", is_active=True).exists()
        )

    def test_a_terminal_dropped_by_an_old_client_comes_back_with_its_account(self):
        CardTerminal.objects.create(
            terminal_id="0JA8Y13W", money_account=self.second
        )

        terminals.sync_from_id_list([])
        terminals.sync_from_id_list(["0JA8Y13W"])

        restored = CardTerminal.objects.get(terminal_id="0JA8Y13W")
        self.assertTrue(restored.is_active)
        self.assertEqual(restored.money_account, self.second)


class RefundsGoBackWhereTheyCameFromTests(TwoBankShopTestCase):
    def test_a_refund_of_a_tagged_card_sale_reduces_that_same_bank(self):
        from apps.sales.services import refund_tender_account_allocations

        order = self.make_order("100.00")
        self.pay("100.00", account=self.second, order=order)

        allocations = list(
            refund_tender_account_allocations(
                order, [(Payment.Method.CARD, Decimal("40.00"))]
            )
        )

        self.assertEqual(
            allocations, [(Payment.Method.CARD, self.second.pk, Decimal("40.00"))]
        )

    def test_a_card_sale_split_across_two_banks_refunds_from_both(self):
        from apps.sales.services import refund_tender_account_allocations

        order = self.make_order("100.00")
        self.pay("75.00", account=self.second, order=order)
        self.pay("25.00", account=self.primary, order=order)

        allocations = list(
            refund_tender_account_allocations(
                order, [(Payment.Method.CARD, Decimal("40.00"))]
            )
        )

        self.assertEqual(
            sum(amount for _, _, amount in allocations), Decimal("40.00")
        )
        self.assertEqual(
            {account_id: amount for _, account_id, amount in allocations},
            {self.second.pk: Decimal("30.00"), self.primary.pk: Decimal("10.00")},
        )

    def test_an_untagged_sale_still_refunds_untagged(self):
        from apps.sales.services import refund_tender_account_allocations

        order = self.make_order("100.00")
        self.pay("100.00", order=order)

        allocations = list(
            refund_tender_account_allocations(
                order, [(Payment.Method.CARD, Decimal("40.00"))]
            )
        )

        self.assertEqual(allocations, [(Payment.Method.CARD, None, Decimal("40.00"))])


class ExpenseAccountRulesTests(TwoBankShopTestCase):
    """What the expense form may and may not say about a bank.

    Same two rules the till and the purchasing screens enforce, because an
    expense filed against a bank the money never left produces a balance no
    statement will agree with — and one filed against the cash box would be
    counted twice, once here and once as the drawer pay-out.
    """

    def _serializer(self, data, instance=None):
        from apps.expenses.serializers import ExpenseSerializer

        return ExpenseSerializer(instance=instance, data=data, partial=instance is not None)

    def test_a_cash_expense_may_not_name_a_bank(self):
        serializer = self._serializer(
            {
                "category": _category().pk,
                "description": "كهرباء",
                "amount": "40.00",
                "payment_method": Expense.PaymentMethod.CASH,
                "money_account": self.second.pk,
            }
        )

        self.assertFalse(serializer.is_valid())
        self.assertIn("money_account", serializer.errors)

    def test_an_expense_may_not_name_the_cash_box(self):
        serializer = self._serializer(
            {
                "category": _category().pk,
                "description": "كهرباء",
                "amount": "40.00",
                "payment_method": Expense.PaymentMethod.TRANSFER,
                "money_account": self.cash.pk,
            }
        )

        self.assertFalse(serializer.is_valid())
        self.assertIn("money_account", serializer.errors)

    def test_switching_a_card_expense_to_cash_clears_its_bank(self):
        """The correction the cashier is making is the right one.

        Refusing the edit would leave them stuck with a row that names a bank
        the money never left; clearing it lets the correction through and stops
        the bank being charged for cash that came out of the drawer.
        """
        expense = _expense(Decimal("40.00"), account=self.second)

        serializer = self._serializer(
            {"payment_method": Expense.PaymentMethod.CASH}, instance=expense
        )

        self.assertTrue(serializer.is_valid(), serializer.errors)
        self.assertIsNone(serializer.validated_data["money_account"])


def _category():
    return ExpenseCategory.objects.get_or_create(name="مصاريف")[0]


def _expense(amount, *, account=None, method=None):
    return Expense.objects.create(
        category=_category(),
        description="كهرباء",
        amount=amount,
        payment_method=method or Expense.PaymentMethod.TRANSFER,
        money_account=account,
    )
