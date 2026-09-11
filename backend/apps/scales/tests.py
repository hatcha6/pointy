"""What a scale is allowed to be told, and what the shop is allowed to believe.

The load-bearing assertions here are the ones about *not* claiming success: a
file that has been produced is not a scale that has been updated, and a push
that half-landed is not a push that worked.
"""

from decimal import Decimal
from unittest.mock import patch

from django.test import TestCase

from apps.catalog.models import Product, ScaleBarcodeRule, ScalePlu, UnitOfMeasure
from apps.catalog.testing import create_product_with_default_variant
from apps.catalog import scale_barcodes as sb
from apps.catalog import scale_rules

from . import services
from .drivers import (
    PluRecord,
    PushOutcome,
    ScaleError,
    ScaleRefusedError,
    ScaleUnreachableError,
)
from .drivers.base import READ_TIMEOUT
from .drivers.cas_cl5000 import CasCl5000Driver, _bcc
from .drivers.file_export import FileExportDriver
from .models import Scale, ScalePushJob


class _FakeSocket:
    """Just enough socket for the write path: what went out, and what came back."""

    def __init__(self, reply):
        self.reply = reply
        self.sent = b""
        self.timeouts = []

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def sendall(self, payload):
        self.sent += payload

    def settimeout(self, value):
        self.timeouts.append(value)

    def recv(self, size):
        if isinstance(self.reply, BaseException):
            raise self.reply
        return self.reply


def _weighed_product(name="طماطم", sku="TOM", price="4.00", unit=None):
    product = create_product_with_default_variant(
        name=name, sku=sku, unit_price=price
    )
    product.unit = unit or Product.Unit.KILOGRAM
    product.save(update_fields=["unit"])
    return product


class PluAllocationTests(TestCase):
    def test_a_number_is_allocated_not_chosen(self):
        first = services.allocate_plu(_weighed_product(sku="A").default_variant)
        second = services.allocate_plu(
            _weighed_product(name="خيار", sku="B").default_variant
        )
        self.assertEqual(first.plu_number, 1)
        self.assertEqual(second.plu_number, 2)

    def test_allocating_twice_returns_the_same_number(self):
        variant = _weighed_product(sku="A").default_variant
        self.assertEqual(
            services.allocate_plu(variant).pk, services.allocate_plu(variant).pk
        )

    def test_a_retired_number_is_never_handed_out_again(self):
        # The sticker carrying PLU 1 may still be on a shelf. The gap stays.
        first = services.allocate_plu(_weighed_product(sku="A").default_variant)
        first.is_active = False
        first.save(update_fields=["is_active"])
        second = services.allocate_plu(
            _weighed_product(name="خيار", sku="B").default_variant
        )
        self.assertEqual(second.plu_number, 2)

    def test_the_printed_name_falls_back_to_the_product(self):
        plu = services.allocate_plu(_weighed_product().default_variant)
        self.assertEqual(plu.printed_name, "طماطم")
        plu.label_name = "TAMATEM"
        self.assertEqual(plu.printed_name, "TAMATEM")


class PriceNormalisationTests(TestCase):
    def test_a_product_kept_in_grams_is_priced_per_kilo(self):
        product = _weighed_product(price="0.04", unit="g")
        self.assertEqual(services.scale_price(product.default_variant), Decimal("40.00"))
        self.assertTrue(services.is_weighed(product.default_variant))

    def test_a_product_kept_in_kilos_is_sent_as_is(self):
        product = _weighed_product(price="40.00")
        self.assertEqual(services.scale_price(product.default_variant), Decimal("40.00"))

    def test_a_counted_product_is_a_by_the_piece_plu(self):
        product = _weighed_product(price="2.50", unit=Product.Unit.PIECE)
        self.assertEqual(services.scale_price(product.default_variant), Decimal("2.50"))
        self.assertFalse(services.is_weighed(product.default_variant))

    def test_the_scale_is_never_told_about_discounts(self):
        # Nothing in plu_records consults the discount engine; this test exists
        # so that stays true. A scale prints the shelf price.
        product = _weighed_product(price="40.00")
        services.allocate_plu(product.default_variant)
        record = services.plu_records()[0]
        self.assertEqual(record.price, Decimal("40.00"))


class FileExportDriverTests(TestCase):
    def setUp(self):
        self.records = [
            PluRecord(plu_number=1, name="طماطم", price=Decimal("40.00")),
            PluRecord(
                plu_number=2,
                name="خبز",
                price=Decimal("1.50"),
                is_weighed=False,
                tare_grams=15,
            ),
        ]

    def test_writes_the_default_column_order(self):
        outcome = FileExportDriver().push(self.records)
        text = outcome.content.decode("utf-8-sig")
        self.assertEqual(
            text.splitlines(),
            ["1,طماطم,40.00,1,0", "2,خبز,1.50,2,15"],
        )

    def test_a_file_is_not_a_delivered_price(self):
        outcome = FileExportDriver().push(self.records)
        self.assertFalse(outcome.delivered)
        self.assertEqual(outcome.filename, "plu.csv")

    def test_columns_delimiter_and_encoding_follow_the_vendor_tool(self):
        outcome = FileExportDriver(
            options={
                "columns": ["plu", "price", "name"],
                "delimiter": ";",
                "encoding": "cp1256",
                "header": True,
                "filename": "PLU.TXT",
            }
        ).push(self.records)
        text = outcome.content.decode("cp1256")
        self.assertEqual(text.splitlines()[0], "plu;price;name")
        self.assertEqual(text.splitlines()[1], "1;40.00;طماطم")
        self.assertEqual(outcome.filename, "PLU.TXT")

    def test_lines_end_the_way_a_windows_importer_expects(self):
        outcome = FileExportDriver().push(self.records)
        self.assertIn(b"\r\n", outcome.content)

    def test_an_unknown_column_is_refused_rather_than_skipped(self):
        with self.assertRaises(ScaleError):
            FileExportDriver(options={"columns": ["plu", "colour"]}).push(self.records)

    def test_a_name_the_encoding_cannot_carry_does_not_break_the_file(self):
        outcome = FileExportDriver(options={"encoding": "ascii"}).push(self.records)
        self.assertIn(b"1,", outcome.content)


class CasDriverTests(TestCase):
    def test_a_plu_number_is_framed_the_way_the_manual_shows(self):
        driver = CasCl5000Driver(host="10.0.0.9")
        # The manual's worked example: PLU 1000 as 03 E8 00 00.
        self.assertEqual(driver._number(1000, 4), b"\x03\xe8\x00\x00")

    def test_byte_order_can_be_switched_for_a_scale_that_disagrees(self):
        big = CasCl5000Driver(host="h", options={"byte_order": "big"})
        little = CasCl5000Driver(host="h", options={"byte_order": "little"})
        self.assertEqual(big._number(1000, 4), b"\x00\x00\x03\xe8")
        self.assertEqual(little._number(1000, 4), b"\xe8\x03\x00\x00")

    def test_a_value_too_large_for_its_field_is_refused(self):
        with self.assertRaises(ScaleError):
            CasCl5000Driver(host="h")._number(2**40, 4)

    def test_the_block_checksum_is_an_xor(self):
        self.assertEqual(_bcc(b"\x01\x02\x03"), 0x00)
        self.assertEqual(_bcc(b"\x10\x01"), 0x11)

    def test_a_scale_with_no_address_fails_before_it_opens_a_socket(self):
        with self.assertRaises(ScaleError):
            CasCl5000Driver(host="").push(
                [PluRecord(plu_number=1, name="x", price=Decimal("1"))]
            )

    def test_a_silent_scale_is_a_happy_scale(self):
        # The manual documents an error line and no acknowledgement, so waiting
        # for a reply that never comes would make a 400-item push take an hour.
        driver = CasCl5000Driver(host="10.0.0.9", options={"ack_window": 0.05})
        connection = _FakeSocket(reply=TimeoutError())
        driver._write_plu(
            connection, PluRecord(plu_number=1, name="x", price=Decimal("1"))
        )
        self.assertTrue(connection.sent)
        # The long read timeout is restored for whatever comes next.
        self.assertEqual(connection.timeouts[-1], READ_TIMEOUT)

    def test_a_complaint_inside_the_window_fails_that_plu(self):
        driver = CasCl5000Driver(host="10.0.0.9", options={"ack_window": 0.05})
        connection = _FakeSocket(reply=b"W02:E82\n")
        with self.assertRaises(ScaleRefusedError):
            driver._write_plu(
                connection, PluRecord(plu_number=7, name="x", price=Decimal("1"))
            )

    def test_a_checksum_complaint_is_named_as_our_fault(self):
        driver = CasCl5000Driver(host="10.0.0.9", options={"ack_window": 0.05})
        connection = _FakeSocket(reply=b"W02:EFE\n")
        with self.assertRaises(ScaleRefusedError) as caught:
            driver._write_plu(
                connection, PluRecord(plu_number=7, name="x", price=Decimal("1"))
            )
        self.assertIn("corrupt", str(caught.exception))

    def test_a_scale_that_disappears_mid_push_stops_the_push(self):
        driver = CasCl5000Driver(host="10.0.0.9", options={"ack_window": 0.05})
        records = [
            PluRecord(plu_number=index, name="x", price=Decimal("1"))
            for index in range(1, 5)
        ]
        with patch.object(
            CasCl5000Driver,
            "_connect",
            return_value=_FakeSocket(reply=OSError("connection reset")),
        ):
            with self.assertRaises(ScaleUnreachableError):
                driver.push(records)

    def test_a_refusal_does_not_stop_the_rest_of_the_push(self):
        driver = CasCl5000Driver(host="10.0.0.9", options={"ack_window": 0.05})
        records = [
            PluRecord(plu_number=index, name="x", price=Decimal("1"))
            for index in range(1, 4)
        ]
        replies = iter([b"W02:E82\n", b"", b""])
        with patch.object(
            CasCl5000Driver, "_connect", return_value=_FakeSocket(reply=b"")
        ):
            with patch.object(
                CasCl5000Driver,
                "_read_complaint",
                side_effect=lambda connection: next(replies),
            ):
                outcome = driver.push(records)
        self.assertEqual(outcome.sent, 2)
        self.assertEqual(outcome.failed, 1)
        self.assertIn(1, outcome.errors)

    def test_an_unreachable_scale_says_so(self):
        driver = CasCl5000Driver(host="192.0.2.1", port=20304)
        with patch("socket.create_connection", side_effect=OSError("no route")):
            with self.assertRaises(ScaleUnreachableError):
                driver.check()


class PushJobTests(TestCase):
    def setUp(self):
        self.scale = Scale.objects.create(name="ميزان الخضار", driver="file_export")
        product = _weighed_product(price="40.00")
        services.allocate_plu(product.default_variant)

    def test_an_export_is_recorded_as_exported_not_succeeded(self):
        job = services.push_scale(self.scale)
        self.assertEqual(job.status, ScalePushJob.Status.EXPORTED)
        self.assertEqual(job.sent_count, 1)
        self.scale.refresh_from_db()
        # Nothing reached the scale, so nothing is stamped on it.
        self.assertIsNone(self.scale.last_push_at)

    def test_a_wire_push_that_lands_is_a_success_and_stamps_the_scale(self):
        self.scale.driver = "cas_cl5000"
        self.scale.host = "10.0.0.9"
        self.scale.save(update_fields=["driver", "host"])
        with patch(
            "apps.scales.drivers.cas_cl5000.CasCl5000Driver.push",
            return_value=PushOutcome(sent=1),
        ):
            job = services.push_scale(self.scale)
        self.assertEqual(job.status, ScalePushJob.Status.SUCCEEDED)
        self.scale.refresh_from_db()
        self.assertIsNotNone(self.scale.last_push_at)

    def test_a_half_landed_push_is_partial_and_names_the_items(self):
        self.scale.driver = "cas_cl5000"
        self.scale.host = "10.0.0.9"
        self.scale.save(update_fields=["driver", "host"])
        with patch(
            "apps.scales.drivers.cas_cl5000.CasCl5000Driver.push",
            return_value=PushOutcome(sent=1, failed=1, errors={7: "refused"}),
        ):
            job = services.push_scale(self.scale)
        self.assertEqual(job.status, ScalePushJob.Status.PARTIAL)
        self.assertEqual(job.errors, {"7": "refused"})

    def test_an_unreachable_scale_fails_the_job_with_its_reason(self):
        self.scale.driver = "cas_cl5000"
        self.scale.host = "192.0.2.1"
        self.scale.save(update_fields=["driver", "host"])
        with patch(
            "apps.scales.drivers.cas_cl5000.CasCl5000Driver.push",
            side_effect=ScaleUnreachableError("Could not reach the scale."),
        ):
            job = services.push_scale(self.scale)
        self.assertEqual(job.status, ScalePushJob.Status.FAILED)
        self.assertIn("Could not reach", job.message)

    def test_a_push_with_nothing_assigned_explains_itself(self):
        ScalePlu.objects.all().delete()
        job = services.push_scale(self.scale)
        self.assertEqual(job.status, ScalePushJob.Status.FAILED)
        self.assertIn("PLU", job.message)

    def test_an_archived_product_is_not_pushed(self):
        product = Product.objects.get(name="طماطم")
        product.archived_at = "2026-01-01T00:00:00Z"
        product.save(update_fields=["archived_at"])
        self.assertEqual(services.plu_records(), [])


class PluResolutionTests(TestCase):
    """The loop closing: a number we pushed comes back on a sticker."""

    def setUp(self):
        ScaleBarcodeRule.objects.update(is_active=False)
        self.rule = ScaleBarcodeRule.objects.create(
            name="Produce", pattern="21IIIIIVVVVVC", value_decimals=3
        )
        self.product = _weighed_product(price="40.00")
        self.plu = services.allocate_plu(self.product.default_variant)

    def test_a_pushed_plu_resolves_at_the_till_without_a_barcode(self):
        self.assertEqual(self.product.default_variant.barcode, "")
        code = sb.build_code(self.rule.as_rule(), str(self.plu.plu_number), Decimal("1.5"))
        match = scale_rules.parse(code)
        self.assertIsNotNone(match)
        self.assertEqual(
            scale_rules.resolve_variant(match), self.product.default_variant
        )

    def test_a_retired_plu_stops_resolving(self):
        self.plu.is_active = False
        self.plu.save(update_fields=["is_active"])
        code = sb.build_code(self.rule.as_rule(), str(self.plu.plu_number), Decimal("1.5"))
        self.assertIsNone(scale_rules.resolve_variant(scale_rules.parse(code)))

    def test_a_real_barcode_still_wins_over_a_plu_number(self):
        # A product whose stored shelf-label code collides with another
        # product's PLU. The stored barcode is the more specific answer and has
        # to win: it is a code somebody deliberately put on this product.
        code = sb.build_code(self.rule.as_rule(), "00001", Decimal("1.5"))
        match = scale_rules.parse(code)
        other = create_product_with_default_variant(
            name="Other", sku="OTH", unit_price="1.00", barcode=match.base_code
        )
        self.assertEqual(self.plu.plu_number, 1)
        self.assertEqual(
            scale_rules.resolve_variant(scale_rules.parse(code)),
            other.default_variant,
        )
