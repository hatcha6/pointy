"""A scale label held up to the price checker.

The kiosk is the one place a customer uses this feature unaided, so it has to
answer the question they actually have — "what does *this packet* cost" — and
not only "what is this cheese a kilo".
"""

from decimal import Decimal

from django.test import TestCase

from apps.catalog import scale_barcodes as sb
from apps.catalog.models import Product, ScaleBarcodeRule
from apps.catalog.testing import create_product_with_default_variant
from apps.discounts.models import DiscountRule

from .pricing import lookup_price


class ScaleLabelLookupTests(TestCase):
    def setUp(self):
        ScaleBarcodeRule.objects.update(is_active=False)
        self.weight_rule = ScaleBarcodeRule.objects.create(
            name="Produce", pattern="21IIIIIVVVVVC", value_decimals=3
        )
        self.price_rule = ScaleBarcodeRule.objects.create(
            name="Deli",
            pattern="23IIIIIVVVVVC",
            value_kind=sb.ValueKind.PRICE,
            value_decimals=2,
        )
        self.product = create_product_with_default_variant(
            name="جبن أبيض", sku="CHEESE", unit_price="40.00", barcode="12345"
        )
        self.product.unit = Product.Unit.KILOGRAM
        self.product.save(update_fields=["unit"])

    def test_a_weight_label_prices_the_packet(self):
        code = sb.build_code(self.weight_rule.as_rule(), "12345", Decimal("0.75"))
        result = lookup_price(code)
        self.assertTrue(result.found)
        self.assertEqual(result.product_name, "جبن أبيض")
        self.assertEqual(result.final_price, Decimal("40.00"))
        self.assertEqual(result.label_quantity, Decimal("0.750"))
        self.assertEqual(result.label_total, Decimal("30.00"))

    def test_a_price_label_reports_what_the_sticker_says(self):
        code = sb.build_code(self.price_rule.as_rule(), "12345", Decimal("12.50"))
        result = lookup_price(code)
        self.assertTrue(result.found)
        # 12.50 / 40.00 is 0.3125 — exactly between two storable quantities.
        # The tie goes down, so the packet rings at 12.48 rather than 12.52.
        self.assertEqual(result.label_quantity, Decimal("0.312"))
        self.assertEqual(result.label_total, Decimal("12.48"))

    def test_a_discount_is_reflected_in_what_the_packet_costs(self):
        DiscountRule.objects.create(
            name="نصف السعر",
            channel=DiscountRule.Channel.SALES,
            scope=DiscountRule.Scope.DOCUMENT,
            value_type=DiscountRule.ValueType.PERCENTAGE,
            value=Decimal("50"),
            is_active=True,
        )
        code = sb.build_code(self.weight_rule.as_rule(), "12345", Decimal("0.75"))
        result = lookup_price(code)
        # The sticker is worth what the till will charge, discount included.
        self.assertEqual(result.final_price, Decimal("20.00"))
        self.assertEqual(result.label_total, Decimal("15.00"))

    def test_an_ordinary_barcode_carries_no_label_figures(self):
        result = lookup_price("12345")
        self.assertTrue(result.found)
        self.assertIsNone(result.label_quantity)
        self.assertIsNone(result.label_total)

    def test_an_unreadable_label_is_still_not_found(self):
        ScaleBarcodeRule.objects.update(is_active=False)
        code = sb.build_code(self.weight_rule.as_rule(), "12345", Decimal("0.75"))
        self.assertFalse(lookup_price(code).found)
