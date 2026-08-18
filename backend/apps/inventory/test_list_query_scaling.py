"""Regression tests: the inventory list endpoints must issue a constant number
of queries regardless of how many rows are on the page.

Both ``stock/`` and ``stock-movements/`` embed the full ``ProductCatalogSerializer``
as ``product_detail``. The viewsets only ``select_related`` variant/product, so
every deep relation that serializer reads (categories, units, variants,
option_values, modifier groups, image attachments, on-hand stock) fired once per
row. These tests lock the query count flat as the row count grows.
"""

import json
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.contrib.contenttypes.models import ContentType
from django.db import connection
from django.test import TestCase, override_settings
from django.test.utils import CaptureQueriesContext
from django.urls import reverse
from rest_framework.request import Request
from rest_framework.test import APIClient, APIRequestFactory

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
from .serializers import StockMovementSerializer


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

    def test_product_detail_payload_is_unchanged_by_the_prefetch(self):
        """The prefetch/annotation must be invisible in the response body.

        ``quantity_on_hand`` now comes from an annotation instead of
        ``Product.quantity_on_hand``'s aggregate, so compare the tuned payload
        against one rendered from a bare (un-prefetched, un-annotated) instance.
        """
        self._add_rows(2)
        # The annotation sums over every variant of the product, so cover a
        # product with a second variant that has stock and a third with no stock
        # row at all — the shapes where a Sum and the aggregate could disagree.
        product = Product.objects.order_by("id").first()
        sibling = ProductVariant.objects.create(
            product=product,
            name="sibling",
            sku="SIB",
            unit_price=Decimal("5"),
            is_active=True,
        )
        StockItem.objects.create(variant=sibling, quantity_on_hand=Decimal("4"))
        ProductVariant.objects.create(
            product=product,
            name="stockless",
            sku="NOSTOCK",
            unit_price=Decimal("5"),
            is_active=True,
        )

        response = self.client.get(reverse("stockmovement-list"))
        self.assertEqual(response.status_code, 200)
        rows = response.data["results"]
        self.assertEqual(len(rows), 2)
        # Same context as the view, so attachment URLs stay absolute either way.
        context = {"request": Request(APIRequestFactory().get("/"))}
        for row in rows:
            cold = StockMovement.objects.get(pk=row["id"])
            expected = StockMovementSerializer(cold, context=context).data
            self.assertEqual(
                json.loads(json.dumps(row, default=str)),
                json.loads(json.dumps(expected, default=str)),
            )
