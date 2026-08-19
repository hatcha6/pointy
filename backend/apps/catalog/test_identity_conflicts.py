"""Duplicate SKU / barcode answers are per-field, not a 500.

Before this, only the standalone ``/product-variants/`` endpoint rejected a
duplicate cleanly; creating or editing a *product* whose default (or generated)
variant reused a barcode hit the partial unique index and returned a 500 that
told the shop owner nothing. These tests pin the contract the catalog forms
rely on: 400, the offending field, and a conflict entry naming the product that
already owns the code.
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

from .models import ProductUnit, ProductUnitBarcode, UnitOfMeasure
from .testing import create_product_with_default_variant

IDENTITY_CHECK_URL = "/api/product-variants/identity-check/"


class CatalogIdentityConflictTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.client = APIClient()
        self.user = get_user_model().objects.create_user(
            username="identity-manager",
            password="pass",
        )
        self.user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client.force_authenticate(user=self.user)
        self.existing = create_product_with_default_variant(
            sku="EXIST-1",
            barcode="999888777",
            name="قهوة عربية",
            unit_price=Decimal("3.00"),
        )

    def _conflicts(self, response):
        return response.data.get("conflicts", [])

    # ---- product create -------------------------------------------------

    def test_create_product_duplicate_barcode_returns_field_error(self):
        response = self.client.post(
            reverse("product-list"),
            {
                "name": "منتج جديد",
                "default_variant": {
                    "sku": "NEW-1",
                    "barcode": "999888777",
                    "unit_price": "5.00",
                },
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("barcode", response.data["default_variant"])
        conflict = self._conflicts(response)[0]
        self.assertEqual(conflict["field"], "barcode")
        self.assertEqual(conflict["target"], "default_variant")
        self.assertEqual(conflict["value"], "999888777")
        self.assertEqual(conflict["product_id"], str(self.existing.pk))
        self.assertIn("قهوة عربية", conflict["message"])

    def test_create_product_duplicate_sku_returns_field_error(self):
        response = self.client.post(
            reverse("product-list"),
            {
                "name": "منتج جديد",
                "default_variant": {"sku": "exist-1", "unit_price": "5.00"},
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("sku", response.data["default_variant"])
        self.assertEqual(self._conflicts(response)[0]["field"], "sku")

    def test_create_product_generated_variant_conflict_carries_row_index(self):
        response = self.client.post(
            reverse("product-list"),
            {
                "name": "منتج بمتغيرات",
                "variants": [
                    {"sku": "GEN-1", "unit_price": "5.00", "is_default": True},
                    {"sku": "GEN-2", "barcode": "999888777", "unit_price": "6.00"},
                ],
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        # The error lands on row 1 only — row 0 stays clean so the form can mark
        # exactly the input the user must fix.
        self.assertEqual(response.data["variants"][0], {})
        self.assertIn("barcode", response.data["variants"][1])
        conflict = self._conflicts(response)[0]
        self.assertEqual(conflict["target"], "variants")
        self.assertEqual(conflict["index"], "1")

    def test_create_product_rejects_barcode_repeated_inside_the_payload(self):
        response = self.client.post(
            reverse("product-list"),
            {
                "name": "منتج بمتغيرات",
                "variants": [
                    {
                        "sku": "GEN-1",
                        "barcode": "555444",
                        "unit_price": "5.00",
                        "is_default": True,
                    },
                    {"sku": "GEN-2", "barcode": "555444", "unit_price": "6.00"},
                ],
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        conflict = self._conflicts(response)[0]
        self.assertEqual(conflict["kind"], "payload")
        self.assertEqual(conflict["index"], "1")

    def test_create_product_rejects_barcode_owned_by_a_packaging_unit(self):
        carton, _ = UnitOfMeasure.objects.get_or_create(
            code="carton",
            defaults={"name": "كرتون"},
        )
        product_unit = ProductUnit.objects.create(
            product=self.existing,
            unit=carton,
            factor_to_base=Decimal("12"),
        )
        ProductUnitBarcode.objects.create(product_unit=product_unit, barcode="111222")

        response = self.client.post(
            reverse("product-list"),
            {
                "name": "منتج جديد",
                "default_variant": {
                    "sku": "NEW-2",
                    "barcode": "111222",
                    "unit_price": "5.00",
                },
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        conflict = self._conflicts(response)[0]
        self.assertEqual(conflict["kind"], "unit")
        self.assertEqual(conflict["unit_code"], "carton")

    def test_create_product_reports_a_conflict_per_offending_field(self):
        response = self.client.post(
            reverse("product-list"),
            {
                "name": "منتج جديد",
                "default_variant": {
                    "sku": "EXIST-1",
                    "barcode": "999888777",
                    "unit_price": "5.00",
                },
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(
            {conflict["field"] for conflict in self._conflicts(response)},
            {"sku", "barcode"},
        )

    def test_create_product_succeeds_with_free_codes(self):
        response = self.client.post(
            reverse("product-list"),
            {
                "name": "منتج جديد",
                "default_variant": {
                    "sku": "FREE-1",
                    "barcode": "123123123",
                    "unit_price": "5.00",
                },
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)

    # ---- product update -------------------------------------------------

    def test_update_product_keeping_its_own_codes_is_not_a_conflict(self):
        response = self.client.patch(
            reverse("product-detail", args=[self.existing.pk]),
            {
                "default_variant": {
                    "sku": "EXIST-1",
                    "barcode": "999888777",
                    "unit_price": "4.00",
                }
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)

    def test_update_product_taking_another_products_barcode_is_rejected(self):
        other = create_product_with_default_variant(
            sku="OTHER-1",
            name="شاي",
            unit_price=Decimal("2.00"),
        )

        response = self.client.patch(
            reverse("product-detail", args=[other.pk]),
            {
                "default_variant": {
                    "sku": "OTHER-1",
                    "barcode": "999888777",
                    "unit_price": "2.00",
                }
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("barcode", response.data["default_variant"])

    def test_conflict_with_an_archived_product_is_reported_as_such(self):
        self.client.post(reverse("product-archive", args=[self.existing.pk]))

        response = self.client.post(
            reverse("product-list"),
            {
                "name": "منتج جديد",
                "default_variant": {
                    "sku": "NEW-3",
                    "barcode": "999888777",
                    "unit_price": "5.00",
                },
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(self._conflicts(response)[0]["is_archived"], "true")

    # ---- variant endpoint ------------------------------------------------

    def test_create_variant_duplicate_barcode_names_the_owner(self):
        product = create_product_with_default_variant(
            sku="P2",
            name="شاي",
            unit_price=Decimal("1.00"),
        )

        response = self.client.post(
            reverse("product-variant-list"),
            {
                "product": product.pk,
                "sku": "P2-B",
                "barcode": "999888777",
                "unit_price": "5.00",
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("barcode", response.data)
        conflict = self._conflicts(response)[0]
        self.assertEqual(conflict["target"], "variant")
        self.assertIn("قهوة عربية", conflict["message"])

    def test_update_variant_keeping_its_own_barcode_is_not_a_conflict(self):
        response = self.client.patch(
            reverse("product-variant-detail", args=[self.existing.default_variant.pk]),
            {"barcode": "999888777", "unit_price": "9.00"},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)

    # ---- identity-check probe -------------------------------------------

    def test_identity_check_reports_the_owner_of_each_code(self):
        response = self.client.get(
            IDENTITY_CHECK_URL,
            {"sku": "exist-1", "barcode": "999888777"},
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["sku"]["product_id"], self.existing.pk)
        self.assertEqual(response.data["barcode"]["variant_sku"], "EXIST-1")

    def test_identity_check_reports_free_codes_as_null(self):
        response = self.client.get(
            IDENTITY_CHECK_URL,
            {"sku": "nobody", "barcode": "000111"},
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertIsNone(response.data["sku"])
        self.assertIsNone(response.data["barcode"])

    def test_identity_check_excludes_the_variant_being_edited(self):
        response = self.client.get(
            IDENTITY_CHECK_URL,
            {
                "barcode": "999888777",
                "exclude_variant": self.existing.default_variant.pk,
            },
        )

        self.assertIsNone(response.data["barcode"])

    def test_conflict_lookup_does_not_scale_with_the_variant_count(self):
        """One batched lookup, not two queries per generated row.

        A product can generate dozens of variants in one write; a per-row
        check would put the catalog's heaviest endpoint back into N+1.
        """
        payload = {
            "name": "منتج بمتغيرات",
            "variants": [
                {
                    "sku": f"BULK-{index}",
                    "barcode": f"70000{index:03d}",
                    "unit_price": "5.00",
                    "is_default": index == 0,
                }
                for index in range(12)
            ],
        }

        with CaptureQueriesContext(connection) as captured:
            response = self.client.post(
                reverse("product-list"),
                payload,
                format="json",
            )
        self.assertEqual(response.status_code, status.HTTP_201_CREATED)

        identity_queries = [
            query
            for query in captured.captured_queries
            if 'FROM "catalog_productvariant"' in query["sql"]
            and ' IN (' in query["sql"]
        ]
        # SKUs and barcodes, one query each — regardless of how many rows.
        self.assertLessEqual(len(identity_queries), 2)

    def test_identity_check_still_reports_archived_owners(self):
        # get_queryset() hides archived products, but their codes stay taken at
        # the unique index — a form told "free" here would fail on save.
        self.client.post(reverse("product-archive", args=[self.existing.pk]))

        response = self.client.get(IDENTITY_CHECK_URL, {"barcode": "999888777"})

        self.assertIsNotNone(response.data["barcode"])
        self.assertTrue(response.data["barcode"]["is_archived"])
