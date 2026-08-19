"""Refunded goods are restocked, so a refund reverses margin — never margin+cost.

Every void and every return puts the items back on the shelf (see
``sales.record_return_stock_movement``), which means the shop keeps the cost of
those goods. Reported profit must therefore drop by the refunded *margin* only.
Netting the whole refund out of profit charges the cost of goods that never
left, so a void at cost would show a loss and a shop with returns would read its
own margin as far worse than it is.
"""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase

from apps.catalog.testing import create_product_with_default_variant
from apps.core.dashboard.helpers import _sales_summary
from apps.core.roles import MANAGER_GROUP, ensure_role_groups
from apps.payments.models import Payment
from apps.sales.models import Order, OrderAdjustment, OrderLine, RegisterSession
from apps.sales.services import return_order_items, void_order

from .models import ReportRun
from .services import generate_report_payload

UNIT_PRICE = Decimal("100.00")
UNIT_COST = Decimal("60.00")


class RefundedCostReturnsToProfitTests(TestCase):
    """One product at 100.00 selling / 60.00 cost, so every unit carries 40.00
    of margin and 60.00 of cost that a refund must give back."""

    def setUp(self):
        ensure_role_groups()
        User = get_user_model()
        self.manager = User.objects.create_user(
            username="refund-cogs-manager", password="pass"
        )
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.product = create_product_with_default_variant(
            sku="REFUND-COGS",
            name="سلعة المرتجع",
            unit_price=UNIT_PRICE,
        )
        self.session = RegisterSession.objects.create(
            owner=self.manager,
            owner_key=f"user:{self.manager.pk}",
            opening_cash=Decimal("0.00"),
        )

    def _sell(self, quantity=1, *, unit_cost=UNIT_COST, unit_factor=Decimal("1")):
        total = UNIT_PRICE * quantity
        order = Order.objects.create(
            register_session=self.session,
            status=Order.Status.PAID,
            subtotal=total,
            total=total,
        )
        line = OrderLine.objects.create(
            order=order,
            variant=self.product.default_variant,
            quantity=quantity,
            unit_price=UNIT_PRICE,
            unit_cost=unit_cost,
            unit_factor=unit_factor,
        )
        Payment.objects.create(
            order=order,
            register_session=self.session,
            method=Payment.Method.CASH,
            amount=total,
        )
        return order, line

    def _summary(self, report_type=ReportRun.ReportType.SALES_SUMMARY):
        return generate_report_payload(
            report_type=report_type, params={}, user=self.manager
        )["summary"]

    def test_voiding_a_sale_leaves_reported_profit_untouched(self):
        self._sell()
        voided, _ = self._sell()
        void_order(order=voided, reason="rung up twice")

        summary = self._summary()
        # Only the first sale happened: 100.00 of net sales, 40.00 of margin.
        # The voided order's goods are back on the shelf, so it costs nothing.
        self.assertEqual(summary["net_sales"], "100.00")
        self.assertEqual(summary["gross_profit"], "40.00")
        self.assertEqual(summary["refund_total"], "100.00")

    def test_full_return_reverses_the_margin_and_nothing_else(self):
        order, line = self._sell()
        return_order_items(order=order, lines=[(line, 1)], reason="لم تعجبه")

        summary = self._summary()
        self.assertEqual(summary["net_sales"], "0.00")
        self.assertEqual(summary["gross_profit"], "0.00")

    def test_partial_return_reverses_only_the_returned_units_margin(self):
        order, line = self._sell(quantity=3)
        return_order_items(order=order, lines=[(line, 1)], reason="واحدة تالفة")

        summary = self._summary()
        # Two of three units stand: 200.00 net sales, 2 x 40.00 margin.
        self.assertEqual(summary["net_sales"], "200.00")
        self.assertEqual(summary["gross_profit"], "80.00")

    def test_return_of_a_multi_unit_line_credits_back_that_unit_s_cost(self):
        # A carton of 12: price and cost are both per carton, and the returned
        # quantity is counted in cartons, so the cost credited back must be the
        # carton cost — not the base-unit cost, and not twelve times it.
        carton_cost = Decimal("48.00")
        order, line = self._sell(
            quantity=2, unit_cost=carton_cost, unit_factor=Decimal("12")
        )
        return_order_items(order=order, lines=[(line, 1)], reason="كرتونة مرتجعة")

        summary = self._summary()
        self.assertEqual(summary["net_sales"], "100.00")
        self.assertEqual(summary["gross_profit"], "52.00")

    def test_profit_costs_report_agrees_with_the_sales_summary(self):
        order, line = self._sell(quantity=2)
        return_order_items(order=order, lines=[(line, 1)], reason="مرتجع")

        sales_summary = self._summary()
        profit_costs = self._summary(ReportRun.ReportType.PROFIT_COSTS)
        self.assertEqual(sales_summary["gross_profit"], "40.00")
        self.assertEqual(
            profit_costs["gross_profit"], sales_summary["gross_profit"]
        )
        self.assertEqual(profit_costs["net_operating_profit"], "40.00")

    def test_dashboard_summary_agrees_with_the_report(self):
        order, line = self._sell(quantity=2)
        return_order_items(order=order, lines=[(line, 1)], reason="مرتجع")

        dashboard = _sales_summary(
            Order.objects.transactional(), OrderAdjustment.objects.all()
        )
        self.assertEqual(dashboard["gross_profit"], self._summary()["gross_profit"])
        self.assertEqual(dashboard["profit_margin_percent"], "40.00")
