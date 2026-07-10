"""Tests for the catalog list ETag / 304 conditional GET (cache.py + views.py).

The catalog-version machinery is globally disabled under the test runner (see
``TESTING`` in settings), so these tests opt back in explicitly with an
isolated LocMem cache.
"""

from decimal import Decimal

from django.contrib.auth.models import Group
from django.contrib.auth import get_user_model
from django.core.cache import cache
from django.test import TestCase, override_settings
from rest_framework import status
from rest_framework.test import APIClient

from apps.catalog.testing import create_product_with_default_variant
from apps.core.roles import MANAGER_GROUP

CACHED = override_settings(
    CACHES={
        "default": {
            "BACKEND": "django.core.cache.backends.locmem.LocMemCache",
            "LOCATION": "catalog-etag-tests",
        },
    },
    POINTY_CATALOG_CACHE_ENABLED=True,
)


@CACHED
class CatalogConditionalGetTests(TestCase):
    def setUp(self):
        cache.clear()
        user = get_user_model().objects.create_user(username="manager", password="x")
        user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.user = user
        self.client_api = APIClient()
        self.client_api.force_authenticate(user=user)
        self.product = create_product_with_default_variant(
            name="Widget", sku="W-1", unit_price="10.00", barcode="123456"
        )

    def _get(self, etag=None, path="/api/products/"):
        headers = {"HTTP_IF_NONE_MATCH": etag} if etag else {}
        return self.client_api.get(path, **headers)

    def test_list_carries_an_etag_and_revalidates_to_304(self):
        response = self._get()
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        etag = response["ETag"]
        self.assertTrue(etag)

        revalidated = self._get(etag=etag)
        self.assertEqual(revalidated.status_code, status.HTTP_304_NOT_MODIFIED)
        self.assertEqual(revalidated["ETag"], etag)
        self.assertFalse(revalidated.content)

    def test_product_edit_invalidates_the_etag(self):
        etag = self._get()["ETag"]
        self.product.name = "Widget v2"
        self.product.save()
        response = self._get(etag=etag)
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertNotEqual(response["ETag"], etag)
        self.assertIn("Widget v2", response.content.decode())

    def test_stock_change_invalidates_the_etag(self):
        from apps.inventory.models import StockItem

        etag = self._get()["ETag"]
        StockItem.objects.create(
            variant=self.product.variants.get(),
            quantity_on_hand=Decimal("7"),
        )
        response = self._get(etag=etag)
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertNotEqual(response["ETag"], etag)

    def test_etag_is_scoped_per_user(self):
        etag = self._get()["ETag"]
        other = get_user_model().objects.create_user(username="manager2", password="x")
        other.groups.add(Group.objects.get(name=MANAGER_GROUP))
        other_client = APIClient()
        other_client.force_authenticate(user=other)
        response = other_client.get("/api/products/", HTTP_IF_NONE_MATCH=etag)
        # Another user's ETag must never validate: full 200 with their own tag.
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertNotEqual(response["ETag"], etag)

    def test_variant_list_supports_conditional_get(self):
        response = self._get(path="/api/product-variants/")
        etag = response["ETag"]
        revalidated = self._get(etag=etag, path="/api/product-variants/")
        self.assertEqual(revalidated.status_code, status.HTTP_304_NOT_MODIFIED)

    def test_no_etag_when_disabled(self):
        with override_settings(POINTY_CATALOG_CACHE_ENABLED=False):
            response = self._get()
            self.assertEqual(response.status_code, status.HTTP_200_OK)
            self.assertNotIn("ETag", response)
