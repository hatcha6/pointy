"""The GS1 parser, against the strings real packs actually carry.

Every test here is named after what goes wrong without it. The two that matter
most are the ones about separators: fixed-length AIs carry none, and a scanner
configured to strip ``GS`` turns a lot number and an expiry into one unreadable
run — which a parser that splits on a character imports as a lot number with a
date glued to its tail, silently, forever.
"""

from datetime import date

from django.test import SimpleTestCase

from apps.catalog import gs1

# A serialised pharmaceutical pack: GTIN, expiry, lot, serial. The lot and the
# serial are variable-length, so each ends at a GS.
FULL = "01034531200000111709113010ABC123" + gs1.GS + "2112345"
# The same pack from a market with no track-and-trace mandate: lot and expiry
# only, which is the majority of what a Libyan pharmacy stocks.
LOT_ONLY = "010345312000001117091130" + gs1.GS + "10ABC123"


class ParsingTests(SimpleTestCase):
    def test_a_fixed_length_ai_needs_no_separator(self):
        """``01`` is followed by exactly fourteen digits and then, immediately,
        the next AI. A parser that split on anything would destroy this."""
        scan = gs1.parse("0103453120000011" + "17091130")
        self.assertEqual(scan.gtin, "03453120000011")
        self.assertEqual(scan.expiry_date, date(2009, 11, 30))

    def test_a_full_serialised_pack_reads_all_four_facts(self):
        scan = gs1.parse(FULL)
        self.assertEqual(scan.gtin, "03453120000011")
        self.assertEqual(scan.lot, "ABC123")
        self.assertEqual(scan.serial, "12345")
        self.assertEqual(scan.expiry_date, date(2009, 11, 30))
        self.assertEqual(scan.warnings, ())

    def test_a_lot_and_expiry_pack_reads_without_a_serial(self):
        scan = gs1.parse(LOT_ONLY)
        self.assertEqual(scan.lot, "ABC123")
        self.assertEqual(scan.serial, "")
        self.assertTrue(scan.is_usable)

    def test_a_symbology_prefix_is_stripped_not_refused(self):
        """A symbol is still the symbol whichever wrapper the reader put on it."""
        scan = gs1.parse("]d2" + FULL)
        self.assertEqual(scan.gtin, "03453120000011")

    def test_a_stripped_group_separator_is_reported_not_imported(self):
        """The failure this parser exists to catch.

        A reader that swallows ``GS`` hands over ``ABC1232112345`` as the lot.
        Importing that would record a lot nobody can ever match again.
        """
        scan = gs1.parse("010345312000001117091130" + "10" + "A" * 30)
        codes = [warning.code for warning in scan.warnings]
        self.assertIn("missing_group_separator", codes)
        message = next(
            warning.message
            for warning in scan.warnings
            if warning.code == "missing_group_separator"
        )
        self.assertIn("أعد ضبط القارئ", message)

    def test_a_last_variable_value_without_a_separator_is_fine(self):
        """Ending the string *is* a terminator. Only an over-long run is
        suspicious."""
        scan = gs1.parse("010345312000001110ABC123")
        self.assertEqual(scan.lot, "ABC123")
        self.assertEqual(scan.warnings, ())

    def test_day_zero_means_the_end_of_that_month(self):
        """A pack that expires in a month rather than on a day. Reading this as
        invalid would refuse a perfectly ordinary box."""
        scan = gs1.parse("0103453120000011" + "17251200")
        self.assertEqual(scan.expiry_date, date(2025, 12, 31))

    def test_the_century_follows_gs1s_own_sliding_window(self):
        """Anchored on the current year, not on a fixed 49/50 cut.

        The cut was right for one year and drifted afterwards: in 2026 it read a
        pack marked ``50`` as 1950 — expired before the shop existed — where
        GS1 says 2050. The rule is that 0 to 50 years ahead is the future and
        51 to 99 ahead is the past, so it is pinned here against three
        different "today"s rather than against whichever one happens to be.
        """
        self.assertEqual(
            gs1._century_of(50, today=date(2026, 6, 1)), 2050
        )
        self.assertEqual(
            gs1._century_of(76, today=date(2026, 6, 1)), 2076
        )
        # 51 years ahead flips to the previous century.
        self.assertEqual(
            gs1._century_of(77, today=date(2026, 6, 1)), 1977
        )
        self.assertEqual(
            gs1._century_of(99, today=date(2026, 6, 1)), 1999
        )
        # And it keeps working once the century turns.
        self.assertEqual(gs1._century_of(0, today=date(2050, 6, 1)), 2100)
        self.assertEqual(gs1._century_of(50, today=date(1999, 6, 1)), 1950)

    def test_a_three_digit_ai_is_read_before_the_two_digit_one(self):
        """``240`` before ``24``, or everything after it shifts by a digit."""
        scan = gs1.parse("0103453120000011240XYZ")
        self.assertEqual(scan.elements.get("240"), "XYZ")
        self.assertEqual(scan.gtin, "03453120000011")

    def test_a_bad_gtin_is_a_warning_and_the_rest_still_reads(self):
        scan = gs1.parse("01ABCDEFGHIJKLMN10LOT1")
        self.assertIn("bad_gtin", [warning.code for warning in scan.warnings])
        self.assertEqual(scan.lot, "LOT1")


class DetectionTests(SimpleTestCase):
    """Refusing to see a GS1 symbol in a plain barcode is half the job.

    The cost of a false positive is a supermarket's own EAN being read as an
    element string, which is a scan that stops working for a shop that never
    asked for any of this.
    """

    def test_a_plain_ean13_is_not_a_gs1_string(self):
        self.assertFalse(gs1.looks_like_gs1("6221031492015"))
        self.assertFalse(gs1.looks_like_gs1("012345678905"))

    def test_a_real_element_string_is(self):
        self.assertTrue(gs1.looks_like_gs1(FULL))
        self.assertTrue(gs1.looks_like_gs1("]d2" + FULL))
        self.assertTrue(gs1.looks_like_gs1("0103453120000011"))

    def test_a_short_code_starting_with_01_is_not(self):
        self.assertFalse(gs1.looks_like_gs1("0123456789"))

    def test_blank_is_not(self):
        self.assertFalse(gs1.looks_like_gs1(""))
        self.assertFalse(gs1.looks_like_gs1(None))


class GtinCandidateTests(SimpleTestCase):
    """A shop types the number printed under the barcode, not the padded GTIN-14.

    Matching only the 14-digit form would mean every pharmacy had to re-key its
    catalog before a single DataMatrix worked.
    """

    def test_a_padded_gtin14_also_matches_its_ean13(self):
        candidates = gs1.gtin_candidates("06221031492015")
        self.assertIn("06221031492015", candidates)
        self.assertIn("6221031492015", candidates)

    def test_leading_zeros_produce_the_upc_form(self):
        candidates = gs1.gtin_candidates("00012345678905")
        self.assertIn("012345678905", candidates)

    def test_nothing_in_nothing_out(self):
        self.assertEqual(gs1.gtin_candidates(""), [])
