"""Figures a report stated wrongly, each pinned to the scenario that showed it.

Found by reading every builder against the documents it reads — not by a
failing screen — so each test below states the arithmetic a reader would do
with the printed page, and fails the way that reader would have.
"""

from datetime import timedelta
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.core.cache import cache
from django.test import TestCase, override_settings
from django.urls import reverse
from django.utils import timezone
from rest_framework import status
from rest_framework.test import APIClient

from apps.catalog.testing import create_product_with_default_variant
from apps.core.models import ShopSettings
from apps.core.roles import MANAGER_GROUP, ensure_role_groups
from apps.core.timeutils import business_timezone
from apps.documents.statuses import DocumentStatus
from apps.employees.models import Employee, PayrollLine, PayrollRun
from apps.inventory.models import StockItem, StockMovement, Warehouse
from apps.inventory.opening_balance import open_stock_balance
from apps.payments.models import Payment
from apps.purchasing.models import (
    PurchaseOrder,
    Supplier,
    SupplierCredit,
    SupplierPayment,
)
from apps.sales.models import Order, OrderLine, RegisterSession
from apps.treasury.models import MoneyAccount
from apps.treasury.position import treasury_position

from .models import ReportRun
from .registry import ReportValidationError
from .sections import decimal_from, quantity
from .services import generate_report_payload

Type = ReportRun.ReportType


def _section(payload, key):
    return next(section for section in payload["sections"] if section["key"] == key)


class ReportTestCase(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.manager = get_user_model().objects.create_user(
            username="correctness-manager", password="pass"
        )
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.today = timezone.localdate()

    def report(self, report_type, granularity="detailed", **params):
        params.setdefault("start_date", self.today.isoformat())
        params.setdefault("end_date", self.today.isoformat())
        return generate_report_payload(
            report_type=report_type,
            params={"granularity": granularity, **params},
            user=self.manager,
        )


@override_settings(
    CACHES={
        "default": {
            "BACKEND": "django.core.cache.backends.locmem.LocMemCache",
            "LOCATION": "report-correctness-tests",
        }
    }
)
class SalesFiguresTests(ReportTestCase):
    def setUp(self):
        super().setUp()
        cache.clear()
        self.client = APIClient()
        self.client.force_authenticate(user=self.manager)
        self.client.post(
            reverse("register-session-start"), {"opening_cash": "0.00"}, format="json"
        )

    def _variant(self, sku, price):
        product = create_product_with_default_variant(
            sku=sku, barcode="", name=f"صنف {sku}", unit_price=Decimal(price)
        )
        StockItem.objects.create(
            variant=product.default_variant, quantity_on_hand=Decimal("100")
        )
        return product.default_variant

    def _sell(self, variant, quantity, unit_cost):
        response = self.client.post(
            reverse("order-checkout"),
            {"lines": [{"variant": variant.pk, "quantity": str(quantity)}]},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        OrderLine.objects.filter(order_id=response.data["id"]).update(
            unit_cost=Decimal(unit_cost)
        )
        return response.data["id"], response.data["lines"][0]["id"]

    def _void(self, order_id):
        response = self.client.post(
            reverse("order-void", args=[order_id]), {"reason": "test"}, format="json"
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)

    def _return(self, order_id, line_id, quantity):
        response = self.client.post(
            reverse("order-return-items", args=[order_id]),
            {"reason": "test", "lines": [{"line": line_id, "quantity": quantity}]},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)

    def test_cost_of_sales_is_the_cost_of_what_stayed_sold(self):
        """Two units at 50 (cost 30), one returned. Stated gross, the page read
        net sales 50, cost of sales 60, gross profit 20."""
        variant = self._variant("COS-1", "50.00")
        order_id, line_id = self._sell(variant, 2, "30.00")
        self._return(order_id, line_id, 1)

        summary = self.report(Type.SALES_SUMMARY)["summary"]
        self.assertEqual(summary["net_sales"], "50.00")
        self.assertEqual(summary["cost_of_sales"], "30.00")
        self.assertEqual(summary["gross_profit"], "20.00")

        statement = {
            row["line"]: row["amount"]
            for row in _section(self.report(Type.PROFIT_COSTS), "profit_statement")["rows"]
        }
        self.assertEqual(statement["cost_of_sales"], "-30.00")
        self.assertEqual(
            decimal_from(statement["net_sales"]) + decimal_from(statement["cost_of_sales"]),
            decimal_from(statement["gross_profit"]),
        )

    def test_a_void_is_one_void_and_no_return(self):
        variant = self._variant("VOID-1", "100.00")
        order_id, _line = self._sell(variant, 1, "60.00")
        self._void(order_id)

        audit = self.report(Type.DISCOUNT_AUDIT)
        self.assertEqual(audit["summary"]["void_count"], 1)
        self.assertEqual(audit["summary"]["void_total"], "100.00")
        self.assertEqual(audit["summary"]["refund_count"], 0)
        self.assertEqual(audit["summary"]["refund_total"], "0.00")
        listed = _section(audit, "voids_and_refunds")
        self.assertEqual([row["kind"] for row in listed["rows"]], ["void"])
        self.assertEqual(listed["totals"]["full"]["amount"], "100.00")

    def test_a_sale_returned_in_full_is_a_return_not_a_void(self):
        """A full return leaves the order VOID too, and was counted as a void
        it never was."""
        variant = self._variant("RET-1", "40.00")
        order_id, line_id = self._sell(variant, 1, "10.00")
        self._return(order_id, line_id, 1)

        audit = self.report(Type.DISCOUNT_AUDIT)["summary"]
        self.assertEqual(audit["void_count"], 0)
        self.assertEqual(audit["refund_count"], 1)
        sales = self.report(Type.SALES_SUMMARY)["summary"]
        self.assertEqual(sales["voided_order_count"], 0)
        self.assertEqual(sales["return_count"], 1)

    def test_hours_are_net_of_voids_and_on_the_shop_clock(self):
        variant = self._variant("HOUR-1", "1000.00")
        voided, _line = self._sell(variant, 1, "1.00")
        self._void(voided)
        kept, _line = self._sell(self._variant("HOUR-2", "50.00"), 1, "1.00")

        payload = self.report(Type.SALES_BY_STAFF)
        hours = _section(payload, "sales_by_hour")
        self.assertEqual(hours["totals"]["full"]["net_sales"], payload["summary"]["net_sales"])
        self.assertEqual(payload["summary"]["net_sales"], "50.00")
        self.assertEqual(payload["summary"]["order_count"], 1)
        self.assertEqual(payload["summary"]["average_sale"], "50.00")
        sold_at = Order.objects.get(pk=kept).created_at.astimezone(business_timezone())
        self.assertEqual(payload["summary"]["busiest_hour"], f"{sold_at.hour:02d}:00")

    def test_credit_sales_are_the_credit_invoices_issued(self):
        """Filtered on "still open", September's credit sales fell every time a
        September invoice was collected."""
        session = RegisterSession.objects.get(owner=self.manager)
        for status_ in (Order.Status.OPEN, Order.Status.PAID):
            Order.objects.create(
                register_session=session,
                sale_type=Order.SaleType.CREDIT,
                status=status_,
                subtotal=Decimal("70.00"),
                total=Decimal("70.00"),
            )
        summary = self.report(Type.SALES_SUMMARY)["summary"]
        self.assertEqual(summary["credit_sales_total"], "140.00")
        self.assertEqual(summary["credit_order_count"], 2)

    def test_last_months_sale_returned_this_month_is_in_this_months_margins(self):
        """Dropped from the margin report because the product sold nothing this
        period, it left the report stating more profit than the sales
        summary."""
        returned = self._variant("BACK-1", "100.00")
        order_id, line_id = self._sell(returned, 1, "60.00")
        Order.objects.filter(pk=order_id).update(
            created_at=timezone.now() - timedelta(days=40)
        )
        self._return(order_id, line_id, 1)
        self._sell(self._variant("NOW-1", "50.00"), 1, "30.00")

        margin = self.report(Type.PRODUCT_MARGIN)
        sales = self.report(Type.SALES_SUMMARY)["summary"]
        self.assertEqual(margin["summary"]["revenue_total"], sales["net_sales"])
        self.assertEqual(margin["summary"]["profit_total"], sales["gross_profit"])
        self.assertEqual(margin["summary"]["loss_making_count"], 1)
        names = [row["product_name"] for row in _section(margin, "margin_losses")["rows"]]
        self.assertEqual(names, ["صنف BACK-1"])


class StockFiguresTests(ReportTestCase):
    def _variant(self, sku):
        return create_product_with_default_variant(
            sku=sku, barcode="", name=f"صنف {sku}", unit_price=Decimal("10.00")
        ).default_variant

    def test_a_quantity_prints_as_digits(self):
        """``normalize()`` alone printed forty as 4E+1."""
        self.assertEqual(quantity(Decimal("40")), "40")
        self.assertEqual(quantity(Decimal("1200.000")), "1200")
        self.assertEqual(quantity(Decimal("2.500")), "2.5")
        self.assertEqual(quantity(Decimal("-0.0001")), "0")

    def test_the_reorder_list_is_what_the_shop_restocks(self):
        wanted = self._variant("RE-1")
        StockItem.objects.create(variant=wanted, quantity_on_hand=0, reorder_level=5)
        transit = Warehouse.objects.get(pk=Warehouse.transit_id())
        StockItem.objects.create(variant=wanted, warehouse=transit, reorder_level=5)
        closed = Warehouse.objects.create(name="مخزن مغلق", code="closed", is_active=False)
        StockItem.objects.create(variant=self._variant("RE-2"), warehouse=closed)
        archived = self._variant("RE-3")
        archived.product.archived_at = timezone.now()
        archived.product.save(update_fields=["archived_at"])
        StockItem.objects.create(variant=archived)
        service = self._variant("RE-4")
        service.product.is_service = True
        service.product.save(update_fields=["is_service"])
        StockItem.objects.create(variant=service)

        payload = self.report(Type.REORDER_ITEMS, granularity="summary")
        self.assertEqual(payload["summary"]["reorder_item_count"], 1)
        self.assertEqual(payload["summary"]["out_of_stock_count"], 1)
        self.assertEqual(payload["summary"]["suggested_units"], "10")
        self.assertEqual(
            [row["product_name"] for row in _section(payload, "reorder_items")["rows"]],
            [wanted.full_name],
        )

    def test_the_stock_schedule_is_one_line_per_variant(self):
        """A variant in two places printed twice, each line carrying its whole
        cost, so the column added up to twice the stock."""
        variant = self._variant("WH-1")
        store = Warehouse.objects.create(
            name="المخزن", code="store", kind=Warehouse.Kind.STORE_ROOM
        )
        open_stock_balance(variant=variant, quantity=Decimal("10"), unit_cost=Decimal("8"))
        open_stock_balance(
            variant=variant, quantity=Decimal("30"), unit_cost=Decimal("8"), warehouse=store
        )

        payload = self.report(Type.INVENTORY_STATUS)
        items = _section(payload, "inventory_items")
        self.assertEqual(len(items["rows"]), 1)
        self.assertEqual(items["rows"][0]["quantity_on_hand"], "40")
        self.assertEqual(items["rows"][0]["unit_cost"], "8.00")
        self.assertEqual(items["totals"]["shown"]["cost_value"], "320.00")
        self.assertEqual(payload["summary"]["cost_stock_value"], "320.00")

    def test_a_past_stock_report_states_no_live_counts(self):
        payload = self.report(
            Type.INVENTORY_STATUS,
            start_date=(self.today - timedelta(days=40)).isoformat(),
            end_date=(self.today - timedelta(days=10)).isoformat(),
        )
        for live in ("low_stock_count", "out_of_stock_count", "retail_stock_value"):
            self.assertNotIn(live, payload["summary"])

    def test_quantity_moved_is_what_moved_on_or_off_a_shelf(self):
        """Stock merely ordered moves nothing; summed off the movement's own
        quantity, a 10-unit order received read as 20."""
        variant = self._variant("MOVE-1")
        item = StockItem.objects.create(variant=variant, quantity_on_hand=10)
        for movement_type, before, after in (
            (StockMovement.Type.EXPECTED, 0, 0),
            (StockMovement.Type.RECEIVE_EXPECTED, 0, 10),
        ):
            StockMovement.objects.create(
                variant=variant,
                stock_item=item,
                movement_type=movement_type,
                quantity=10,
                on_hand_before=before,
                on_hand_after=after,
                committed_before=0,
                committed_after=0,
                expected_before=0,
                expected_after=0,
            )
        summary = self.report(Type.STOCK_MOVEMENTS)["summary"]
        self.assertEqual(summary["movement_count"], 2)
        self.assertEqual(summary["quantity_moved"], "10")


class MoneyFiguresTests(ReportTestCase):
    def setUp(self):
        super().setUp()
        self.session = RegisterSession.objects.create(
            owner=self.manager,
            owner_key=f"user:{self.manager.pk}",
            opening_cash=Decimal("0.00"),
        )

    def _cash_sale(self, amount, *, paid_at):
        order = Order.objects.create(
            register_session=self.session,
            status=Order.Status.PAID,
            subtotal=Decimal(amount),
            total=Decimal(amount),
        )
        return Payment.objects.create(
            order=order, method=Payment.Method.CASH, amount=Decimal(amount), paid_at=paid_at
        )

    def test_the_cash_statement_starts_at_the_accounts_opening(self):
        """Money taken before the box was opened in Pointy is inside its
        opening balance; replayed as well, a shop that upgraded mid-month
        closed the month with that half-month counted twice."""
        start = self.today - timedelta(days=20)
        cash = MoneyAccount.objects.get(kind=MoneyAccount.Kind.CASH)
        cash.opening_balance = Decimal("3000.00")
        cash.opening_at = self.today - timedelta(days=5)
        cash.save(update_fields=["opening_balance", "opening_at"])
        noon = timezone.now().replace(hour=12)
        self._cash_sale("4000.00", paid_at=noon - timedelta(days=10))
        self._cash_sale("2500.00", paid_at=noon - timedelta(days=2))

        payload = self.report(
            Type.CASH_POSITION, start_date=start.isoformat(), end_date=self.today.isoformat()
        )
        self.assertEqual(
            payload["summary"]["closing_total"],
            str(treasury_position(as_of=self.today)["totals"]["total"]),
        )

    def test_a_provider_float_sits_beside_the_cash_not_inside_it(self):
        MoneyAccount.objects.create(
            name="LNET", kind=MoneyAccount.Kind.PROVIDER, opening_balance=Decimal("2000.00")
        )
        payload = self.report(Type.CASH_POSITION, granularity="summary")
        self.assertEqual(
            payload["summary"]["closing_total"],
            str(treasury_position()["totals"]["total"]),
        )
        self.assertEqual(payload["summary"]["provider_float"], "2000.00")
        self.assertEqual(
            _section(payload, "account_balances")["totals"]["shown"]["closing_balance"],
            payload["summary"]["closing_total"],
        )
        floats = _section(payload, "provider_float")
        self.assertEqual(floats["totals"]["shown"]["closing_balance"], "2000.00")

    def test_a_payment_given_back_is_not_a_payment_taken(self):
        """One card payment taken and then cancelled was two payments that came
        to nothing."""
        noon = timezone.now()
        kept = self._cash_sale("30.00", paid_at=noon)
        cancelled = self._cash_sale("50.00", paid_at=noon)
        Payment.objects.create(
            order=cancelled.order,
            method=Payment.Method.CASH,
            amount=Decimal("-50.00"),
            paid_at=noon,
            reverses=cancelled,
        )
        Payment.objects.filter(pk=cancelled.pk).update(doc_status=DocumentStatus.CANCELLED)

        payload = self.report(Type.PAYMENT_METHODS, granularity="summary")
        self.assertEqual(payload["summary"]["payment_total"], "30.00")
        self.assertEqual(payload["summary"]["payment_count"], 1)
        self.assertTrue(kept.pk)

    def test_the_comparison_column_states_the_earlier_payments(self):
        """Summed from the rows of a table the comparison pass never builds,
        every previous period read 0.00."""
        self._cash_sale("80.00", paid_at=timezone.now() - timedelta(days=1))
        payload = generate_report_payload(
            report_type=Type.PAYMENT_METHODS,
            params={"preset": "today", "comparison": "previous_period"},
            user=self.manager,
        )
        self.assertEqual(payload["previous_summary"]["payment_total"], "80.00")

    def test_an_open_drawer_has_no_variance_yet(self):
        row = _section(self.report(Type.REGISTER_CLOSURE), "register_sessions")["rows"][0]
        self.assertEqual(row["status"], RegisterSession.Status.OPEN)
        self.assertEqual(row["closing_cash"], "")
        self.assertEqual(row["cash_variance"], "")

    def test_a_negative_deduction_prints_once_signed(self):
        """Prefixed as text, a deduction that went the other way printed
        ``--100.00``: here customers paid down more debt than they ran up, so
        what they owe *fell*."""
        from apps.customers.models import Customer

        invoice = Order.objects.create(
            register_session=self.session,
            customer=Customer.objects.create(full_name="مدين قديم"),
            sale_type=Order.SaleType.CREDIT,
            status=Order.Status.OPEN,
            subtotal=Decimal("100.00"),
            total=Decimal("100.00"),
        )
        Order.objects.filter(pk=invoice.pk).update(
            created_at=timezone.now() - timedelta(days=10)
        )
        Payment.objects.create(
            order=invoice,
            method=Payment.Method.CASH,
            amount=Decimal("100.00"),
            paid_at=timezone.now(),
        )

        bridge = {
            row["line"]: row["amount"]
            for row in _section(self.report(Type.PROFIT_COSTS), "cash_bridge")["rows"]
        }
        self.assertEqual(bridge["movement_in_receivables"], "100.00")
        self.assertEqual(bridge["unreconciled_difference"], "0.00")


class PurchasingFiguresTests(ReportTestCase):
    def setUp(self):
        super().setUp()
        self.supplier = Supplier.objects.create(name="مورد الأرقام")

    def _order(self, status_, total, **fields):
        return PurchaseOrder.objects.create(
            supplier=self.supplier,
            status=status_,
            subtotal=Decimal(total),
            total=Decimal(total),
            **fields,
        )

    def test_a_draft_is_not_a_purchase(self):
        self._order(PurchaseOrder.Status.DRAFT, "500.00")
        self._order(PurchaseOrder.Status.RECEIVED, "300.00", cancelled_total=Decimal("20.00"))

        summary = self.report(Type.PURCHASING_SUMMARY, granularity="summary")["summary"]
        self.assertEqual(summary["purchase_total"], "280.00")
        self.assertEqual(summary["purchase_order_count"], 1)
        profit = self.report(Type.PROFIT_COSTS, granularity="summary")["summary"]
        self.assertEqual(profit["purchase_spend_total"], "280.00")

    def test_paid_to_suppliers_is_money_that_left(self):
        order = self._order(PurchaseOrder.Status.RECEIVED, "300.00")
        for method, amount in (
            (SupplierPayment.Method.CASH, "100.00"),
            (SupplierPayment.Method.SUPPLIER_CREDIT, "50.00"),
        ):
            SupplierPayment.objects.create(
                supplier=self.supplier,
                purchase_order=order,
                method=method,
                amount=Decimal(amount),
            )
        summary = self.report(Type.PURCHASING_SUMMARY, granularity="summary")["summary"]
        self.assertEqual(summary["supplier_paid_total"], "100.00")

    def test_each_statement_figure_counts_one_kind_of_line(self):
        """Summed as whole columns, the purchases figure took in what the
        supplier refunded and the paid figure the goods sent back — and the
        paid figure was headed «الرواتب المصروفة»."""
        order = self._order(PurchaseOrder.Status.RECEIVED, "300.00")
        SupplierPayment.objects.create(
            supplier=self.supplier,
            purchase_order=order,
            method=SupplierPayment.Method.CASH,
            amount=Decimal("100.00"),
        )
        SupplierCredit.objects.create(
            supplier=self.supplier,
            purchase_order=order,
            amount=Decimal("50.00"),
            remaining_amount=Decimal("50.00"),
        )
        summary = self.report(
            Type.SUPPLIER_STATEMENT, supplier_id=self.supplier.pk
        )["summary"]
        self.assertEqual(summary["invoiced_total"], "300.00")
        self.assertEqual(summary["returned_total"], "50.00")
        self.assertEqual(summary["paid_to_supplier_total"], "100.00")
        self.assertNotIn("paid_total", summary)
        self.assertEqual(
            decimal_from(summary["opening_balance"])
            + decimal_from(summary["account_entries_total"])
            + decimal_from(summary["invoiced_total"])
            - decimal_from(summary["returned_total"])
            - decimal_from(summary["paid_to_supplier_total"]),
            decimal_from(summary["closing_balance"]),
        )


class BalanceSheetFiguresTests(ReportTestCase):
    def test_opening_stock_is_brought_onto_the_books_not_earned(self):
        """A shop that typed in its stock on its first day read that stock as
        the period's profit."""
        open_stock_balance(
            variant=create_product_with_default_variant(
                sku="OPEN-1", barcode="", name="بضاعة", unit_price=Decimal("20")
            ).default_variant,
            quantity=Decimal("10"),
            unit_cost=Decimal("15"),
        )
        payload = self.report(Type.BALANCE_SHEET)
        self.assertEqual(payload["summary"]["net_position_change"], "150.00")
        self.assertEqual(payload["summary"]["period_result"], "0.00")
        movement = {
            row["line"]: row["amount"]
            for row in _section(payload, "net_position_movement")["rows"]
        }
        self.assertEqual(movement["opening_balances_recorded"], "150.00")


class PayrollFiguresTests(ReportTestCase):
    def _run(self, status_, employee, net):
        run = PayrollRun.objects.create(
            status=status_, period_start=self.today, period_end=self.today
        )
        PayrollLine.objects.create(
            payroll_run=run,
            employee=employee,
            rate=Decimal(net),
            gross_amount=Decimal(net),
            net_amount=Decimal(net),
        )
        return run

    def test_the_employee_table_is_the_agreed_wages_per_employee(self):
        first = Employee.objects.create(full_name="أحمد")
        namesake = Employee.objects.create(full_name="أحمد")
        self._run(PayrollRun.Status.APPROVED, first, "500.00")
        self._run(PayrollRun.Status.APPROVED, namesake, "300.00")
        self._run(PayrollRun.Status.DRAFT, first, "900.00")

        table = _section(
            self.report(Type.PAYROLL_SUMMARY, granularity="summary"), "employee_totals"
        )
        self.assertEqual(
            sorted(row["net_total"] for row in table["rows"]), ["300.00", "500.00"]
        )
        self.assertEqual(table["totals"]["full"]["net_total"], "800.00")


class PackAndVerifyTests(ReportTestCase):
    def test_the_pack_carries_what_qualifies_its_parts(self):
        codes = {
            note["code"]
            for note in self.report(Type.MONTH_END_PACK, granularity="summary")["notes"]
        }
        self.assertIn("basis_accrual", codes)
        self.assertIn("stock_as_of", codes)
        self.assertIn("receivables_as_of", codes)

    def _run_and_verify(self, *, created_days_ago=0, lock_after=False):
        client = APIClient()
        client.force_authenticate(user=self.manager)
        response = client.post(
            reverse("report-list"),
            {
                "report_type": Type.SALES_SUMMARY,
                "output_format": ReportRun.OutputFormat.JSON,
                "params": {"preset": "last_month", "comparison": "none"},
            },
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        run = ReportRun.objects.get(pk=response.data["id"])
        if created_days_ago:
            # As if it had been run back then: its stored period is the month
            # before *that* day.
            run.created_at = timezone.now() - timedelta(days=created_days_ago)
            run.payload = generate_report_payload(
                report_type=run.report_type,
                params=run.params,
                user=self.manager,
                period_today=timezone.localdate(run.created_at),
            )
            from .services import report_figures_checksum

            run.figures_checksum = report_figures_checksum(run.payload)
            run.save(update_fields=["created_at", "payload", "figures_checksum"])
        if lock_after:
            settings = ShopSettings.load()
            settings.books_locked_through = self.today
            settings.save(update_fields=["books_locked_through"])
        return client.post(reverse("report-verify", args=[run.pk])).data

    def test_verifying_last_months_run_rebuilds_that_month(self):
        """Resolved against today, "last month" verified in November compared
        September with October and reported every figure as changed."""
        self.assertTrue(self._run_and_verify(created_days_ago=45)["matches"])

    def test_closing_the_books_after_a_run_is_not_a_change(self):
        """The ordinary close — run September, then lock it — read as changed
        figures, because the rebuilt report says "closed" where the run said
        "open"."""
        self.assertTrue(self._run_and_verify(lock_after=True)["matches"])


class IdentifiedFiguresTests(ReportTestCase):
    def test_a_code_of_separators_names_no_article(self):
        """It normalised to nothing, and nothing matched every article without
        a second code."""
        with self.assertRaises(ReportValidationError):
            self.report(Type.UNIT_LEDGER, code="-")
