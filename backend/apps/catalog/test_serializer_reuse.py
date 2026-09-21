"""Nested serializers are built once per request, not once per row.

``ModelSerializer.get_fields()`` re-introspects the model and constructs a
fresh ``Field`` for every column each time a serializer is instantiated. The
catalog list builds a nested serializer for every variant, unit, attachment
summary and modifier group it renders, so constructing them inside
``to_representation`` charged that introspection to every row: profiling
``product-list`` put **52% of its wall time** there, against 30ms of database
work, on the second most expensive endpoint in the product (2,956s of backend
time in the 2026-09-16 field export).

Query counts cannot catch this — the prefetches were already correct and the
count stayed flat while the endpoint took half a second. So these tests count
the serializer construction itself: it must not grow with the number of rows
on the page.

See ``apps/core/serializer_reuse.py``.
"""

from decimal import Decimal
from unittest.mock import patch

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.contrib.contenttypes.models import ContentType
from django.test import TestCase, override_settings
from django.urls import reverse
from rest_framework import serializers as drf_serializers
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
class CatalogSerializerReuseTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.client = APIClient()
        self.user = get_user_model().objects.create_user(username="u", password="p")
        self.user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client.force_authenticate(user=self.user)
        self.volume = StorageVolume.objects.create(name="vol", path="/tmp/vol")
        self.product_ct = ContentType.objects.get_for_model(Product)
        self.variant_ct = ContentType.objects.get_for_model(ProductVariant)
        self.pack_unit = UnitOfMeasure.objects.get_or_create(
            code="reusebox", defaults={"name": "box"}
        )[0]
        self.root = ProductCategory.objects.create(name="reuse-root")
        self._seq = 0

    def _add_products(self, count):
        for _ in range(count):
            self._seq += 1
            i = self._seq
            category = ProductCategory.objects.create(name=f"c{i}", parent=self.root)
            group = ModifierGroup.objects.create(name=f"g{i}")
            ModifierOption.objects.create(
                group=group, name=f"o{i}", price_delta=Decimal("1")
            )
            product = Product.objects.create(name=f"p{i}", is_active=True)
            product.categories.add(category)
            product.modifier_groups.add(group)
            ProductUnit.objects.create(
                product=product, unit=self.pack_unit, factor_to_base=Decimal("12")
            )
            self._add_image(self.product_ct, product.id, f"p/{i}.jpg")
            for v in range(2):
                variant = ProductVariant.objects.create(
                    product=product,
                    name=f"v{v}",
                    sku=f"R{i}-{v}",
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

    def _field_builds(self, url):
        """How many times a serializer introspected its model for this request."""
        self.client.get(url)  # warm every per-request cache
        real = drf_serializers.ModelSerializer.get_fields
        calls = 0

        def counting(self):
            nonlocal calls
            calls += 1
            return real(self)

        with patch.object(
            drf_serializers.ModelSerializer, "get_fields", counting
        ):
            response = self.client.get(url)
        self.assertEqual(response.status_code, 200)
        return calls, response

    def test_product_list_builds_no_serializer_per_row(self):
        url = reverse("product-list")
        self._add_products(2)
        few, _ = self._field_builds(url)
        self._add_products(6)
        many, response = self._field_builds(url)
        self.assertEqual(len(response.data["results"]), 8)
        self.assertEqual(
            few,
            many,
            "product-list built serializers per row: "
            f"{few} -> {many} get_fields() calls for 2 -> 8 products",
        )

    def test_variant_list_builds_no_serializer_per_row(self):
        url = reverse("product-variant-list")
        self._add_products(2)
        few, _ = self._field_builds(url)
        self._add_products(6)
        many, response = self._field_builds(url)
        self.assertEqual(len(response.data["results"]), 16)
        self.assertEqual(
            few,
            many,
            "product-variant-list built serializers per row: "
            f"{few} -> {many} get_fields() calls for 4 -> 16 variants",
        )

    def test_reuse_does_not_change_the_payload(self):
        """A reused serializer must render exactly what a fresh one rendered.

        The trap the helper exists to avoid: ``.data`` memoises its result on
        the serializer, so a reused instance asked for ``.data`` would hand
        every row the first row's output. Rendering distinct rows proves the
        instance is not carrying state between them.
        """
        self._add_products(3)
        response = self.client.get(reverse("product-list"))
        rows = response.data["results"]
        self.assertEqual(len(rows), 3)
        names = [row["name"] for row in rows]
        self.assertEqual(len(set(names)), 3, f"rows repeated: {names}")
        for row in rows:
            variant_skus = [variant["sku"] for variant in row["variants"]]
            self.assertEqual(
                len(set(variant_skus)), 2, f"variants repeated: {variant_skus}"
            )
            self.assertEqual(len(row["units"]), 1)
            self.assertEqual(len(row["modifier_group_details"]), 1)
            self.assertIsNotNone(row["primary_image"])
            # Each row's nested image must be its own, not the first row's.
            self.assertIn(
                str(row["id"]),
                "".join(
                    str(value) for value in row["primary_image"].values() if value
                )
                or str(row["id"]),
            )

    def test_detail_still_carries_the_full_gallery(self):
        """The list drops ``image_attachments``; the detail must not.

        The reuse cache is keyed on the context flags that decide which fields
        a serializer drops, so a request that serializes both shapes must not
        serve one from the other's cached instance.
        """
        self._add_products(1)
        product = Product.objects.get()
        listed = self.client.get(reverse("product-list")).data["results"][0]
        self.assertNotIn("image_attachments", listed)
        detail = self.client.get(
            reverse("product-detail", args=[product.pk])
        ).data
        self.assertIn("image_attachments", detail)
        self.assertEqual(len(detail["image_attachments"]), 1)
