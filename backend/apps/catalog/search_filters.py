"""Relevance-ranked product search + deterministic ordering for the catalog.

Replaces DRF's stock ``SearchFilter``/``OrderingFilter`` on :class:`~apps.catalog
.views.ProductViewSet` with one backend that owns both matching *and* the final
``ORDER BY``. Three things the stock filter got wrong for a POS:

* **Numeric queries matched names.** ``1004`` used to match any product whose
  name merely contained "1004". Here a pure-digit query is treated as a *code*:
  variant SKU / barcode / unit (carton) barcode matches rank above name matches.
* **No ranking.** Matches were all equal and sorted alphabetically. Here every
  match gets a relevance tier (exact -> starts-with -> contains) and the best
  match comes first, with "most bought" popularity as the ambient tiebreak.
* **Unstable ordering.** ``ordering=name`` produced a name-only sort that can
  skip/repeat rows across pages; every ordering here ends in ``id``.

Matching uses ``Exists()`` *subqueries*, never joins across the multi-valued
``variants`` / ``units__barcodes`` / ``aliases`` relations: a join would fan one
product into many rows and inflate the ``Sum('variants__stock_items__...')`` rollups
the queryset already carries (corrupting the in-stock filter and the stock shown
to the client). ``Exists`` is a scalar correlated subquery — no extra rows, no
``distinct()`` needed, and it all stays inside the single main SELECT (zero extra
queries). Barcode *scanning* is untouched: it uses the exact ``?barcode=`` filter
and sends no ``search``, so this backend early-returns for it.

``?search_in=`` narrows a search to one half of it: ``code`` looks only at the
variant SKU / barcode and the unit (carton) barcodes, ``name`` only at product
and variant names and the aliases. It is what the search-mode picker sends, a
per-device option on the till, the purchasing screen and the catalog. Absent —
or anything else — keeps the mixed search above, SQL for SQL.
"""

import re

from django.db.models import (
    BooleanField,
    Case,
    Exists,
    IntegerField,
    OuterRef,
    Q,
    Value,
    When,
)
from rest_framework.filters import BaseFilterBackend

from .models import ProductAlias, ProductUnitBarcode, ProductVariant

# Arabic tashkeel (harakat) + tatweel: invisible/joining marks that shouldn't
# affect a substring match. We strip these from the QUERY so a term typed with
# vowel marks still matches the bare stored text. Deliberately NOT NFKD-normalized
# and NOT letter-folded: NFKD decomposes composed letters like alef-with-hamza
# (U+0623) into a bare alef (U+0627) + a combining hamza, and dropping that mark
# would fold the letter — which breaks ``icontains`` against the raw stored name
# (the DB column keeps the composed letter). Stripping only the standalone marks
# leaves every base letter unchanged, so it stays safe for a substring match.
_ARABIC_MARKS_RE = re.compile(
    "[ؐ-ًؚ-ٰٟۖ-ۭـ]"
)


def _normalize_query(text):
    """Trim, collapse whitespace and strip Arabic harakat/tatweel from a raw query.

    Kept intentionally light (no letter folding) so the normalized term still
    matches the raw stored product/variant/SKU text via ``icontains``.
    """
    if not text:
        return ""
    text = _ARABIC_MARKS_RE.sub("", text)
    return re.sub(r"\s+", " ", text).strip()


# A normalized query is "code-like" when it is nothing but digits — the core case
# from the bug report ("1004"). Codes then rank above name matches.
_CODE_QUERY_RE = re.compile(r"^\d+$")

# The default sort (no search): most-bought first, then a stable name/id key.
_DEFAULT_ORDERING = ("-popularity", "name", "id")

# Allowed client ``ordering=`` values -> the stable ORDER BY they map to. Every
# tuple ends in a unique column (id) so pagination never skips/repeats a row.
# ``unit_price`` has no product-level column (it lives on the variant) and was a
# server-side no-op before this backend too, so it preserves today's name order
# rather than silently reinterpreting the request.
_ORDERING_MAP = {
    "": _DEFAULT_ORDERING,
    "name": ("name", "id"),
    "-name": ("-name", "id"),
    "popularity": ("popularity", "name", "id"),
    "-popularity": _DEFAULT_ORDERING,
    "created_at": ("created_at", "id"),
    "-created_at": ("-created_at", "id"),
    "unit_price": ("name", "id"),
    "-unit_price": ("name", "id"),
}

_SUPPLIER_BOOST = "is_supplier_product"

SEARCH_IN_PARAM = "search_in"
SEARCH_IN_CODE = "code"
SEARCH_IN_NAME = "name"


def _search_scope(request):
    """``code``, ``name`` or None (both) — which half of a product a search reads.

    An unknown value is treated as absent rather than refused: a newer till
    asking for a scope this server has never heard of still gets an answer.
    """
    value = (request.query_params.get(SEARCH_IN_PARAM) or "").strip().lower()
    return value if value in (SEARCH_IN_CODE, SEARCH_IN_NAME) else None


def _scored(is_code, code_tiers, name_tiers):
    """Pair each tier with its score, best first.

    Codes lead for numeric queries and names for text; the other group is still
    ranked below, so a text query can fall back to a code hit and vice versa.
    A scoped search passes one group empty and ranks just the other.
    """
    ordered = (*code_tiers, *name_tiers) if is_code else (*name_tiers, *code_tiers)
    return [(condition, len(ordered) - index) for index, condition in enumerate(ordered)]


class CatalogRelevanceFilter(BaseFilterBackend):
    """Search relevance + stable ordering for the product list. See module docs."""

    RELEVANCE_ALIAS = "search_relevance"

    def filter_queryset(self, request, queryset, view):
        term = _normalize_query(request.query_params.get("search", ""))
        boost = self._supplier_boost_active(request, queryset)
        if not term:
            return self._order_browse(request, queryset, boost)
        return self._order_by_relevance(
            queryset, term, boost, scope=_search_scope(request)
        )

    # -- helpers --------------------------------------------------------------

    def _supplier_boost_active(self, request, queryset):
        """True when a purchasing supplier is selected AND the queryset carries the
        ``is_supplier_product`` annotation (added by the viewset). Only then does the
        boost lead the ORDER BY; otherwise we don't order by a constant."""
        value = request.query_params.get("preferred_supplier")
        return bool(
            value
            and value.isdigit()
            and _SUPPLIER_BOOST in queryset.query.annotations
        )

    def _order_browse(self, request, queryset, boost):
        """No search term: honour the client's chosen sort with a stable tiebreak,
        floating the selected supplier's products on top when boosting."""
        base = _ORDERING_MAP.get(request.query_params.get("ordering", ""), _DEFAULT_ORDERING)
        if boost:
            return queryset.order_by(f"-{_SUPPLIER_BOOST}", *base)
        return queryset.order_by(*base)

    def _order_by_relevance(self, queryset, term, boost, scope=None):
        is_code = bool(_CODE_QUERY_RE.match(term))
        searches_codes = scope != SEARCH_IN_NAME
        searches_names = scope != SEARCH_IN_CODE

        variants = ProductVariant.objects.filter(product=OuterRef("pk"))
        unit_barcodes = ProductUnitBarcode.objects.filter(
            product_unit__product=OuterRef("pk")
        )
        aliases = ProductAlias.objects.filter(product=OuterRef("pk"))

        # Each match tier as scalar Exists() booleans (0 join rows). Product.name is
        # a direct column, so its tiers stay ordinary field lookups combined with
        # the annotated variant/alias booleans as Q-over-annotations below. A
        # scoped search annotates only its own half: the other half's subqueries
        # would be costed against every row for tiers nothing can reach.
        annotations = {}
        code_tiers = name_tiers = ()
        if searches_codes:
            annotations.update(
                _sku_exact=Exists(
                    variants.filter(Q(sku__iexact=term) | Q(barcode__iexact=term))
                ),
                _ubar_exact=Exists(unit_barcodes.filter(barcode__iexact=term)),
                _sku_prefix=Exists(
                    variants.filter(
                        Q(sku__istartswith=term) | Q(barcode__istartswith=term)
                    )
                ),
                _ubar_prefix=Exists(unit_barcodes.filter(barcode__istartswith=term)),
                _sku_contains=Exists(
                    variants.filter(Q(sku__icontains=term) | Q(barcode__icontains=term))
                ),
                _ubar_contains=Exists(unit_barcodes.filter(barcode__icontains=term)),
            )
            code_tiers = (
                Q(_sku_exact=True) | Q(_ubar_exact=True),
                Q(_sku_prefix=True) | Q(_ubar_prefix=True),
                Q(_sku_contains=True) | Q(_ubar_contains=True),
            )
        if searches_names:
            annotations.update(
                _vname_exact=Exists(variants.filter(name__iexact=term)),
                _vname_prefix=Exists(variants.filter(name__istartswith=term)),
                _vname_contains=Exists(variants.filter(name__icontains=term)),
                _alias_contains=Exists(aliases.filter(alias__icontains=term)),
            )
            name_tiers = (
                Q(name__iexact=term) | Q(_vname_exact=True),
                Q(name__istartswith=term) | Q(_vname_prefix=True),
                Q(name__icontains=term)
                | Q(_vname_contains=True)
                | Q(_alias_contains=True),
            )
        queryset = queryset.annotate(**annotations)

        # Higher tier = better match. See _scored for the code-vs-name order.
        tiers = _scored(is_code, code_tiers, name_tiers)

        # Restrict to matches with NON-correlated subqueries so the pg_trgm indexes
        # are actually used. The tier annotations above are *correlated* Exists —
        # great for RANKING the matched set, but using an OR of them as the WHERE
        # clause forces Postgres to evaluate all ten against every product in the
        # catalogue (no index can serve a correlated-Exists OR), which is what made
        # search crawl on a real-shop catalogue. Each id__in below is an independent
        # indexable subquery; the tier Case then runs only over the matched rows.
        #
        # Built term by term in the unscoped search's own order, so a search
        # without ?search_in= compiles to exactly the SQL it always has.
        variant_match = Q()
        if searches_codes:
            variant_match |= Q(sku__icontains=term) | Q(barcode__icontains=term)
        if searches_names:
            variant_match |= Q(name__icontains=term)

        match_q = Q()
        if searches_names:
            match_q |= Q(name__icontains=term)
        match_q |= Q(
            id__in=ProductVariant.objects.filter(variant_match).values("product_id")
        )
        if searches_codes:
            match_q |= Q(
                id__in=ProductUnitBarcode.objects.filter(
                    barcode__icontains=term
                ).values("product_unit__product_id")
            )
        if searches_names:
            match_q |= Q(
                id__in=ProductAlias.objects.filter(alias__icontains=term).values(
                    "product_id"
                )
            )

        queryset = queryset.filter(match_q).annotate(
            **{
                self.RELEVANCE_ALIAS: Case(
                    *[When(condition, then=Value(score)) for condition, score in tiers],
                    default=Value(0),
                    output_field=IntegerField(),
                )
            }
        )

        order = [f"-{_SUPPLIER_BOOST}"] if boost else []
        order += [f"-{self.RELEVANCE_ALIAS}", "-popularity", "name", "id"]
        return queryset.order_by(*order)


# Browse (no search) orderings for the variant list. Every tuple ends in ``id``
# for stable pagination; popularity/name come from the parent product.
_VARIANT_DEFAULT_ORDERING = ("-product__popularity", "product__name", "name", "id")
_VARIANT_ORDERING_MAP = {
    "": _VARIANT_DEFAULT_ORDERING,
    "product__name": ("product__name", "name", "id"),
    "-product__name": ("-product__name", "name", "id"),
    "name": ("name", "id"),
    "-name": ("-name", "id"),
    "sku": ("sku", "id"),
    "-sku": ("-sku", "id"),
    "created_at": ("created_at", "id"),
    "-created_at": ("-created_at", "id"),
    "popularity": ("product__popularity", "product__name", "id"),
    "-popularity": _VARIANT_DEFAULT_ORDERING,
}


class VariantRelevanceFilter(BaseFilterBackend):
    """Relevance search + stable ordering for ``/api/product-variants/``.

    The purchasing picker and the stock-count item search both hit that endpoint;
    this gives them the *same* ranking, Arabic normalization and code-vs-name
    logic as :class:`CatalogRelevanceFilter`, replacing the stock ILIKE
    ``SearchFilter``. It is deliberately leaner than the product filter: a
    variant's ``sku`` / ``barcode`` / ``name`` are its own columns, so the code
    and name tiers are direct field lookups — only the product-level unit
    (carton) barcode still needs an ``Exists`` subquery. ``product__name`` joins
    the parent 1:1 (no fan-out). This keeps the plan small enough to stay under
    the JIT threshold on the client's on-prem Postgres. ``?search_in=`` scopes
    it exactly as it scopes the product search (see the module docs).
    """

    RELEVANCE_ALIAS = "search_relevance"

    def filter_queryset(self, request, queryset, view):
        term = _normalize_query(request.query_params.get("search", ""))
        if not term:
            base = _VARIANT_ORDERING_MAP.get(
                request.query_params.get("ordering", ""), _VARIANT_DEFAULT_ORDERING
            )
            return queryset.order_by(*base)
        return self._order_by_relevance(queryset, term, scope=_search_scope(request))

    def _order_by_relevance(self, queryset, term, scope=None):
        is_code = bool(_CODE_QUERY_RE.match(term))
        searches_codes = scope != SEARCH_IN_NAME
        searches_names = scope != SEARCH_IN_CODE

        code_tiers = name_tiers = ()
        if searches_codes:
            unit_barcodes = ProductUnitBarcode.objects.filter(
                product_unit__product=OuterRef("product_id")
            )
            queryset = queryset.annotate(
                _ubar_exact=Exists(unit_barcodes.filter(barcode__iexact=term)),
                _ubar_prefix=Exists(unit_barcodes.filter(barcode__istartswith=term)),
                _ubar_contains=Exists(unit_barcodes.filter(barcode__icontains=term)),
            )
            code_tiers = (
                Q(sku__iexact=term) | Q(barcode__iexact=term) | Q(_ubar_exact=True),
                Q(sku__istartswith=term)
                | Q(barcode__istartswith=term)
                | Q(_ubar_prefix=True),
                Q(sku__icontains=term)
                | Q(barcode__icontains=term)
                | Q(_ubar_contains=True),
            )
        if searches_names:
            name_tiers = (
                Q(name__iexact=term) | Q(product__name__iexact=term),
                Q(name__istartswith=term) | Q(product__name__istartswith=term),
                Q(name__icontains=term) | Q(product__name__icontains=term),
            )

        tiers = _scored(is_code, code_tiers, name_tiers)

        # Match with indexable predicates: variant columns are direct (trigram
        # UPPER indexes serve them); product name joins 1:1; the unit barcode is a
        # non-correlated id__in over the parent product. Built in the unscoped
        # search's own order, so its SQL does not change.
        match_q = Q()
        if searches_codes:
            match_q |= Q(sku__icontains=term) | Q(barcode__icontains=term)
        if searches_names:
            match_q |= Q(name__icontains=term) | Q(product__name__icontains=term)
        if searches_codes:
            match_q |= Q(
                product_id__in=ProductUnitBarcode.objects.filter(
                    barcode__icontains=term
                ).values("product_unit__product_id")
            )

        queryset = queryset.filter(match_q).annotate(
            **{
                self.RELEVANCE_ALIAS: Case(
                    *[When(condition, then=Value(score)) for condition, score in tiers],
                    default=Value(0),
                    output_field=IntegerField(),
                )
            }
        )
        return queryset.order_by(
            f"-{self.RELEVANCE_ALIAS}", "-product__popularity", "product__name", "name", "id"
        )
