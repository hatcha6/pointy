"""The public invoice page names what the printed receipt names under a line.

A customer opening the shared link should read the same invoice as the slip in
their hand: the unit a line was sold in, the extras chosen on it, and the
handset's IMEI that makes the page a warranty document. The query count stays
flat however many such lines the invoice holds.
"""

from decimal import Decimal

from django.db import connection
from django.test import TestCase
from django.test.utils import CaptureQueriesContext
from django.urls import reverse
from rest_framework.test import APIClient

from apps.catalog.models import Product, UnitOfMeasure
from apps.catalog.testing import create_product_with_default_variant
from apps.core.models import ShopSettings
from apps.inventory.models import StockUnit, Warehouse

from .models import Order, OrderLine, OrderLineModifier


class PublicInvoiceLineDetailTests(TestCase):
    def setUp(self):
        self.client = APIClient()
        ShopSettings.load()
        ShopSettings.objects.filter(pk=1).update(enable_online_invoices=True)
        UnitOfMeasure.objects.update_or_create(
            code="carton", defaults={"name": "كرتونة", "abbreviation": "كرتونة"}
        )
        self.juice = create_product_with_default_variant(
            sku="PUB-JUICE", name="عصير", unit_price=Decimal("30.00")
        )
        self.phone = create_product_with_default_variant(
            sku="PUB-PHONE", name="هاتف", unit_price=Decimal("850.00")
        )
        Product.objects.filter(pk=self.phone.pk).update(
            tracking_mode=Product.TrackingMode.SERIAL
        )
        self.meal = create_product_with_default_variant(
            sku="PUB-MEAL", name="شاورما", unit_price=Decimal("12.50")
        )
        self.order = Order.objects.create(
            status=Order.Status.PAID,
            subtotal=Decimal("0.00"),
            total=Decimal("0.00"),
            extra_discount_amount=Decimal("3.00"),
        )

    def _line(self, product, **fields):
        return OrderLine.objects.create(
            order=self.order,
            variant=product.variants.get(),
            unit_price=fields.pop("unit_price", Decimal("10.00")),
            **fields,
        )

    def _fetch(self):
        url = reverse("public-invoice-detail", args=[self.order.public_token])
        response = self.client.get(url, HTTP_X_POINTY_RELAYED_REQUEST="1")
        self.assertEqual(response.status_code, 200)
        return response.data

    def _sell_phone(self, code):
        line = self._line(self.phone, quantity=Decimal("1"))
        StockUnit.objects.create(
            variant=self.phone.variants.get(),
            warehouse_id=Warehouse.default_id(),
            code=code,
            status=StockUnit.Status.SOLD,
            incoming_rate=Decimal("0"),
            sold_order_line=line,
        )
        return line

    def test_lines_carry_unit_extras_and_serials(self):
        self._line(self.juice, quantity=Decimal("2"), unit="carton")
        self._sell_phone("356938035643809")
        meal = self._line(self.meal, quantity=Decimal("2"))
        OrderLineModifier.objects.create(
            order_line=meal,
            group_name="الإضافات",
            option_name="جبنة",
            unit_price_delta=Decimal("2.00"),
            quantity=1,
        )

        body = self._fetch()
        juice, phone, meal_line = body["lines"]
        self.assertEqual(juice["unit_label"], "كرتونة")
        self.assertEqual(juice["modifiers"], [])
        self.assertEqual(juice["identifiers"], [])
        self.assertEqual(
            [row["code"] for row in phone["identifiers"]], ["356938035643809"]
        )
        self.assertNotIn("is_consignment", phone["identifiers"][0])
        self.assertEqual(
            [(m["name"], m["price_delta"]) for m in meal_line["modifiers"]],
            [("جبنة", "2.00")],
        )
        self.assertEqual(body["extra_discount_amount"], "3.00")
        # Shop-local wall-clock time (Tripoli has no DST), not UTC.
        self.assertTrue(body["created_at"].endswith("+02:00"), body["created_at"])

    def test_serials_and_extras_do_not_query_per_line(self):
        def count():
            # Warm per-process caches so they don't land on one measurement.
            self._fetch()
            with CaptureQueriesContext(connection) as queries:
                self._fetch()
            return len(queries)

        for index in range(2):
            self._sell_phone(f"35693803564380{index}")
        small = count()
        for index in range(2, 6):
            self._sell_phone(f"35693803564380{index}")
        self.assertEqual(small, count())
