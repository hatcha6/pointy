"""Regression test: ``products/<id>/variants/`` must not query per variant.

The action is the product-detail screen's variant list. It hand-rolled its own
prefetch list instead of the shared ``variant_detail_queryset()`` that
``ProductVariantSerializer`` needs, so every relation the shorter list omitted
(the 1:1 stock row, the parent product's categories/units/variant-options/
modifier groups, each image attachment's own FKs) fired once per variant.
"""

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
from apps.core.roles import MANAGER_GROUP, ensure_role_groups
from apps.inventory.models import StockItem

from .models import (
    ModifierGroup,
    ModifierOption,
    Product,
    ProductCategory,
    ProductUnit,
    ProductVariant,
    UnitOfMeasure,
    VariantOption,
    VariantOptionValue,
)
from .serializers import ProductVariantSerializer


@override_settings(
    CACHES={"default": {"BACKEND": "django.core.cache.backends.locmem.LocMemCache"}}
)
class ProductVariantsActionQueryScalingTests(TestCase):
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

        category = ProductCategory.objects.create(name="cat")
        group = ModifierGroup.objects.create(name="grp")
        ModifierOption.objects.create(group=group, name="opt", price_delta=Decimal("1"))
        self.product = Product.objects.create(name="p", is_active=True)
        self.product.categories.add(category)
        self.product.modifier_groups.add(group)
        self._add_image(self.product_ct, self.product.id, "p/1.jpg")

        box = UnitOfMeasure.objects.get_or_create(code="box", defaults={"name": "box"})[0]
        ProductUnit.objects.create(
            product=self.product, unit=box, factor_to_base=Decimal("12")
        )

        self.option = VariantOption.objects.create(code="testsize", name="Size")
        self.product.variant_options.add(self.option)

    def _add_variants(self, count):
        for _ in range(count):
            self._seq += 1
            i = self._seq
            variant = ProductVariant.objects.create(
                product=self.product,
                name="",
                sku=f"S{i}",
                unit_price=Decimal("5"),
                is_active=True,
                is_default=(i == 1),
            )
            value = VariantOptionValue.objects.create(
                option=self.option, code=f"v{i}", name=f"V{i}"
            )
            variant.option_values.add(value)
            StockItem.objects.create(variant=variant, quantity_on_hand=Decimal("3"))
            self._add_image(self.variant_ct, variant.id, f"v/{i}.jpg")

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
        # Warm the permission / content-type / catalog-version caches so the
        # measured request reflects steady state, not first-request warmup.
        self.client.get(url)
        with CaptureQueriesContext(connection) as ctx:
            response = self.client.get(url)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data["count"], expected_rows)
        return len(ctx.captured_queries), response.data["results"]

    def test_query_count_does_not_grow_with_variants(self):
        url = reverse("product-variants", args=[self.product.pk])
        self._add_variants(3)
        small, _ = self._measure(url, expected_rows=3)
        self._add_variants(3)
        large, _ = self._measure(url, expected_rows=6)
        self.assertEqual(
            small,
            large,
            f"product-variants scaled with rows: {small} -> {large} queries (N+1)",
        )

    def test_payload_matches_an_unprefetched_serialization(self):
        """The prefetch must change where the values come from, never what they say."""
        self._add_variants(3)
        url = reverse("product-variants", args=[self.product.pk])
        primed = self.client.get(url).data["results"]

        request = APIRequestFactory().get(url)
        request.user = self.user
        cold = ProductVariantSerializer(
            # No prefetch at all: every relation resolves with its own query.
            ProductVariant.objects.filter(product=self.product).order_by(
                "-is_default", "name", "id"
            ),
            many=True,
            context={"request": Request(request)},
        ).data
        self.assertEqual(primed, cold)
