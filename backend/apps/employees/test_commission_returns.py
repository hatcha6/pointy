"""Commission and the money that came back.

Both commission bases that read the sales ledger — a cashier's own sales, and a
technician's ``order_total`` repair invoices — are valued from ``Order.total``.
A void makes the whole sale disappear, so goods that come back earn no
commission; but a *partial* return leaves the order PAID and never touches
``Order.total``. These tests ask whether the rule the full return states still
holds when only part of the invoice is handed back.
"""

from datetime import date
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.utils import timezone

from apps.catalog.testing import create_product_with_default_variant
from apps.core.models import ShopSettings
from apps.core.roles import CASHIER_GROUP, ensure_role_groups
from apps.inventory.models import StockItem
from apps.payments.models import Payment
from apps.sales.models import Order, OrderAdjustment, RegisterSession
from apps.sales.services import checkout_order, return_order_items

from .models import CompensationPlan, Employee, PayrollAdjustment
from .services import draft_monthly_payroll_run


def draft_commission_for(employee):
    """Draft this month's payroll and return ``employee``'s commission line."""
    run, _ = draft_monthly_payroll_run(
        period_start=timezone.localdate().replace(day=1),
        period_end=timezone.localdate(),
    )
    adjustment = (
        PayrollAdjustment.objects.filter(
            payroll_line__payroll_run=run,
            payroll_line__employee=employee,
            adjustment_type=PayrollAdjustment.AdjustmentType.COMMISSION,
        )
        .order_by("id")
        .first()
    )
    return Decimal("0.00") if adjustment is None else adjustment.amount


class SalesCommissionReturnsTests(TestCase):
    """One cashier on 10% of sales, selling four units at 25.00 (=100.00)."""

    def setUp(self):
        ensure_role_groups()
        ShopSettings.load()
        User = get_user_model()
        self.cashier = User.objects.create_user(username="commission-cashier", password="pass")
        self.cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.employee = Employee.objects.create(
            full_name="كاشير عمولة المرتجعات",
            user=self.cashier,
        )
        CompensationPlan.objects.create(
            employee=self.employee,
            pay_type=CompensationPlan.PayType.MONTHLY_SALARY,
            salary_type=CompensationPlan.SalaryType.MONTHLY_FIXED_PLUS_SALES_COMMISSION,
            amount=Decimal("900.00"),
            commission_percent=Decimal("10.00"),
            effective_from=date(2020, 1, 1),
        )
        self.variant = create_product_with_default_variant(
            name="Kettle",
            sku="KETTLE",
            unit_price="25.00",
            barcode="",
        ).default_variant
        StockItem.objects.create(variant=self.variant, quantity_on_hand=Decimal("10"))
        self.session = RegisterSession.objects.create(
            owner=self.cashier,
            owner_key=f"user:{self.cashier.pk}",
        )

    def _sell(self, quantity):
        total = (Decimal("25.00") * Decimal(quantity)).quantize(Decimal("0.01"))
        return checkout_order(
            register_session=self.session,
            lines_data=[{"variant": self.variant, "quantity": Decimal(quantity)}],
            payments_data=[{"method": Payment.Method.CASH, "amount": total}],
        )

    def _draft_commission(self):
        return draft_commission_for(self.employee)

    def test_fully_returned_sale_earns_no_commission(self):
        """The whole basket comes back: the order voids and the commission goes."""
        order = self._sell("4")
        return_order_items(
            order=order,
            lines=[(order.lines.get(), Decimal("4"))],
            reason="All returned",
        )
        order.refresh_from_db()
        self.assertEqual(order.status, Order.Status.VOID)

        self.assertEqual(self._draft_commission(), Decimal("0.00"))

    def test_partially_returned_sale_earns_commission_only_on_what_was_kept(self):
        """One of four units comes back, so 25.00 of the 100.00 is not a sale.

        The shop kept 75.00, refunded 25.00 and restocked the unit, so the
        commissionable base is 75.00 and 10% of it is 7.50. Paying 10.00 would
        pay the cashier for goods sitting back on the shelf — and would make a
        99%-return earn full commission while a 100% return earns none.
        """
        order = self._sell("4")
        return_order_items(
            order=order,
            lines=[(order.lines.get(), Decimal("1"))],
            reason="One returned",
        )
        order.refresh_from_db()
        self.assertEqual(order.status, Order.Status.PAID)

        self.assertEqual(self._draft_commission(), Decimal("7.50"))


class OperationsCommissionInvoiceTests(TestCase):
    """A technician paid 5% of the *invoice* of the repairs they completed.

    ``order_total`` is the only operations base that reads the sales ledger, so
    it is the only one that can be told the customer never paid.
    """

    def setUp(self):
        ensure_role_groups()
        ShopSettings.load()
        self.employee = Employee.objects.create(full_name="فني الفاتورة الملغاة")
        CompensationPlan.objects.create(
            employee=self.employee,
            pay_type=CompensationPlan.PayType.COMMISSION,
            salary_type=CompensationPlan.SalaryType.OPERATIONS_COMMISSION_ONLY,
            amount=Decimal("0.00"),
            commission_percent=Decimal("5.00"),
            operations_commission_base=(
                CompensationPlan.OperationsCommissionBase.ORDER_TOTAL
            ),
            effective_from=date(2020, 1, 1),
        )

    def _completed_repair_invoiced(self, *, total, order_status=Order.Status.PAID):
        from apps.operations.models import Job, WorkflowTemplate

        template = WorkflowTemplate.objects.get(job_type="repair", is_system=True)
        job = Job.objects.create(
            job_type="repair",
            workflow_template=template,
            current_stage=template.stages.order_by("display_order").first(),
            status=Job.Status.COMPLETED,
            assigned_employee=self.employee,
            approved_price=Decimal(total),
        )
        order = Order.objects.create(
            status=order_status,
            subtotal=Decimal(total),
            total=Decimal(total),
        )
        Job.objects.filter(pk=job.pk).update(
            order=order, completed_at=timezone.now()
        )
        return order

    def _draft_commission(self):
        return draft_commission_for(self.employee)

    def test_voided_repair_invoice_earns_no_commission(self):
        """The invoice was cancelled, so there is no invoice total to pay on."""
        self._completed_repair_invoiced(total="300.00")
        self._completed_repair_invoiced(total="400.00", order_status=Order.Status.VOID)

        # Only the 300.00 invoice was collected: 5% of it is 15.00.
        self.assertEqual(self._draft_commission(), Decimal("15.00"))

    def test_partially_returned_repair_invoice_pays_on_the_net_invoice(self):
        """Half the invoice was refunded, so half of it is not commissionable."""
        order = self._completed_repair_invoiced(total="300.00")
        User = get_user_model()
        session = RegisterSession.objects.create(
            owner=User.objects.create_user(username="returns-desk", password="pass"),
            owner_key="user:returns-desk",
        )
        OrderAdjustment.objects.create(
            order=order,
            register_session=session,
            adjustment_type=OrderAdjustment.AdjustmentType.RETURN,
            amount=Decimal("150.00"),
            cash_amount=Decimal("150.00"),
        )

        # 300.00 invoiced - 150.00 refunded = 150.00, and 5% of it is 7.50.
        self.assertEqual(self._draft_commission(), Decimal("7.50"))
