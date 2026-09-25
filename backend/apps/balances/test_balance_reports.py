"""The reports read the balances too — and still add up.

Every report here states a position a person can check by hand: a statement's
closing figure is what the party owes today, an aging's total is the balance
sheet's line, and the profit report's cash bridge closes to nothing left
unexplained. An entry that one of them forgot would show as exactly one of
those failing.
"""

from datetime import datetime, time, timedelta
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.utils import timezone

from apps.core.models import ShopSettings
from apps.core.roles import MANAGER_GROUP, ensure_role_groups
from apps.customers.models import Customer
from apps.customers.receivables import customer_balance
from apps.documents.guards import system_write
from apps.payments.models import Payment
from apps.purchasing.models import PurchaseOrder, Supplier, SupplierPayment
from apps.reports.models import ReportRun
from apps.reports.services import generate_report_payload
from apps.sales.models import Order, RegisterSession
from apps.sales.services import record_customer_account_payment

from .customers import apply_customer_credit, create_customer_entry
from .models import BalanceEntry
from .suppliers import create_supplier_entry, record_supplier_account_payment

Type = ReportRun.ReportType
Kind = BalanceEntry.Kind
Direction = BalanceEntry.Direction


class _ReportCase(TestCase):
    def setUp(self):
        ensure_role_groups()
        ShopSettings.load()
        self.manager = get_user_model().objects.create_user(
            username="rep-manager", password="p"
        )
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.today = timezone.localdate()
        self.session = RegisterSession.objects.create(
            owner=self.manager,
            owner_key=f"user:{self.manager.pk}",
            opening_cash=Decimal("0.00"),
        )

    def _at(self, days_ago):
        day = self.today - timedelta(days=days_ago)
        return timezone.make_aware(datetime.combine(day, time(12)))

    def _report(self, report_type, *, start, end=None, **params):
        return generate_report_payload(
            report_type=report_type,
            params={
                "start_date": start.isoformat(),
                "end_date": (end or self.today).isoformat(),
                **params,
            },
            user=self.manager,
        )

    @staticmethod
    def _section(payload, key):
        return next(s for s in payload["sections"] if s["key"] == key)

    def _lines(self, payload, key):
        return {row["line"]: row for row in self._section(payload, key)["rows"]}


class CustomerReportTests(_ReportCase):
    """A customer carried in owing 1,000 from the paper ledger, sixty days
    ago; sold 200 on آجل twenty days ago; given 150 of credit (a refund owed)
    ten days ago; paid 300 in cash five days ago.

    Net today: 1,000 + 200 − 150 − 300 = 750.
    """

    def setUp(self):
        super().setUp()
        self.customer = Customer.objects.create(full_name="زبون الكشف")
        create_customer_entry(
            customer=self.customer,
            kind=Kind.OPENING,
            direction=Direction.THEY_OWE_US,
            amount=Decimal("1000.00"),
            effective_date=self.today - timedelta(days=60),
            actor=self.manager,
        )
        self.invoice = Order.objects.create(
            register_session=self.session,
            customer=self.customer,
            sale_type=Order.SaleType.CREDIT,
            status=Order.Status.OPEN,
            subtotal=Decimal("200.00"),
            total=Decimal("200.00"),
        )
        from apps.sales.testing import issue

        issue(self.invoice, status=Order.Status.OPEN)
        Order.objects.filter(pk=self.invoice.pk).update(created_at=self._at(20))
        create_customer_entry(
            customer=self.customer,
            kind=Kind.ADJUSTMENT,
            direction=Direction.WE_OWE_THEM,
            amount=Decimal("150.00"),
            effective_date=self.today - timedelta(days=10),
            note="مبلغ مسترد مستحق",
            actor=self.manager,
        )
        record_customer_account_payment(
            self.customer,
            method=Payment.Method.CASH,
            amount=Decimal("300.00"),
            register_session=self.session,
        )
        # Giving a submitted payment a past is a fixture's job, not a user's.
        with system_write():
            Payment.objects.filter(method=Payment.Method.CASH).update(
                paid_at=self._at(5)
            )

    def test_the_account_nets_to_what_is_owed(self):
        balance = customer_balance(self.customer)
        self.assertEqual(balance.net, Decimal("750.00"))
        self.assertEqual(balance.unapplied_credit, Decimal("0.00"))

    def test_the_statement_closes_on_the_same_figure(self):
        payload = self._report(
            Type.CUSTOMER_STATEMENT,
            start=self.today - timedelta(days=90),
            customer_id=self.customer.pk,
        )

        summary = payload["summary"]
        self.assertEqual(summary["opening_balance"], "0.00")
        self.assertEqual(summary["closing_balance"], "750.00")
        # The header adds up: 0 + (1,000 − 150) + 200 − 0 − 300 + 0 = 750.
        self.assertEqual(summary["account_entries_total"], "850.00")
        self.assertEqual(summary["invoiced_total"], "200.00")
        self.assertEqual(summary["received_total"], "300.00")
        rows = self._section(payload, "statement_entries")["rows"]
        kinds = [row["kind"] for row in rows]
        self.assertEqual(
            kinds, ["opening_balance", "invoice", "balance_adjustment", "payment"]
        )
        # The credit is credited once, on its own day — not again when it was
        # spent against the invoice.
        self.assertNotIn(
            Payment.Method.ACCOUNT_CREDIT, [row["kind"] for row in rows]
        )
        self.assertEqual(rows[-1]["balance"], "750.00")

    def test_an_opening_balance_carried_into_a_later_period(self):
        payload = self._report(
            Type.CUSTOMER_STATEMENT,
            start=self.today - timedelta(days=30),
            customer_id=self.customer.pk,
        )
        self.assertEqual(payload["summary"]["opening_balance"], "1000.00")
        self.assertEqual(payload["summary"]["closing_balance"], "750.00")

    def test_the_aging_holds_what_is_still_owed(self):
        payload = self._report(Type.RECEIVABLES_AGING, start=self.today)
        # The credit and the collection settled the oldest debt first — 450 of
        # the opening balance — so 550 of it is still owed, and the invoice,
        # which neither reached, is owed whole.
        self.assertEqual(payload["summary"]["receivable_total"], "750.00")
        row = self._section(payload, "receivables_aging")["rows"][0]
        self.assertEqual(row["d31_60"], "550.00")
        self.assertEqual(row["d0_30"], "200.00")

    def test_the_balance_sheet_states_the_debt_and_keeps_the_opening_out_of_the_result(self):
        payload = self._report(Type.BALANCE_SHEET, start=self.today - timedelta(days=90))

        assets = self._lines(payload, "balance_assets")
        self.assertEqual(assets["customer_receivables"]["closing_balance"], "750.00")
        movement = self._lines(payload, "net_position_movement")
        # The 1,000 was the position the shop started from, not a profit.
        self.assertEqual(movement["opening_balances_recorded"]["amount"], "1000.00")

    def test_the_profit_reports_cash_bridge_still_closes(self):
        payload = self._report(Type.PROFIT_COSTS, start=self.today - timedelta(days=90))

        bridge = self._lines(payload, "cash_bridge")
        self.assertEqual(bridge["debts_recorded_on_account"]["amount"], "1000.00")
        self.assertEqual(bridge["settled_from_account_credit"]["amount"], "150.00")
        self.assertEqual(bridge["unreconciled_difference"]["amount"], "0.00")


class CustomerCreditOnTheBalanceSheetTests(_ReportCase):
    def test_credit_the_shop_still_owes_is_a_liability(self):
        customer = Customer.objects.create(full_name="زبون دائن")
        create_customer_entry(
            customer=customer,
            kind=Kind.OPENING,
            direction=Direction.WE_OWE_THEM,
            amount=Decimal("400.00"),
            effective_date=self.today - timedelta(days=3),
            actor=self.manager,
        )

        payload = self._report(Type.BALANCE_SHEET, start=self.today - timedelta(days=7))

        liabilities = self._lines(payload, "balance_liabilities")
        self.assertEqual(liabilities["customer_credits"]["opening_balance"], "0.00")
        self.assertEqual(liabilities["customer_credits"]["closing_balance"], "400.00")
        movement = self._lines(payload, "net_position_movement")
        self.assertEqual(movement["opening_balances_recorded"]["amount"], "-400.00")
        self.assertEqual(movement["period_result"]["amount"], "0.00")

    def test_an_adjustment_is_part_of_the_result(self):
        """A service nobody invoiced is money the shop earned."""
        customer = Customer.objects.create(full_name="خدمة")
        create_customer_entry(
            customer=customer,
            kind=Kind.ADJUSTMENT,
            direction=Direction.THEY_OWE_US,
            amount=Decimal("90.00"),
            note="صيانة خارج النظام",
            actor=self.manager,
        )

        payload = self._report(Type.BALANCE_SHEET, start=self.today - timedelta(days=7))

        movement = self._lines(payload, "net_position_movement")
        self.assertNotIn("opening_balances_recorded", movement)
        self.assertEqual(movement["period_result"]["amount"], "90.00")

    def test_spent_credit_leaves_the_liability(self):
        customer = Customer.objects.create(full_name="زبون")
        create_customer_entry(
            customer=customer,
            kind=Kind.OPENING,
            direction=Direction.WE_OWE_THEM,
            amount=Decimal("100.00"),
            actor=self.manager,
        )
        invoice = Order.objects.create(
            register_session=self.session,
            customer=customer,
            sale_type=Order.SaleType.CREDIT,
            status=Order.Status.OPEN,
            subtotal=Decimal("60.00"),
            total=Decimal("60.00"),
        )
        from apps.sales.testing import issue

        issue(invoice, status=Order.Status.OPEN)
        apply_customer_credit(customer, actor=self.manager)

        payload = self._report(Type.BALANCE_SHEET, start=self.today)

        liabilities = self._lines(payload, "balance_liabilities")
        self.assertEqual(liabilities["customer_credits"]["closing_balance"], "40.00")
        assets = self._lines(payload, "balance_assets")
        self.assertEqual(assets["customer_receivables"]["closing_balance"], "0.00")


class SupplierReportTests(_ReportCase):
    """A supplier the shop owed 1,000 from before (sixty days ago), who owes
    the shop 100 for goods sent back outside the system (thirty days ago);
    an order of 500 received twenty days ago; 600 paid on account ten days ago.

    Net today: 1,000 − 100 + 500 − 600 = 800.
    """

    def setUp(self):
        super().setUp()
        self.supplier = Supplier.objects.create(name="مورد الكشف")
        create_supplier_entry(
            supplier=self.supplier,
            kind=Kind.OPENING,
            direction=Direction.WE_OWE_THEM,
            amount=Decimal("1000.00"),
            effective_date=self.today - timedelta(days=60),
            actor=self.manager,
        )
        create_supplier_entry(
            supplier=self.supplier,
            kind=Kind.ADJUSTMENT,
            direction=Direction.THEY_OWE_US,
            amount=Decimal("100.00"),
            effective_date=self.today - timedelta(days=30),
            note="بضاعة مرتجعة قبل النظام",
            actor=self.manager,
        )
        order = PurchaseOrder.objects.create(
            supplier=self.supplier,
            status=PurchaseOrder.Status.RECEIVED,
            subtotal=Decimal("500.00"),
            total=Decimal("500.00"),
        )
        PurchaseOrder.objects.filter(pk=order.pk).update(created_at=self._at(20))
        record_supplier_account_payment(
            self.supplier,
            method=SupplierPayment.Method.CASH,
            amount=Decimal("600.00"),
            paid_at=self._at(10),
            created_by=self.manager,
        )

    def test_the_supplier_nets_to_what_is_owed(self):
        supplier = Supplier.objects.get(pk=self.supplier.pk)
        self.assertEqual(supplier.payable_balance, Decimal("900.00"))
        self.assertEqual(supplier.credit_balance, Decimal("100.00"))
        self.assertEqual(supplier.net_balance, Decimal("800.00"))

    def test_the_statement_closes_on_the_net_balance(self):
        payload = self._report(
            Type.SUPPLIER_STATEMENT,
            start=self.today - timedelta(days=90),
            supplier_id=self.supplier.pk,
        )
        self.assertEqual(payload["summary"]["closing_balance"], "800.00")
        kinds = [
            row["kind"] for row in self._section(payload, "statement_entries")["rows"]
        ]
        self.assertEqual(
            kinds, ["opening_balance", "balance_adjustment", "purchase", "cash"]
        )

    def test_the_payables_aging_matches_the_supplier(self):
        payload = self._report(Type.PAYABLES_AGING, start=self.today)
        # 600 on account paid the opening balance first, leaving 400 of it; the
        # order is untouched.
        self.assertEqual(payload["summary"]["payable_total"], "900.00")

    def test_the_balance_sheet_carries_both_sides(self):
        payload = self._report(Type.BALANCE_SHEET, start=self.today - timedelta(days=90))

        liabilities = self._lines(payload, "balance_liabilities")
        assets = self._lines(payload, "balance_assets")
        self.assertEqual(liabilities["supplier_payables"]["closing_balance"], "900.00")
        self.assertEqual(assets["supplier_credits"]["closing_balance"], "100.00")
        movement = self._lines(payload, "net_position_movement")
        self.assertEqual(movement["opening_balances_recorded"]["amount"], "-1000.00")
