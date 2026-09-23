"""Product search relevance, supplier soft-boost and the query-count budget.

Covers the behaviour of :class:`apps.catalog.search_filters.CatalogRelevanceFilter`
end to end through the product-list API.
"""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.db import connection
from django.test import TestCase, override_settings
from django.test.utils import CaptureQueriesContext
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient

from apps.core.roles import MANAGER_GROUP, ensure_role_groups

from .testing import create_product_with_default_variant


def _result_ids(response):
    return [row["id"] for row in response.data["results"]]


class _AuthedCatalogTest(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.client = APIClient()
        self.user = get_user_model().objects.create_user(
            username="search-user",
            password="pass",
        )
        self.user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client.force_authenticate(user=self.user)

    def _list(self, **params):
        params.setdefault("is_active", "true")
        return self.client.get(reverse("product-list"), params)


class ProductSearchRelevanceTests(_AuthedCatalogTest):
    def test_numeric_query_ranks_code_over_name(self):
        # The bug report: "1004" used to surface anything with 1004 in the *name*.
        by_name = create_product_with_default_variant(
            name="Widget 1004", sku="WIDGET", unit_price="1"
        )
        by_code = create_product_with_default_variant(
            name="Gadget", sku="1004", unit_price="1"
        )

        response = self._list(search="1004")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        # The exact code hit ranks above the incidental name substring.
        self.assertEqual(_result_ids(response), [by_code.id, by_name.id])

    def test_numeric_query_prefers_prefix_over_midstring(self):
        prefix = create_product_with_default_variant(
            name="Cable red", sku="1004-RED", unit_price="1"
        )
        midstring = create_product_with_default_variant(
            name="Cable blue", sku="X1004", unit_price="1"
        )

        response = self._list(search="1004")

        self.assertEqual(_result_ids(response), [prefix.id, midstring.id])

    def test_numeric_query_matches_unit_barcode(self):
        # A carton (unit) barcode resolves just like a variant code.
        from .models import ProductUnit, ProductUnitBarcode, UnitOfMeasure

        product = create_product_with_default_variant(
            name="Eggs tray", sku="EGG", unit_price="1"
        )
        carton = UnitOfMeasure.objects.create(code="carton-egg", name="Carton")
        unit = ProductUnit.objects.create(
            product=product, unit=carton, factor_to_base=Decimal("30")
        )
        ProductUnitBarcode.objects.create(product_unit=unit, barcode="9990001")

        response = self._list(search="9990001")

        self.assertEqual(_result_ids(response), [product.id])

    def test_text_query_ranks_exact_then_prefix_then_contains(self):
        contains = create_product_with_default_variant(
            name="Best Coffee", sku="C3", unit_price="1"
        )
        prefix = create_product_with_default_variant(
            name="Coffee Beans", sku="C2", unit_price="1"
        )
        exact = create_product_with_default_variant(
            name="Coffee", sku="C1", unit_price="1"
        )

        response = self._list(search="coffee")

        self.assertEqual(_result_ids(response), [exact.id, prefix.id, contains.id])

    def test_text_query_ignores_harakat(self):
        # Product name is "قهوة"; the query is the same word with a fatha on the
        # first letter — the normalizer strips the mark so it still matches.
        coffee = create_product_with_default_variant(
            name="قهوة", sku="QAH", unit_price="1"
        )

        response = self._list(search="قَهوة")

        self.assertEqual(_result_ids(response), [coffee.id])

    def test_text_query_excludes_non_matches(self):
        create_product_with_default_variant(name="Tea", sku="T1", unit_price="1")
        coffee = create_product_with_default_variant(
            name="Coffee", sku="C1", unit_price="1"
        )

        response = self._list(search="coffee")

        self.assertEqual(_result_ids(response), [coffee.id])

    def test_relevance_tiebroken_by_popularity(self):
        # Two equally-relevant "contains" matches — the more-bought one leads.
        quiet = create_product_with_default_variant(
            name="Coffee quiet", sku="CQ", unit_price="1"
        )
        popular = create_product_with_default_variant(
            name="Coffee popular", sku="CP", unit_price="1"
        )
        popular.popularity = 50
        popular.save(update_fields=["popularity"])

        response = self._list(search="coffee")

        self.assertEqual(_result_ids(response), [popular.id, quiet.id])

    def test_barcode_exact_path_unchanged(self):
        create_product_with_default_variant(
            name="Alpha", sku="A1", barcode="6210000000017", unit_price="1"
        )
        create_product_with_default_variant(
            name="Beta", sku="B1", barcode="6210000000024", unit_price="1"
        )

        response = self._list(barcode="6210000000017")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        skus = {row["default_variant"]["sku"] for row in response.data["results"]}
        self.assertEqual(skus, {"A1"})


class ProductBrowseOrderingTests(_AuthedCatalogTest):
    def test_default_browse_is_most_bought(self):
        low = create_product_with_default_variant(name="Zeta", sku="Z", unit_price="1")
        high = create_product_with_default_variant(name="Alpha", sku="A", unit_price="1")
        low.popularity = 1
        low.save(update_fields=["popularity"])
        high.popularity = 99
        high.save(update_fields=["popularity"])

        # No ordering param -> server default is most-bought first.
        response = self._list()

        self.assertEqual(_result_ids(response), [high.id, low.id])

    def test_name_ordering_is_stable(self):
        first = create_product_with_default_variant(name="Same", sku="S1", unit_price="1")
        second = create_product_with_default_variant(name="Same", sku="S2", unit_price="1")

        response = self._list(ordering="name")

        # Duplicate names must fall back to a stable id key (no skipped/repeated rows).
        self.assertEqual(_result_ids(response), [first.id, second.id])


class ProductSupplierBoostTests(_AuthedCatalogTest):
    def setUp(self):
        super().setUp()
        from apps.purchasing.models import PurchaseLine, PurchaseOrder, Supplier

        self.supplier = Supplier.objects.create(name="Acme")
        # Both match "coffee", and p2 ("Coffee") is the BETTER text match (exact)
        # AND sorts first by name — so relevance or a name sort alone would list p2
        # first. The supplier boost must override both and float p1 (Acme's) up.
        self.p2 = create_product_with_default_variant(
            name="Coffee", sku="OTHER-1", unit_price="1"
        )
        self.p1 = create_product_with_default_variant(
            name="Coffee deluxe", sku="SUP-1", unit_price="1"
        )
        order = PurchaseOrder.objects.create(supplier=self.supplier)
        PurchaseLine.objects.create(
            purchase_order=order,
            variant=self.p1.default_variant,
            quantity=Decimal("1"),
            unit_cost=Decimal("1.00"),
        )

    def test_preferred_supplier_floats_without_filtering(self):
        response = self._list(
            preferred_supplier=str(self.supplier.id), ordering="name"
        )

        ids = _result_ids(response)
        self.assertEqual(ids[0], self.p1.id)
        # Soft boost: the other product is still present, not filtered out.
        self.assertIn(self.p2.id, ids)

    def test_preferred_supplier_leads_search_relevance(self):
        # p2 ("Coffee") is the exact match, but the supplier's product leads anyway.
        response = self._list(
            search="coffee", preferred_supplier=str(self.supplier.id)
        )

        ids = _result_ids(response)
        self.assertEqual(ids[0], self.p1.id)
        self.assertIn(self.p2.id, ids)

    def test_hard_supplier_filter_still_restricts(self):
        # The existing ?supplier= hard filter is untouched by the new boost param.
        response = self._list(supplier=str(self.supplier.id))

        self.assertEqual(_result_ids(response), [self.p1.id])

    def test_cancelled_po_does_not_boost(self):
        from apps.purchasing.models import PurchaseLine, PurchaseOrder, Supplier

        supplier2 = Supplier.objects.create(name="Beta supplier")
        zeta = create_product_with_default_variant(
            name="Zeta", sku="ZZZ", unit_price="1"
        )
        cancelled = PurchaseOrder.objects.create(
            supplier=supplier2, status=PurchaseOrder.Status.CANCELLED
        )
        PurchaseLine.objects.create(
            purchase_order=cancelled,
            variant=zeta.default_variant,
            quantity=Decimal("1"),
            unit_cost=Decimal("1.00"),
        )

        response = self._list(
            preferred_supplier=str(supplier2.id), ordering="name"
        )

        ids = _result_ids(response)
        # "Zeta" would lead if the cancelled PO wrongly boosted it; it must sort last.
        self.assertEqual(ids[-1], zeta.id)


@override_settings(
    CACHES={"default": {"BACKEND": "django.core.cache.backends.locmem.LocMemCache"}}
)
class ProductListQueryBudgetTests(_AuthedCatalogTest):
    """The product list is the single most-hit endpoint; it must stay fast.

    The guarantee that actually matters for cashiers is that the query count does
    NOT grow with the catalog size (no N+1) — a shop with 10k products must issue
    the same handful of queries as one with 10. The absolute ceiling is a cold-cache
    number (``active_product_ids`` and content types are cached in real use, so the
    steady-state count is lower); it only guards against a gross regression.
    """

    QUERY_CEILING = 20

    def _seed(self, count, supplier=None):
        from .models import Product

        start = Product.objects.count()  # unique SKUs across repeated calls
        for index in range(start, start + count):
            product = create_product_with_default_variant(
                name=f"Coffee {index}", sku=f"COF-{index}", unit_price="1"
            )
            product.popularity = index
            product.save(update_fields=["popularity"])
            if supplier is not None and index == start:
                from apps.purchasing.models import PurchaseLine, PurchaseOrder

                order = PurchaseOrder.objects.create(supplier=supplier)
                PurchaseLine.objects.create(
                    purchase_order=order,
                    variant=product.default_variant,
                    quantity=Decimal("1"),
                    unit_cost=Decimal("1.00"),
                )

    def _measure(self, **params):
        # Clear the active-product-id / catalog caches so both measurements are
        # cold and comparable (direct ORM creates don't invalidate them).
        from django.core.cache import cache

        cache.clear()
        with CaptureQueriesContext(connection) as ctx:
            response = self._list(**params)
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        return ctx

    def test_query_count_does_not_grow_with_catalog_size(self):
        # A handful of matching products...
        self._seed(3)
        few = len(self._measure(search="coffee"))
        # ...then 10x more (still one page) must NOT cost more queries. (It may cost
        # slightly fewer as process-level caches like ContentType warm up — the point
        # is that the count never grows with catalog size, i.e. there is no N+1.)
        self._seed(30)
        many = len(self._measure(search="coffee"))
        self.assertLessEqual(
            many,
            few,
            msg=f"product search N+1s on catalog size: {few} -> {many} queries",
        )

    def test_search_with_boost_stays_within_budget(self):
        from apps.purchasing.models import Supplier

        supplier = Supplier.objects.create(name="Acme")
        self._seed(5, supplier=supplier)

        ctx = self._measure(
            search="coffee",
            preferred_supplier=str(supplier.id),
            ordering="-popularity",
        )
        self.assertLessEqual(
            len(ctx),
            self.QUERY_CEILING,
            msg=f"search+boost used {len(ctx)} queries:\n"
            + "\n".join(q["sql"] for q in ctx.captured_queries),
        )

    def test_browse_stays_within_budget(self):
        self._seed(5)

        ctx = self._measure()
        self.assertLessEqual(
            len(ctx),
            self.QUERY_CEILING,
            msg=f"browse used {len(ctx)} queries:\n"
            + "\n".join(q["sql"] for q in ctx.captured_queries),
        )


class CatalogListPayloadTests(_AuthedCatalogTest):
    """The catalog list must not re-embed the parent product on every variant."""

    def test_list_variants_omit_redundant_product_detail(self):
        product = create_product_with_default_variant(
            name="Slim Payload", sku="SLIM-1", unit_price="1"
        )

        response = self._list(search="Slim")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        row = next(r for r in response.data["results"] if r["id"] == product.id)
        for variant in row["variants"]:
            self.assertNotIn("product_detail", variant)
        if row.get("default_variant"):
            self.assertNotIn("product_detail", row["default_variant"])

    def test_standalone_variant_endpoint_keeps_product_detail(self):
        create_product_with_default_variant(
            name="Keep Detail", sku="KEEP-1", unit_price="1"
        )

        response = self.client.get(
            reverse("product-variant-list"), {"search": "KEEP-1"}
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertTrue(response.data["results"])
        self.assertIn("product_detail", response.data["results"][0])


class VariantSearchRelevanceTests(_AuthedCatalogTest):
    """The variant endpoint (purchasing / stock-count) reuses relevance ranking."""

    def _variants(self, **params):
        return self.client.get(reverse("product-variant-list"), params)

    def test_numeric_query_ranks_exact_code_first(self):
        create_product_with_default_variant(
            name="Thing 5005", sku="THING", unit_price="1"
        )
        create_product_with_default_variant(name="Other", sku="5005", unit_price="1")

        response = self._variants(search="5005")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        skus = [row["sku"] for row in response.data["results"]]
        self.assertTrue(skus, msg="variant search returned no rows")
        # The exact code hit ranks above the incidental name substring.
        self.assertEqual(skus[0], "5005")

    def test_search_matches_parent_product_name(self):
        create_product_with_default_variant(
            name="Zebra Cheese", sku="ZC-1", unit_price="1"
        )

        response = self._variants(search="Zebra")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertTrue(any(row["sku"] == "ZC-1" for row in response.data["results"]))


class ProductSearchScopeTests(_AuthedCatalogTest):
    """``?search_in=`` — the per-device search-mode picker on the till, the
    purchasing screen and the catalog. It narrows WHAT a search reads; how the
    matches it keeps are ranked is the ordinary relevance order."""

    def setUp(self):
        super().setUp()
        # One product per half of the search: "1004" is in this one's NAME...
        self.named = create_product_with_default_variant(
            name="Widget 1004", sku="WIDGET", unit_price="1"
        )
        # ...and in this one's CODE.
        self.coded = create_product_with_default_variant(
            name="Gadget", sku="1004", unit_price="1"
        )

    def test_code_scope_ignores_names(self):
        response = self._list(search="1004", search_in="code")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(_result_ids(response), [self.coded.id])

    def test_name_scope_ignores_codes(self):
        # The reason a shop turns the picker on: a product whose NAME carries a
        # number, looked up by that number, without every SKU containing it.
        response = self._list(search="1004", search_in="name")

        self.assertEqual(_result_ids(response), [self.named.id])

    def test_code_scope_reads_barcodes_and_carton_barcodes(self):
        from .models import ProductUnit, ProductUnitBarcode, UnitOfMeasure

        scanned = create_product_with_default_variant(
            name="Milk", sku="MLK", barcode="6210000000017", unit_price="1"
        )
        carton = UnitOfMeasure.objects.create(code="carton-milk", name="Carton")
        unit = ProductUnit.objects.create(
            product=scanned, unit=carton, factor_to_base=Decimal("12")
        )
        ProductUnitBarcode.objects.create(product_unit=unit, barcode="6219990001")

        by_barcode = self._list(search="6210000000017", search_in="code")
        by_carton = self._list(search="6219990001", search_in="code")

        self.assertEqual(_result_ids(by_barcode), [scanned.id])
        self.assertEqual(_result_ids(by_carton), [scanned.id])

    def test_code_scope_ranks_exact_then_prefix_then_contains(self):
        prefix = create_product_with_default_variant(
            name="Cable red", sku="1004-RED", unit_price="1"
        )
        midstring = create_product_with_default_variant(
            name="Cable blue", sku="X1004", unit_price="1"
        )

        response = self._list(search="1004", search_in="code")

        self.assertEqual(
            _result_ids(response), [self.coded.id, prefix.id, midstring.id]
        )

    def test_name_scope_reads_variant_names_and_aliases(self):
        from .models import ProductAlias

        variant_named = create_product_with_default_variant(
            name="Shirt", sku="SH-1", variant_name="Crimson", unit_price="1"
        )
        aliased = create_product_with_default_variant(
            name="Soda", sku="SD-1", unit_price="1"
        )
        ProductAlias.objects.create(
            product=aliased, alias="Crimson fizz", normalized="crimson fizz"
        )

        response = self._list(search="crimson", search_in="name")

        self.assertEqual(
            sorted(_result_ids(response)), sorted([variant_named.id, aliased.id])
        )
        # Neither is a code, so a code search finds nothing at all.
        self.assertEqual(_result_ids(self._list(search="crimson", search_in="code")), [])

    def test_name_scope_ranks_exact_then_prefix_then_contains(self):
        contains = create_product_with_default_variant(
            name="Best Coffee", sku="C3", unit_price="1"
        )
        prefix = create_product_with_default_variant(
            name="Coffee Beans", sku="C2", unit_price="1"
        )
        exact = create_product_with_default_variant(
            name="Coffee", sku="COFFEE-1", unit_price="1"
        )

        response = self._list(search="coffee", search_in="name")

        self.assertEqual(_result_ids(response), [exact.id, prefix.id, contains.id])

    def test_unknown_scope_searches_everything(self):
        # A newer till asking for a scope this server does not know still gets
        # the ordinary search rather than an error or an empty list.
        response = self._list(search="1004", search_in="colour")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(_result_ids(response), [self.coded.id, self.named.id])

    def test_scope_without_a_search_does_not_filter(self):
        response = self._list(search_in="code", ordering="name")

        self.assertEqual(
            sorted(_result_ids(response)), sorted([self.coded.id, self.named.id])
        )

    def test_scope_keeps_the_supplier_boost(self):
        from apps.purchasing.models import PurchaseLine, PurchaseOrder, Supplier

        supplier = Supplier.objects.create(name="Acme")
        boosted = create_product_with_default_variant(
            name="Widget 1004 deluxe", sku="WD-2", unit_price="1"
        )
        order = PurchaseOrder.objects.create(supplier=supplier)
        PurchaseLine.objects.create(
            purchase_order=order,
            variant=boosted.default_variant,
            quantity=Decimal("1"),
            unit_cost=Decimal("1.00"),
        )

        response = self._list(
            search="widget", search_in="name", preferred_supplier=str(supplier.id)
        )

        self.assertEqual(_result_ids(response), [boosted.id, self.named.id])

    def test_scoped_search_does_not_rank_the_half_it_skips(self):
        # Every Exists() tier is costed against the whole catalogue, so a scoped
        # search must not carry the other half's subqueries along unused.
        from rest_framework.request import Request
        from rest_framework.test import APIRequestFactory

        from .models import Product
        from .search_filters import CatalogRelevanceFilter

        def sql(**params):
            request = Request(APIRequestFactory().get("/", params))
            queryset = CatalogRelevanceFilter().filter_queryset(
                request, Product.objects.all(), view=None
            )
            return str(queryset.query)

        by_name = sql(search="1004", search_in="name")
        by_code = sql(search="1004", search_in="code")

        self.assertNotIn("catalog_productunitbarcode", by_name)
        self.assertNotIn('"sku"', by_name)
        self.assertNotIn("catalog_productalias", by_code)


class VariantSearchScopeTests(_AuthedCatalogTest):
    """The purchasing catalog lists variants; ``?search_in=`` scopes it the same
    way it scopes the product list."""

    def setUp(self):
        super().setUp()
        create_product_with_default_variant(
            name="Thing 5005", sku="THING", unit_price="1"
        )
        create_product_with_default_variant(name="Other", sku="5005", unit_price="1")

    def _skus(self, **params):
        response = self.client.get(reverse("product-variant-list"), params)
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        return [row["sku"] for row in response.data["results"]]

    def test_code_scope_ignores_names(self):
        self.assertEqual(self._skus(search="5005", search_in="code"), ["5005"])

    def test_name_scope_ignores_codes(self):
        self.assertEqual(self._skus(search="5005", search_in="name"), ["THING"])

    def test_name_scope_reads_the_parent_product_name(self):
        create_product_with_default_variant(
            name="Zebra Cheese", sku="ZC-1", unit_price="1"
        )

        self.assertEqual(self._skus(search="zebra", search_in="name"), ["ZC-1"])
        self.assertEqual(self._skus(search="zebra", search_in="code"), [])

    def test_code_scope_reads_carton_barcodes(self):
        from .models import ProductUnit, ProductUnitBarcode, UnitOfMeasure

        product = create_product_with_default_variant(
            name="Eggs tray", sku="EGG", unit_price="1"
        )
        carton = UnitOfMeasure.objects.create(code="carton-egg", name="Carton")
        unit = ProductUnit.objects.create(
            product=product, unit=carton, factor_to_base=Decimal("30")
        )
        ProductUnitBarcode.objects.create(product_unit=unit, barcode="9990001")

        self.assertEqual(self._skus(search="9990001", search_in="code"), ["EGG"])
        self.assertEqual(self._skus(search="9990001", search_in="name"), [])

    def test_unknown_scope_searches_everything(self):
        self.assertEqual(
            self._skus(search="5005", search_in="colour"), ["5005", "THING"]
        )
