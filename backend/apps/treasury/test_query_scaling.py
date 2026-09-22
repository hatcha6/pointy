"""The money position must cost a flat number of queries.

Two ways this screen could quietly become expensive:

* **Per account.** Derived flows are computed once per *kind* and attributed to
  that kind's default account, so a shop that adds a second and third bank
  account must not pay for a second and third sweep of every payment table. If
  this test starts growing, the routing in ``_default_account_ids`` has been
  bypassed and each account is aggregating for itself.

* **Per row.** The drill-down renders a supplier name, an expense category and
  an order number per movement — all attribute reads that hide a query without
  ``select_related``. The list runs to ``MOVEMENT_ROW_LIMIT`` rows, so an
  unprimed read is a per-row cost on the screen an owner opens to ask where the
  money went.

Both are measured at N and 2N: a flat count proves the batching holds, a growing
one proves it is gone.
"""

from datetime import timedelta
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.db import connection
from django.test import TestCase
from django.test.utils import CaptureQueriesContext
from django.utils import timezone

from apps.expenses.models import Expense, ExpenseCategory
from apps.payments.models import Payment
from apps.purchasing.models import Supplier, SupplierPayment
from apps.sales.models import Order, RegisterCashMovement, RegisterSession

from .models import MoneyAccount, MoneyTransfer
from .movements import account_movements
from .position import treasury_position

# Three aggregates per bank account: sales+commission in one pass over
# ``Payment``, supplier payments, and expenses. Consignor payouts and payroll
# carry no account, so they stay with the default and are not paid for again
# per account.
QUERIES_PER_BANK_ACCOUNT = 3

BASE_ROWS = 6


class TreasuryQueryScalingTests(TestCase):
    def setUp(self):
        User = get_user_model()
        self.user = User.objects.create_user(username="treasury-scale", password="pw")
        self.today = timezone.localdate()
        self.cash = MoneyAccount.objects.get(kind=MoneyAccount.Kind.CASH)
        self.bank = MoneyAccount.objects.get(kind=MoneyAccount.Kind.BANK)
        self.session = RegisterSession.objects.create(
            owner=self.user,
            owner_key=f"user:{self.user.pk}",
            opening_cash=Decimal("50.00"),
        )
        self.supplier = Supplier.objects.create(name="مورد الخزينة")
        self.category, _ = ExpenseCategory.objects.get_or_create(name="إيجار")
        self.seeded = 0

    # --- seeding ---------------------------------------------------------

    def _seed_movements(self, count):
        """Add ``count`` of every movement kind the drill-down renders."""
        for index in range(self.seeded, self.seeded + count):
            order = Order.objects.create(
                status=Order.Status.PAID,
                register_session=self.session,
                subtotal=Decimal("10.00"),
                total=Decimal("10.00"),
            )
            Payment.objects.create(
                order=order,
                method=Payment.Method.CASH,
                amount=Decimal("10.00"),
                register_session=self.session,
            )
            Expense.objects.create(
                category=self.category,
                description=f"مصروف {index}",
                amount=Decimal("2.00"),
                payment_method=Expense.PaymentMethod.CASH,
                spent_at=self.today,
            )
            SupplierPayment.objects.create(
                supplier=self.supplier,
                amount=Decimal("3.00"),
                method=SupplierPayment.Method.CASH,
            )
            RegisterCashMovement.objects.create(
                register_session=self.session,
                movement_type=RegisterCashMovement.MovementType.PAY_OUT,
                amount=Decimal("1.00"),
                reason=f"سلفة {index}",
            )
            MoneyTransfer.objects.create(
                from_account=self.cash,
                to_account=self.bank,
                amount=Decimal("5.00"),
                reason=f"إيداع {index}",
            )
        self.seeded += count

    def _add_bank_accounts(self, count):
        for index in range(count):
            MoneyAccount.objects.create(
                name=f"مصرف {index}",
                kind=MoneyAccount.Kind.BANK,
                opening_at=self.today,
            )

    # --- measurement -----------------------------------------------------

    def _position_queries(self):
        with CaptureQueriesContext(connection) as captured:
            treasury_position()
        return len(captured)

    def _movement_queries(self):
        with CaptureQueriesContext(connection) as captured:
            account_movements(
                self.cash,
                start=self.today - timedelta(days=1),
                end=self.today,
            )
        return len(captured)

    # --- tests -----------------------------------------------------------

    def test_a_bank_account_costs_a_fixed_number_of_queries(self):
        """Adding a bank account costs the same two aggregates every time.

        It used to cost nothing, because every card payment in the shop was
        attributed to one default account. Now each account asks its own
        question over its own window — it has to, since two accounts opened in
        different months cannot share a range — so the guard is no longer "flat"
        but "a small constant per account, and never a query per ROW".

        Three is the budget: the payments aggregate (sales and commission in
        one pass), the supplier-payments aggregate and the expenses aggregate.
        Anything more means a per-account lookup crept back in — a
        ``select_related`` that was dropped, or a last-count fetch that stopped
        being batched.
        """
        self._seed_movements(BASE_ROWS)
        baseline = self._position_queries()

        self._add_bank_accounts(4)
        self.assertEqual(
            self._position_queries(),
            baseline + 4 * QUERIES_PER_BANK_ACCOUNT,
            "A bank account costs more than its two aggregates — something is "
            "being looked up per account instead of batched across them.",
        )

    def test_a_bank_account_costs_the_same_however_many_rows_it_holds(self):
        self._seed_movements(BASE_ROWS)
        self._add_bank_accounts(2)
        baseline = self._position_queries()

        self._seed_movements(BASE_ROWS)
        self.assertEqual(
            self._position_queries(),
            baseline,
            "Per-account attribution must still aggregate in SQL.",
        )

    def test_the_position_does_not_scale_with_the_number_of_movements(self):
        self._seed_movements(BASE_ROWS)
        baseline = self._position_queries()

        self._seed_movements(BASE_ROWS)
        self.assertEqual(
            self._position_queries(),
            baseline,
            "The balance is aggregated in SQL; it must not read rows.",
        )

    def test_the_drill_down_does_not_scale_with_row_count(self):
        self._seed_movements(BASE_ROWS)
        baseline = self._movement_queries()

        self._seed_movements(BASE_ROWS)
        self.assertEqual(
            self._movement_queries(),
            baseline,
            "A movement row reads a supplier, a category or an order number "
            "per row — add it to the select_related on its builder.",
        )

    def test_the_drill_down_still_names_what_it_lists(self):
        """The select_related must not change what the rows say."""
        self._seed_movements(1)
        rows = account_movements(
            self.cash,
            start=self.today - timedelta(days=1),
            end=self.today,
        )["rows"]

        by_source = {row["source"]: row for row in rows}
        self.assertEqual(by_source["suppliers"]["description"], "مورد الخزينة")
        self.assertIn("إيجار", by_source["expenses"]["description"])
        self.assertEqual(by_source["drawer_out"]["description"], "سلفة 0")

    def test_the_screen_and_the_drill_down_cost_what_we_think(self):
        """A named ceiling, so a regression is visible in the diff rather than
        only in a shop's slow screen."""
        self._seed_movements(BASE_ROWS)

        # 2 kinds x 6 aggregates, plus the account list, the counts per account
        # and the transfer pair per account.
        self.assertLessEqual(self._position_queries(), 25)
        self.assertLessEqual(self._movement_queries(), 10)
