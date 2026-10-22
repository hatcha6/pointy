"""The products-list bulk actions keep tills and price sheets consistent.

``bulk-reprice`` and ``bulk-set-flags`` write with ``bulk_update`` / ``update``,
which fire no ``post_save`` — so they must announce the change themselves, or a
till never revalidates and keeps selling at the old price. And a reprice must
move a foreign-priced product's frozen price sheet with its base price, or the
next FX reprice quietly puts the old price back.
"""

from decimal import Decimal
from unittest.mock import patch

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient

from apps.catalog.models import Product
from apps.catalog.pricing import reprice_preview, set_foreign_price
from apps.core.roles import MANAGER_GROUP, ensure_role_groups

from .test_foreign_pricing import ForeignPricingTestCase


def catalog_defs_bumps(state_bump) -> int:
    # Other counters may move too (loading shop settings touches "settings").
    return sum(1 for call in state_bump.call_args_list if call.args == ("catalog_defs",))


class BulkActionConsistencyTests(ForeignPricingTestCase):
    def setUp(self):
        super().setUp()
        ensure_role_groups()
        self.client = APIClient()
        user = get_user_model().objects.create_user(username="bulk-owner", password="pass")
        user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client.force_authenticate(user=user)

    def reprice(self, ids, mode="increase_percent", value="10"):
        response = self.client.post(
            reverse("product-bulk-reprice"),
            {"ids": ids, "mode": mode, "value": value},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        return response.data["updated"]

    def test_reprice_restates_a_foreign_price_sheet(self):
        self.add_rate("5.00")
        product, variant = self.make_product(currency="USD")
        set_foreign_price(variant, "10.00")  # 50.00 LYD at 5.00

        self.assertEqual(self.reprice([product.pk]), 1)

        variant.refresh_from_db()
        self.assertEqual(variant.unit_price, Decimal("55.00"))
        self.assertEqual(variant.price_amount, Decimal("11.00"))
        self.assertEqual(variant.price_rate, Decimal("5.00000000"))
        # Nothing has drifted, so the FX reprice screen offers nothing back.
        self.assertFalse(any(p.changed for p in reprice_preview(products=Product.objects.filter(pk=product.pk))))

    def test_reprice_leaves_a_base_priced_product_without_a_sheet(self):
        product, variant = self.make_product(price="10.00")
        self.reprice([product.pk], mode="set", value="12.5")
        variant.refresh_from_db()
        self.assertEqual(variant.unit_price, Decimal("12.50"))
        self.assertIsNone(variant.price_amount)
        self.assertIsNone(variant.price_rate)

    def test_reprice_announces_the_change_to_tills(self):
        product, _ = self.make_product()
        with (
            patch("apps.catalog.cache.bump_catalog_version") as catalog_bump,
            patch("apps.core.state_version.bump") as state_bump,
            self.captureOnCommitCallbacks(execute=True),
        ):
            self.reprice([product.pk])
        catalog_bump.assert_called_once()
        self.assertEqual(catalog_defs_bumps(state_bump), 1)

    def test_a_reprice_that_changes_nothing_announces_nothing(self):
        product, _ = self.make_product(price="0.00")
        with (
            patch("apps.catalog.cache.bump_catalog_version") as catalog_bump,
            patch("apps.core.state_version.bump") as state_bump,
            self.captureOnCommitCallbacks(execute=True),
        ):
            self.assertEqual(self.reprice([product.pk], mode="decrease_amount", value="1"), 0)
        catalog_bump.assert_not_called()
        self.assertEqual(catalog_defs_bumps(state_bump), 0)

    def test_set_flags_announces_the_change_to_tills(self):
        product, _ = self.make_product()
        with (
            patch("apps.catalog.cache.bump_catalog_version") as catalog_bump,
            patch("apps.core.state_version.bump") as state_bump,
            self.captureOnCommitCallbacks(execute=True),
        ):
            response = self.client.post(
                reverse("product-bulk-set-flags"),
                {"ids": [product.pk], "is_active": False},
                format="json",
            )
        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        product.refresh_from_db()
        self.assertFalse(product.is_active)
        catalog_bump.assert_called_once()
        self.assertEqual(catalog_defs_bumps(state_bump), 1)
