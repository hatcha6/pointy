"""Search the way cashiers type: every word anywhere, folded, and forgiven.

The cases come from field telemetry (a grocery till, Sep 2026) and from the
shop's own catalogue: sizes glued to names, hamza nobody types, a code
half-remembered next to a word of the name, a category chip left on.
"""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.db import connection
from django.test import TestCase, override_settings
from django.test.utils import CaptureQueriesContext
from django.urls import reverse
from rest_framework import status
from rest_framework.request import Request
from rest_framework.test import APIClient, APIRequestFactory

from apps.core.roles import MANAGER_GROUP, ensure_role_groups
from apps.inventory.models import StockItem, Warehouse

from .models import Product, ProductAlias, ProductCategory
from .search_filters import CatalogRelevanceFilter
from .testing import create_product_with_default_variant

_counter = {"sku": 0}


def _product(name, *, sku=None, barcode="", variant_name="", stock=None, category=None):
    _counter["sku"] += 1
    product = create_product_with_default_variant(
        name=name,
        sku=sku or f"SKU-{_counter['sku']}",
        barcode=barcode,
        variant_name=variant_name,
        unit_price="1",
    )
    if stock is not None:
        StockItem.objects.create(
            variant=product.default_variant,
            warehouse=Warehouse.objects.get(pk=Warehouse.default_id()),
            quantity_on_hand=Decimal(stock),
        )
    if category is not None:
        product.categories.add(category)
    return product


def _ids(response):
    return [row["id"] for row in response.data["results"]]


def _postgres_only(test):
    def wrapper(self, *args, **kwargs):
        if connection.vendor != "postgresql":
            self.skipTest("trigram similarity is PostgreSQL's")
        return test(self, *args, **kwargs)

    wrapper.__name__ = test.__name__
    return wrapper


class _SearchTest(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.client = APIClient()
        self.user = get_user_model().objects.create_user(
            username="search-matching", password="pass"
        )
        self.user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client.force_authenticate(user=self.user)

    def _list(self, **params):
        params.setdefault("is_active", "true")
        response = self.client.get(reverse("product-list"), params)
        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        return response

    def _till(self, **params):
        """The product list the way the till asks for it."""
        params.setdefault("system", "sellable")
        params.setdefault("in_stock", "true")
        params.setdefault("ordering", "-popularity")
        return self._list(**params)

    def _variants(self, **params):
        response = self.client.get(reverse("product-variant-list"), params)
        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        return response


class EveryWordAnywhereTests(_SearchTest):
    def test_word_order_does_not_matter(self):
        rice = _product("أرز النجمة حبة قصيرة 1 كجم")

        self.assertEqual(_ids(self._list(search="النجمه ارز")), [rice.id])

    def test_hamza_and_taa_marbuta_fold_both_ways(self):
        # The field catalogue spells rice both ways, about half and half.
        with_hamza = _product("أرز النجمة")
        without = _product("ارز الوادي")

        for typed in ("ارز", "أرز"):
            with self.subTest(typed=typed):
                self.assertEqual(
                    sorted(_ids(self._list(search=typed))),
                    sorted([with_hamza.id, without.id]),
                )
        self.assertEqual(_ids(self._list(search="الوادى")), [without.id])

    def test_a_size_glued_to_the_name_is_still_two_words(self):
        ketchup = _product("كاتشب575")
        shampoo = _product("شامبو 400 مل")

        self.assertEqual(_ids(self._list(search="كاتشب 575")), [ketchup.id])
        self.assertEqual(_ids(self._list(search="شامبو400")), [shampoo.id])

    def test_a_name_word_and_part_of_the_barcode(self):
        nassim = _product("حليب النسيم", barcode="6241000045811")
        _product("حليب المراعي", barcode="6281007000000")

        self.assertEqual(_ids(self._list(search="حليب 6241000")), [nassim.id])
        self.assertEqual(_ids(self._list(search="6241000 حليب")), [nassim.id])

    def test_a_name_word_and_part_of_the_sku(self):
        pepsi = _product("بيبسي علبة", sku="PEP-0043")
        _product("بيبسي قارورة", sku="PEP-0099")

        self.assertEqual(_ids(self._list(search="0043 بيبسي")), [pepsi.id])
        self.assertEqual(_ids(self._list(search="بيبسي 0043")), [pepsi.id])

    def test_arabic_indic_digits_find_a_barcode(self):
        water = _product("مياه النبع", barcode="6241000910416")

        self.assertEqual(_ids(self._list(search="٦٢٤١٠٠٠٩١٠٤١٦")), [water.id])

    def test_every_word_has_to_match_something(self):
        _product("أرز النجمة")

        self.assertEqual(_ids(self._list(search="ارز صابون")), [])

    def test_words_may_come_from_the_product_and_its_variant(self):
        shirt = _product("قميص قطن", variant_name="أحمر")
        _product("قميص صوف", variant_name="أزرق")

        self.assertEqual(_ids(self._list(search="قميص احمر")), [shirt.id])

    def test_aliases_are_searched_folded(self):
        soda = _product("Soda can")
        ProductAlias.objects.create(product=soda, alias="مشروب غازي", normalized="مشروب غازي")

        self.assertEqual(_ids(self._list(search="غازى")), [soda.id])


class ArabicRankingTests(_SearchTest):
    def test_exact_then_prefix_then_word_start_then_inside_a_word(self):
        inside = _product("عصيربرتقال")
        word_start = _product("عصير البرتقال")
        prefix = _product("برتقال مصري")
        exact = _product("برتقال")

        self.assertEqual(
            _ids(self._list(search="برتقال")),
            [exact.id, prefix.id, word_start.id, inside.id],
        )

    def test_the_query_as_typed_beats_the_same_words_scattered(self):
        scattered = _product("نجمة أرز")
        together = _product("أرز النجمة")

        self.assertEqual(
            _ids(self._list(search="ارز النجمه")), [together.id, scattered.id]
        )

    def test_popularity_breaks_ties(self):
        quiet = _product("تونة طرابلس")
        busy = _product("تونة المتوسط")
        Product.objects.filter(pk=busy.pk).update(popularity=40)

        self.assertEqual(_ids(self._list(search="تونه")), [busy.id, quiet.id])


class NothingMatchedTests(_SearchTest):
    def test_a_well_typed_search_says_so(self):
        _product("عصير برتقال")

        outcome = self._list(search="عصير").data["search"]

        self.assertEqual(outcome["match"], "exact")
        self.assertIsNone(outcome["corrected_query"])
        self.assertFalse(outcome["category_fallback"])

    def test_arabic_typed_on_the_english_layout(self):
        milk = _product("الحليب الطازج")

        response = self._list(search="hgpgdf")

        self.assertEqual(_ids(response), [milk.id])
        self.assertEqual(response.data["search"]["match"], "layout")
        self.assertEqual(response.data["search"]["corrected_query"], "الحليب")

    def test_a_slip_onto_the_neighbouring_key(self):
        juice = _product("عصير برتقال")
        _product("عصا مكنسة")

        response = self._list(search="عصبر")

        self.assertEqual(_ids(response), [juice.id])
        self.assertEqual(response.data["search"]["match"], "corrected")
        self.assertEqual(response.data["search"]["corrected_query"], "عصير")

    def test_words_run_together(self):
        harissa = _product("هريسة منزلية")
        _product("هريسة حارة")

        response = self._list(search="هريسةمنز")

        self.assertEqual(_ids(response), [harissa.id])
        self.assertEqual(response.data["search"]["match"], "corrected")

    def test_a_loanword_spelled_another_way_is_an_ordinary_match(self):
        # «شكلاطة», «شكلاتة», «شوكولاتة» and «شوكولاطة» all sit in one field
        # catalogue; typing any of them has to find all of them, the spelling
        # as typed first.
        as_typed = _product("شوكولاطة ريجيل")
        other_spelling = _product("شكلاطة نوتيلا 750")
        _product("حليب نيدو")

        response = self._list(search="شوكولاطة")

        self.assertEqual(_ids(response), [as_typed.id, other_spelling.id])
        self.assertEqual(response.data["search"]["match"], "exact")

    @_postgres_only
    def test_a_short_word_misspelled_falls_back_to_near_misses(self):
        # Four letters is too short for the loanword key in the ordinary
        # search; the near-miss fallback still finds it.
        soap = _product("صابون ليلاس 160جم")
        _product("حليب نيدو")

        response = self._list(search="ليلس")

        self.assertEqual(_ids(response), [soap.id])
        self.assertIn(response.data["search"]["match"], ("corrected", "fuzzy"))

    @_postgres_only
    def test_the_hard_g_spelled_with_jeem(self):
        spaghetti = _product("مكرونة اسباقيتي أيدا")

        response = self._list(search="اسباجيتي")

        self.assertEqual(_ids(response), [spaghetti.id])

    def test_nothing_at_all(self):
        _product("عصير برتقال")

        response = self._list(search="zzzqqq")

        self.assertEqual(_ids(response), [])
        self.assertEqual(response.data["search"]["match"], "none")

    def test_the_fallbacks_stay_within_a_query_budget(self):
        for index in range(6):
            _product(f"صابون {index}")
        with CaptureQueriesContext(connection) as queries:
            self._list(search="زعترية")
        # Strict search, the layout/vocabulary/fuzzy attempts and recording
        # the miss — a fixed number, whatever the catalogue size.
        self.assertLessEqual(len(queries), 25, "\n".join(q["sql"] for q in queries))


class OutOfStockTests(_SearchTest):
    def test_matches_hidden_by_stock_are_counted_not_guessed_around(self):
        _product("حليب النسيم")  # nothing on hand
        _product("حليب المراعي", stock="5")

        response = self._till(search="النسيم")

        self.assertEqual(_ids(response), [])
        self.assertEqual(response.data["search"]["hidden_out_of_stock"], 1)
        self.assertEqual(response.data["search"]["match"], "none")

    def test_in_stock_matches_show_as_usual(self):
        almarai = _product("حليب المراعي", stock="5")

        response = self._till(search="المراعي")

        self.assertEqual(_ids(response), [almarai.id])
        self.assertEqual(response.data["search"]["hidden_out_of_stock"], 0)


class CategoryChipTests(_SearchTest):
    def setUp(self):
        super().setUp()
        self.bread = ProductCategory.objects.create(name="مخبوزات")
        self.drinks = ProductCategory.objects.create(name="مشروبات")
        self.pepsi = _product("بيبسي علبة", stock="9", category=self.drinks)
        self.bun = _product("خبز بيبسي؟", stock="9", category=self.bread)

    def test_the_till_leaves_the_chip_when_nothing_inside_it_matches(self):
        cola = _product("كوكا كولا", stock="9", category=self.drinks)

        response = self._till(search="كولا", category=self.bread.id)

        self.assertEqual(_ids(response), [cola.id])
        self.assertTrue(response.data["search"]["category_fallback"])

    def test_matches_inside_the_chip_come_alone(self):
        response = self._till(search="بيبسي", category=self.bread.id)

        self.assertEqual(_ids(response), [self.bun.id])
        self.assertFalse(response.data["search"]["category_fallback"])

    def test_the_back_office_catalogue_keeps_its_filter(self):
        response = self._list(search="بيبسي علبه", category=self.bread.id, system="all")

        self.assertEqual(_ids(response), [])

    def test_a_client_can_opt_out(self):
        response = self._till(
            search="بيبسي علبه", category=self.bread.id, category_fallback="0"
        )

        self.assertEqual(_ids(response), [])


class ScannedCodeTests(_SearchTest):
    def test_a_code_scanned_on_the_arabic_layout(self):
        widget = _product("Widget", sku="W-1", barcode="AB123")

        self.assertEqual(_ids(self._list(barcode="شلا123")), [widget.id])
        rows = self._variants(barcode="شلا123").data["results"]
        self.assertEqual([row["sku"] for row in rows], ["W-1"])

    def test_arabic_indic_digits_in_a_typed_barcode(self):
        water = _product("مياه", barcode="6241000910416")

        self.assertEqual(_ids(self._list(barcode="٦٢٤١٠٠٠٩١٠٤١٦")), [water.id])

    def test_a_code_typed_on_the_arabic_layout_into_search(self):
        widget = _product("Widget", sku="ZX-9", barcode="QW5566")

        response = self._list(search="ضص5566")

        self.assertEqual(_ids(response), [widget.id])


class VariantSearchTests(_SearchTest):
    def test_every_word_anywhere(self):
        _product("أرز النجمة", sku="RICE-7")

        rows = self._variants(search="النجمه ارز").data["results"]

        self.assertEqual([row["sku"] for row in rows], ["RICE-7"])

    def test_the_outcome_rides_along(self):
        _product("عصير برتقال", sku="JUICE-1")

        response = self._variants(search="عصبر")

        self.assertEqual([row["sku"] for row in response.data["results"]], ["JUICE-1"])
        self.assertEqual(response.data["search"]["match"], "corrected")


class SearchPlanShapeTests(_SearchTest):
    """Ranking by correlated EXISTS once cost ~700 ms of JIT per search; the
    search must reach variants, aliases and codes by membership only."""

    def test_no_correlated_exists_anywhere_in_the_search(self):
        _product("أرز النجمة", sku="1004")
        for params in ({"search": "ارز"}, {"search": "1004"}, {"search": "ارز 1004"}):
            with self.subTest(params=params):
                request = Request(APIRequestFactory().get("/", params))
                queryset = CatalogRelevanceFilter().filter_queryset(
                    request, Product.objects.all(), view=None
                )
                self.assertNotIn("EXISTS", str(queryset.query).upper())


@override_settings(
    POINTY_CATALOG_CACHE_ENABLED=True,
    CACHES={"default": {"BACKEND": "django.core.cache.backends.locmem.LocMemCache"}},
)
class AliasInvalidatesCachedSearchesTests(TestCase):
    def test_a_new_alias_moves_the_catalog_version(self):
        from .cache import catalog_version

        product = _product("Soda")
        before = catalog_version()

        ProductAlias.objects.create(product=product, alias="صودا", normalized="صودا")

        self.assertGreater(catalog_version(), before)
