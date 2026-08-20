"""Regression tests: the catalog list endpoints must issue a constant number
of queries regardless of how many products/variants are on the page.

Field telemetry from the first client showed product-list and product-variant-list
(the hot POS browsing paths) running dozens of queries per request because the
serialized image attachments and the variant list's product_detail chains were
not prefetched. These tests lock the query count flat as the row count grows, so
a future serializer change that reintroduces a per-row query fails loudly.
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
from apps.core.roles import MANAGER_GROUP, ensure_role_groups

from .models import (
    ModifierGroup,
    ModifierOption,
    Product,
    ProductCategory,
    ProductUnit,
    ProductVariant,
    UnitOfMeasure,
)


@override_settings(
    CACHES={"default": {"BACKEND": "django.core.cache.backends.locmem.LocMemCache"}}
)
class CatalogListQueryScalingTests(TestCase):
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
        # A packaging unit on every product: ``unit_detail`` nests
        # UnitOfMeasureSerializer, whose product_count falls back to a COUNT once
        # per *serialization* -- so without the annotated prefetch this is one
        # query per row even though every row shares the one unit object.
        self.pack_unit = UnitOfMeasure.objects.get_or_create(
            code="scalingbox",
            defaults={"name": "box"},
        )[0]

    def _add_products(self, count):
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
            ProductUnit.objects.create(
                product=product,
                unit=self.pack_unit,
                factor_to_base=Decimal("12"),
            )
            self._add_image(self.product_ct, product.id, f"p/{i}.jpg")
            for v in range(2):
                variant = ProductVariant.objects.create(
                    product=product,
                    name=f"v{v}",
                    sku=f"S{i}-{v}",
                    unit_price=Decimal("5"),
                    is_active=True,
                    is_default=(v == 0),
                )
                self._add_image(self.variant_ct, variant.id, f"v/{i}-{v}.jpg")

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
        # Warm the per-request caches (catalog version stamp, permission cache,
        # content-type cache) so the measured request reflects only steady-state
        # query cost — otherwise first-request warmup masks the comparison.
        self.client.get(url)
        with CaptureQueriesContext(connection) as ctx:
            response = self.client.get(url)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data["count"], expected_rows)
        return len(ctx.captured_queries)

    def test_product_list_query_count_does_not_grow_with_rows(self):
        # Plain list (no ?is_active=true) to bypass the single-flight active-id
        # cache; the serializer N+1 under test is independent of the filter.
        url = reverse("product-list")
        self._add_products(3)
        small = self._measure(url, expected_rows=3)
        self._add_products(5)
        large = self._measure(url, expected_rows=8)
        self.assertEqual(
            small,
            large,
            f"product-list scaled with rows: {small} -> {large} queries (N+1)",
        )

    def test_variant_list_query_count_does_not_grow_with_rows(self):
        url = reverse("product-variant-list")
        self._add_products(3)
        small = self._measure(url, expected_rows=6)
        self._add_products(5)
        large = self._measure(url, expected_rows=16)
        self.assertEqual(
            small,
            large,
            f"product-variant-list scaled with rows: {small} -> {large} queries (N+1)",
        )
