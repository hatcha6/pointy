"""A variant's GTIN and a product's ``expiry_required``, through the API.

Both columns existed on the models and neither was reachable: the GS1 resolver
fell back to the ordinary barcode, and receiving demanded an expiry date only
for products the §18.4 migration had flagged, with no way to flag a new one.
These tests pin the write contract the product form relies on — a GTIN is
checked and stored as the GTIN-14 a DataMatrix carries, a duplicate is a
structured conflict naming its owner, and what was saved is what a scan finds.
"""

from datetime import date
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import SimpleTestCase, TestCase
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient

from apps.core.roles import MANAGER_GROUP, ensure_role_groups
from apps.inventory.tracked_testing import receive, tracked_product

from . import gs1
from .models import Product, ProductVariant
from .testing import create_product_with_default_variant

# EAN-13 4006381333931 — a real, valid trade item number — and its GTIN-14.
EAN = "4006381333931"
GTIN14 = "04006381333931"
# The same number with its last digit wrong: the typo this exists to catch.
BAD_CHECK = "4006381333932"


class GtinNormalisationTests(SimpleTestCase):
    def test_every_printed_length_becomes_the_same_gtin_14(self):
        self.assertEqual(gs1.normalize_gtin(EAN), GTIN14)
        self.assertEqual(gs1.normalize_gtin(GTIN14), GTIN14)
        self.assertEqual(gs1.normalize_gtin("036000291452"), "00036000291452")
        self.assertEqual(gs1.normalize_gtin("96385074"), "00000096385074")

    def test_the_groups_people_type_between_digits_are_dropped(self):
        self.assertEqual(gs1.normalize_gtin("4 006381 333931"), GTIN14)
        self.assertEqual(gs1.normalize_gtin("400-6381-333931"), GTIN14)

    def test_blank_stays_blank(self):
        self.assertEqual(gs1.normalize_gtin(""), "")
        self.assertEqual(gs1.normalize_gtin(None), "")

    def test_a_wrong_check_digit_length_or_letter_is_refused(self):
        for value, code in (
            (BAD_CHECK, "gtin_check_digit"),
            ("12345", "gtin_length"),
            ("40063813339X1", "gtin_not_digits"),
        ):
            with self.subTest(value=value):
                with self.assertRaises(gs1.GtinError) as caught:
                    gs1.normalize_gtin(value)
                self.assertEqual(caught.exception.code, code)


class _ManagerApiTestCase(TestCase):
    def setUp(self):
        ensure_role_groups()
        user = get_user_model().objects.create_user(username="gtin-owner", password="pw")
        user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client = APIClient()
        self.client.force_authenticate(user=user)

    def _conflicts(self, response):
        return response.data.get("conflicts", [])


class ProductGtinApiTests(_ManagerApiTestCase):
    def _create(self, **default_variant):
        return self.client.post(
            reverse("product-list"),
            {
                "name": "أموكسيسيلين 500",
                "tracking_mode": "batch",
                "default_variant": {"unit_price": "12.00", **default_variant},
            },
            format="json",
        )

    def test_a_typed_ean_is_stored_as_the_gtin_14_and_read_back(self):
        response = self._create(gtin=EAN)

        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        self.assertEqual(response.data["default_variant"]["gtin"], GTIN14)
        variant = ProductVariant.objects.get(product_id=response.data["id"])
        self.assertEqual(variant.gtin, GTIN14)

    def test_a_wrong_check_digit_is_a_field_error_not_a_stored_typo(self):
        response = self._create(gtin=BAD_CHECK)

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("gtin", response.data["default_variant"])
        self.assertFalse(Product.objects.filter(name="أموكسيسيلين 500").exists())

    def test_a_gtin_another_product_holds_is_a_conflict_naming_it(self):
        owner = create_product_with_default_variant(
            sku="GT-OWNER", name="باراسيتامول", unit_price=Decimal("3.00")
        )
        ProductVariant.objects.filter(pk=owner.default_variant.pk).update(gtin=GTIN14)

        response = self._create(gtin=EAN)

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("gtin", response.data["default_variant"])
        conflict = self._conflicts(response)[0]
        self.assertEqual(conflict["field"], "gtin")
        self.assertEqual(conflict["target"], "default_variant")
        self.assertEqual(conflict["value"], GTIN14)
        self.assertEqual(conflict["product_id"], str(owner.pk))
        self.assertIn("باراسيتامول", conflict["message"])

    def test_a_gtin_that_is_another_products_barcode_is_a_conflict(self):
        """The resolver looks in both columns, so one trade item on two
        products would scan to whichever the query met first."""
        create_product_with_default_variant(
            sku="GT-EAN", barcode=EAN, name="أموكسيسيلين قديم",
            unit_price=Decimal("3.00"),
        )

        response = self._create(gtin=GTIN14)

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(self._conflicts(response)[0]["field"], "gtin")

    def test_a_products_own_barcode_may_be_its_own_gtin(self):
        response = self._create(barcode=EAN, gtin=EAN)

        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        product = Product.objects.get(pk=response.data["id"])

        # And saving it again — the edit sheet re-sends both — is not a clash
        # with itself.
        again = self.client.patch(
            reverse("product-detail", args=[product.pk]),
            {"default_variant": {"barcode": EAN, "gtin": GTIN14, "unit_price": "12.00"}},
            format="json",
        )
        self.assertEqual(again.status_code, status.HTTP_200_OK, again.data)

    def test_generated_variants_carry_their_own_gtins_and_may_not_share_one(self):
        response = self.client.post(
            reverse("product-list"),
            {
                "name": "شراب سعال",
                "variants": [
                    {"sku": "GT-V1", "unit_price": "5.00", "gtin": EAN,
                     "is_default": True},
                    {"sku": "GT-V2", "unit_price": "6.00", "gtin": GTIN14},
                ],
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        conflict = self._conflicts(response)[0]
        self.assertEqual(conflict["field"], "gtin")
        self.assertEqual(conflict["kind"], "payload")
        self.assertEqual(conflict["index"], "1")

    def test_an_edit_that_omits_the_gtin_keeps_it(self):
        product = Product.objects.get(pk=self._create(gtin=EAN).data["id"])

        response = self.client.patch(
            reverse("product-detail", args=[product.pk]),
            {"default_variant": {"unit_price": "14.00"}},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.assertEqual(product.default_variant.gtin, GTIN14)


class VariantEndpointGtinTests(_ManagerApiTestCase):
    def setUp(self):
        super().setUp()
        self.product = create_product_with_default_variant(
            sku="GT-VAR", name="فيتامين د", unit_price=Decimal("8.00")
        )
        self.variant = self.product.default_variant
        self.url = reverse("product-variant-detail", args=[self.variant.pk])

    def test_the_variant_editor_sets_and_clears_a_gtin(self):
        response = self.client.patch(self.url, {"gtin": EAN}, format="json")
        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.assertEqual(response.data["gtin"], GTIN14)

        response = self.client.patch(self.url, {"name": "عبوة"}, format="json")
        self.variant.refresh_from_db()
        self.assertEqual(self.variant.gtin, GTIN14)

        response = self.client.patch(self.url, {"gtin": ""}, format="json")
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.variant.refresh_from_db()
        self.assertEqual(self.variant.gtin, "")

    def test_the_variant_editor_refuses_a_bad_check_digit_and_a_duplicate(self):
        response = self.client.patch(self.url, {"gtin": BAD_CHECK}, format="json")
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("gtin", response.data)

        other = create_product_with_default_variant(
            sku="GT-OTHER", name="زنك", unit_price=Decimal("8.00")
        )
        ProductVariant.objects.filter(pk=other.default_variant.pk).update(gtin=GTIN14)
        response = self.client.patch(self.url, {"gtin": EAN}, format="json")
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(response.data["conflicts"][0]["field"], "gtin")
        self.assertEqual(response.data["conflicts"][0]["target"], "variant")


class ExpiryRequiredApiTests(_ManagerApiTestCase):
    def test_expiry_required_round_trips(self):
        response = self.client.post(
            reverse("product-list"),
            {
                "name": "حليب",
                "tracking_mode": "batch",
                "expiry_required": True,
                "default_variant": {"unit_price": "4.00"},
            },
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        self.assertTrue(response.data["expiry_required"])
        product = Product.objects.get(pk=response.data["id"])
        self.assertTrue(product.expiry_required)

        response = self.client.patch(
            reverse("product-detail", args=[product.pk]),
            {"expiry_required": False},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        product.refresh_from_db()
        self.assertFalse(product.expiry_required)

    def test_the_old_tracks_expiry_flag_still_means_the_date_is_owed(self):
        """A client that predates the mode says «يتابع تاريخ الانتهاء», and
        that meant receiving demanded the date."""
        response = self.client.post(
            reverse("product-list"),
            {
                "name": "زبادي",
                "tracks_expiry": True,
                "default_variant": {"unit_price": "2.00"},
            },
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        self.assertEqual(response.data["tracking_mode"], "batch")
        self.assertTrue(response.data["expiry_required"])


class SavedGtinResolvesAScanTests(_ManagerApiTestCase):
    def test_the_gtin_saved_through_the_api_is_what_a_datamatrix_finds(self):
        product = tracked_product(
            name="لقاح مسلسل", sku="GT-VAX", mode=Product.TrackingMode.SERIAL_BATCH
        )
        variant = product.default_variant
        # Typed as the EAN-13 printed under the symbol.
        response = self.client.patch(
            reverse("product-variant-detail", args=[variant.pk]),
            {"gtin": "3453120000011"},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        receive(
            variant=variant,
            quantity=1,
            unit_cost="40.00",
            units=[{"code": "GT-PACK-1"}],
            batches=[{"code": "LOT77", "expiry_date": date(2029, 11, 30)}],
        )

        symbol = "0103453120000011" + "17291130" + "10LOT77" + gs1.GS + "21GT-PACK-1"
        response = self.client.get(reverse("resolve-barcode"), {"code": symbol})

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["kind"], "gs1")
        self.assertEqual(response.data["variant"]["id"], variant.pk)
        self.assertEqual(response.data["stock_batch"]["code"], "LOT77")
        self.assertEqual(response.data["stock_unit"]["code"], "GT-PACK-1")
