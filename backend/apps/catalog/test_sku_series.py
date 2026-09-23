"""The automatic SKU: a plain number, counting up from 1000.

A shop keeps no SKUs, or keeps its own numbered ones, or has thirteen-digit
barcodes sitting in its SKU column from the days the form copied a scan into
it. Each of those has to lead somewhere sensible — and none of them may ever
renumber a product that already carries a code.
"""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient

from apps.core.roles import MANAGER_GROUP, ensure_role_groups

from .models import Product, ProductUnit, ProductUnitBarcode, ProductVariant, UnitOfMeasure
from .sku_series import allocate_variant_sku, next_variant_sku
from .testing import create_product_with_default_variant


def _product(sku, barcode=""):
    return create_product_with_default_variant(
        name=f"منتج {sku}",
        sku=sku,
        barcode=barcode,
        unit_price=Decimal("5.00"),
    )


class SkuSeriesTests(TestCase):
    def test_an_empty_catalogue_starts_at_1000(self):
        self.assertEqual(next_variant_sku(), "1000")

    def test_a_shop_with_no_plain_numbers_starts_at_1000(self):
        _product("RICE-5")
        _product("P000012")

        self.assertEqual(next_variant_sku(), "1000")

    def test_it_carries_on_from_the_shops_own_numbers(self):
        _product("17")
        _product("523")
        _product("RICE-5")

        self.assertEqual(next_variant_sku(), "524")

    def test_a_barcode_in_the_sku_column_is_not_a_serial(self):
        """The old form copied a scanned code into the SKU. Counting one would
        number the next product 6281234567891."""
        _product("6281234567890")  # EAN-13
        _product("62812345")  # EAN-8, the shortest real barcode

        self.assertEqual(next_variant_sku(), "1000")

    def test_leading_zeros_count_by_value(self):
        _product("00042")

        self.assertEqual(next_variant_sku(), "43")

    def test_it_steps_past_a_number_already_used_as_a_barcode(self):
        """"Barcode = SKU" is one click on the form; the number it offers must
        not already be somebody's barcode."""
        _product("1000", barcode="1003")

        self.assertEqual(next_variant_sku(), "1004")

    def test_packaging_barcodes_count_too(self):
        product = _product("1000")
        carton, _ = UnitOfMeasure.objects.get_or_create(
            code="carton",
            defaults={"name": "كرتون"},
        )
        unit = ProductUnit.objects.create(
            product=product,
            unit=carton,
            factor_to_base=Decimal("12"),
        )
        ProductUnitBarcode.objects.create(product_unit=unit, barcode="2000")

        self.assertEqual(next_variant_sku(), "2001")

    def test_looking_reserves_nothing(self):
        self.assertEqual(next_variant_sku(), "1000")
        self.assertEqual(next_variant_sku(), "1000")

    def test_allocations_in_one_transaction_count_up(self):
        product = Product.objects.create(name="قميص")
        for _ in range(3):
            ProductVariant.objects.create(
                product=product,
                sku=allocate_variant_sku(),
                unit_price=Decimal("20.00"),
            )

        self.assertEqual(
            sorted(product.variants.values_list("sku", flat=True)),
            ["1000", "1001", "1002"],
        )


class NextSkuEndpointTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.client = APIClient()
        user = get_user_model().objects.create_user(
            username="sku-series-manager",
            password="pass",
        )
        user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client.force_authenticate(user=user)

    def _next(self):
        response = self.client.get(reverse("product-variant-next-sku"))
        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        return response.data["sku"]

    def _create(self, name, **default_variant):
        response = self.client.post(
            reverse("product-list"),
            {
                "name": name,
                "default_variant": {"unit_price": "5.00", **default_variant},
            },
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        return ProductVariant.objects.get(product__name=name)

    def test_it_says_what_the_next_product_will_be_numbered(self):
        _product("1041")

        self.assertEqual(self._next(), "1042")

    def test_what_the_form_shows_is_what_is_saved(self):
        """The form fills the number in and may copy it into the barcode; the
        product saved from that form carries exactly those codes."""
        shown = self._next()

        variant = self._create("أرز", sku=shown, barcode=shown)

        self.assertEqual((variant.sku, variant.barcode), ("1000", "1000"))
        self.assertEqual(self._next(), "1001")

    def test_products_saved_without_a_sku_are_numbered_in_order(self):
        """An older till still sends a blank SKU; the server numbers it."""
        skus = [self._create(name, sku="").sku for name in ("أرز", "سكر", "شاي")]

        self.assertEqual(skus, ["1000", "1001", "1002"])

    def test_it_needs_a_signed_in_user(self):
        response = APIClient().get(reverse("product-variant-next-sku"))

        self.assertIn(
            response.status_code,
            (status.HTTP_401_UNAUTHORIZED, status.HTTP_403_FORBIDDEN),
        )
