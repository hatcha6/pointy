"""Asking the catalog about one place rather than the whole shop.

The product list's stock figures are sums across every place a shop keeps
stock. A shop with a store room also needs the other question — what is on the
shop floor — and it is the same list with the sums narrowed, not a second
endpoint with its own drift.
"""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from apps.catalog.testing import create_product_with_default_variant
from apps.core.roles import MANAGER_GROUP, ensure_role_groups
from apps.inventory.models import StockItem, Warehouse


class CatalogWarehouseRollupTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        user = get_user_model().objects.create_user(username="m", password="p")
        user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client = APIClient()
        self.client.force_authenticate(user=user)

        self.showroom = Warehouse.objects.get(pk=Warehouse.default_id())
        self.store = Warehouse.objects.create(name="المخزن", code="store")
        self.product = create_product_with_default_variant(
            name="سكر", sku="CW-1", barcode="", unit_price=Decimal("5.00")
        )
        variant = self.product.default_variant
        StockItem.objects.create(
            variant=variant, warehouse=self.showroom, quantity_on_hand=Decimal("3")
        )
        StockItem.objects.create(
            variant=variant, warehouse=self.store, quantity_on_hand=Decimal("40")
        )

    def _row(self, **query):
        response = self.client.get(reverse("product-list"), query)
        self.assertEqual(response.status_code, 200, response.data)
        rows = response.data["results"] if "results" in response.data else response.data
        return next(row for row in rows if row["id"] == self.product.pk)

    def test_without_a_place_the_list_reports_the_whole_shop(self):
        self.assertEqual(
            Decimal(str(self._row()["quantity_on_hand"])), Decimal("43.000")
        )

    def test_asking_about_one_place_narrows_the_sums(self):
        self.assertEqual(
            Decimal(str(self._row(warehouse=self.showroom.pk)["quantity_on_hand"])),
            Decimal("3.000"),
        )
        self.assertEqual(
            Decimal(str(self._row(warehouse=self.store.pk)["quantity_on_hand"])),
            Decimal("40.000"),
        )

    def test_a_place_that_holds_nothing_reports_nothing_rather_than_everything(self):
        empty = Warehouse.objects.create(name="فارغ", code="empty")
        self.assertEqual(
            Decimal(str(self._row(warehouse=empty.pk)["quantity_on_hand"])),
            Decimal("0.000"),
        )

    def test_a_stale_bookmark_shows_the_shop_rather_than_an_error(self):
        """An unparseable value is not a request worth refusing — the caller
        gets the whole shop, which is the answer they had before filters
        existed."""
        self.assertEqual(
            Decimal(str(self._row(warehouse="not-a-number")["quantity_on_hand"])),
            Decimal("43.000"),
        )
