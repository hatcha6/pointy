"""A quotation's stock hold must always carry an expiry date.

``StockItem.quantity_committed`` is the only thing standing between a quoted
customer and the shelf: with overselling off, ``prepare_sale_stock_adjustments``
sells against ``quantity_on_hand - quantity_committed``, so every held unit is a
unit the POS will refuse to sell to anyone else.

There are exactly three ways a hold is ever freed — conversion
(``consume_quote_reservations``), the nightly expiry sweep
(``release_expired_quote_reservations``), and a direct service call. The sweep
selects on ``valid_until__lt=today`` and skips NULLs, and an OPEN quotation
cannot be voided (``validate_order_adjustment_allowed`` requires PAID). So a
hold placed on a quotation with no ``valid_until`` has no release path at all:
the units are frozen for the life of the shop.

``Order.reserves_stock``'s own docstring says the quantities are held "until
``valid_until``" — these tests hold the API to that.
"""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient

from apps.catalog.testing import create_product_with_default_variant
from apps.core.roles import CASHIER_GROUP, ensure_role_groups
from apps.customers.models import Customer
from apps.inventory.models import StockItem

from . import tasks as sales_tasks
from .models import Order, RegisterSession, StockReservation
from .services import reserve_stock_for_quote


class QuotationReservationExpiryTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.client = APIClient()
        self.user = get_user_model().objects.create_user(
            username="quote-cashier", password="pass"
        )
        self.user.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.client.force_authenticate(user=self.user)
        self.product = create_product_with_default_variant(
            sku="HOLD", barcode="", name="Held widget", unit_price=Decimal("5.00")
        )
        self.variant = self.product.default_variant
        self.stock_item = StockItem.objects.create(
            variant=self.variant, quantity_on_hand=10
        )
        self.customer = Customer.objects.create(full_name="Quote Customer")
        self.client.post(
            reverse("register-session-start"), {"opening_cash": "0.00"}, format="json"
        )

    def _checkout(self, **overrides):
        payload = {
            "lines": [{"variant": self.variant.pk, "quantity": 2}],
            "sale_type": "quotation",
            "customer": self.customer.pk,
        }
        payload.update(overrides)
        return self.client.post(reverse("order-checkout"), payload, format="json")

    def test_reserving_quotation_requires_an_expiry_date(self):
        """A hold with no deadline can never be released, so it must be refused
        at the door rather than accepted and stranded."""
        response = self._checkout(reserve_stock=True)

        self.assertEqual(
            response.status_code, status.HTTP_400_BAD_REQUEST, response.data
        )
        self.stock_item.refresh_from_db()
        self.assertEqual(self.stock_item.quantity_committed, Decimal("0.000"))
        self.assertFalse(StockReservation.objects.exists())

    def test_reserving_quotation_with_an_expiry_date_still_holds_stock(self):
        response = self._checkout(reserve_stock=True, valid_until="2099-12-31")

        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        self.stock_item.refresh_from_db()
        self.assertEqual(self.stock_item.quantity_committed, Decimal("2.000"))

    def test_quotation_without_a_hold_does_not_need_an_expiry_date(self):
        """``valid_until`` stays optional for a plain price offer — only the
        stock hold makes it mandatory."""
        response = self._checkout()

        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        self.stock_item.refresh_from_db()
        self.assertEqual(self.stock_item.quantity_committed, Decimal("0.000"))

    def test_expiry_sweep_can_never_release_a_hold_that_has_no_expiry_date(self):
        """This is *why* the date is mandatory: the sweep filters on
        ``valid_until__lt=today`` and so cannot see a NULL, leaving the units
        committed forever. If this ever starts releasing, the guard above can be
        relaxed — until then it must stay."""
        order = Order.objects.create(
            sale_type=Order.SaleType.QUOTATION,
            reserves_stock=True,
            valid_until=None,
            register_session=RegisterSession.objects.first(),
            customer=self.customer,
            subtotal=Decimal("10.00"),
            total=Decimal("10.00"),
        )
        order.lines.create(
            variant=self.variant, quantity=Decimal("2"), unit_price=Decimal("5.00")
        )
        reserve_stock_for_quote(order)
        self.stock_item.refresh_from_db()
        self.assertEqual(self.stock_item.quantity_committed, Decimal("2.000"))

        released = sales_tasks.release_expired_quote_reservations()

        self.assertEqual(released, 0)
        self.stock_item.refresh_from_db()
        self.assertEqual(self.stock_item.quantity_committed, Decimal("2.000"))
        self.assertEqual(
            order.stock_reservations.filter(
                status=StockReservation.Status.ACTIVE
            ).count(),
            1,
        )
