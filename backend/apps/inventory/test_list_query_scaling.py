"""Regression tests for the inventory list endpoints' payload and query cost.

Both ``stock/`` and ``stock-movements/`` used to embed the full
``ProductCatalogSerializer`` as ``product_detail`` — an entire product tree
(categories, units, sibling variants, option values, modifier groups, image
attachments, on-hand stock) on every row, which no client read, at a measured 23
queries per row. The field is gone; these tests keep it gone and lock the query
count flat as the row count grows.
"""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.contrib.contenttypes.models import ContentType
from django.db import connection
from django.test import TestCase, override_settings
from django.test.utils import CaptureQueriesContext
from django.urls import reverse
from rest_framework.test import APIClient

from apps.attachments.models import Attachment, StorageVolume
from apps.catalog.models import (
    ModifierGroup,
    ModifierOption,
    Product,
    ProductCategory,
    ProductVariant,
)
from apps.core.roles import MANAGER_GROUP, ensure_role_groups

from .models import StockItem, StockMovement


@override_settings(
    CACHES={"default": {"BACKEND": "django.core.cache.backends.locmem.LocMemCache"}}
)
class InventoryListQueryScalingTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.client = APIClient()
        self.user = get_user_model().objects.create_user(username="u", password="p")
        self.user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client.force_authenticate(user=self.user)
        self.volume = StorageVolume.objects.create(name="vol", path="/tmp/vol")
        self.product_ct = ContentType.objects.get_for_model(Product)
        self.variant_ct = ContentType.objects.get_for_model(ProductVariant)
        self._seq = 0

    def _add_rows(self, count):
        """Each row = its own product/variant, one stock item and one movement."""
        for _ in range(count):
            self._seq += 1
            i = self._seq
            category = ProductCategory.objects.create(name=f"cat{i}")
            group = ModifierGroup.objects.create(name=f"grp{i}")
            ModifierOption.objects.create(
                group=group, name=f"opt{i}", price_delta=Decimal("1")
            )
            product = Product.objects.create(name=f"p{i}", is_active=True)
            product.categories.add(category)
            product.modifier_groups.add(group)
            self._add_image(self.product_ct, product.id, f"p/{i}.jpg")
            variant = ProductVariant.objects.create(
                product=product,
                name=f"v{i}",
                sku=f"S{i}",
                unit_price=Decimal("5"),
                is_active=True,
                is_default=True,
            )
            self._add_image(self.variant_ct, variant.id, f"v/{i}.jpg")
            stock_item = StockItem.objects.create(
                variant=variant,
                quantity_on_hand=Decimal("7"),
            )
            StockMovement.objects.create(
                stock_item=stock_item,
                variant=variant,
                movement_type=StockMovement.Type.INCREASE,
                quantity=Decimal("7"),
                created_by=self.user,
                on_hand_before=Decimal("0"),
                on_hand_after=Decimal("7"),
                committed_before=Decimal("0"),
                committed_after=Decimal("0"),
                expected_before=Decimal("0"),
                expected_after=Decimal("0"),
            )

    def _add_image(self, content_type, object_id, path):
        Attachment.objects.create(
            owner_content_type=content_type,
            owner_object_id=object_id,
            role=Attachment.Role.PRODUCT_IMAGE,
            storage_volume=self.volume,
            relative_path=path,
            original_filename=path,
            original_size=10,
            stored_size=10,
            checksum_sha256="x",
            is_primary=True,
            created_by=self.user,
        )

    def _measure(self, url, expected_rows):
        # Warm the per-request caches (permission cache, content types) so the
        # measured request reflects steady-state cost only.
        self.client.get(url)
        with CaptureQueriesContext(connection) as ctx:
            response = self.client.get(url)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data["count"], expected_rows)
        return len(ctx.captured_queries)

    def test_stock_list_query_count_does_not_grow_with_rows(self):
        url = reverse("stockitem-list")
        self._add_rows(3)
        small = self._measure(url, expected_rows=3)
        self._add_rows(5)
        large = self._measure(url, expected_rows=8)
        self.assertEqual(
            small,
            large,
            f"stock-list scaled with rows: {small} -> {large} queries (N+1)",
        )

    def test_stock_movement_list_query_count_does_not_grow_with_rows(self):
        url = reverse("stockmovement-list")
        self._add_rows(3)
        small = self._measure(url, expected_rows=3)
        self._add_rows(5)
        large = self._measure(url, expected_rows=8)
        self.assertEqual(
            small,
            large,
            f"stock-movement-list scaled with rows: {small} -> {large} queries (N+1)",
        )

    def test_movement_list_expands_a_shared_product_once(self):
        """The real caller filters by product, so a page shares one product.

        Prefetching the forward FK (rather than select_related) de-duplicates it:
        adding more movements for the same product must not add queries.
        """
        self._add_rows(1)
        variant = ProductVariant.objects.get()
        stock_item = StockItem.objects.get()
        url = f"{reverse('stockmovement-list')}?product={variant.product_id}"
        one = self._measure(url, expected_rows=1)
        for _ in range(7):
            StockMovement.objects.create(
                stock_item=stock_item,
                variant=variant,
                movement_type=StockMovement.Type.INCREASE,
                quantity=Decimal("1"),
                created_by=self.user,
                on_hand_before=Decimal("0"),
                on_hand_after=Decimal("1"),
                committed_before=Decimal("0"),
                committed_after=Decimal("0"),
                expected_before=Decimal("0"),
                expected_after=Decimal("0"),
            )
        many = self._measure(url, expected_rows=8)
        self.assertEqual(
            one,
            many,
            f"a shared product re-expanded per row: {one} -> {many} queries",
        )

    def test_rows_carry_no_embedded_product_tree(self):
        """The heavy ``product_detail`` field stays gone from both endpoints.

        Each row keeps the identifiers a caller needs to fetch the product from
        the catalog endpoints (``product``, ``variant``, sku and names) — just
        not an inlined copy of it.
        """
        self._add_rows(1)
        for url in (reverse("stockitem-list"), reverse("stockmovement-list")):
            row = self.client.get(url).data["results"][0]
            self.assertNotIn("product_detail", row)
            self.assertIn("product", row)
            self.assertIn("variant", row)
            self.assertEqual(row["variant_sku"], "S1")
            self.assertEqual(row["variant_name"], "v1")
            self.assertEqual(row["variant_full_name"], "p1 - v1")
