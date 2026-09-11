"""What a scale label is allowed to mean.

The vectors in ``PARSE_VECTORS`` are shared with the Dart parser
(``frontend/test/shared/barcode/scale_barcode_test.dart``). Both sides must
agree digit for digit: the till reads a label locally and the price checker
reads the same label on the server, and a shop that got two different answers
from the same sticker would be right never to trust either.
"""

from decimal import Decimal

from django.core.exceptions import ValidationError
from django.test import TestCase

from apps.catalog import scale_barcodes as sb
from apps.catalog import scale_rules
from apps.catalog.models import (
    Product,
    ProductUnit,
    ProductUnitBarcode,
    ScaleBarcodeRule,
    UnitOfMeasure,
)
from apps.catalog.scale_quantity import conversion_factor, resolve_scale_quantity
from apps.catalog.testing import create_product_with_default_variant

WEIGHT_RULE = sb.ScaleRule(
    pattern="21IIIIIVVVVVC",
    value_kind=sb.ValueKind.WEIGHT,
    value_decimals=3,
    name="weight",
)
PRICE_RULE = sb.ScaleRule(
    pattern="23IIIIIVVVVVC",
    value_kind=sb.ValueKind.PRICE,
    value_decimals=2,
    name="price",
)
COMPAT_RULE = sb.ScaleRule(
    pattern="2XIIIIIVVVVVC",
    value_kind=sb.ValueKind.WEIGHT,
    value_decimals=3,
    name="compat",
)

#: ``(code, rule, item_code, value, base_code)`` — the shared cross-language table.
PARSE_VECTORS = [
    ("2112345015002", WEIGHT_RULE, "12345", Decimal("1.500"), "2112345000008"),
    ("2112345000008", WEIGHT_RULE, "12345", Decimal("0.000"), "2112345000008"),
    ("2312345012500", PRICE_RULE, "12345", Decimal("12.50"), "2312345000002"),
    ("2012345007505", COMPAT_RULE, "12345", Decimal("0.750"), "2012345000001"),
]


class ParserTests(TestCase):
    rules = [WEIGHT_RULE, PRICE_RULE, COMPAT_RULE]

    def test_shared_vectors(self):
        for code, rule, item_code, value, base_code in PARSE_VECTORS:
            with self.subTest(code=code):
                match = sb.parse(code, self.rules)
                self.assertIsNotNone(match, code)
                self.assertEqual(match.rule.name, rule.name)
                self.assertEqual(match.item_code, item_code)
                self.assertEqual(match.value, value)
                self.assertEqual(match.base_code, base_code)

    def test_base_code_recomputes_the_check_digit(self):
        # Odoo's worked example: the masked code is a valid EAN-13 in its own
        # right, which is what a shop's own shelf label carries.
        match = sb.parse("2112345015002", self.rules)
        self.assertTrue(sb.has_valid_check_digit(match.base_code))

    def test_candidates_are_ordered_most_specific_first(self):
        code = sb.build_code(WEIGHT_RULE, "00123", Decimal("1.5"))
        match = sb.parse(code, self.rules)
        self.assertEqual(
            match.candidate_barcodes,
            ("2100123000005", "2100123", "00123", "123"),
        )

    def test_unmatched_codes_are_not_scale_labels(self):
        for code in (
            "",
            "   ",
            None,
            "6221031492039",  # an ordinary supplier EAN
            "21123450150",  # too short
            "211234501500222",  # too long
            "21ABC45015002",  # not digits
            "2112345015002 ",  # trailing space is stripped, then matches
        ):
            with self.subTest(code=code):
                match = sb.parse(code, self.rules)
                if code == "2112345015002 ":
                    self.assertIsNotNone(match)
                else:
                    self.assertIsNone(match)

    def test_wrong_check_digit_is_refused(self):
        self.assertIsNone(sb.parse("2112345015003", self.rules))

    def test_a_scale_that_prints_a_wrong_check_digit_can_be_accommodated(self):
        lenient = sb.ScaleRule(
            pattern="21IIIIIVVVVVC",
            value_kind=sb.ValueKind.WEIGHT,
            value_decimals=3,
            require_check_digit=False,
        )
        match = sb.parse("2112345015003", [lenient])
        self.assertIsNotNone(match)
        self.assertEqual(match.value, Decimal("1.500"))

    def test_price_and_weight_are_never_confused(self):
        # The same five digits under two rules. Nothing in the digits decides
        # this; only the configured prefix does.
        weight = sb.parse("2112345012506", self.rules)
        price = sb.parse("2312345012500", self.rules)
        self.assertEqual(weight.value_kind, sb.ValueKind.WEIGHT)
        self.assertEqual(weight.value, Decimal("1.250"))
        self.assertEqual(price.value_kind, sb.ValueKind.PRICE)
        self.assertEqual(price.value, Decimal("12.50"))

    def test_build_code_round_trips_every_rule(self):
        for rule in self.rules:
            for value in (Decimal("0"), Decimal("0.005"), Decimal("1.5"), Decimal("99.999")):
                if rule.value_kind == sb.ValueKind.PRICE and value == Decimal("0.005"):
                    continue  # not representable at two decimals
                with self.subTest(rule=rule.name, value=value):
                    code = sb.build_code(rule, "12345", value)
                    match = sb.parse(code, [rule])
                    self.assertIsNotNone(match)
                    self.assertEqual(
                        match.value,
                        value.quantize(Decimal(1).scaleb(-rule.value_decimals)),
                    )

    def test_build_code_refuses_a_value_that_does_not_fit(self):
        with self.assertRaises(sb.ScaleRuleError):
            sb.build_code(WEIGHT_RULE, "12345", Decimal("1000"))

    def test_check_digit_matches_known_good_codes(self):
        # A real Coca-Cola EAN-13, a scale label, and the masked base code.
        for code in ("5449000000996", "2112345015002", "2112345000008"):
            with self.subTest(code=code):
                self.assertTrue(sb.has_valid_check_digit(code))


class PatternValidationTests(TestCase):
    def test_rejects_patterns_that_cannot_describe_a_label(self):
        cases = {
            "": "required",
            "IIIIIVVVVVC": "prefix",
            "21IIIIIVVVVVQ": "Unknown pattern characters",
            "21VVVVVVVVVC": "item-code digit",
            "21IIIIIIIIIC": "value digit",
            "21IIIIICVVVVV": "last position",
        }
        for pattern, fragment in cases.items():
            with self.subTest(pattern=pattern):
                with self.assertRaises(sb.ScaleRuleError) as caught:
                    sb.validate_pattern(pattern)
                self.assertIn(fragment, str(caught.exception))

    def test_rejects_more_decimals_than_digits(self):
        with self.assertRaises(sb.ScaleRuleError):
            sb.ScaleRule(pattern="21IIIIIVVVVVC", value_decimals=6)


class RuleModelTests(TestCase):
    def test_the_seeded_rule_reads_what_the_till_read_before(self):
        rule = ScaleBarcodeRule.objects.get(pattern="2XIIIIIVVVVVC")
        self.assertTrue(rule.is_active)
        match = scale_rules.parse("2012345007505")
        self.assertIsNotNone(match)
        self.assertEqual(match.value, Decimal("0.750"))

    def test_two_active_rules_cannot_describe_the_same_label(self):
        ScaleBarcodeRule.objects.create(name="A", pattern="21IIIIIVVVVVC")
        clash = ScaleBarcodeRule(name="B", pattern="21IIIIIVVVVVC")
        with self.assertRaises(ValidationError) as caught:
            clash.clean()
        self.assertIn("pattern", caught.exception.message_dict)

    def test_an_inactive_rule_may_duplicate_an_active_one(self):
        ScaleBarcodeRule.objects.create(name="A", pattern="21IIIIIVVVVVC")
        spare = ScaleBarcodeRule(name="B", pattern="21IIIIIVVVVVC", is_active=False)
        spare.clean()  # does not raise

    def test_a_more_specific_rule_wins_over_the_broad_seeded_one(self):
        # The whole point of ordering by specificity: a shop adds a deli scale
        # on prefix 23 and it fires, even though the seeded catch-all matches
        # every 2-prefixed code and was created first.
        ScaleBarcodeRule.objects.create(
            name="Deli",
            pattern="23IIIIIVVVVVC",
            value_kind=sb.ValueKind.PRICE,
            value_decimals=2,
            sequence=50,
        )
        match = scale_rules.parse("2312345012500")
        self.assertEqual(match.value_kind, sb.ValueKind.PRICE)
        self.assertEqual(match.value, Decimal("12.50"))

    def test_one_unusable_row_does_not_stop_the_till_scanning(self):
        # Only reachable by a hand-edited database or an older release, but the
        # cost of getting it wrong is that every scan 500s. Skip the row, log
        # it, and keep reading the rules that do work.
        ScaleBarcodeRule.objects.filter(pattern="2XIIIIIVVVVVC").update(
            pattern="nonsense"
        )
        ScaleBarcodeRule.objects.create(name="Good", pattern="21IIIIIVVVVVC")
        with self.assertLogs("apps.catalog.scale_rules", level="WARNING"):
            rules = scale_rules.active_rules()
        self.assertEqual([rule.name for rule in rules], ["Good"])
        self.assertIsNotNone(scale_rules.parse("2112345015002"))

    def test_a_clash_check_survives_an_unusable_existing_row(self):
        ScaleBarcodeRule.objects.filter(pattern="2XIIIIIVVVVVC").update(
            pattern="nonsense"
        )
        ScaleBarcodeRule(name="New", pattern="21IIIIIVVVVVC").clean()

    def test_inactive_rules_are_not_consulted(self):
        ScaleBarcodeRule.objects.update(is_active=False)
        self.assertIsNone(scale_rules.parse("2012345007505"))


class QuantityTests(TestCase):
    def setUp(self):
        self.kg_product = create_product_with_default_variant(
            name="Tomatoes", sku="TOM", unit_price="4.00", barcode="12345"
        )
        self.kg_product.unit = Product.Unit.KILOGRAM
        self.kg_product.save(update_fields=["unit"])
        self.kg_variant = self.kg_product.default_variant

    def _match(self, code, rule):
        match = sb.parse(code, [rule])
        self.assertIsNotNone(match, code)
        return match

    def test_a_weight_label_rings_its_weight(self):
        match = self._match("2112345015002", WEIGHT_RULE)
        resolved = resolve_scale_quantity(match, self.kg_variant)
        self.assertEqual(resolved.quantity, Decimal("1.500"))
        self.assertEqual(resolved.warning, "")

    def test_a_weight_label_converts_into_the_products_own_unit(self):
        gram = UnitOfMeasure.objects.get(code="g")
        self.kg_product.unit = gram.code
        self.kg_product.save(update_fields=["unit"])
        match = self._match("2112345015002", WEIGHT_RULE)
        resolved = resolve_scale_quantity(match, self.kg_variant)
        self.assertEqual(resolved.quantity, Decimal("1500.000"))

    def test_a_counted_product_never_takes_a_weight(self):
        self.kg_product.unit = Product.Unit.PIECE
        self.kg_product.save(update_fields=["unit"])
        match = self._match("2112345015002", WEIGHT_RULE)
        resolved = resolve_scale_quantity(match, self.kg_variant)
        self.assertEqual(resolved.quantity, Decimal("1"))
        self.assertEqual(resolved.warning, sb.WARN_NOT_FRACTIONAL)

    def test_a_weight_that_cannot_reach_the_products_unit_is_reported(self):
        self.assertIsNone(conversion_factor("kg", "box"))
        litre = UnitOfMeasure.objects.filter(code="l").first()
        self.assertIsNotNone(litre)
        self.assertIsNone(conversion_factor("kg", litre.code))

    def test_a_zero_value_label_is_an_identity_not_a_measurement(self):
        match = self._match("2112345000008", WEIGHT_RULE)
        self.assertTrue(match.is_zero_value)
        resolved = resolve_scale_quantity(match, self.kg_variant)
        self.assertEqual(resolved.quantity, Decimal("1"))
        self.assertEqual(resolved.warning, "")

    def test_a_price_label_becomes_the_quantity_that_costs_it(self):
        match = self._match("2312345012500", PRICE_RULE)
        resolved = resolve_scale_quantity(match, self.kg_variant)
        self.assertEqual(resolved.quantity, Decimal("3.125"))
        self.assertEqual(resolved.label_total, Decimal("12.50"))
        self.assertEqual(resolved.rung_total, Decimal("12.50"))
        self.assertEqual(resolved.warning, "")

    def test_a_price_label_that_cannot_be_rung_exactly_says_so(self):
        self.kg_variant.unit_price = Decimal("300.00")
        self.kg_variant.save(update_fields=["unit_price"])
        match = self._match("2312345012500", PRICE_RULE)
        resolved = resolve_scale_quantity(match, self.kg_variant)
        self.assertEqual(resolved.quantity, Decimal("0.042"))
        self.assertEqual(resolved.rung_total, Decimal("12.60"))
        self.assertEqual(resolved.warning, sb.WARN_ROUNDING_DRIFT)
        self.assertEqual(resolved.drift, Decimal("0.10"))

    def test_a_price_label_never_divides_by_a_zero_price(self):
        self.kg_variant.unit_price = Decimal("0")
        self.kg_variant.save(update_fields=["unit_price"])
        match = self._match("2312345012500", PRICE_RULE)
        resolved = resolve_scale_quantity(match, self.kg_variant)
        self.assertEqual(resolved.quantity, Decimal("1"))
        self.assertEqual(resolved.warning, sb.WARN_NO_UNIT_PRICE)

    def test_a_count_label_rings_its_count(self):
        rule = sb.ScaleRule(
            pattern="24IIIIIVVVVVC",
            value_kind=sb.ValueKind.COUNT,
            value_decimals=0,
        )
        code = sb.build_code(rule, "12345", Decimal("6"))
        resolved = resolve_scale_quantity(sb.parse(code, [rule]), self.kg_variant)
        self.assertEqual(resolved.quantity, Decimal("6.000"))


class VariantResolutionTests(TestCase):
    def setUp(self):
        ScaleBarcodeRule.objects.update(is_active=False)
        self.rule = ScaleBarcodeRule.objects.create(
            name="Produce", pattern="21IIIIIVVVVVC", value_decimals=3
        )

    def test_resolves_a_product_stored_under_the_short_item_code(self):
        product = create_product_with_default_variant(
            name="Cucumber", sku="CUC", unit_price="3.00", barcode="12345"
        )
        match = scale_rules.parse("2112345015002")
        self.assertEqual(
            scale_rules.resolve_variant(match), product.default_variant
        )

    def test_resolves_a_product_stored_under_the_full_base_code(self):
        product = create_product_with_default_variant(
            name="Olives", sku="OLI", unit_price="9.00", barcode="2112345000008"
        )
        match = scale_rules.parse("2112345015002")
        self.assertEqual(
            scale_rules.resolve_variant(match), product.default_variant
        )

    def test_the_base_code_wins_over_the_bare_item_code(self):
        bare = create_product_with_default_variant(
            name="Bare", sku="BARE", unit_price="1.00", barcode="12345"
        )
        full = create_product_with_default_variant(
            name="Full", sku="FULL", unit_price="1.00", barcode="2112345000008"
        )
        match = scale_rules.parse("2112345015002")
        self.assertEqual(scale_rules.resolve_variant(match), full.default_variant)
        self.assertNotEqual(scale_rules.resolve_variant(match), bare.default_variant)

    def test_an_archived_product_does_not_answer_a_scan(self):
        product = create_product_with_default_variant(
            name="Gone", sku="GONE", unit_price="1.00", barcode="12345"
        )
        product.archived_at = "2026-01-01T00:00:00Z"
        product.save(update_fields=["archived_at"])
        match = scale_rules.parse("2112345015002")
        self.assertIsNone(scale_rules.resolve_variant(match))

    def test_an_unknown_item_code_resolves_to_nothing(self):
        code = sb.build_code(self.rule.as_rule(), "99999", Decimal("1.5"))
        match = scale_rules.parse(code)
        self.assertIsNotNone(match)
        self.assertIsNone(scale_rules.resolve_variant(match))

    def test_a_carton_barcode_is_never_a_weight(self):
        product = create_product_with_default_variant(
            name="Crisps", sku="CRISP", unit_price="1.00"
        )
        box = UnitOfMeasure.objects.get(code="box")
        unit = ProductUnit.objects.create(
            product=product, unit=box, factor_to_base=Decimal("12")
        )
        ProductUnitBarcode.objects.create(product_unit=unit, barcode="2112345015002")
        self.assertTrue(scale_rules.matches_unit_barcode("2112345015002"))
