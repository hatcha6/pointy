"""A serialized article is sold by naming it — never by the server's pick (§6.3).

Until now ``_plan_unit_issue`` took the oldest sellable article whenever a sale
named none, and an order created open through ``/api/orders/`` and paid later
had nowhere to keep the article it was written against — so the invoice, the
warranty and ``StockUnit.sold_order_line`` could all name a handset that was
still in the drawer. These tests hold both halves: the refusal, and the open
order that keeps its selection until the payment issues it.
"""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.test import TestCase
from rest_framework import serializers
from rest_framework.test import APIClient

from apps.catalog.models import Product
from apps.inventory.integrity import assert_tracking_invariants
from apps.inventory.models import StockAllocation, StockUnit
from apps.inventory.tracked_testing import receive, tracked_product
from apps.sales.models import Order, OrderLine, RegisterSession
from apps.sales.services import checkout_order

IMEI_A = "351234567890116"
IMEI_B = "351234567890124"
IMEI_C = "351234567890132"


def _till():
    return RegisterSession.objects.create(
        owner_key="test-serial-naming-till",
        status=RegisterSession.Status.OPEN,
        opening_cash=Decimal("0.00"),
    )


class _HandsetsOnTheShelf(TestCase):
    def setUp(self):
        self.product = tracked_product(
            name="iPhone 13",
            sku="IP13",
            mode=Product.TrackingMode.SERIAL,
            unit_price="1500.00",
        )
        self.variant = self.product.default_variant
        receive(
            variant=self.variant,
            quantity=3,
            unit_cost="1200.00",
            units=[{"code": IMEI_A}, {"code": IMEI_B}, {"code": IMEI_C}],
        )
        self.oldest, self.second, self.third = StockUnit.objects.filter(
            variant=self.variant
        ).order_by("pk")


class CheckoutRefusesAnUnnamedHandset(_HandsetsOnTheShelf):
    def _sell(self, **line_extra):
        return checkout_order(
            register_session=_till(),
            lines_data=[
                {"variant": self.variant, "quantity": Decimal("1"), **line_extra}
            ],
            payments_data=[{"method": "cash", "amount": Decimal("1500.00")}],
        )

    def test_a_sale_that_names_no_handset_is_refused_in_arabic(self):
        with self.assertRaises(serializers.ValidationError) as caught:
            self._sell()

        detail = caught.exception.detail
        self.assertEqual(str(detail["code"]), "stock_unit_required")
        self.assertIn("iPhone 13", str(detail["detail"]))
        self.assertFalse(Order.objects.exists())
        self.assertEqual(
            StockUnit.objects.filter(status=StockUnit.Status.IN_STOCK).count(), 3
        )
        assert_tracking_invariants()

    def test_naming_the_handset_sells_that_one_and_not_the_oldest(self):
        order = self._sell(stock_units=[self.second.pk])

        self.second.refresh_from_db()
        self.oldest.refresh_from_db()
        self.assertEqual(self.second.status, StockUnit.Status.SOLD)
        self.assertEqual(self.second.sold_order_line.order_id, order.pk)
        self.assertEqual(self.oldest.status, StockUnit.Status.IN_STOCK)
        assert_tracking_invariants()

    def test_a_scanned_code_names_it_too(self):
        self._sell(stock_unit_codes=[IMEI_C])

        self.third.refresh_from_db()
        self.assertEqual(self.third.status, StockUnit.Status.SOLD)
        assert_tracking_invariants()

    def test_an_untracked_product_still_sells_without_naming_anything(self):
        cola = tracked_product(
            name="كولا", sku="COLA", mode=Product.TrackingMode.QUANTITY
        )
        receive(variant=cola.default_variant, quantity=5, unit_cost="1.00")

        order = checkout_order(
            register_session=_till(),
            lines_data=[{"variant": cola.default_variant, "quantity": Decimal("2")}],
            payments_data=[{"method": "cash", "amount": Decimal("200.00")}],
        )

        self.assertIsNone(order.lines.get().stock_selection)


class OpenOrderKeepsItsHandsetUntilPaid(_HandsetsOnTheShelf):
    """``/api/orders/`` writes the order; a payment issues its stock later."""

    def setUp(self):
        super().setUp()
        self.user = get_user_model().objects.create_superuser(
            username="owner", password="pass"
        )
        self.client = APIClient()
        self.client.force_authenticate(self.user)
        RegisterSession.objects.create(
            owner=self.user,
            owner_key=f"user:{self.user.pk}",
            status=RegisterSession.Status.OPEN,
            opening_cash=Decimal("0.00"),
        )

    def _create(self, **line_extra):
        return self.client.post(
            "/api/orders/",
            {
                "lines": [
                    {"variant": self.variant.pk, "quantity": "1", **line_extra}
                ]
            },
            format="json",
        )

    def _pay(self, order_id, amount):
        return self.client.post(
            "/api/payments/",
            {"order": order_id, "method": "cash", "amount": str(amount)},
            format="json",
        )

    def test_an_order_that_names_no_handset_is_refused_when_written(self):
        response = self._create()

        self.assertEqual(response.status_code, 400, response.content)
        self.assertIn("stock_unit_required", response.content.decode())
        self.assertFalse(Order.objects.exists())

    def test_naming_more_handsets_than_the_quantity_is_refused(self):
        response = self._create(stock_units=[self.second.pk, self.third.pk])

        self.assertEqual(response.status_code, 400, response.content)
        self.assertIn("stock_unit_count_mismatch", response.content.decode())

    def test_payment_issues_the_handset_the_order_named(self):
        created = self._create(stock_units=[self.second.pk])
        self.assertEqual(created.status_code, 201, created.content)
        line = OrderLine.objects.get(order_id=created.data["id"])
        self.assertEqual(line.stock_selection["stock_units"], [self.second.pk])
        # Written, not yet issued: the handset is still on the shelf.
        self.second.refresh_from_db()
        self.assertEqual(self.second.status, StockUnit.Status.IN_STOCK)

        paid = self._pay(created.data["id"], created.data["total"])
        self.assertEqual(paid.status_code, 201, paid.content)

        self.second.refresh_from_db()
        self.oldest.refresh_from_db()
        self.assertEqual(self.second.status, StockUnit.Status.SOLD)
        self.assertEqual(self.second.sold_order_line_id, line.pk)
        self.assertEqual(self.oldest.status, StockUnit.Status.IN_STOCK)
        self.assertTrue(
            StockAllocation.objects.filter(
                unit=self.second, direction=StockAllocation.Direction.OUT
            ).exists()
        )
        assert_tracking_invariants()

    def test_a_handset_sold_elsewhere_in_between_refuses_the_payment(self):
        created = self._create(stock_unit_codes=[IMEI_B])
        self.assertEqual(created.status_code, 201, created.content)
        checkout_order(
            register_session=_till(),
            lines_data=[
                {
                    "variant": self.variant,
                    "quantity": Decimal("1"),
                    "stock_units": [self.second.pk],
                }
            ],
            payments_data=[{"method": "cash", "amount": Decimal("1500.00")}],
        )

        paid = self._pay(created.data["id"], created.data["total"])

        self.assertEqual(paid.status_code, 400, paid.content)
        self.oldest.refresh_from_db()
        self.assertEqual(self.oldest.status, StockUnit.Status.IN_STOCK)
        assert_tracking_invariants()
