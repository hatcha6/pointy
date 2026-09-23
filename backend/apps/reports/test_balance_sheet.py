"""الميزانية العمومية: the shop's position at both ends of a period, and zakat.

One small shop, built so every line of the statement moves between the two
dates for a reason a reader can name: stock that left without a sale, a wage
run approved before the period and paid inside it, a staff loan repaid from
those wages, a supplier paid on account, and the owner putting money in and
taking some out. The figures below are worked by hand from that story, so a
test that fails here is the statement disagreeing with arithmetic, not with
itself.
"""

from datetime import datetime, time, timedelta
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.utils import timezone

from apps.catalog.testing import create_product_with_default_variant
from apps.core.roles import (
    ACCOUNTANT_GROUP,
    CASHIER_GROUP,
    MANAGER_GROUP,
    ensure_role_groups,
)
from apps.customers.models import Customer
from apps.employees.models import (
    Employee,
    EmployeeLoan,
    EmployeeLoanPayment,
    PayrollAdjustment,
    PayrollLine,
    PayrollRun,
)
from apps.inventory.models import (
    StockLedgerEntry,
    StockUnit,
    StockValuationBin,
    Warehouse,
)
from apps.inventory.reporting import stock_retail_value
from apps.payments.models import Payment
from apps.purchasing.models import PurchaseOrder, Supplier, SupplierPayment
from apps.sales.models import Order, RegisterSession
from apps.treasury.models import MoneyAccount, MoneyTransfer

from .models import ReportRun
from .services import ReportAccessDenied, generate_report_payload

Type = ReportRun.ReportType


class BalanceSheetTests(TestCase):
    """The period is the last seven days; the opening column is the day before."""

    def setUp(self):
        ensure_role_groups()
        User = get_user_model()
        self.manager = User.objects.create_user(username="bs-manager", password="p")
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.today = timezone.localdate()
        self.start = self.today - timedelta(days=7)

        self._stock()
        self._money()
        self._customer_debt()
        self._supplier_debt()
        self._staff()

    # -- the shop ----------------------------------------------------------

    def _at(self, days_ago):
        """Noon, ``days_ago`` days back — well clear of any day boundary."""
        day = self.today - timedelta(days=days_ago)
        return timezone.make_aware(datetime.combine(day, time(12)))

    def _stock(self):
        """Ten units at 2.00 bought a month ago; four left five days ago with
        no sale — the one thing in the period that made the shop poorer."""
        product = create_product_with_default_variant(
            sku="BS-1", name="شاحن", unit_price=Decimal("10.00")
        )
        self.variant = product.default_variant
        self.warehouse_id = Warehouse.default_id()
        for days_ago, quantity, value, balance in (
            (30, 10, "20.00", (10, "20.00")),
            (5, -4, "-8.00", (6, "12.00")),
        ):
            StockLedgerEntry.objects.create(
                variant=self.variant,
                warehouse_id=self.warehouse_id,
                posting_at=self._at(days_ago),
                quantity_change=Decimal(quantity),
                valuation_rate=Decimal("2.00"),
                value_change=Decimal(value),
                balance_quantity=Decimal(balance[0]),
                balance_value=Decimal(balance[1]),
            )
        StockValuationBin.objects.create(
            variant=self.variant,
            warehouse_id=self.warehouse_id,
            quantity=Decimal("6"),
            valuation_rate=Decimal("2.00"),
            stock_value=Decimal("12.00"),
        )

    def _money(self):
        """The seeded cash box, opened with 100; the owner adds 40 and takes 15."""
        self.cash = MoneyAccount.objects.get(kind=MoneyAccount.Kind.CASH)
        self.cash.opening_balance = Decimal("100.00")
        self.cash.opening_at = self.today - timedelta(days=60)
        self.cash.save()
        MoneyTransfer.objects.create(
            to_account=self.cash,
            amount=Decimal("40.00"),
            moved_at=self.today - timedelta(days=3),
        )
        MoneyTransfer.objects.create(
            from_account=self.cash,
            amount=Decimal("15.00"),
            moved_at=self.today - timedelta(days=1),
        )

    def _customer_debt(self):
        """A 70.00 credit sale, 20.00 paid in cash at the counter."""
        session = RegisterSession.objects.create(
            owner=self.manager,
            owner_key=f"user:{self.manager.pk}",
            opening_cash=Decimal("0.00"),
        )
        order = Order.objects.create(
            register_session=session,
            customer=Customer.objects.create(full_name="زبون آجل"),
            sale_type=Order.SaleType.CREDIT,
            status=Order.Status.OPEN,
            subtotal=Decimal("70.00"),
            total=Decimal("70.00"),
        )
        Order.objects.filter(pk=order.pk).update(created_at=self._at(20))
        Payment.objects.create(
            order=order,
            method=Payment.Method.CASH,
            amount=Decimal("20.00"),
            paid_at=self._at(20),
        )

    def _supplier_debt(self):
        """An 80.00 order, 30.00 of it paid on account inside the period."""
        self.supplier = Supplier.objects.create(name="مورد")
        order = PurchaseOrder.objects.create(
            supplier=self.supplier,
            status=PurchaseOrder.Status.RECEIVED,
            subtotal=Decimal("80.00"),
            total=Decimal("80.00"),
        )
        PurchaseOrder.objects.filter(pk=order.pk).update(created_at=self._at(25))
        SupplierPayment.objects.create(
            supplier=self.supplier,
            method=SupplierPayment.Method.CASH,
            amount=Decimal("30.00"),
            paid_at=self._at(3),
        )

    def _staff(self):
        """A 30.00 loan, and a wage run of 35.00 that withholds 10.00 of it.

        Approved twelve days ago and paid yesterday: owed in full at the
        opening, settled at the close — 25.00 in cash and 10.00 off the loan.
        """
        employee = Employee.objects.create(full_name="موظف")
        loan = EmployeeLoan.objects.create(
            employee=employee,
            status=EmployeeLoan.Status.APPROVED,
            amount=Decimal("30.00"),
            monthly_deduction=Decimal("10.00"),
            outstanding_balance=Decimal("20.00"),
            reviewed_at=self._at(20),
        )
        run = PayrollRun.objects.create(
            status=PayrollRun.Status.PAID,
            period_start=self.today - timedelta(days=40),
            period_end=self.today - timedelta(days=13),
            approved_at=self._at(12),
            payment_date=self.today - timedelta(days=1),
            paid_at=self._at(1),
            gross_total=Decimal("35.00"),
            deductions_total=Decimal("10.00"),
            net_total=Decimal("25.00"),
        )
        line = PayrollLine.objects.create(
            payroll_run=run,
            employee=employee,
            gross_amount=Decimal("35.00"),
            deductions_amount=Decimal("10.00"),
            net_amount=Decimal("25.00"),
        )
        PayrollAdjustment.objects.create(
            payroll_line=line,
            direction=PayrollAdjustment.Direction.DEDUCTION,
            adjustment_type=PayrollAdjustment.AdjustmentType.LOAN,
            amount=Decimal("10.00"),
            loan=loan,
        )
        EmployeeLoanPayment.objects.create(
            loan=loan, payroll_line=line, amount=Decimal("10.00"), paid_at=self._at(1)
        )

    # -- helpers -----------------------------------------------------------

    def _report(self, *, end=None, user=None):
        return generate_report_payload(
            report_type=Type.BALANCE_SHEET,
            params={
                "start_date": self.start.isoformat(),
                "end_date": (end or self.today).isoformat(),
            },
            user=user or self.manager,
        )

    def _section(self, payload, key):
        return next(s for s in payload["sections"] if s["key"] == key)

    def _lines(self, payload, key):
        return {row["line"]: row for row in self._section(payload, key)["rows"]}

    # -- the statement -----------------------------------------------------

    def test_what_the_shop_owned_at_both_ends_of_the_period(self):
        assets = self._lines(self._report(), "balance_assets")
        expected = {
            # line: (opening, closing)
            "stock_at_cost": ("20.00", "12.00"),
            "cash_and_bank": ("120.00", "90.00"),
            "customer_receivables": ("50.00", "50.00"),
            "employee_loans": ("30.00", "20.00"),
        }
        self.assertEqual(set(assets), set(expected))
        for line, (opening, closing) in expected.items():
            with self.subTest(line=line):
                self.assertEqual(assets[line]["opening_balance"], opening)
                self.assertEqual(assets[line]["closing_balance"], closing)

    def test_what_the_shop_owed_at_both_ends_of_the_period(self):
        liabilities = self._lines(self._report(), "balance_liabilities")
        # The supplier was paid 30.00 on account; the wage run was owed whole —
        # the 10.00 it withheld for the loan included — until it was paid.
        self.assertEqual(liabilities["supplier_payables"]["opening_balance"], "80.00")
        self.assertEqual(liabilities["supplier_payables"]["closing_balance"], "50.00")
        self.assertEqual(liabilities["employee_payables"]["opening_balance"], "35.00")
        self.assertEqual(liabilities["employee_payables"]["closing_balance"], "0.00")

    def test_each_side_foots_to_the_total_stated_for_it(self):
        payload = self._report()
        assets = self._section(payload, "balance_assets")["totals"]["shown"]
        liabilities = self._section(payload, "balance_liabilities")["totals"]["shown"]
        self.assertEqual((assets["opening_balance"], assets["closing_balance"]), ("220.00", "172.00"))
        self.assertEqual(
            (liabilities["opening_balance"], liabilities["closing_balance"]), ("115.00", "50.00")
        )
        net = self._lines(payload, "balance_net")
        self.assertEqual(net["net_position"]["opening_balance"], "105.00")
        self.assertEqual(net["net_position"]["closing_balance"], "122.00")
        self.assertEqual(net["net_position"]["change"], "17.00")
        summary = payload["summary"]
        self.assertEqual(summary["total_assets"], assets["closing_balance"])
        self.assertEqual(summary["total_liabilities"], liabilities["closing_balance"])
        self.assertEqual(summary["net_position"], "122.00")
        self.assertEqual(summary["opening_net_position"], "105.00")

    def test_the_change_is_explained_by_the_owner_and_by_trading(self):
        """The net-worth method: what the owner put in and took out is set
        aside, and what is left is what the business itself did — here, the
        four units that left the shelf at a cost of 8.00 with nothing sold."""
        payload = self._report()
        movement = self._lines(payload, "net_position_movement")
        self.assertEqual(movement["opening_net_position"]["amount"], "105.00")
        self.assertEqual(movement["outside_money_added"]["amount"], "40.00")
        self.assertEqual(movement["outside_money_withdrawn"]["amount"], "-15.00")
        self.assertEqual(movement["period_result"]["amount"], "-8.00")
        self.assertEqual(movement["closing_net_position"]["amount"], "122.00")
        self.assertEqual(payload["summary"]["period_result"], "-8.00")

    def test_paying_the_wages_did_not_change_what_the_shop_is_worth(self):
        """Yesterday alone: the run was paid, 25.00 in cash and 10.00 off the
        loan, and the owner took 15.00. None of it is trading, so the day's
        result is nothing. Counted net of the loan instalment, the wage run
        would have taken 10.00 off the shop's worth on the day it was paid."""
        yesterday = self.today - timedelta(days=1)
        payload = generate_report_payload(
            report_type=Type.BALANCE_SHEET,
            params={"start_date": yesterday.isoformat(), "end_date": yesterday.isoformat()},
            user=self.manager,
        )
        movement = self._lines(payload, "net_position_movement")
        self.assertEqual(movement["outside_money_withdrawn"]["amount"], "-15.00")
        self.assertEqual(movement["period_result"]["amount"], "0.00")

    # -- zakat -------------------------------------------------------------

    def test_zakat_values_the_goods_at_what_they_sell_for(self):
        payload = self._report()
        zakat = self._lines(payload, "zakat")
        # Six units on the shelf at 10.00, not at their 2.00 cost.
        self.assertEqual(zakat["stock_at_selling_price"]["amount"], "60.00")
        self.assertNotIn("stock_at_cost", zakat)
        self.assertEqual(zakat["zakat_assets_total"]["amount"], "220.00")
        self.assertEqual(zakat["zakat_liabilities"]["amount"], "-50.00")
        self.assertEqual(zakat["zakat_base"]["amount"], "170.00")
        self.assertEqual(zakat["zakat_due"]["amount"], "4.25")
        self.assertEqual(payload["summary"]["zakat_due"], "4.25")
        self.assertEqual(payload["summary"]["zakat_base"], "170.00")

    def test_nothing_is_due_on_a_base_that_is_not_positive(self):
        big = PurchaseOrder.objects.create(
            supplier=self.supplier,
            status=PurchaseOrder.Status.RECEIVED,
            subtotal=Decimal("1000.00"),
            total=Decimal("1000.00"),
        )
        PurchaseOrder.objects.filter(pk=big.pk).update(created_at=self._at(2))
        payload = self._report()
        self.assertEqual(payload["summary"]["zakat_base"], "-830.00")
        self.assertEqual(payload["summary"]["zakat_due"], "0.00")

    def test_consigned_goods_are_not_the_shops_to_count(self):
        StockUnit.objects.create(
            variant=self.variant,
            warehouse_id=self.warehouse_id,
            code="CONSIGNED-1",
            status=StockUnit.Status.IN_STOCK,
            incoming_rate=Decimal("0"),
            is_consignment=True,
            acquired_at=self._at(4),
            in_stock_since=self._at(4),
        )
        # Six on the shelf, one of them somebody else's.
        self.assertEqual(stock_retail_value(), Decimal("50.00"))

    def test_a_variant_below_zero_holds_nothing_to_value(self):
        other = create_product_with_default_variant(
            sku="BS-2", name="كابل", unit_price=Decimal("5.00")
        ).default_variant
        StockValuationBin.objects.create(
            variant=other,
            warehouse_id=self.warehouse_id,
            quantity=Decimal("-3"),
            stock_value=Decimal("-6.00"),
        )
        self.assertEqual(stock_retail_value(), Decimal("60.00"))

    def test_a_past_period_says_its_goods_are_priced_today(self):
        """There is no price history, so a past quantity can only be valued
        at today's price — and the page has to say so."""
        live = {n["code"] for n in self._report()["notes"]}
        past = {n["code"] for n in self._report(end=self.today - timedelta(days=1))["notes"]}
        self.assertNotIn("zakat_prices_today", live)
        self.assertIn("zakat_prices_today", past)

    # -- the page ----------------------------------------------------------

    def test_lines_the_shop_has_nothing_on_stay_off_the_page(self):
        payload = self._report()
        assets = self._lines(payload, "balance_assets")
        liabilities = self._lines(payload, "balance_liabilities")
        for line in ("provider_float", "supplier_credits", "consignor_advances"):
            self.assertNotIn(line, assets)
        self.assertNotIn("consignor_payables", liabilities)

    def test_every_line_agrees_with_the_report_that_owns_it(self):
        """Nothing is re-derived: each closing figure is the one its own report
        states for the same day."""
        params = {"start_date": self.start.isoformat(), "end_date": self.today.isoformat()}

        def summary(report_type):
            return generate_report_payload(
                report_type=report_type, params=params, user=self.manager
            )["summary"]

        assets = self._lines(self._report(), "balance_assets")
        liabilities = self._lines(self._report(), "balance_liabilities")
        self.assertEqual(
            assets["stock_at_cost"]["closing_balance"],
            summary(Type.INVENTORY_STATUS)["cost_stock_value"],
        )
        self.assertEqual(
            assets["cash_and_bank"]["closing_balance"],
            summary(Type.CASH_POSITION)["closing_total"],
        )
        self.assertEqual(
            assets["customer_receivables"]["closing_balance"],
            summary(Type.RECEIVABLES_AGING)["receivable_total"],
        )
        self.assertEqual(
            liabilities["supplier_payables"]["closing_balance"],
            summary(Type.PAYABLES_AGING)["payable_total"],
        )
        self.supplier.refresh_from_db()
        self.assertEqual(
            liabilities["supplier_payables"]["closing_balance"],
            str(self.supplier.payable_balance),
        )

    def test_only_the_reporting_roles_may_see_the_whole_shop(self):
        User = get_user_model()
        accountant = User.objects.create_user(username="bs-accountant", password="p")
        accountant.groups.add(Group.objects.get(name=ACCOUNTANT_GROUP))
        cashier = User.objects.create_user(username="bs-cashier", password="p")
        cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))

        self.assertEqual(self._report(user=accountant)["summary"]["net_position"], "122.00")
        with self.assertRaises(ReportAccessDenied):
            self._report(user=cashier)
