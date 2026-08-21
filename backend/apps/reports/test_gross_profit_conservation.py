"""A sale that is entirely undone must leave reported profit exactly where it
found it.

Gross profit is stated in three places — the sales-summary report, the
profit-and-costs report and the dashboard — and all three used to recompute the
sale's revenue from raw line arithmetic (``quantity * unit_price -
discount_total``, summed unrounded) while the refund that reverses it is the
document's own ``OrderAdjustment.amount``, which is rounded per line. The two
are not the same number on any line whose gross does not land on a whole cent,
so voiding a sale left a residue of profit behind on goods the shop no longer
sold.
"""

from datetime import date, timedelta
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.core.cache import cache
from django.test import TestCase, override_settings
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient

from apps.catalog.models import Product
from apps.catalog.testing import create_product_with_default_variant
from apps.core.roles import MANAGER_GROUP, ensure_role_groups
from apps.inventory.models import StockItem
from apps.reports.services import generate_report_payload
from apps.sales.models import Order, OrderLine


@override_settings(
    CACHES={
        "default": {
            "BACKEND": "django.core.cache.backends.locmem.LocMemCache",
            "LOCATION": "gross-profit-conservation-tests",
        }
    }
)
class GrossProfitConservationTests(TestCase):
    """0.750 kg at 5.50 is a gross of 4.1250 — a half-cent. The line stores
    4.12; the raw expression keeps 4.1250. One weighed sale, voided, is enough
    to separate them."""

    def setUp(self):
        # The dashboard caches each section under a key that names neither the
        # database nor the test, so a sibling test's payload is served to this
        # one unless the cache is isolated and emptied. Same guard
        # ``DashboardApiTests`` uses.
        cache.clear()
        ensure_role_groups()
        User = get_user_model()
        self.manager = User.objects.create_user(
            username="profit-manager", password="pass"
        )
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        product = create_product_with_default_variant(
            sku="WEIGHED-1",
            barcode="",
            name="Weighed goods",
            unit_price=Decimal("5.50"),
        )
        product.unit = Product.Unit.KILOGRAM
        product.save(update_fields=["unit"])
        self.variant = product.default_variant
        StockItem.objects.create(variant=self.variant, quantity_on_hand=Decimal("100"))
        self.client = APIClient()
        self.client.force_authenticate(user=self.manager)
        self.client.post(
            reverse("register-session-start"),
            {"opening_cash": "0.00"},
            format="json",
        )

    def _sell(self):
        response = self.client.post(
            reverse("order-checkout"),
            {"lines": [{"variant": self.variant.pk, "quantity": "0.750"}]},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        order_id = response.data["id"]
        # The cost basis a purchase would have snapshotted. Set directly so the
        # test is about the report's arithmetic, not about how the cost got
        # onto the line.
        OrderLine.objects.filter(order_id=order_id).update(
            unit_cost=Decimal("3.33")
        )
        order = Order.objects.get(pk=order_id)
        line = order.lines.get()
        # The document's own figures: this is the money that actually moved.
        self.assertEqual(line.line_subtotal, Decimal("4.12"))
        self.assertEqual(line.line_cost, Decimal("2.50"))
        self.assertEqual(order.total, Decimal("4.12"))
        # ... and the profit the invoice itself reports for that money.
        self.assertEqual(order.total_profit, Decimal("1.62"))
        return order_id

    def _void(self, order_id):
        void = self.client.post(
            reverse("order-void", args=[order_id]),
            {"reason": "conservation"},
            format="json",
        )
        self.assertEqual(void.status_code, status.HTTP_200_OK)
        # Everything the sale took in went back out, to the cent.
        order = Order.objects.get(pk=order_id)
        self.assertEqual(order.status, Order.Status.VOID)
        self.assertEqual(order.adjustments.get().amount, Decimal("4.12"))

    def _sell_and_void(self):
        self._void(self._sell())

    def _report(self, report_type):
        params = {
            "start_date": (date.today() - timedelta(days=1)).isoformat(),
            "end_date": (date.today() + timedelta(days=1)).isoformat(),
        }
        return generate_report_payload(
            report_type=report_type, params=params, user=self.manager
        )["summary"]

    def test_sales_summary_profit_is_the_invoice_s_own(self):
        # Non-vacuity for the three below: the report has to agree with the
        # invoice while the sale still stands, not merely reach zero once it is
        # gone. 4.12 charged less 2.50 of cost is 1.62 — the raw expression
        # makes it 1.63.
        self._sell()
        summary = self._report("sales_summary")
        self.assertEqual(summary["net_sales"], "4.12")
        self.assertEqual(summary["gross_profit"], "1.62")

    def test_sales_summary_profit_is_zero_after_a_void(self):
        self._sell_and_void()
        summary = self._report("sales_summary")
        self.assertEqual(summary["net_sales"], "0.00")
        self.assertEqual(summary["gross_profit"], "0.00")

    def test_profit_costs_profit_is_zero_after_a_void(self):
        self._sell_and_void()
        summary = self._report("profit_costs")
        self.assertEqual(summary["gross_profit"], "0.00")

    def test_dashboard_profit_is_zero_after_a_void(self):
        self._sell_and_void()
        response = self.client.get(
            reverse("dashboard"), {"period": "today", "sections": "sales"}
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        summary = response.data["sections"]["sales"]["summary"]
        self.assertEqual(summary["net_sales"], "0.00")
        self.assertEqual(summary["gross_profit"], "0.00")
