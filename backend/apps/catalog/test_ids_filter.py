"""``GET /api/products/?ids=`` fetches a known set of products in one request.

The purchase-order editor rebuilds a draft from an order's lines and needs each
line's full product (variants, units). It used to fetch product-detail once per
line in parallel — up to 59 requests to open one order in the field. One list
request for the whole order replaces that; archived products stay reachable with
``archived=all`` because an order may still point at one.
"""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.urls import reverse
from django.utils import timezone
from rest_framework import status
from rest_framework.test import APIClient

from apps.catalog.testing import create_product_with_default_variant
from apps.core.roles import MANAGER_GROUP, ensure_role_groups


class ProductIdsFilterTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.client = APIClient()
        user = get_user_model().objects.create_user(username="u", password="p")
        user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client.force_authenticate(user)
        self.first = create_product_with_default_variant(
            name="First", sku="F-1", unit_price=Decimal("1.00")
        )
        self.second = create_product_with_default_variant(
            name="Second", sku="S-1", unit_price=Decimal("2.00")
        )
        self.other = create_product_with_default_variant(
            name="Other", sku="O-1", unit_price=Decimal("3.00")
        )
        self.archived = create_product_with_default_variant(
            name="Archived", sku="A-1", unit_price=Decimal("4.00")
        )
        self.archived.archived_at = timezone.now()
        self.archived.save(update_fields=["archived_at"])

    def _ids(self, response):
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        return sorted(row["id"] for row in response.data["results"])

    def test_ids_returns_exactly_the_requested_products(self):
        response = self.client.get(
            reverse("product-list"), {"ids": f"{self.first.id},{self.second.id}"}
        )
        self.assertEqual(self._ids(response), sorted([self.first.id, self.second.id]))
        row = next(r for r in response.data["results"] if r["id"] == self.first.id)
        # The editor needs the variant tree, so the rows are full catalog rows.
        self.assertEqual(row["variants"][0]["sku"], "F-1")

    def test_unknown_ids_are_simply_absent(self):
        response = self.client.get(reverse("product-list"), {"ids": f"{self.first.id},999999"})
        self.assertEqual(self._ids(response), [self.first.id])

    def test_archived_products_need_archived_all(self):
        hidden = self.client.get(reverse("product-list"), {"ids": str(self.archived.id)})
        self.assertEqual(self._ids(hidden), [])
        shown = self.client.get(
            reverse("product-list"),
            {"ids": f"{self.archived.id},{self.first.id}", "archived": "all"},
        )
        self.assertEqual(self._ids(shown), sorted([self.archived.id, self.first.id]))

    def test_ids_combined_with_is_active_true_bypasses_the_whole_catalog_cache(self):
        response = self.client.get(
            reverse("product-list"), {"ids": str(self.first.id), "is_active": "true"}
        )
        self.assertEqual(self._ids(response), [self.first.id])
