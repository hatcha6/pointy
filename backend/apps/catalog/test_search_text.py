"""The folding rules search reads text with, and the SQL copy of them.

``search_text`` (Python) and the functions migration 0034 creates (SQL) must
agree byte for byte: the database stores names folded by one and the query is
folded by the other. The parity tests run the same strings through both.
"""

from django.db import connection
from django.test import SimpleTestCase, TestCase

from . import search_text
from .models import Product
from .testing import create_product_with_default_variant

# Strings that exercise every rule — and the shapes the field catalogue
# actually has (sizes glued to names, doubled spaces, both digit sets).
PARITY_CORPUS = [
    "كاتشب575",
    "أرز النجمة ٣٣٠مل",
    "4.75لتر",
    "1/4",
    "Kellogg's كورن",
    "شكلاطة  دحية",
    "ﻻ",
    "نسكافيه نستلا 3*1",
    "a1b2",
    "12ab34",
    "5.5كجم",
    "د.ل",
    "«بيبسي»",
    "‏بيبسي‎",
    "ـــبيبسي",
    "قَهْوَة",
    "۱۲۳",
    "x-ray 1004-RED",
    "ٱلرحمن",
    "ؤ ئ ة ى ک ی",
    "  multiple   spaces  ",
    "كوكا-كولا",
    "٫5",
    "1,000.50",
    "..",
    "/x/",
    "الالبان",
    "بالفراولة",
    "مايونيز",
    "شوكولاطة",
    "+218 91-234 5678",
    "مناديل معطرة فرش بيبي 120",
    "بوطاس جودي جافيل 4.75لتر",
    "ڤيمتو",
    "Kellogg\u00b4s",
    "Kellogg\u2019s",
]


class FoldTests(SimpleTestCase):
    def test_letter_variants_fold_to_one_form(self):
        self.assertEqual(search_text.fold("أرز"), search_text.fold("ارز"))
        self.assertEqual(search_text.fold("إسباني"), "اسباني")
        self.assertEqual(search_text.fold("مكرونة"), search_text.fold("مكرونه"))
        self.assertEqual(search_text.fold("بيبسى"), search_text.fold("بيبسي"))

    def test_marks_tatweel_and_direction_controls_vanish(self):
        self.assertEqual(search_text.fold("قَهْوَة"), "قهوه")
        self.assertEqual(search_text.fold("بيـــبسي"), "بيبسي")
        self.assertEqual(search_text.fold("‏بيبسي‎"), "بيبسي")

    def test_numbers_split_from_the_words_they_are_glued_to(self):
        self.assertEqual(search_text.fold("كاتشب575"), "كاتشب 575")
        self.assertEqual(search_text.fold("4.75لتر"), "4.75 لتر")
        self.assertEqual(search_text.fold("250ml"), "250 ml")

    def test_numbers_keep_their_own_punctuation(self):
        self.assertEqual(search_text.fold("1/4"), "1/4")
        self.assertEqual(search_text.fold("1,000.50"), "1,000.50")
        self.assertEqual(search_text.fold("كوكا-كولا"), "كوكا كولا")

    def test_both_arabic_digit_sets_become_ascii(self):
        self.assertEqual(search_text.fold("٣٣٠"), "330")
        self.assertEqual(search_text.fold("۳۳۰"), "330")

    def test_presentation_forms_and_ligatures_become_letters(self):
        self.assertEqual(search_text.fold("ﻻ"), "لا")

    def test_every_kind_of_apostrophe_joins_the_word(self):
        for written in ("Kellogg's", "Kellogg\u2019s", "Kellogg\u00b4s", "Kellogg`s"):
            with self.subTest(written=written):
                self.assertEqual(search_text.fold(written), "kelloggs")

    def test_tokens_are_the_words_in_order_without_repeats(self):
        self.assertEqual(search_text.tokens("أرز  النجمة أرز"), ["ارز", "النجمه"])


class SkeletonTests(SimpleTestCase):
    def test_loanword_spellings_share_a_key(self):
        pairs = [
            ("شوكولاطة", "شكلاطة"),
            ("اسباجيتي", "اسباقيتي"),
            ("كاتشاب", "كاتشب"),
            ("مايونيز", "ميونيز"),
            ("بسكوت", "بسكويت"),
            ("نسكافيه", "نسكافي"),
        ]
        for first, second in pairs:
            with self.subTest(first=first, second=second):
                self.assertEqual(
                    search_text.skeleton(first), search_text.skeleton(second)
                )

    def test_different_words_keep_different_keys(self):
        self.assertNotEqual(search_text.skeleton("موز"), search_text.skeleton("منزلية"))


class KeyboardLayoutTests(SimpleTestCase):
    def test_arabic_typed_on_the_english_layout(self):
        self.assertEqual(search_text.latin_to_arabic_layout("hgpgdf"), "الحليب")

    def test_a_code_scanned_on_the_arabic_layout(self):
        # «لا» is ONE key (b), not «ل» then «ا».
        self.assertEqual(search_text.arabic_to_latin_layout("شلا123"), "ab123")
        self.assertEqual(search_text.arabic_to_latin_layout("لأ"), "G")


class PhoneKeyTests(SimpleTestCase):
    def test_every_way_of_writing_a_libyan_number_gives_one_key(self):
        for written in (
            "+218 91-234 5678",
            "00218912345678",
            "0912345678",
            "912345678",
            "٠٩١٢٣٤٥٦٧٨",
        ):
            with self.subTest(written=written):
                self.assertEqual(search_text.phone_key(written), "912345678")

    def test_what_looks_like_a_phone_number(self):
        self.assertTrue(search_text.looks_like_phone("091 234 5678"))
        self.assertFalse(search_text.looks_like_phone("حليب 0912"))
        self.assertFalse(search_text.looks_like_phone("1234"))


class SqlParityTests(TestCase):
    """The SQL functions give exactly what the Python ones give."""

    def setUp(self):
        if connection.vendor != "postgresql":
            self.skipTest("the SQL functions are PostgreSQL's")

    def _sql(self, function, value):
        with connection.cursor() as cursor:
            cursor.execute(f"SELECT {function}(%s)", [value])
            return cursor.fetchone()[0]

    def test_fold_matches_python(self):
        for value in PARITY_CORPUS:
            with self.subTest(value=value):
                self.assertEqual(
                    self._sql("pointy_search_fold", value), search_text.fold(value)
                )

    def test_skeleton_matches_python(self):
        for value in PARITY_CORPUS:
            with self.subTest(value=value):
                self.assertEqual(
                    self._sql("pointy_search_skeleton", value),
                    search_text.skeleton(value),
                )

    def test_phone_key_matches_python(self):
        for value in ("+218 91-234 5678", "00218912345678", "٠٩١٢٣٤٥٦٧٨", "x"):
            with self.subTest(value=value):
                self.assertEqual(
                    self._sql("pointy_phone_key", value), search_text.phone_key(value)
                )

    def test_generated_columns_hold_the_folded_name(self):
        product = create_product_with_default_variant(
            name="أرز النجمة ٣٣٠مل", sku="RICE-1", unit_price="1"
        )
        stored = Product.objects.values_list("search_name", "search_skeleton").get(
            pk=product.pk
        )
        self.assertEqual(
            stored,
            (
                search_text.fold(product.name),
                search_text.skeleton(product.name),
            ),
        )

    def test_generated_columns_follow_a_bulk_update(self):
        product = create_product_with_default_variant(
            name="Old", sku="BULK-1", unit_price="1"
        )
        Product.objects.filter(pk=product.pk).update(name="شكلاطة دحية")
        self.assertEqual(
            Product.objects.values_list("search_name", flat=True).get(pk=product.pk),
            "شكلاطه دحيه",
        )
