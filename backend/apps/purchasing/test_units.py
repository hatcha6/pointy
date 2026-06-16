from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient

from apps.catalog.models import ProductUnit, UnitOfMeasure
from apps.catalog.testing import create_product_with_default_variant
from apps.core.roles import MANAGER_GROUP, ensure_role_groups
from apps.inventory.models import StockItem
from apps.purchasing.models import PurchaseOrder
from apps.purchasing.services import latest_variant_unit_cost


class PurchaseUnitTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.client = APIClient()
        self.user = get_user_model().objects.create_user(
            username="unit-purchaser", password="pass"
        )
        self.user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client.force_authenticate(user=self.user)

        self.product = create_product_with_default_variant(
            name="Soda", sku="SODA", unit_price="1.00"
        )
        self.variant = self.product.default_variant
        ProductUnit.objects.create(
            product=self.product,
            unit=UnitOfMeasure.objects.get(code="carton"),
            factor_to_base=Decimal("24"),
        )
        from apps.purchasing.models import Supplier

        self.supplier = Supplier.objects.create(name="Beverages Inc")

    def _create_order(self):
        return self.client.post(
            reverse("purchaseorder-list"),
            {
                "supplier": self.supplier.pk,
                "lines": [
                    {
                        "variant": self.variant.pk,
                        "quantity": 3,
                        "unit": "carton",
                        "unit_cost": "48.00",
                    }
                ],
            },
            format="json",
        )

    def test_pack_purchase_converts_to_base_units_through_lifecycle(self):
        StockItem.objects.create(variant=self.variant, quantity_on_hand=Decimal("0"))
        create_response = self._create_order()
        self.assertEqual(
            create_response.status_code, status.HTTP_201_CREATED, create_response.data
        )
        line = create_response.data["lines"][0]
        self.assertEqual(line["unit"], "carton")
        self.assertEqual(Decimal(line["unit_factor"]), Decimal("24"))
        self.assertEqual(Decimal(line["base_quantity"]), Decimal("72.000"))
        # 48 per carton ÷ 24 = 2.00 per base unit.
        self.assertEqual(Decimal(line["base_unit_cost"]), Decimal("2.00"))

        order_id = create_response.data["id"]
        submit_response = self.client.post(
            reverse("purchaseorder-submit", args=[order_id]), format="json"
        )
        self.assertEqual(submit_response.status_code, status.HTTP_200_OK)
        stock_item = StockItem.objects.get(variant=self.variant)
        # 3 cartons × 24 = 72 base units expected.
        self.assertEqual(stock_item.quantity_expected, Decimal("72.000"))

        receive_response = self.client.post(
            reverse("purchaseorder-receive", args=[order_id]), format="json"
        )
        self.assertEqual(receive_response.status_code, status.HTTP_200_OK)
        self.assertEqual(
            receive_response.data["status"], PurchaseOrder.Status.RECEIVED
        )
        stock_item = StockItem.objects.get(variant=self.variant)
        self.assertEqual(stock_item.quantity_on_hand, Decimal("72.000"))
        self.assertEqual(stock_item.quantity_expected, Decimal("0.000"))

    def test_cost_lookup_normalises_to_base_unit(self):
        StockItem.objects.create(variant=self.variant, quantity_on_hand=Decimal("0"))
        order_id = self._create_order().data["id"]
        self.client.post(reverse("purchaseorder-submit", args=[order_id]), format="json")
        self.client.post(reverse("purchaseorder-receive", args=[order_id]), format="json")
        self.assertEqual(latest_variant_unit_cost(self.variant.pk), Decimal("2.00"))

    def test_unpurchasable_unit_rejected(self):
        self.product.units.update(is_purchasable=False)
        response = self._create_order()
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
