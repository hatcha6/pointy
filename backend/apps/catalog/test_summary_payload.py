"""The catalog LIST rows drop the full image_attachments gallery (product AND
each nested variant) — the card shows only the primary image, and the detail
screen re-fetches the rest. Each attachment is ~20 fields, so shipping the whole
gallery per product/variant on a heavily paged, ETag-cached endpoint was pure
weight. This guards the trim (and that retrieve still carries the gallery)."""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.contrib.contenttypes.models import ContentType
from django.test import TestCase
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient

from apps.attachments.models import Attachment, StorageVolume
from apps.catalog.models import Product, ProductVariant
from apps.catalog.testing import create_product_with_default_variant
from apps.core.roles import MANAGER_GROUP, ensure_role_groups


class CatalogSummaryPayloadTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.client = APIClient()
        self.user = get_user_model().objects.create_user(username="u", password="p")
        self.user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client.force_authenticate(self.user)
        self.volume = StorageVolume.objects.create(name="vol", path="/tmp/vol")
        self.product = create_product_with_default_variant(
            name="Imaged", sku="IMG-1", unit_price=Decimal("5.00")
        )
        self.variant = self.product.default_variant
        self._image(Product, self.product.id, "p.jpg")
        self._image(ProductVariant, self.variant.id, "v.jpg")

    def _image(self, model, object_id, path):
        Attachment.objects.create(
            owner_content_type=ContentType.objects.get_for_model(model),
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

    def test_list_omits_image_attachments_but_keeps_primary_image(self):
        row = self.client.get(reverse("product-list")).data["results"][0]

        self.assertNotIn("image_attachments", row)
        self.assertIsNotNone(row["primary_image"])  # the card thumbnail stays
        variant_row = row["variants"][0]
        self.assertNotIn("image_attachments", variant_row)
        self.assertIsNotNone(variant_row["primary_image"])

    def test_retrieve_still_carries_the_full_gallery(self):
        row = self.client.get(
            reverse("product-detail", args=[self.product.id])
        ).data

        self.assertIn("image_attachments", row)
        self.assertEqual(len(row["image_attachments"]), 1)
        self.assertIn("image_attachments", row["variants"][0])
