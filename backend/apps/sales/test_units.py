from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient

from apps.catalog.models import ProductUnit, UnitOfMeasure
from apps.catalog.testing import create_product_with_default_variant
from apps.core.roles import CASHIER_GROUP, ensure_role_groups
from apps.inventory.models import StockItem
from apps.sales.models import OrderLine


class CheckoutUnitTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.client = APIClient()
        self.user = get_user_model().objects.create_user(
            username="unit-cashier", password="pass"
        )
        self.user.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.client.force_authenticate(user=self.user)

        self.product = create_product_with_default_variant(
            name="Water", sku="W1", unit_price="1.00"
        )
        self.variant = self.product.default_variant
        ProductUnit.objects.create(
            product=self.product,
            unit=UnitOfMeasure.objects.get(code="box"),
            factor_to_base=Decimal("12"),
        )
        StockItem.objects.create(variant=self.variant, quantity_on_hand=Decimal("100"))
        self.client.post(
            reverse("register-session-start"),
            {"opening_cash": "0.00"},
            format="json",
        )

    def _checkout(self, lines):
        return self.client.post(
            reverse("order-checkout"), {"lines": lines}, format="json"
        )

    def test_checkout_in_box_unit_converts_stock_and_price(self):
        response = self._checkout(
            [{"variant": self.variant.pk, "quantity": 2, "unit": "box"}]
        )
        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)

        line = OrderLine.objects.get()
        self.assertEqual(line.unit, "box")
        self.assertEqual(line.unit_factor, Decimal("12"))
        self.assertEqual(line.quantity, Decimal("2"))
        # 12x the per-piece price; stock drops by 24 base units.
        self.assertEqual(line.unit_price, Decimal("12.00"))
        self.assertEqual(line.base_quantity, Decimal("24.000"))
        stock = StockItem.objects.get(variant=self.variant)
        self.assertEqual(stock.quantity_on_hand, Decimal("76.000"))

    def test_custom_unit_price_is_used(self):
        product_unit = self.product.units.get()
        product_unit.price = Decimal("10.00")
        product_unit.save()
        response = self._checkout(
            [{"variant": self.variant.pk, "quantity": 1, "unit": "box"}]
        )
        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        line = OrderLine.objects.get()
        self.assertEqual(line.unit_price, Decimal("10.00"))

    def test_base_unit_sale_unchanged(self):
        response = self._checkout([{"variant": self.variant.pk, "quantity": 3}])
        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        line = OrderLine.objects.get()
        self.assertEqual(line.unit_factor, Decimal("1"))
        self.assertEqual(line.unit_price, Decimal("1.00"))
        stock = StockItem.objects.get(variant=self.variant)
        self.assertEqual(stock.quantity_on_hand, Decimal("97.000"))

    def test_fractional_box_accepted(self):
        # A whole-number unit (box) now accepts a fractional quantity — the
        # cashier's choice. 1.5 boxes × 12 = 18 base units off stock.
        response = self._checkout(
            [{"variant": self.variant.pk, "quantity": "1.5", "unit": "box"}]
        )
        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        line = OrderLine.objects.get()
        self.assertEqual(line.quantity, Decimal("1.5"))
        self.assertEqual(line.base_quantity, Decimal("18.000"))
        stock = StockItem.objects.get(variant=self.variant)
        self.assertEqual(stock.quantity_on_hand, Decimal("82.000"))

    def test_unknown_unit_rejected(self):
        response = self._checkout(
            [{"variant": self.variant.pk, "quantity": 1, "unit": "carton"}]
        )
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
