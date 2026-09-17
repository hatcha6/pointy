"""One scan, one answer — the endpoint the till reaches when its own lookup misses.

The shape of these tests follows the shape of the promise: a shop that sells
Coca-Cola never gets here, a phone shop gets a handset, and a pharmacy gets a
variant, a lot, an expiry and a serial out of one symbol.
"""

from datetime import date, timedelta
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Permission
from django.test import TestCase
from django.urls import reverse
from django.utils import timezone
from rest_framework import status
from rest_framework.test import APIClient

from apps.catalog import gs1
from apps.catalog.models import Product
from apps.inventory.models import StockBatch, StockUnit
from apps.inventory.tracked_testing import receive, tracked_product

IMEI = "351234567890116"


def _client(*permissions):
    user = get_user_model().objects.create_user(username="till", password="pw")
    for codename in permissions:
        app_label, code = codename.split(".")
        user.user_permissions.add(
            Permission.objects.get(content_type__app_label=app_label, codename=code)
        )
    client = APIClient()
    client.force_authenticate(user=user)
    return client


def _resolve(client, code):
    return client.get(reverse("resolve-barcode"), {"code": code})


class SerialResolutionTests(TestCase):
    def setUp(self):
        self.product = tracked_product(
            name="iPhone 13 Pro",
            sku="RES-IP",
            mode=Product.TrackingMode.SERIAL,
            unit_price="1500.00",
        )
        self.variant = self.product.default_variant
        receive(
            variant=self.variant,
            quantity=1,
            unit_cost="1200.00",
            units=[{"code": IMEI, "list_price": Decimal("1650.00")}],
        )
        self.unit = StockUnit.objects.get()

    def test_scanning_an_imei_returns_the_handset_and_its_own_price(self):
        response = _resolve(_client("catalog.view_productvariant"), IMEI)

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["kind"], "stock_unit")
        self.assertEqual(response.data["variant"]["id"], self.variant.pk)
        self.assertEqual(response.data["stock_unit"]["id"], self.unit.pk)
        self.assertEqual(response.data["stock_unit"]["list_price"], "1650.00")

    def test_punctuation_in_the_scan_does_not_matter(self):
        response = _resolve(_client("catalog.view_productvariant"), " 351234-567890116 ")
        self.assertEqual(response.data["kind"], "stock_unit")

    def test_a_sold_handset_no_longer_resolves(self):
        """One live unit per identifier. A sold one is history, not stock."""
        self.unit.status = StockUnit.Status.SOLD
        self.unit.save(update_fields=["status", "updated_at"])

        response = _resolve(_client("catalog.view_productvariant"), IMEI)
        self.assertEqual(response.data["kind"], "none")
        self.assertFalse(response.data["found"])

    def test_a_cashier_without_the_cost_permission_is_not_told_the_cost(self):
        response = _resolve(_client("catalog.view_productvariant"), IMEI)
        self.assertNotIn("incoming_rate", response.data["stock_unit"])
        self.assertNotIn("total_cost", response.data["stock_unit"])

    def test_a_plain_code_that_is_nothing_resolves_to_nothing(self):
        response = _resolve(_client("catalog.view_productvariant"), "6221031492015")
        self.assertEqual(response.data["kind"], "none")

    def test_resolving_needs_the_variant_permission(self):
        user = get_user_model().objects.create_user(username="nobody", password="pw")
        client = APIClient()
        client.force_authenticate(user=user)
        self.assertEqual(
            _resolve(client, IMEI).status_code, status.HTTP_403_FORBIDDEN
        )


class Gs1ResolutionTests(TestCase):
    """One DataMatrix, and the till knows which pack it is holding."""

    def setUp(self):
        self.product = tracked_product(
            name="لقاح مسلسل",
            sku="RES-VAX",
            mode=Product.TrackingMode.SERIAL_BATCH,
            unit_price="90.00",
        )
        self.variant = self.product.default_variant
        # Held apart from the row, because one test blanks the column and
        # still needs to scan the same symbol.
        self.gtin = "03453120000011"
        self.variant.gtin = self.gtin
        self.variant.save(update_fields=["gtin", "updated_at"])
        self.expiry = date(2029, 11, 30)
        receive(
            variant=self.variant,
            quantity=1,
            unit_cost="40.00",
            units=[{"code": "PACK-1"}],
            batches=[{"code": "ABC123", "expiry_date": self.expiry}],
        )

    def _symbol(self, *, lot="ABC123", serial="PACK-1", expiry="291130"):
        return f"01{self.gtin}17{expiry}10{lot}" + gs1.GS + f"21{serial}"

    def test_one_symbol_resolves_variant_lot_expiry_and_unit(self):
        response = _resolve(_client("catalog.view_productvariant"), self._symbol())

        self.assertEqual(response.data["kind"], "gs1")
        self.assertEqual(response.data["variant"]["id"], self.variant.pk)
        self.assertEqual(response.data["stock_batch"]["code"], "ABC123")
        self.assertEqual(response.data["stock_unit"]["code"], "PACK-1")
        self.assertEqual(response.data["expiry_date"], self.expiry.isoformat())
        self.assertEqual(response.data["warnings"], [])

    def test_the_gtin_also_matches_a_variant_that_only_typed_its_ean(self):
        """No pharmacy should have to re-key its catalog before a scan works."""
        self.variant.gtin = ""
        self.variant.barcode = "3453120000011"
        self.variant.save(update_fields=["gtin", "barcode", "updated_at"])

        response = _resolve(_client("catalog.view_productvariant"), self._symbol())
        self.assertEqual(response.data["variant"]["id"], self.variant.pk)

    def test_an_expiry_that_disagrees_with_the_lot_is_reported_not_overwritten(self):
        """The person holding the box is the only one who can say which label
        is right."""
        response = _resolve(
            _client("catalog.view_productvariant"), self._symbol(expiry="301130")
        )
        codes = [warning["code"] for warning in response.data["warnings"]]
        self.assertIn("expiry_mismatch", codes)
        # And the lot's own date still wins the payload, because that is what
        # the shop's ledger says the goods are.
        self.assertEqual(response.data["expiry_date"], self.expiry.isoformat())

    def test_an_unknown_lot_says_so_and_still_names_the_variant(self):
        response = _resolve(
            _client("catalog.view_productvariant"), self._symbol(lot="NOPE")
        )
        codes = [warning["code"] for warning in response.data["warnings"]]
        self.assertIn("unknown_lot", codes)
        self.assertEqual(response.data["variant"]["id"], self.variant.pk)

    def test_an_unknown_gtin_is_not_a_match_and_explains_itself(self):
        response = _resolve(
            _client("catalog.view_productvariant"),
            "01999999999999917291130" + "10ABC123",
        )
        self.assertEqual(response.data["kind"], "none")
        codes = [warning["code"] for warning in response.data["warnings"]]
        self.assertIn("unknown_gtin", codes)

    def test_a_scanner_that_strips_the_separator_is_named_as_the_problem(self):
        response = _resolve(
            _client("catalog.view_productvariant"),
            f"01{self.variant.gtin}17291130" + "10" + "A" * 30,
        )
        codes = [warning["code"] for warning in response.data["warnings"]]
        self.assertIn("missing_group_separator", codes)


class LotBarcodeResolutionTests(TestCase):
    def test_a_lot_barcode_printed_on_a_carton_resolves_to_its_lot(self):
        product = tracked_product(
            name="أموكسيسيلين",
            sku="RES-AMOX",
            mode=Product.TrackingMode.BATCH,
            unit_price="20.00",
        )
        receive(
            variant=product.default_variant,
            quantity=10,
            unit_cost="14.00",
            batches=[
                {
                    "code": "L-99",
                    "quantity": Decimal("10"),
                    "expiry_date": timezone.localdate() + timedelta(days=100),
                    "barcode": "CARTON-L99",
                }
            ],
        )
        StockBatch.objects.filter(code="L-99").update(barcode="CARTON-L99")

        response = _resolve(_client("catalog.view_productvariant"), "CARTON-L99")
        self.assertEqual(response.data["kind"], "stock_batch")
        self.assertEqual(response.data["stock_batch"]["code"], "L-99")
