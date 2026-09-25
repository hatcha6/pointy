"""The shelf's quick-access category: made once, pinned once, filled on every sync.

A card is a system product, so no one can put it in a category by hand — the
sync files every card product of a provider under one category of its own and
pins it to the till's quick-access strip the first time, so the whole shelf is
one tap away. After that the category is the shop's to arrange; the sync only
keeps adding cards to it.
"""

from __future__ import annotations

from unittest import mock

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from rest_framework.test import APIClient

from apps.catalog.models import ProductCategory
from apps.core.roles import CASHIER_GROUP, ensure_role_groups

from . import shelf_category
from .models import IntegrationVoucherBrand
from .test_qareeb import PSN, _listing, _StubDriver, logged_in, qareeb_account, sync

SHELF_KEY = "vouchers:qareeb"


class ShelfCategoryTests(TestCase):
    def setUp(self):
        self.account = logged_in(qareeb_account())

    def _category(self) -> ProductCategory:
        return ProductCategory.objects.get(system_key=SHELF_KEY)

    def _card_products(self) -> set[int]:
        return set(
            IntegrationVoucherBrand.objects.filter(product__isnull=False).values_list(
                "product_id", flat=True
            )
        )

    def _filed(self, category) -> set[int]:
        return set(category.products.values_list("id", flat=True))

    def test_the_first_sync_files_every_card_under_one_pinned_category(self):
        ProductCategory.objects.create(name="مشروبات", is_quick_access=True, display_order=4)
        ProductCategory.objects.create(name="غير مثبت", display_order=9)

        sync(self.account, _StubDriver(_listing(), {"115": PSN}))

        category = self._category()
        self.assertEqual(category.name, "كروت قريب")
        self.assertIsNone(category.parent)
        self.assertTrue(category.is_active)
        self.assertTrue(category.is_quick_access)
        # After every chip the shop already pinned; unpinned ones do not count.
        self.assertEqual(category.display_order, 5)
        # Libyana, Almadar and the PSN brand read on its own.
        self.assertEqual(len(self._card_products()), 3)
        self.assertEqual(self._filed(category), self._card_products())

    def test_an_unchanged_shelf_writes_nothing(self):
        driver = _StubDriver(_listing(), {"115": PSN})
        sync(self.account, driver)
        with mock.patch("apps.catalog.signals.bump_catalog_version") as bump:
            again = sync(self.account, driver)
        self.assertEqual(again.changed, 0)
        bump.assert_not_called()
        self.assertEqual(ProductCategory.objects.filter(system_key=SHELF_KEY).count(), 1)

    def test_a_brand_that_joins_the_shelf_later_is_filed_too(self):
        sync(self.account, _StubDriver(_listing(almadar=False)), refresh_limit=0)
        self.assertEqual(len(self._card_products()), 1)

        sync(self.account, _StubDriver(_listing(), {"115": PSN}))

        almadar = IntegrationVoucherBrand.objects.get(code="31").product
        self.assertIn(almadar.pk, self._filed(self._category()))
        self.assertEqual(self._filed(self._category()), self._card_products())

    def test_the_shops_arrangement_survives_every_later_sync(self):
        sync(self.account, _StubDriver(_listing(almadar=False)), refresh_limit=0)
        parent = ProductCategory.objects.create(name="اتصالات")
        category = self._category()
        category.name = "الكروت"
        category.parent = parent
        category.is_quick_access = False
        category.is_active = False
        category.display_order = 0
        category.save()

        # A sync with something new to file, so it is not merely idle.
        sync(self.account, _StubDriver(_listing(), {"115": PSN}))

        category.refresh_from_db()
        self.assertEqual(category.name, "الكروت")
        self.assertEqual(category.parent, parent)
        self.assertFalse(category.is_quick_access)
        self.assertFalse(category.is_active)
        self.assertEqual(category.display_order, 0)
        self.assertEqual(self._filed(category), self._card_products())

    def test_a_shelf_synced_before_the_category_existed_is_filed_on_the_next_sweep(self):
        driver = _StubDriver(_listing(), {"115": PSN})
        sync(self.account, driver)
        # The state an upgrade finds: every card product made, no category yet.
        ProductCategory.objects.filter(system_key=SHELF_KEY).delete()

        report = sync(self.account, driver)

        category = self._category()
        self.assertTrue(category.is_quick_access)
        self.assertEqual(self._filed(category), self._card_products())
        # The category and the three products put in it.
        self.assertEqual(report.changed, 4)

    def test_nothing_on_sale_makes_no_category(self):
        # Libyana sold out, PSN's items never read: no card to sell, no chip.
        sync(self.account, _StubDriver(_listing(libyana=(), almadar=False)), refresh_limit=0)
        self.assertFalse(ProductCategory.objects.filter(system_key=SHELF_KEY).exists())

    def test_a_shop_category_of_the_same_name_is_left_alone(self):
        mine = ProductCategory.objects.create(name="كروت قريب")

        sync(self.account, _StubDriver(_listing(), {"115": PSN}))

        self.assertEqual(self._category().name, "كروت قريب (2)")
        mine.refresh_from_db()
        self.assertEqual(mine.system_key, "")
        self.assertFalse(mine.products.exists())

    def test_two_syncs_racing_to_make_it_share_one(self):
        sync(self.account, _StubDriver(_listing(), {"115": PSN}))
        winner = self._category()
        # The loser of the insert takes the winner's row instead of failing.
        category, created = shelf_category._make_category(self.account)
        self.assertFalse(created)
        self.assertEqual(category.pk, winner.pk)

    def test_the_till_gets_the_cards_behind_the_chip(self):
        sync(self.account, _StubDriver(_listing(), {"115": PSN}))
        ensure_role_groups()
        cashier = get_user_model().objects.create_user(username="till", password="x")
        cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))
        client = APIClient()
        client.force_authenticate(cashier)
        category = self._category()

        # What the strip loads...
        strip = client.get(
            "/api/product-categories/", {"is_quick_access": "true", "is_active": "true"}
        )
        self.assertEqual(strip.status_code, 200, strip.data)
        self.assertEqual([row["id"] for row in strip.data["results"]], [category.pk])
        self.assertTrue(strip.data["results"][0]["is_system"])

        # ...and what tapping it asks the catalog for.
        grid = client.get(
            "/api/products/",
            {"category": category.pk, "system": "sellable", "is_active": "true"},
        )
        self.assertEqual(grid.status_code, 200, grid.data)
        self.assertEqual(
            {row["id"] for row in grid.data["results"]}, self._card_products()
        )
