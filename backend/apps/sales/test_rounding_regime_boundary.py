"""The boundary between the discount engine's rounding regime and the order's.

The backend rounds money two different ways on purpose:

* ``apps.discounts.services.money`` — 2dp **HALF_UP**, the discount engine's
  regime, so a discount amount rounds in the shop's favour;
* ``apps.sales.services.money`` / ``Order.recalculate`` — 2dp **HALF_EVEN**,
  the sales regime, which is what an order actually stores.

Both are correct in their own domain. What is not correct is letting an
engine-domain figure decide a sales-domain question. A line whose
``unit_price × quantity`` lands exactly on a half-cent — 0.75 kg at 5.50 is
4.125 — is 4.13 to the engine and 4.12 to the order, and every caller that
treated ``discount_result.total`` as *the amount to tender* asked for a cent the
order then refused, killing the sale outright with HTTP 400 "Payment total
cannot exceed the order total."

These tests pin the boundary: whatever decides or displays what the customer
pays uses the order's own arithmetic (``expected_order_totals``). They need no
discount rule to exist — the divergence is in the subtotal itself.
"""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from rest_framework.test import APIClient

from apps.catalog.testing import create_product_with_default_variant
from apps.core.models import ShopSettings
from apps.core.roles import MANAGER_GROUP, ensure_role_groups
from apps.inventory.models import StockItem

from .models import Order, OrderLine, RegisterSession
from .services import calculate_sales_discounts, exchange_order_items


class HalfCentLineTestCase(TestCase):
    """A 0.75 quantity at 5.50 — exactly 4.125, the half-cent boundary."""

    def setUp(self):
        ensure_role_groups()
        User = get_user_model()
        self.user = User.objects.create_user(username="rounding-user", password="pass")
        self.user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        settings = ShopSettings.load()
        settings.allow_overselling = False
        settings.prevent_selling_at_loss = False
        settings.enable_cash_payments = True
        settings.save()

        self.product = create_product_with_default_variant(
            name="Weighed", sku="WEIGHED", unit_price="5.50"
        )
        self.variant = self.product.default_variant
        StockItem.objects.create(
            variant=self.variant, quantity_on_hand=Decimal("100")
        )
        self.session = RegisterSession.objects.create(
            owner=self.user, owner_key=f"user:{self.user.pk}"
        )
        self.client = APIClient()
        self.client.force_authenticate(self.user)

    def test_the_two_regimes_really_do_disagree_on_this_line(self):
        """Guards the premise. If this stops holding the rest proves nothing."""
        result = calculate_sales_discounts(
            lines_data=[{"variant": self.variant, "quantity": Decimal("0.75")}]
        )
        self.assertEqual(result.subtotal, Decimal("4.13"))  # engine: HALF_UP
        self.assertEqual(
            (self.variant.unit_price * Decimal("0.75")).quantize(Decimal("0.01")),
            Decimal("4.12"),  # order line: HALF_EVEN
        )

    def test_a_half_cent_sale_can_be_rung_up_at_all(self):
        """The regression: this checkout used to 400 and the sale was impossible."""
        response = self.client.post(
            "/api/orders/checkout/",
            {
                "register_session": self.session.pk,
                "lines": [{"variant": self.variant.pk, "quantity": "0.75"}],
                "payment_method": "cash",
            },
            format="json",
        )
        self.assertEqual(response.status_code, 201, response.data)
        order = Order.objects.get(pk=response.data["id"])
        # The customer pays the order's total, to the cent, and owes nothing.
        self.assertEqual(order.total, Decimal("4.12"))
        self.assertEqual(order.amount_paid, Decimal("4.12"))
        self.assertEqual(order.balance_due, Decimal("0.00"))
        self.assertEqual(order.status, Order.Status.PAID)

    def test_the_preview_quotes_what_checkout_will_accept(self):
        """The cashier tenders what the cart pane shows; the two must agree."""
        payload = {"lines": [{"variant": self.variant.pk, "quantity": "0.75"}]}
        preview = self.client.post(
            "/api/orders/discount-preview/", payload, format="json"
        )
        self.assertEqual(preview.status_code, 200, preview.data)
        self.assertEqual(preview.data["subtotal"], "4.12")
        self.assertEqual(preview.data["total"], "4.12")

        response = self.client.post(
            "/api/orders/checkout/",
            {
                "register_session": self.session.pk,
                "lines": [{"variant": self.variant.pk, "quantity": "0.75"}],
                "payments": [
                    {"method": "cash", "amount": preview.data["total"]}
                ],
            },
            format="json",
        )
        self.assertEqual(response.status_code, 201, response.data)

    def test_an_exchange_settles_on_a_half_cent_replacement(self):
        """The same crossing, one layer up: the replacement leg is a checkout."""
        original = self.client.post(
            "/api/orders/checkout/",
            {
                "register_session": self.session.pk,
                "lines": [{"variant": self.variant.pk, "quantity": "2"}],
                "payment_method": "cash",
            },
            format="json",
        )
        self.assertEqual(original.status_code, 201, original.data)
        order = Order.objects.get(pk=original.data["id"])
        outbound_line = order.lines.get()

        exchange = exchange_order_items(
            order=order,
            outbound_lines=[(OrderLine.objects.get(pk=outbound_line.pk), Decimal("1"))],
            replacement_lines=[
                {"variant": self.variant, "quantity": Decimal("0.75")}
            ],
            settlement_method="cash",
            reason="half-cent replacement",
            register_session=self.session,
        )
        replacement = exchange.replacement_order
        self.assertEqual(replacement.total, Decimal("4.12"))
        self.assertEqual(replacement.amount_paid, Decimal("4.12"))
        self.assertEqual(exchange.replacement_amount, Decimal("4.12"))
        self.assertEqual(exchange.outbound_amount, Decimal("5.50"))
        # The customer is owed the difference, not charged it.
        self.assertEqual(exchange.net_amount, Decimal("-1.38"))
