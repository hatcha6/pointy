"""Catalog pricing-integrity tests.

User priority for this hardening pass: "prices don't change on their own" and
"all kinds of products and their variants work correctly". These cover the
guards in :meth:`Product.ensure_default_variant` /
:meth:`Product._default_variant_defaults` (which must NOT silently reset
``unit_price`` to 0 or regenerate the SKU on a partial product update), the
independence of per-variant prices, the unit-pricing engine's price derivation,
SKU/barcode normalisation and uniqueness, and the ``active()`` queryset's
exclusion of archived products.

Existing coverage (apps/catalog/tests.py, apps/catalog/test_units.py) already
exercises: model-level SKU/barcode uniqueness, ``active()`` excluding an
inactive variant and an inactive product, derived/custom unit pricing at the
engine level, and basic create/update of generated variants. These tests add
the missing *immutability* and *cross-product* scenarios.
"""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.db import IntegrityError, transaction
from django.test import TestCase
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient

from apps.catalog.models import (
    Product,
    ProductUnit,
    ProductVariant,
    UnitOfMeasure,
)
from apps.catalog.serializers import (
    ProductCatalogSerializer,
    ProductVariantSerializer,
)
from apps.catalog.testing import create_product_with_default_variant
from apps.catalog.units import resolve_unit, unit_sale_price
from apps.core.roles import MANAGER_GROUP, ensure_role_groups


class PriceImmutabilityOnReadTests(TestCase):
    """Reading / serialising a product must never write to the DB."""

    def test_reading_default_variant_does_not_mutate_unit_price(self):
        product = create_product_with_default_variant(
            name="Espresso", sku="ESP", unit_price="3.50"
        )
        variant_pk = product.default_variant.pk

        # Read it many ways; none should issue a write.
        for _ in range(3):
            _ = product.default_variant
            _ = product.default_variant.unit_price

        fresh = ProductVariant.objects.get(pk=variant_pk)
        self.assertEqual(fresh.unit_price, Decimal("3.50"))
        # Reading must not have spawned a second variant either.
        self.assertEqual(product.variants.count(), 1)

    def test_serializing_product_does_not_mutate_unit_price_or_sku(self):
        product = create_product_with_default_variant(
            name="Latte", sku="LAT-1", unit_price="6.00"
        )
        variant_pk = product.default_variant.pk

        data = ProductCatalogSerializer(product).data
        self.assertEqual(data["default_variant"]["unit_price"], "6.00")
        self.assertEqual(data["default_variant"]["sku"], "LAT-1")

        fresh = ProductVariant.objects.get(pk=variant_pk)
        self.assertEqual(fresh.unit_price, Decimal("6.00"))
        self.assertEqual(fresh.sku, "LAT-1")


class PartialUpdatePriceImmutabilityTests(TestCase):
    """A product edit that omits ``unit_price`` must not reset it to 0 or
    regenerate the variant SKU — the core "prices don't change on their own"
    guard around ``ensure_default_variant`` / ``_default_variant_defaults``."""

    def setUp(self):
        ensure_role_groups()
        self.client = APIClient()
        self.user = get_user_model().objects.create_user(
            username="pricing-manager", password="pass"
        )
        self.user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client.force_authenticate(user=self.user)

    def test_rename_via_api_without_default_variant_keeps_price_and_sku(self):
        """The common edit: PATCH only the product name, no variant payload."""
        product = create_product_with_default_variant(
            name="Old name", sku="KEEP-1", unit_price="9.99"
        )
        variant = product.default_variant

        response = self.client.patch(
            reverse("product-detail", args=[product.pk]),
            {"name": "New name"},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        product.refresh_from_db()
        variant.refresh_from_db()
        self.assertEqual(product.name, "New name")
        self.assertEqual(variant.unit_price, Decimal("9.99"))
        self.assertEqual(variant.sku, "KEEP-1")
        # The serialised response also reports the unchanged price.
        self.assertEqual(response.data["default_variant"]["unit_price"], "9.99")

    def test_partial_default_variant_payload_omitting_price_keeps_price(self):
        """A default_variant block that updates only the barcode must not zero
        the price (defaults dict is built but only present fields are applied)."""
        product = create_product_with_default_variant(
            name="Tea", sku="TEA-7", unit_price="4.25"
        )
        variant = product.default_variant

        response = self.client.patch(
            reverse("product-detail", args=[product.pk]),
            {"default_variant": {"barcode": "BAR-NEW"}},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        variant.refresh_from_db()
        self.assertEqual(variant.unit_price, Decimal("4.25"))
        self.assertEqual(variant.barcode, "BAR-NEW")
        # SKU must be the original, not a freshly generated one.
        self.assertEqual(variant.sku, "TEA-7")

    def test_ensure_default_variant_without_price_does_not_reset_existing(self):
        """Directly: ensure_default_variant called with no unit_price must leave
        the existing variant's price and SKU alone."""
        product = create_product_with_default_variant(
            name="Juice", sku="JUI-3", unit_price="2.50"
        )
        variant = product.default_variant

        returned = product.ensure_default_variant(name="Juice updated")

        self.assertEqual(returned.pk, variant.pk)
        variant.refresh_from_db()
        self.assertEqual(variant.unit_price, Decimal("2.50"))
        self.assertEqual(variant.sku, "JUI-3")
        self.assertEqual(variant.name, "Juice updated")
        self.assertEqual(product.variants.count(), 1)

    def test_ensure_default_variant_with_price_updates_only_that_field(self):
        """When unit_price IS supplied it should be applied, without touching the
        SKU that was not supplied."""
        product = create_product_with_default_variant(
            name="Cake", sku="CAKE-1", unit_price="10.00"
        )
        variant = product.default_variant

        product.ensure_default_variant(unit_price=Decimal("12.00"))

        variant.refresh_from_db()
        self.assertEqual(variant.unit_price, Decimal("12.00"))
        self.assertEqual(variant.sku, "CAKE-1")

    def test_update_other_product_field_via_serializer_keeps_price(self):
        """Flip is_active through the serializer with no variant data; the
        default-variant block is skipped entirely so the price is untouched."""
        product = create_product_with_default_variant(
            name="Soda", sku="SODA-9", unit_price="1.75"
        )
        variant = product.default_variant

        serializer = ProductCatalogSerializer(
            product, data={"is_active": False}, partial=True
        )
        self.assertTrue(serializer.is_valid(), serializer.errors)
        serializer.save()

        product.refresh_from_db()
        variant.refresh_from_db()
        self.assertFalse(product.is_active)
        self.assertEqual(variant.unit_price, Decimal("1.75"))
        self.assertEqual(variant.sku, "SODA-9")


class MultiVariantPriceIndependenceTests(TestCase):
    """A product with several variants — each keeps its own price."""

    def test_each_variant_keeps_independent_price(self):
        product = create_product_with_default_variant(
            name="Shirt", sku="SH-S", unit_price="20.00"
        )
        medium = ProductVariant.objects.create(
            product=product, name="Medium", sku="SH-M", unit_price=Decimal("22.00")
        )
        large = ProductVariant.objects.create(
            product=product, name="Large", sku="SH-L", unit_price=Decimal("25.00")
        )

        prices = {
            v.sku: v.unit_price
            for v in ProductVariant.objects.filter(product=product)
        }
        self.assertEqual(
            prices,
            {
                "SH-S": Decimal("20.00"),
                "SH-M": Decimal("22.00"),
                "SH-L": Decimal("25.00"),
            },
        )
        # Sanity: ids are distinct and there is exactly one default.
        self.assertEqual(product.variants.filter(is_default=True).count(), 1)
        self.assertNotEqual(medium.pk, large.pk)

    def test_editing_one_variant_price_leaves_siblings_unchanged(self):
        product = create_product_with_default_variant(
            name="Mug", sku="MUG-S", unit_price="5.00"
        )
        big = ProductVariant.objects.create(
            product=product, name="Big", sku="MUG-L", unit_price=Decimal("8.00")
        )

        big.unit_price = Decimal("9.50")
        big.save(update_fields=["unit_price", "updated_at"])

        product.default_variant.refresh_from_db()
        self.assertEqual(product.default_variant.unit_price, Decimal("5.00"))
        big.refresh_from_db()
        self.assertEqual(big.unit_price, Decimal("9.50"))

    def test_variant_endpoint_update_does_not_touch_sibling_price(self):
        """Editing one variant's price through the variant serializer must not
        bleed into the product's other variants."""
        product = create_product_with_default_variant(
            name="Cap", sku="CAP-A", unit_price="11.00"
        )
        other = ProductVariant.objects.create(
            product=product, name="B", sku="CAP-B", unit_price=Decimal("13.00")
        )

        serializer = ProductVariantSerializer(
            other, data={"unit_price": "14.00"}, partial=True
        )
        self.assertTrue(serializer.is_valid(), serializer.errors)
        serializer.save()

        product.default_variant.refresh_from_db()
        other.refresh_from_db()
        self.assertEqual(product.default_variant.unit_price, Decimal("11.00"))
        self.assertEqual(other.unit_price, Decimal("14.00"))


class DefaultVariantRulesTests(TestCase):
    """ensure_default_variant promotes/creates exactly one default and the
    unique-default constraint holds."""

    def test_ensure_default_variant_promotes_existing_non_default(self):
        product = Product.objects.create(name="Promote me")
        variant = ProductVariant.objects.create(
            product=product,
            name="only",
            sku="PROMO-1",
            unit_price=Decimal("7.00"),
            is_default=False,
        )
        self.assertIsNone(product.default_variant)

        returned = product.ensure_default_variant()

        self.assertEqual(returned.pk, variant.pk)
        variant.refresh_from_db()
        self.assertTrue(variant.is_default)
        self.assertEqual(product.variants.filter(is_default=True).count(), 1)
        # Promotion must not have reset the price.
        self.assertEqual(variant.unit_price, Decimal("7.00"))

    def test_ensure_default_variant_creates_when_none_exists(self):
        product = Product.objects.create(name="Empty")

        variant = product.ensure_default_variant(unit_price=Decimal("3.00"))

        self.assertIsNotNone(variant)
        self.assertTrue(variant.is_default)
        self.assertEqual(variant.unit_price, Decimal("3.00"))
        self.assertEqual(variant.sku, f"P{product.pk:06d}")
        self.assertEqual(product.variants.count(), 1)

    def test_unique_default_constraint_blocks_second_default(self):
        product = create_product_with_default_variant(
            name="Dup default", sku="DD-1", unit_price="1.00"
        )

        with self.assertRaises(IntegrityError), transaction.atomic():
            ProductVariant.objects.create(
                product=product,
                name="second default",
                sku="DD-2",
                unit_price=Decimal("2.00"),
                is_default=True,
            )

    def test_default_variant_property_does_not_create_on_read(self):
        product = Product.objects.create(name="No variants yet")

        self.assertIsNone(product.default_variant)
        self.assertEqual(product.variants.count(), 0)


class UnitPricingDerivationTests(TestCase):
    """Per-unit price derivation and the rule that selling in a non-base unit
    never rewrites the base variant price."""

    def setUp(self):
        self.product = create_product_with_default_variant(
            name="Water", sku="WTR", unit_price="1.25"
        )
        self.variant = self.product.default_variant
        self.box = UnitOfMeasure.objects.get(code="box")
        self.product_unit = ProductUnit.objects.create(
            product=self.product,
            unit=self.box,
            factor_to_base=Decimal("12"),
        )

    def test_derived_unit_price_is_unit_price_times_factor(self):
        resolved = resolve_unit(self.product, "box")
        self.assertEqual(
            unit_sale_price(self.variant, resolved),
            Decimal("15.00"),  # 1.25 * 12
        )

    def test_custom_product_unit_price_overrides_derived(self):
        self.product_unit.price = Decimal("13.50")
        self.product_unit.save(update_fields=["price", "updated_at"])

        resolved = resolve_unit(self.product, "box")
        self.assertEqual(unit_sale_price(self.variant, resolved), Decimal("13.50"))

    def test_resolving_and_pricing_non_base_unit_leaves_base_price_intact(self):
        # Price the box unit, then confirm the base variant row is untouched.
        resolved = resolve_unit(self.product, "box")
        _ = unit_sale_price(self.variant, resolved)

        self.variant.refresh_from_db()
        self.assertEqual(self.variant.unit_price, Decimal("1.25"))
        # The base unit still derives to exactly the variant price (factor 1).
        base_resolved = resolve_unit(self.product, "")
        self.assertEqual(
            unit_sale_price(self.variant, base_resolved), Decimal("1.25")
        )


class SkuBarcodeNormalizationTests(TestCase):
    """SKU upper-cased/trimmed and unique; blank barcodes allowed for many
    variants but a non-blank barcode is globally unique."""

    def test_sku_is_uppercased_and_trimmed_on_save(self):
        product = Product.objects.create(name="Norm")
        variant = ProductVariant.objects.create(
            product=product,
            sku="  lower-sku  ",
            barcode="  ABC123  ",
            unit_price=Decimal("1.00"),
            is_default=True,
        )

        variant.refresh_from_db()
        self.assertEqual(variant.sku, "LOWER-SKU")
        # Barcode is trimmed but case-preserved.
        self.assertEqual(variant.barcode, "ABC123")

    def test_sku_uniqueness_is_case_insensitive_via_normalization(self):
        create_product_with_default_variant(
            name="First", sku="UNIQ-1", unit_price="1.00"
        )
        product = Product.objects.create(name="Second")

        # "uniq-1" normalises to "UNIQ-1", colliding with the existing SKU.
        with self.assertRaises(IntegrityError), transaction.atomic():
            ProductVariant.objects.create(
                product=product,
                sku="uniq-1",
                unit_price=Decimal("2.00"),
                is_default=True,
            )

    def test_blank_barcode_allowed_across_many_variants(self):
        product = create_product_with_default_variant(
            name="Blanks", sku="BLK-1", barcode="", unit_price="1.00"
        )
        # Several blank-barcode variants coexist; the partial unique index only
        # constrains non-blank barcodes.
        ProductVariant.objects.create(
            product=product, sku="BLK-2", barcode="", unit_price=Decimal("1.00")
        )
        ProductVariant.objects.create(
            product=product, sku="BLK-3", barcode="", unit_price=Decimal("1.00")
        )
        self.assertEqual(
            product.variants.filter(barcode="").count(), 3
        )

    def test_non_blank_barcode_unique_across_products(self):
        create_product_with_default_variant(
            name="Owner", sku="OWN-1", barcode="555000", unit_price="1.00"
        )
        other = Product.objects.create(name="Thief")

        with self.assertRaises(IntegrityError), transaction.atomic():
            ProductVariant.objects.create(
                product=other,
                sku="THF-1",
                barcode="555000",
                unit_price=Decimal("1.00"),
                is_default=True,
            )


class ActiveVariantArchiveTests(TestCase):
    """ProductVariant.objects.active() excludes archived products. (Inactive
    variant / inactive product are already covered in apps/catalog/tests.py.)"""

    def test_active_excludes_archived_product_variants(self):
        live = create_product_with_default_variant(
            name="Live", sku="ALIVE", unit_price="1.00", is_active=True
        )
        archived = create_product_with_default_variant(
            name="Archived", sku="GONE", unit_price="1.00", is_active=True
        )
        # Archived but still is_active=True — archive must still hide it.
        archived.archive()
        self.assertTrue(archived.is_active)

        active_skus = list(
            ProductVariant.objects.active().values_list("sku", flat=True)
        )
        self.assertIn("ALIVE", active_skus)
        self.assertNotIn("GONE", active_skus)
        self.assertEqual(active_skus, [live.default_variant.sku])

    def test_active_excludes_all_three_exclusion_kinds_together(self):
        """A single query distinguishing archived, inactive-product, and
        inactive-variant exclusions all at once."""
        keep = create_product_with_default_variant(
            name="Keep", sku="KEEP", unit_price="1.00", is_active=True
        )
        archived = create_product_with_default_variant(
            name="Arch", sku="ARCH", unit_price="1.00", is_active=True
        )
        archived.archive()
        inactive_product = create_product_with_default_variant(
            name="InactiveP", sku="INACTP", unit_price="1.00", is_active=False
        )
        inactive_variant_product = create_product_with_default_variant(
            name="InactiveV", sku="INACTV", unit_price="1.00", is_active=True
        )
        bad_variant = inactive_variant_product.default_variant
        bad_variant.is_active = False
        bad_variant.save(update_fields=["is_active", "updated_at"])

        active_skus = set(
            ProductVariant.objects.active().values_list("sku", flat=True)
        )
        self.assertEqual(active_skus, {keep.default_variant.sku})
        # Each excluded SKU is genuinely absent.
        for sku in ("ARCH", "INACTP", "INACTV"):
            self.assertNotIn(sku, active_skus)
        # The excluded products still exist (exclusion is a filter, not a delete).
        self.assertTrue(Product.objects.filter(pk=inactive_product.pk).exists())
