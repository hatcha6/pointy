"""Regression test: detail actions that only need a product's *identity* must
not drag the catalog prefetch tree along.

``ProductViewSet.queryset`` prefetches thirteen relations because the POS
catalog list serializes all of them. ``get_object()`` runs that same queryset
for every detail route, so the product-details screen's side tabs --
``attachments`` (serializes ``product.attachments``), ``variants`` (rebuilds
its own ``variant_detail_queryset()``) and ``bought-together`` (uses the row's
id) -- each paid the whole tree and threw every prefetched row away.

The tests below force the tree back on and compare, so they measure the saving
rather than asserting a fixture-specific magic number, and they check the
payload is byte-identical either way: dropping a prefetch must change where a
value is read from, never what it says.
"""

from decimal import Decimal
from unittest.mock import patch

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
from .views import ProductViewSet


def _without_rotating_tokens(payload):
    """Attachment ``content_url``s re-sign per serialization, so two identical
    payloads never compare equal until the token is stripped."""
    if isinstance(payload, list):
        return [_without_rotating_tokens(item) for item in payload]
    if isinstance(payload, dict):
        return {key: _without_rotating_tokens(value) for key, value in payload.items()}
    if isinstance(payload, str) and "token=" in payload:
        return payload.split("token=")[0]
    return payload


@override_settings(
    CACHES={"default": {"BACKEND": "django.core.cache.backends.locmem.LocMemCache"}}
)
class ProductIdentityOnlyActionTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.client = APIClient()
        self.user = get_user_model().objects.create_user(username="u", password="p")
        self.user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client.force_authenticate(user=self.user)
        self.volume = StorageVolume.objects.create(name="vol", path="/tmp/vol")
        self.product_ct = ContentType.objects.get_for_model(Product)
        self.variant_ct = ContentType.objects.get_for_model(ProductVariant)

        # A product rich enough that every prefetch in the catalog tree has rows
        # to fetch -- an unpopulated relation makes the waste invisible.
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
        for index in range(1, 4):
            variant = ProductVariant.objects.create(
                product=self.product,
                name="",
                sku=f"S{index}",
                unit_price=Decimal("5"),
                is_active=True,
                is_default=(index == 1),
            )
            value = VariantOptionValue.objects.create(
                option=self.option, code=f"v{index}", name=f"V{index}"
            )
            variant.option_values.add(value)
            StockItem.objects.create(variant=variant, quantity_on_hand=Decimal("3"))
            self._add_image(self.variant_ct, variant.id, f"v/{index}.jpg")

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

    def _measure(self, url):
        # Warm the permission / content-type / catalog-version caches so the
        # measured request reflects steady state, not first-request warmup.
        self.client.get(url)
        with CaptureQueriesContext(connection) as ctx:
            response = self.client.get(url)
        self.assertEqual(response.status_code, 200)
        return len(ctx.captured_queries), _without_rotating_tokens(response.json())

    def _compare(self, url, minimum_saving):
        # ``create=True`` so this reads as a clean assertion failure -- not an
        # AttributeError -- on a tree where the optimization is absent.
        with patch.object(ProductViewSet, "identity_only_actions", frozenset(), create=True):
            heavy_queries, heavy_body = self._measure(url)
        lean_queries, lean_body = self._measure(url)
        self.assertEqual(
            lean_body,
            heavy_body,
            "dropping the prefetch tree changed the payload",
        )
        self.assertLessEqual(
            lean_queries,
            heavy_queries - minimum_saving,
            f"{url} still pays the catalog prefetch tree: "
            f"{heavy_queries} queries with it, {lean_queries} without",
        )

    def test_attachments_tab_skips_the_catalog_prefetch_tree(self):
        self._compare(reverse("product-attachments", args=[self.product.pk]), 8)

    def test_variants_tab_skips_the_catalog_prefetch_tree(self):
        self._compare(reverse("product-variants", args=[self.product.pk]), 8)

    def test_bought_together_skips_the_catalog_prefetch_tree(self):
        self._compare(reverse("product-bought-together", args=[self.product.pk]), 8)

    def test_actions_that_serialize_the_product_keep_the_prefetch_tree(self):
        """The guard on the other side: ``retrieve``/``archive``/``restore``
        answer with ``ProductCatalogSerializer``, so adding them to the
        identity-only set would trade thirteen prefetches for an N+1 per
        variant. Their query count must not move when the tree is forced on."""
        url = reverse("product-detail", args=[self.product.pk])
        with patch.object(ProductViewSet, "identity_only_actions", frozenset(), create=True):
            heavy_queries, heavy_body = self._measure(url)
        lean_queries, lean_body = self._measure(url)
        self.assertEqual(lean_body, heavy_body)
        self.assertEqual(
            lean_queries,
            heavy_queries,
            "product-detail no longer prefetches the catalog tree",
        )
