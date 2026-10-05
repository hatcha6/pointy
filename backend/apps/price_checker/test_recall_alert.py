"""A recalled or expired pack at the price checker (§6.8.1, §8.2, §13).

A customer scanning a pack from a quarantined lot used to be quoted its price
as if nothing were wrong. Now every code that names a lot — a serial inside
it, the carton's lot barcode, the pack's GS1 DataMatrix — answers with a safety
notice instead, and the response withholds the price altogether.
"""

import json
from datetime import timedelta
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Permission
from django.core.cache import cache
from django.test import TestCase
from django.urls import reverse
from django.utils import timezone
from rest_framework import status
from rest_framework.test import APIClient

from apps.catalog import gs1
from apps.catalog.models import Product
from apps.inventory.models import StockBatch
from apps.inventory.tracked_testing import receive, tracked_product

from .cache import lookup_price_cached
from .drivers import GenericTcpDriver
from .pricing import (
    AVAILABILITY_EXPIRED,
    AVAILABILITY_OK,
    AVAILABILITY_RECALLED,
    lookup_price,
)
from .serializers import (
    KIOSK_FOUND_KEYS,
    KIOSK_LOT_DETAIL_KEYS,
    KIOSK_LOT_KEYS,
    KIOSK_PRICE_KEYS,
    KIOSK_UNIT_KEYS,
    price_result_payload,
)
from .test_lookup_cache import CACHED
from .tests import BARCODE, make_product, profile

GTIN = "03453120000011"
LOT = "ABC123"
CARTON = "CARTON-ABC123"
PACK = "PACK-1"

#: Words that must never reach a kiosk, by any key or value.
FORBIDDEN = ("incoming_rate", "cost", "supplier", "consign", "40.00", "مورد")

_SEQUENCE = 0


def _user(*permissions):
    global _SEQUENCE
    _SEQUENCE += 1
    user = get_user_model().objects.create_user(
        username=f"staff-{_SEQUENCE}", password="pw"
    )
    for codename in permissions:
        app_label, code = codename.split(".")
        user.user_permissions.add(
            Permission.objects.get(content_type__app_label=app_label, codename=code)
        )
    return user


def _client(*permissions):
    client = APIClient()
    client.force_authenticate(user=_user(*permissions))
    return client


def _symbol(*, lot=LOT, serial=PACK, expiry="291130"):
    return f"01{GTIN}17{expiry}10{lot}" + gs1.GS + f"21{serial}"


class _PackFixture:
    """One serialised pharmacy pack, in one lot, on the shelf."""

    expiry_days = 400

    def setUp(self):
        self.product = tracked_product(
            name="لقاح مسلسل",
            sku="KIOSK-VAX",
            mode=Product.TrackingMode.SERIAL_BATCH,
            unit_price="90.00",
        )
        self.variant = self.product.default_variant
        self.variant.gtin = GTIN
        self.variant.save(update_fields=["gtin", "updated_at"])
        receive(
            variant=self.variant,
            quantity=1,
            unit_cost="40.00",
            units=[{"code": PACK}],
            batches=[
                {
                    "code": LOT,
                    "expiry_date": timezone.localdate()
                    + timedelta(days=self.expiry_days),
                    "barcode": CARTON,
                }
            ],
        )
        self.lot = StockBatch.objects.get(variant=self.variant)

    def quarantine(self, reason=""):
        response = _client(
            "inventory.view_stockbatch", "inventory.quarantine_batch"
        ).post(
            reverse("stock-batch-quarantine", args=[self.lot.pk]),
            {"reason": reason},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.lot.refresh_from_db()


class RecalledPackTests(_PackFixture, TestCase):
    def test_a_sellable_pack_is_priced_and_names_its_lot(self):
        for code in (PACK, CARTON, _symbol()):
            with self.subTest(code=code):
                result = lookup_price(code)
                self.assertTrue(result.found)
                self.assertEqual(result.availability, AVAILABILITY_OK)
                self.assertEqual(result.lot_code, LOT)
                self.assertEqual(result.final_price, Decimal("90.00"))

    def test_every_code_on_a_quarantined_pack_answers_recalled(self):
        """Unit code, carton lot barcode, and the pack's own DataMatrix."""
        self.quarantine()
        for code in (PACK, CARTON, _symbol()):
            with self.subTest(code=code):
                result = lookup_price(code)
                self.assertTrue(result.found)
                self.assertEqual(result.availability, AVAILABILITY_RECALLED)
                self.assertEqual(result.product_name, "لقاح مسلسل")
                self.assertEqual(result.lot_code, LOT)

    def test_a_recalled_payload_carries_no_price_by_any_name(self):
        """§13, updated deliberately: the key set is asserted by name, and a
        stopped pack's response has no price key at all — a kiosk on an older
        build reads ``final_price_display`` whatever ``availability`` says."""
        self.quarantine(reason="سحب من المصنع — تلوث")
        for code in (PACK, CARTON, _symbol()):
            with self.subTest(code=code):
                payload = price_result_payload(lookup_price(code))
                self.assertEqual(set(payload), KIOSK_FOUND_KEYS | {"lot"})
                self.assertEqual(set(payload["lot"]), KIOSK_LOT_KEYS)
                self.assertTrue(KIOSK_PRICE_KEYS.isdisjoint(payload))
                self.assertFalse(payload["in_stock"])
                self.assertEqual(payload["availability"], "recalled")
                flattened = json.dumps(payload, ensure_ascii=False, default=str)
                self.assertNotIn("90.00", flattened)
                # The reason is for staff; a customer is told to see a cashier.
                self.assertNotIn("تلوث", flattened)
                for forbidden in FORBIDDEN:
                    self.assertNotIn(forbidden, flattened)

    def test_a_sellable_lot_payload_keeps_the_price_and_the_exact_key_set(self):
        for code in (PACK, CARTON, _symbol()):
            with self.subTest(code=code):
                payload = price_result_payload(lookup_price(code))
                self.assertEqual(
                    set(payload), KIOSK_FOUND_KEYS | KIOSK_PRICE_KEYS | {"lot"}
                )
                self.assertEqual(set(payload["lot"]), KIOSK_LOT_KEYS)
                self.assertEqual(payload["final_price"], "90.00")
                flattened = json.dumps(payload, ensure_ascii=False, default=str)
                for forbidden in FORBIDDEN:
                    self.assertNotIn(forbidden, flattened)

    def test_the_shelf_scanner_shows_the_notice_not_the_price(self):
        self.quarantine()
        lines = GenericTcpDriver().display_lines(lookup_price(CARTON), profile())
        self.assertEqual(lines[0], "موقوف عن البيع")
        self.assertIn("يرجى مراجعة الكاشير", lines)
        self.assertFalse(any("90" in line for line in lines))

    def test_releasing_the_lot_brings_the_price_back(self):
        self.quarantine()
        response = _client(
            "inventory.view_stockbatch", "inventory.quarantine_batch"
        ).post(reverse("stock-batch-release-quarantine", args=[self.lot.pk]))
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(lookup_price(CARTON).availability, AVAILABILITY_OK)


class QuarantineStampTests(_PackFixture, TestCase):
    def test_quarantine_records_when_and_why_and_release_clears_both(self):
        self.quarantine(reason="سحب من المصنع")
        self.assertIsNotNone(self.lot.quarantined_at)
        self.assertEqual(self.lot.quarantine_reason, "سحب من المصنع")
        first = self.lot.quarantined_at

        # A second press keeps the first moment.
        self.quarantine()
        self.assertEqual(self.lot.quarantined_at, first)
        self.assertEqual(self.lot.quarantine_reason, "سحب من المصنع")

        _client(
            "inventory.view_stockbatch", "inventory.quarantine_batch"
        ).post(reverse("stock-batch-release-quarantine", args=[self.lot.pk]))
        self.lot.refresh_from_db()
        self.assertIsNone(self.lot.quarantined_at)
        self.assertEqual(self.lot.quarantine_reason, "")


class ExpiredPackTests(_PackFixture, TestCase):
    expiry_days = -3

    def test_an_expired_lot_answers_expired_when_the_product_refuses_it(self):
        for code in (PACK, CARTON, _symbol()):
            with self.subTest(code=code):
                result = lookup_price(code)
                self.assertEqual(result.availability, AVAILABILITY_EXPIRED)
                self.assertEqual(
                    result.lot_expiry, timezone.localdate() - timedelta(days=3)
                )

    def test_a_product_that_may_sell_expired_goods_is_still_priced(self):
        self.product.prevent_selling_expired = False
        self.product.save(update_fields=["prevent_selling_expired", "updated_at"])
        result = lookup_price(CARTON)
        self.assertEqual(result.availability, AVAILABILITY_OK)
        self.assertEqual(result.final_price, Decimal("90.00"))

    def test_the_shelf_scanner_says_expired(self):
        lines = GenericTcpDriver().display_lines(lookup_price(CARTON), profile())
        self.assertEqual(lines[0], "منتهي الصلاحية")


class Gs1WithoutARegisteredLotTests(_PackFixture, TestCase):
    def test_an_unregistered_lot_still_reads_its_printed_expiry(self):
        """The date printed on the pack is the customer's own information."""
        result = lookup_price(_symbol(lot="NEVER-SEEN", serial="X", expiry="200101"))
        self.assertTrue(result.found)
        self.assertEqual(result.lot_code, "NEVER-SEEN")
        self.assertEqual(result.availability, AVAILABILITY_EXPIRED)
        self.assertIsNone(result.batch_id)


class StaffLotDetailTests(_PackFixture, TestCase):
    """Staff mode may say what the kiosk may not: status, since when, and why."""

    def setUp(self):
        super().setUp()
        self.url = reverse("price-checker-lookup")
        self.quarantine(reason="سحب من المصنع")

    def test_the_kiosk_never_gets_the_detail_even_when_it_asks(self):
        response = APIClient().get(self.url, {"barcode": CARTON, "staff": "1"})
        data = response.json()
        self.assertEqual(data["availability"], "recalled")
        self.assertNotIn("lot_detail", data)
        self.assertNotIn("سحب", json.dumps(data, ensure_ascii=False))

    def test_a_signed_in_kiosk_that_does_not_ask_gets_none(self):
        """A kiosk can be entered from a device a manager is signed in on."""
        client = _client("inventory.view_stockbatch")
        data = client.get(self.url, {"barcode": CARTON}).json()
        self.assertNotIn("lot_detail", data)

    def test_a_reader_without_the_lot_permission_gets_none(self):
        data = _client().get(self.url, {"barcode": CARTON, "staff": "1"}).json()
        self.assertNotIn("lot_detail", data)

    def test_staff_get_status_date_and_reason(self):
        client = _client("inventory.view_stockbatch")
        data = client.get(self.url, {"barcode": CARTON, "staff": "1"}).json()
        detail = data["lot_detail"]
        self.assertEqual(set(detail), KIOSK_LOT_DETAIL_KEYS)
        self.assertEqual(detail["status"], "quarantined")
        self.assertEqual(detail["quarantine_reason"], "سحب من المصنع")
        self.assertIsNotNone(detail["quarantined_at"])
        self.assertEqual(detail["batch_id"], self.lot.pk)
        # Still no price, and still no cost, even for staff.
        self.assertTrue(KIOSK_PRICE_KEYS.isdisjoint(data))
        self.assertNotIn("40.00", json.dumps(data))


class IdentifiedArticleKeySetTests(TestCase):
    """The unit block of §13 is unchanged by any of this."""

    def test_a_handset_without_a_lot_keeps_its_old_shape(self):
        product = tracked_product(
            name="آيفون",
            sku="KIOSK-IMEI",
            mode=Product.TrackingMode.SERIAL,
            unit_price="1800.00",
        )
        receive(
            variant=product.default_variant,
            quantity=1,
            unit_cost="1200.00",
            units=[{"code": "358240051111110"}],
        )
        payload = price_result_payload(lookup_price("358240051111110"))
        self.assertEqual(set(payload), KIOSK_FOUND_KEYS | KIOSK_PRICE_KEYS)
        self.assertEqual(set(payload["unit"]), KIOSK_UNIT_KEYS)
        self.assertEqual(payload["availability"], "ok")


class OrdinaryProductCostsNothingExtraTests(TestCase):
    """A shop that sells Coca-Cola must not be able to tell that this shipped."""

    def test_an_ordinary_barcode_lookup_query_count_is_pinned(self):
        make_product(price="20.00")
        # Variant by barcode, category ids, the discount engine's rule read,
        # the variant's option values (its display name) and the stock read
        # for ``in_stock`` — the same five as before lots existed, and not one
        # of them about a lot, a unit or a GS1 symbol.
        with self.assertNumQueries(5):
            result = lookup_price(BARCODE)
        self.assertTrue(result.found)
        self.assertEqual(result.availability, AVAILABILITY_OK)
        self.assertEqual(set(price_result_payload(result)), KIOSK_FOUND_KEYS | KIOSK_PRICE_KEYS)


@CACHED
class QuarantineInvalidatesTheKioskCacheTests(_PackFixture, TestCase):
    def setUp(self):
        cache.clear()
        super().setUp()

    def test_a_cached_ok_dies_the_moment_the_lot_is_quarantined(self):
        self.assertEqual(lookup_price_cached(CARTON).availability, AVAILABILITY_OK)
        with self.assertNumQueries(0):
            self.assertEqual(
                lookup_price_cached(CARTON).availability, AVAILABILITY_OK
            )

        self.quarantine()  # StockBatch.save bumps the catalog version

        self.assertEqual(
            lookup_price_cached(CARTON).availability, AVAILABILITY_RECALLED
        )
