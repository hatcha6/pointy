"""The pure money layer: no database, no Django models.

These tests exist to pin the two decisions the rest of the feature is built on —
that money refuses to mix currencies, and that a conversion rounds once, half-up,
to the target currency's precision.
"""

from decimal import Decimal

from django.test import SimpleTestCase

from apps.fx.money import (
    MAX_SUPPORTED_DECIMALS,
    CurrencyError,
    CurrencyMismatch,
    CurrencySpec,
    InvalidRate,
    Money,
    convert,
    invert_rate,
    normalize_code,
    quantize_amount,
    quantize_rate,
)


class NormalizationTests(SimpleTestCase):
    def test_codes_are_upper_cased_and_stripped(self):
        self.assertEqual(normalize_code("  usd "), "USD")
        self.assertEqual(normalize_code("Lyd"), "LYD")

    def test_blank_code_normalizes_to_empty(self):
        self.assertEqual(normalize_code(None), "")
        self.assertEqual(normalize_code("   "), "")

    def test_money_requires_a_currency(self):
        with self.assertRaises(CurrencyError):
            Money("1.00", "")

    def test_money_normalizes_its_currency(self):
        self.assertEqual(Money("1.00", " usd ").currency, "USD")

    def test_money_accepts_string_and_float_amounts(self):
        self.assertEqual(Money("1.10", "USD").amount, Decimal("1.10"))
        # Floats go through str() so 0.1 does not arrive as 0.1000000000000000055.
        self.assertEqual(Money(0.1, "USD").amount, Decimal("0.1"))

    def test_money_rejects_nonsense_amounts(self):
        with self.assertRaises(CurrencyError):
            Money("not-a-number", "USD")


class ArithmeticTests(SimpleTestCase):
    def test_addition_within_one_currency(self):
        total = Money("10.00", "USD") + Money("2.50", "USD")
        self.assertEqual(total, Money("12.50", "USD"))

    def test_subtraction_within_one_currency(self):
        self.assertEqual(
            Money("10.00", "LYD") - Money("2.50", "LYD"), Money("7.50", "LYD")
        )

    def test_mixing_currencies_raises_rather_than_coercing(self):
        with self.assertRaises(CurrencyMismatch):
            Money("12.00", "USD") + Money("82.20", "LYD")

    def test_comparison_across_currencies_also_raises(self):
        with self.assertRaises(CurrencyMismatch):
            Money("12.00", "USD") < Money("82.20", "LYD")

    def test_scaling_by_a_quantity(self):
        self.assertEqual(Money("3.00", "USD") * 4, Money("12.00", "USD"))
        self.assertEqual(4 * Money("3.00", "USD"), Money("12.00", "USD"))

    def test_money_times_money_is_meaningless_and_refused(self):
        with self.assertRaises(CurrencyError):
            Money("3.00", "USD") * Money("2.00", "USD")

    def test_negation_and_absolute(self):
        self.assertEqual(-Money("3.00", "USD"), Money("-3.00", "USD"))
        self.assertEqual(abs(Money("-3.00", "USD")), Money("3.00", "USD"))

    def test_zero_helper(self):
        zero = Money.zero("LYD")
        self.assertTrue(zero.is_zero)
        self.assertEqual(zero.currency, "LYD")

    def test_adding_a_non_money_raises(self):
        with self.assertRaises(CurrencyError):
            Money("1.00", "USD") + 1


class RoundingTests(SimpleTestCase):
    def test_pricing_regime_is_half_up_not_half_even(self):
        # The distinction that matters: banker's rounding would give 0.02 here.
        self.assertEqual(quantize_amount("0.025", 2), Decimal("0.03"))
        self.assertEqual(quantize_amount("0.035", 2), Decimal("0.04"))

    def test_zero_decimal_currency(self):
        self.assertEqual(quantize_amount("10.5", 0), Decimal("11"))

    def test_precision_wider_than_the_schema_is_refused(self):
        with self.assertRaises(CurrencyError):
            quantize_amount("1.2345", MAX_SUPPORTED_DECIMALS + 1)

    def test_negative_precision_is_refused(self):
        with self.assertRaises(CurrencyError):
            quantize_amount("1.23", -1)

    def test_rate_quantizes_to_eight_places(self):
        self.assertEqual(quantize_rate("6.851234567891"), Decimal("6.85123457"))

    def test_rates_must_be_positive_and_finite(self):
        for bad in ("0", "-1", "NaN", "Infinity"):
            with self.assertRaises(InvalidRate, msg=bad):
                quantize_rate(bad)


class ConversionTests(SimpleTestCase):
    def test_the_worked_example_from_the_plan(self):
        result = convert(Money("12.00", "USD"), to_code="LYD", rate="6.85")
        self.assertEqual(result, Money("82.20", "LYD"))

    def test_rounds_once_at_the_end_not_per_step(self):
        # 3 x 0.335 = 1.005 -> 1.01. Rounding each 0.335 to 0.34 first would
        # give 1.02, which is the per-line drift this rule exists to prevent.
        scaled = Money("0.335", "USD") * 3
        self.assertEqual(
            convert(scaled, to_code="LYD", rate="1"), Money("1.01", "LYD")
        )

    def test_target_precision_is_honoured(self):
        self.assertEqual(
            convert(Money("12.00", "USD"), to_code="JPY", rate="150.7", decimals=0),
            Money("1808", "JPY"),
        )

    def test_same_currency_at_rate_one_is_a_no_op(self):
        self.assertEqual(
            convert(Money("12.00", "USD"), to_code="USD", rate=1),
            Money("12.00", "USD"),
        )

    def test_same_currency_at_any_other_rate_is_a_caller_bug(self):
        with self.assertRaises(InvalidRate):
            convert(Money("12.00", "USD"), to_code="USD", rate="6.85")

    def test_conversion_refuses_a_non_positive_rate(self):
        with self.assertRaises(InvalidRate):
            convert(Money("12.00", "USD"), to_code="LYD", rate="0")

    def test_conversion_requires_a_target(self):
        with self.assertRaises(CurrencyError):
            convert(Money("12.00", "USD"), to_code="  ", rate="6.85")

    def test_conversion_requires_money(self):
        with self.assertRaises(CurrencyError):
            convert(Decimal("12.00"), to_code="LYD", rate="6.85")


class InversionTests(SimpleTestCase):
    def test_inverse_of_a_rate(self):
        self.assertEqual(invert_rate("4"), Decimal("0.25"))

    def test_inverted_rate_is_not_the_exact_reciprocal(self):
        # 1/6.85 does not terminate, so the stored 8dp inverse cannot multiply
        # back to exactly 1. This is the reason a document freezes the rate it
        # used instead of re-deriving one on the way back.
        inverse = invert_rate("6.85")
        self.assertNotEqual(inverse * Decimal("6.85"), Decimal("1"))

    def test_round_trip_stays_within_one_cent(self):
        # The loss above is far below the cent, so a round trip is safe to show
        # a user even though it is not safe to re-derive a stored figure from.
        for amount in ("12.00", "0.05", "1999.99", "7.77"):
            forward = convert(Money(amount, "USD"), to_code="LYD", rate="6.85")
            back = convert(forward, to_code="USD", rate=invert_rate("6.85"))
            self.assertLessEqual(
                abs(back.amount - Decimal(amount)), Decimal("0.01"), msg=amount
            )


class CurrencySpecTests(SimpleTestCase):
    def test_symbol_falls_back_across_languages_then_to_the_code(self):
        spec = CurrencySpec(code="LYD", symbol_ar="د.ل", symbol_en="LYD")
        self.assertEqual(spec.symbol("ar"), "د.ل")
        self.assertEqual(spec.symbol("en"), "LYD")
        bare = CurrencySpec(code="XAF")
        self.assertEqual(bare.symbol("ar"), "XAF")

    def test_money_helper_rounds_to_the_spec(self):
        spec = CurrencySpec(code="LYD", decimals=2)
        self.assertEqual(spec.money("1.005"), Money("1.01", "LYD"))

    def test_spec_rejects_precision_the_schema_cannot_hold(self):
        with self.assertRaises(CurrencyError):
            CurrencySpec(code="KWD", decimals=3)
