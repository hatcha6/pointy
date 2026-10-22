"""A variant answers to more than one barcode.

``ProductVariant.barcode`` stays the primary code; ``extra_barcodes`` are the
others a scan also resolves. These tests pin the round trip through every write
door (product form default variant, generated variants, the variant endpoint),
the "absent key keeps, list replaces" rule, uniqueness against every other kind
of code, and that each lookup a till uses finds a variant by an extra code.
"""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.db import connection
from django.test import TestCase
from django.test.utils import CaptureQueriesContext
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient

from apps.core.roles import MANAGER_GROUP, ensure_role_groups
from apps.price_checker.pricing import lookup_price

from .models import (
    ProductUnit,
    ProductUnitBarcode,
    ProductVariantBarcode,
    UnitOfMeasure,
)
from .testing import create_product_with_default_variant

IDENTITY_CHECK_URL = "/api/product-variants/identity-check/"


class VariantExtraBarcodeTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.client = APIClient()
        self.user = get_user_model().objects.create_user(
            username="extra-barcodes-manager",
            password="pass",
        )
        self.user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client.force_authenticate(user=self.user)

    def _create(self, **default_variant):
        return self.client.post(
            reverse("product-list"),
            {
                "name": "حليب المراعي",
                "default_variant": {"unit_price": "4.50", **default_variant},
            },
            format="json",
        )

    def _extras(self, variant_id):
        return list(
            ProductVariantBarcode.objects.filter(variant_id=variant_id).values_list(
                "barcode", flat=True
            )
        )

    # ---- writes ------------------------------------------------------------

    def test_product_create_stores_and_returns_extra_barcodes(self):
        response = self._create(
            barcode="6281000000011",
            extra_barcodes=[" 6281000000028 ", "6281000000028", "", "6281000000011", "7001"],
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        variant = response.data["default_variant"]
        # Trimmed, de-duplicated, blanks and the primary code dropped, order kept.
        self.assertEqual(variant["extra_barcodes"], ["6281000000028", "7001"])
        self.assertEqual(self._extras(variant["id"]), ["6281000000028", "7001"])

        detail = self.client.get(reverse("product-detail", args=[response.data["id"]]))
        self.assertEqual(
            detail.data["default_variant"]["extra_barcodes"], ["6281000000028", "7001"]
        )
        self.assertEqual(detail.data["variants"][0]["extra_barcodes"], ["6281000000028", "7001"])

    def test_product_edit_without_the_key_keeps_extras_and_a_list_replaces_them(self):
        created = self._create(barcode="111", extra_barcodes=["222", "333"]).data
        url = reverse("product-detail", args=[created["id"]])

        kept = self.client.patch(
            url, {"default_variant": {"barcode": "111", "unit_price": "5.00"}}, format="json"
        )
        self.assertEqual(kept.status_code, status.HTTP_200_OK, kept.data)
        self.assertEqual(kept.data["default_variant"]["extra_barcodes"], ["222", "333"])

        replaced = self.client.patch(
            url,
            {"default_variant": {"barcode": "111", "extra_barcodes": ["444"]}},
            format="json",
        )
        self.assertEqual(replaced.data["default_variant"]["extra_barcodes"], ["444"])

        cleared = self.client.patch(
            url,
            {"default_variant": {"barcode": "111", "extra_barcodes": []}},
            format="json",
        )
        self.assertEqual(cleared.data["default_variant"]["extra_barcodes"], [])

    def test_promoting_an_extra_to_primary_is_not_a_conflict(self):
        created = self._create(barcode="111", extra_barcodes=["222"]).data

        response = self.client.patch(
            reverse("product-detail", args=[created["id"]]),
            {"default_variant": {"barcode": "222", "extra_barcodes": ["111"]}},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.assertEqual(response.data["default_variant"]["barcode"], "222")
        self.assertEqual(response.data["default_variant"]["extra_barcodes"], ["111"])

    def test_generated_variants_carry_their_own_extras_and_may_swap_them(self):
        created = self.client.post(
            reverse("product-list"),
            {
                "name": "عصير",
                "variants": [
                    {"barcode": "A1", "extra_barcodes": ["A2"], "unit_price": "1", "is_default": True},
                    {"barcode": "B1", "extra_barcodes": ["B2"], "unit_price": "1"},
                ],
            },
            format="json",
        )
        self.assertEqual(created.status_code, status.HTTP_201_CREATED, created.data)
        rows = sorted(created.data["variants"], key=lambda row: row["barcode"])
        self.assertEqual([row["extra_barcodes"] for row in rows], [["A2"], ["B2"]])

        # One save moves each extra code onto the other row.
        swapped = self.client.patch(
            reverse("product-detail", args=[created.data["id"]]),
            {
                "variants": [
                    {"id": rows[0]["id"], "barcode": "A1", "extra_barcodes": ["B2"], "unit_price": "1"},
                    {"id": rows[1]["id"], "barcode": "B1", "extra_barcodes": ["A2"], "unit_price": "1"},
                ]
            },
            format="json",
        )
        self.assertEqual(swapped.status_code, status.HTTP_200_OK, swapped.data)
        self.assertEqual(self._extras(rows[0]["id"]), ["B2"])
        self.assertEqual(self._extras(rows[1]["id"]), ["A2"])

    def test_variant_endpoint_reads_and_writes_extras(self):
        product = create_product_with_default_variant(
            name="ماء", sku="V-1", barcode="900", unit_price=Decimal("1.00")
        )
        variant = product.default_variant
        url = reverse("product-variant-detail", args=[variant.pk])

        response = self.client.patch(url, {"extra_barcodes": ["901", "902"]}, format="json")

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.assertEqual(response.data["extra_barcodes"], ["901", "902"])
        self.assertEqual(self.client.get(url).data["extra_barcodes"], ["901", "902"])

    # ---- uniqueness --------------------------------------------------------

    def test_extra_barcode_owned_by_another_products_primary_is_rejected(self):
        create_product_with_default_variant(
            name="قهوة", sku="OWN-1", barcode="555", unit_price=Decimal("1.00")
        )

        response = self._create(barcode="111", extra_barcodes=["555"])

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        conflict = response.data["conflicts"][0]
        self.assertEqual(conflict["field"], "extra_barcodes")
        self.assertEqual(conflict["target"], "default_variant")
        self.assertEqual(conflict["value"], "555")
        self.assertIn("قهوة", conflict["message"])

    def test_primary_barcode_owned_by_another_products_extra_is_rejected(self):
        self._create(barcode="111", extra_barcodes=["222"])

        response = self.client.post(
            reverse("product-list"),
            {"name": "شاي", "default_variant": {"barcode": "222", "unit_price": "1"}},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        conflict = response.data["conflicts"][0]
        self.assertEqual(conflict["field"], "barcode")
        self.assertIn("حليب المراعي", conflict["message"])

    def test_extra_barcode_repeated_across_rows_of_one_payload_is_rejected(self):
        response = self.client.post(
            reverse("product-list"),
            {
                "name": "عصير",
                "variants": [
                    {"barcode": "A1", "unit_price": "1", "is_default": True},
                    {"barcode": "B1", "extra_barcodes": ["A1"], "unit_price": "1"},
                ],
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        conflict = response.data["conflicts"][0]
        self.assertEqual(conflict["kind"], "payload")
        self.assertEqual(conflict["field"], "extra_barcodes")
        self.assertEqual(conflict["index"], "1")

    def test_extra_barcode_owned_by_a_packaging_unit_is_rejected_both_ways(self):
        carton, _ = UnitOfMeasure.objects.get_or_create(
            code="carton-extra", defaults={"name": "كرتونة"}
        )
        owner = create_product_with_default_variant(
            name="علبة", sku="CTN-1", barcode="800", unit_price=Decimal("1.00")
        )
        unit = ProductUnit.objects.create(product=owner, unit=carton, factor_to_base=12)
        ProductUnitBarcode.objects.create(product_unit=unit, barcode="801")

        response = self._create(barcode="111", extra_barcodes=["801"])
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(response.data["conflicts"][0]["kind"], "unit")

        self._create(barcode="112", extra_barcodes=["802"])
        unit_write = self.client.patch(
            reverse("product-detail", args=[owner.pk]),
            {"units": [{"unit": carton.code, "factor_to_base": "12", "barcodes": ["802"]}]},
            format="json",
        )
        self.assertEqual(unit_write.status_code, status.HTTP_400_BAD_REQUEST)

    def test_identity_check_reports_the_owner_of_an_extra_barcode(self):
        variant_id = self._create(barcode="111", extra_barcodes=["222"]).data[
            "default_variant"
        ]["id"]

        taken = self.client.get(IDENTITY_CHECK_URL, {"barcode": "222"})
        own = self.client.get(
            IDENTITY_CHECK_URL, {"barcode": "222", "exclude_variant": variant_id}
        )

        self.assertEqual(taken.data["barcode"]["variant_id"], variant_id)
        self.assertIsNone(own.data["barcode"])

    # ---- lookups -----------------------------------------------------------

    def test_every_till_lookup_finds_the_variant_by_an_extra_barcode(self):
        created = self._create(barcode="6281000000011", extra_barcodes=["6281000000028"]).data
        variant_id = created["default_variant"]["id"]

        by_variant = self.client.get(
            reverse("product-variant-list"), {"barcode": "6281000000028"}
        )
        by_product = self.client.get(reverse("product-list"), {"barcode": "6281000000028"})
        by_search = self.client.get(reverse("product-list"), {"search": "6281000000028"})
        by_variant_search = self.client.get(
            reverse("product-variant-list"), {"search": "6281000000028"}
        )

        def ids(response):
            return [row["id"] for row in response.data["results"]]

        self.assertEqual(ids(by_variant), [variant_id])
        self.assertEqual(by_variant.data["results"][0]["extra_barcodes"], ["6281000000028"])
        self.assertEqual(ids(by_product), [created["id"]])
        self.assertEqual(ids(by_search), [created["id"]])
        self.assertEqual(ids(by_variant_search), [variant_id])

        price = lookup_price("6281000000028")
        self.assertTrue(price.found)
        self.assertEqual(price.variant_id, variant_id)

    def test_product_list_does_not_fire_a_query_per_variant_for_extras(self):
        for index in range(3):
            self._create(barcode=f"10{index}", extra_barcodes=[f"20{index}"])
        baseline = self._count_list_queries()
        for index in range(3, 9):
            self._create(barcode=f"10{index}", extra_barcodes=[f"20{index}"])

        self.assertEqual(self._count_list_queries(), baseline)

    def _count_list_queries(self):
        with CaptureQueriesContext(connection) as queries:
            response = self.client.get(reverse("product-list"))
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        return len(queries)
