"""A variant can be saved without a SKU, and the server codes it.

Plenty of shops keep no SKUs — a sack of rice has a name and a price and
nothing else — so the forms no longer demand one. The column stays unique and
non-blank, which means every write path that now accepts a blank has to fill
it in. These tests pin the two halves of that: a blank is accepted, and an
existing row's code is never silently renumbered by an emptied field.
"""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient

from apps.core.roles import MANAGER_GROUP, ensure_role_groups

from .models import Product, ProductVariant, VariantOption, VariantOptionValue
from .testing import create_product_with_default_variant


class OptionalVariantSkuTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.client = APIClient()
        self.user = get_user_model().objects.create_user(
            username="sku-manager",
            password="pass",
        )
        self.user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client.force_authenticate(user=self.user)

    # ---- product create -------------------------------------------------

    def test_create_product_with_blank_sku_generates_one(self):
        response = self.client.post(
            reverse("product-list"),
            {
                "name": "أرز",
                "default_variant": {"sku": "", "barcode": "", "unit_price": "5.00"},
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        variant = ProductVariant.objects.get(product__name="أرز")
        self.assertEqual(variant.sku, "1000")
        self.assertEqual(variant.barcode, "")

    def test_two_blank_sku_products_do_not_collide(self):
        for name in ("أرز", "سكر"):
            response = self.client.post(
                reverse("product-list"),
                {
                    "name": name,
                    "default_variant": {"sku": "", "unit_price": "5.00"},
                },
                format="json",
            )
            self.assertEqual(
                response.status_code, status.HTTP_201_CREATED, response.data
            )

        skus = sorted(ProductVariant.objects.values_list("sku", flat=True))
        self.assertEqual(skus, ["1000", "1001"])

    # ---- product update -------------------------------------------------

    def test_clearing_a_sku_keeps_the_code_the_row_already_has(self):
        """The shop has been printing RICE-5 on labels; emptying the input in a
        form that also carries a dozen other fields must not renumber it."""
        product = create_product_with_default_variant(
            name="أرز",
            sku="RICE-5",
            unit_price=Decimal("5.00"),
        )

        response = self.client.patch(
            reverse("product-detail", args=[product.pk]),
            {"default_variant": {"sku": "", "unit_price": "6.00"}},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        variant = product.variants.get()
        self.assertEqual(variant.sku, "RICE-5")
        self.assertEqual(variant.unit_price, Decimal("6.00"))

    # ---- generated variants ---------------------------------------------

    def test_generated_variants_without_skus_each_get_their_own(self):
        option = VariantOption.objects.create(code="shirt-color", name="اللون")
        red = VariantOptionValue.objects.create(
            option=option,
            code="red",
            name="أحمر",
        )
        blue = VariantOptionValue.objects.create(
            option=option,
            code="blue",
            name="أزرق",
        )

        response = self.client.post(
            reverse("product-list"),
            {
                "name": "قميص",
                "variant_options": [option.pk],
                "variants": [
                    {
                        "sku": "",
                        "unit_price": "20.00",
                        "is_default": True,
                        "option_values": [red.pk],
                    },
                    {"sku": "", "unit_price": "20.00", "option_values": [blue.pk]},
                ],
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        product = Product.objects.get(name="قميص")
        skus = sorted(product.variants.values_list("sku", flat=True))
        self.assertEqual(skus, ["1000", "1001"], "two blank SKUs must not collide")

    # ---- the standalone variant endpoint --------------------------------

    def test_creating_a_variant_without_a_sku_generates_one(self):
        product = create_product_with_default_variant(
            name="أرز",
            sku="RICE-5",
            unit_price=Decimal("5.00"),
        )

        response = self.client.post(
            reverse("product-variant-list"),
            {"product": product.pk, "unit_price": "7.00", "name": "كيس كبير"},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        created = product.variants.get(name="كيس كبير")
        self.assertEqual(created.sku, "1000")

    def test_clearing_a_variant_sku_keeps_its_code(self):
        product = create_product_with_default_variant(
            name="أرز",
            sku="RICE-5",
            unit_price=Decimal("5.00"),
        )
        variant = product.variants.get()

        response = self.client.patch(
            reverse("product-variant-detail", args=[variant.pk]),
            {"sku": ""},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        variant.refresh_from_db()
        self.assertEqual(variant.sku, "RICE-5")

    def test_a_sent_sku_is_still_used(self):
        response = self.client.post(
            reverse("product-list"),
            {
                "name": "أرز",
                "default_variant": {"sku": "rice-5", "unit_price": "5.00"},
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        self.assertEqual(ProductVariant.objects.get().sku, "RICE-5")
