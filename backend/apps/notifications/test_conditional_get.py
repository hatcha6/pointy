"""Tests for the notifications feed ETag / 304 (cache.py + views.py).

The version machinery is globally disabled under the test runner, so these
tests opt back in explicitly with an isolated LocMem cache.
"""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.core.cache import cache
from django.test import TestCase, override_settings
from rest_framework import status
from rest_framework.test import APIClient

from apps.catalog.testing import create_product_with_default_variant
from apps.core.roles import MANAGER_GROUP
from apps.inventory.models import StockItem
from apps.notifications.services import sync_business_notifications

CACHED = override_settings(
    CACHES={
        "default": {
            "BACKEND": "django.core.cache.backends.locmem.LocMemCache",
            "LOCATION": "notifications-etag-tests",
        },
    },
    POINTY_NOTIFICATIONS_CACHE_ENABLED=True,
)


@CACHED
class NotificationsConditionalGetTests(TestCase):
    def setUp(self):
        cache.clear()
        user = get_user_model().objects.create_user(username="manager", password="x")
        user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.user = user
        self.client_api = APIClient()
        self.client_api.force_authenticate(user=user)
        # A deterministic out-of-stock condition the sync keeps re-asserting.
        self.product = create_product_with_default_variant(
            name="Widget", sku="W-1", unit_price="10.00", barcode="123456"
        )
        StockItem.objects.create(
            variant=self.product.variants.get(),
            quantity_on_hand=Decimal("0"),
        )
        sync_business_notifications()

    def _get(self, etag=None, path="/api/business-notifications/"):
        headers = {"HTTP_IF_NONE_MATCH": etag} if etag else {}
        return self.client_api.get(path, **headers)

    def test_list_carries_an_etag_and_revalidates_to_304(self):
        response = self._get()
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertTrue(response.data["results"])  # the out-of-stock row is visible
        etag = response["ETag"]
        self.assertTrue(etag)

        revalidated = self._get(etag=etag)
        self.assertEqual(revalidated.status_code, status.HTTP_304_NOT_MODIFIED)
        self.assertEqual(revalidated["ETag"], etag)
        self.assertFalse(revalidated.content)

    def test_resync_without_material_change_keeps_the_etag(self):
        # The beat re-runs the sync every few minutes and rewrites
        # last_seen_at on every persisting row; that alone must NOT orphan
        # every device's ETag.
        etag = self._get()["ETag"]
        sync_business_notifications()
        revalidated = self._get(etag=etag)
        self.assertEqual(revalidated.status_code, status.HTTP_304_NOT_MODIFIED)

    def test_material_sync_change_invalidates_the_etag(self):
        etag = self._get()["ETag"]
        # A second product going out of stock creates a new notification.
        second = create_product_with_default_variant(
            name="Gadget", sku="G-1", unit_price="5.00", barcode="654321"
        )
        StockItem.objects.create(
            variant=second.variants.get(),
            quantity_on_hand=Decimal("0"),
        )
        sync_business_notifications()
        response = self._get(etag=etag)
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertNotEqual(response["ETag"], etag)

    def test_dismissing_invalidates_only_that_users_etag(self):
        first = self._get()
        etag = first["ETag"]
        notification_id = first.data["results"][0]["id"]

        other = get_user_model().objects.create_user(username="manager2", password="x")
        other.groups.add(Group.objects.get(name=MANAGER_GROUP))
        other_client = APIClient()
        other_client.force_authenticate(user=other)
        other_etag = other_client.get("/api/business-notifications/")["ETag"]

        dismiss = self.client_api.post(
            f"/api/business-notifications/{notification_id}/dismiss/"
        )
        self.assertEqual(dismiss.status_code, status.HTTP_200_OK)

        # The dismissing user's next poll must see the change...
        response = self._get(etag=etag)
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertNotEqual(response["ETag"], etag)
        # ...while the other user's cached copy stays valid.
        other_revalidated = other_client.get(
            "/api/business-notifications/", HTTP_IF_NONE_MATCH=other_etag
        )
        self.assertEqual(
            other_revalidated.status_code, status.HTTP_304_NOT_MODIFIED
        )

    def test_etag_is_scoped_per_user(self):
        etag = self._get()["ETag"]
        other = get_user_model().objects.create_user(username="manager3", password="x")
        other.groups.add(Group.objects.get(name=MANAGER_GROUP))
        other_client = APIClient()
        other_client.force_authenticate(user=other)
        response = other_client.get(
            "/api/business-notifications/", HTTP_IF_NONE_MATCH=etag
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertNotEqual(response["ETag"], etag)

    def test_no_etag_when_disabled(self):
        with override_settings(POINTY_NOTIFICATIONS_CACHE_ENABLED=False):
            response = self._get()
            self.assertEqual(response.status_code, status.HTTP_200_OK)
            self.assertNotIn("ETag", response)