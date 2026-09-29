"""Product and variant search: every typed word found somewhere, then ranked.

Replaces DRF's stock ``SearchFilter``/``OrderingFilter`` on the product list
(POS, back-office catalogue) and the variant list (purchasing, stock counts).
What one search does, in order:

1. **Fold the query** the way the catalogue's names are stored folded
   (``search_text.fold``, the generated ``search_name`` columns): «أرز» and
   «ارز» are one word, «كاتشب575» is two, harakat and tatweel are gone.
2. **Every word must match somewhere.** A product matches when each typed word
   occurs in its name, a variant name, an alias, a SKU, a barcode or a carton
   barcode — each word on its own, in any order. «النجمه ارز» finds «أرز النجمة
   حبة قصيرة»; «حليب 624100» finds the milk whose barcode holds those digits,
   which is how cashiers type when they half-remember a code.
3. **Rank.** A query that looks like a code (``1004``, ``AB-12``) ranks code
   hits first — exact, then prefix, then anywhere. Otherwise names lead: exact
   name, name starting with the query, every word starting a word of the name,
   the query as typed inside the name, every word inside the name, then codes,
   then words spread over variants/aliases/codes. "Most bought" breaks ties and
   every ORDER BY ends in ``id`` so pagination never skips or repeats a row.
4. **Only if nothing matched**, forgive, most certain first — so a well-typed
   search never pays for any of it:

   * the till's category chip is lifted (see ``_category_fallback_allowed``);
   * matches that exist but are out of stock are counted, and the search
     stops there — «3 matches are out of stock» beats a fuzzy guess at
     something else;
   * the query retyped from the other keyboard layout («hgpgdf» → «الحليب», or
     a scanner on the Arabic layout that scrambled a Latin code);
   * the words corrected against the shop's own vocabulary — one-key slips and
     words run together (``search_fallback``);
   * trigram similarity and the loanword key («شوكولاطة» → «شكلاطة»).

   What happened rides back with the page (``search_outcome``) so the till can
   say «showing results for …» instead of pretending the cashier typed it.

Matching and ranking reach variants, aliases and codes by membership —
non-correlated ``id IN (SELECT product_id ...)`` — never a join (which would
fan one product into many rows and inflate the stock sums the catalogue list
carries) and never a correlated ``EXISTS`` (which PostgreSQL costs once per
catalogue row; that is what once made every search pay ~700 ms of JIT).

``?search_in=code|name`` (the per-device search-mode picker) narrows a search
to one half; absent or unknown, both halves are searched. Barcode *scanning*
uses the exact ``?barcode=`` filter and sends no ``search`` at all.
"""

from __future__ import annotations

import logging
import re
from dataclasses import dataclass

from django.db import connections
from django.db.models import Case, F, FloatField, IntegerField, Q, Value, When
from django.db.models.lookups import GreaterThanOrEqual
from rest_framework.filters import BaseFilterBackend

from . import search_text
from .models import ProductAlias, ProductUnitBarcode, ProductVariant
from .search_fallback import correct_tokens, shop_vocabulary
from .search_sql import WordSimilarity, supports_similarity

logger = logging.getLogger(__name__)

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

CATEGORY_FALLBACK_PARAM = "category_fallback"

# A query longer than this is almost certainly pasted text; the words after it
# would only make the SQL bigger.
MAX_TOKENS = 8

# pg_trgm word similarity at or above which a word counts as a near miss.
FUZZY_THRESHOLD = 0.5

MATCH_EXACT = "exact"
MATCH_LAYOUT = "layout"
MATCH_CORRECTED = "corrected"
MATCH_FUZZY = "fuzzy"
MATCH_NONE = "none"

_OUTCOME_ATTR = "_pointy_search_outcome"


@dataclass
class SearchOutcome:
    """What a search did, sent back with the page it produced."""

    query: str
    match: str = MATCH_EXACT
    corrected_query: str = ""
    hidden_out_of_stock: int = 0
    category_fallback: bool = False

    def as_payload(self) -> dict:
        return {
            "query": self.query,
            "match": self.match,
            "corrected_query": self.corrected_query or None,
            "hidden_out_of_stock": self.hidden_out_of_stock,
            "category_fallback": self.category_fallback,
        }


def search_outcome(request) -> SearchOutcome | None:
    """The outcome of the search this request ran, if it ran one."""
    return getattr(request, _OUTCOME_ATTR, None)


def _search_scope(request):
    """``code``, ``name`` or None (both) — which half of a product a search reads.

    An unknown value is treated as absent rather than refused: a newer till
    asking for a scope this server has never heard of still gets an answer.
    """
    value = (request.query_params.get(SEARCH_IN_PARAM) or "").strip().lower()
    return value if value in (SEARCH_IN_CODE, SEARCH_IN_NAME) else None


def _scored(is_code, code_tiers, name_tiers, floor_tiers=()):
    """Pair each tier with its score, best first.

    Codes lead for code-like queries and names for text; the other group is
    still ranked below, so a text query can fall back to a code hit and vice
    versa. A scoped search passes one group empty and ranks just the other.
    ``floor_tiers`` rank under both — only rows matched by nothing better
    (the loanword key alone) score lower.
    """
    ordered = (*code_tiers, *name_tiers) if is_code else (*name_tiers, *code_tiers)
    ordered = (*ordered, *floor_tiers)
    return [(condition, len(ordered) - index) for index, condition in enumerate(ordered)]


def _every(conditions):
    combined = Q()
    for condition in conditions:
        combined &= condition
    return combined


def _starts_a_word(field, word):
    """``word`` begins some word of ``field`` — with or without «ال» before it."""
    return (
        Q(**{f"{field}__startswith": word})
        | Q(**{f"{field}__contains": f" {word}"})
        | Q(**{f"{field}__startswith": f"ال{word}"})
        | Q(**{f"{field}__contains": f" ال{word}"})
    )


def _has_word(field, word):
    """``word`` is one whole word of the space-separated ``field``."""
    return (
        Q(**{field: word})
        | Q(**{f"{field}__startswith": f"{word} "})
        | Q(**{f"{field}__endswith": f" {word}"})
        | Q(**{f"{field}__contains": f" {word} "})
    )


_ARTICLE = "ال"


def _without_article(token):
    """«النجمه» -> «نجمه», so a typed article also finds a name without one.
    Only when four letters remain: «البان» must not become «بان» and match
    «بانادول». (The other way round needs nothing: «نجمه» is inside
    «النجمه» already.)"""
    if token.startswith(_ARTICLE) and len(token) - len(_ARTICLE) >= 4:
        return token[len(_ARTICLE) :]
    return None


def _contains_word(field, token):
    """``token`` occurs in ``field``, allowing for a typed article."""
    condition = Q(**{f"{field}__contains": token})
    stem = _without_article(token)
    if stem:
        condition |= Q(**{f"{field}__contains": stem})
    return condition


# A typed word long enough to be matched by its loanword key as well as by its
# spelling — «شكلاته» then also finds the catalogue's «شكلاطة» and «شوكولاتة».
# Five letters: shorter keys collide too easily («حليب» and «حلبة» share one).
SOUNDS_ALIKE_MIN_LETTERS = 5

_SCANNED_CODE_RE = re.compile(r"[A-Za-z0-9._/\-]+")


def _sounds_alike_key(token, *, min_letters=SOUNDS_ALIKE_MIN_LETTERS):
    if len(token) < min_letters or search_text.has_digits(token):
        return None
    key = search_text.skeleton(token)
    if len(key) < 3 or " " in key:
        return None
    return key


def _looks_like_scanned_code(text):
    """A Latin code a scanner could have typed: letters, digits, a few joiners
    — and at least one digit, which is what tells a code from a word."""
    return bool(_SCANNED_CODE_RE.fullmatch(text)) and search_text.has_digits(text)


def _variants(condition):
    return ProductVariant.objects.filter(condition).values("product_id")


def _aliases(condition):
    return ProductAlias.objects.filter(condition).values("product_id")


def _unit_barcodes(condition):
    return ProductUnitBarcode.objects.filter(condition).values(
        "product_unit__product_id"
    )


@dataclass(frozen=True)
class _Query:
    raw: str
    phrase: str
    tokens: tuple
    # The query as one code (digits made ASCII), or "" when it has spaces.
    code: str
    is_code: bool

    @classmethod
    def parse(cls, raw):
        raw = (raw or "").strip()
        if not raw:
            return None
        code = search_text.code_form(raw)
        return cls(
            raw=raw,
            phrase=search_text.fold(raw),
            tokens=tuple(search_text.tokens(raw)[:MAX_TOKENS]),
            code="" if (not code or " " in code) else code,
            is_code=search_text.looks_like_code(raw),
        )

    @classmethod
    def of_tokens(cls, tokens):
        phrase = " ".join(tokens)
        return cls(raw=phrase, phrase=phrase, tokens=tuple(tokens), code="", is_code=False)


class _ProductRows:
    """How a PRODUCT row is matched: its own name is a column of the row;
    variant names, aliases and codes are reached by membership."""

    name_field = "search_name"
    skeleton_field = "search_skeleton"

    def word(self, token, *, names, codes, sounds_alike=True):
        match = Q()
        if names:
            match |= _contains_word("search_name", token)
            match |= Q(id__in=_variants(_contains_word("search_name", token)))
            match |= Q(id__in=_aliases(_contains_word("search_alias", token)))
            key = _sounds_alike_key(token) if sounds_alike else None
            if key:
                match |= _has_word("search_skeleton", key)
        if codes:
            match |= Q(
                id__in=_variants(Q(sku__icontains=token) | Q(barcode__icontains=token))
            )
            match |= Q(id__in=_unit_barcodes(Q(barcode__icontains=token)))
        return match

    def name_tiers(self, query):
        phrase = query.phrase
        return (
            Q(search_name=phrase)
            | Q(id__in=_variants(Q(search_name=phrase)))
            | Q(id__in=_aliases(Q(search_alias=phrase))),
            Q(search_name__startswith=phrase)
            | Q(id__in=_variants(Q(search_name__startswith=phrase)))
            | Q(id__in=_aliases(Q(search_alias__startswith=phrase))),
            _every(
                _starts_a_word("search_name", _without_article(token) or token)
                for token in query.tokens
            ),
            Q(search_name__contains=phrase)
            | Q(id__in=_variants(Q(search_name__contains=phrase)))
            | Q(id__in=_aliases(Q(search_alias__contains=phrase))),
            _every(_contains_word("search_name", token) for token in query.tokens),
        )

    def code_tiers(self, code):
        def tier(lookup):
            return Q(
                id__in=_variants(
                    Q(**{f"sku__{lookup}": code}) | Q(**{f"barcode__{lookup}": code})
                )
            ) | Q(id__in=_unit_barcodes(Q(**{f"barcode__{lookup}": code})))

        return (tier("iexact"), tier("istartswith"), tier("icontains"))


class _VariantRows:
    """How a VARIANT row is matched: its own name and codes are columns, the
    parent product's name joins 1:1, aliases and carton barcodes belong to the
    product and are reached by membership."""

    name_field = "product__search_name"
    skeleton_field = "product__search_skeleton"

    def word(self, token, *, names, codes, sounds_alike=True):
        match = Q()
        if names:
            match |= _contains_word("search_name", token)
            match |= _contains_word("product__search_name", token)
            match |= Q(product_id__in=_aliases(_contains_word("search_alias", token)))
            key = _sounds_alike_key(token) if sounds_alike else None
            if key:
                match |= _has_word("product__search_skeleton", key)
        if codes:
            match |= Q(sku__icontains=token) | Q(barcode__icontains=token)
            match |= Q(product_id__in=_unit_barcodes(Q(barcode__icontains=token)))
        return match

    def name_tiers(self, query):
        phrase = query.phrase
        return (
            Q(search_name=phrase)
            | Q(product__search_name=phrase)
            | Q(product_id__in=_aliases(Q(search_alias=phrase))),
            Q(search_name__startswith=phrase)
            | Q(product__search_name__startswith=phrase)
            | Q(product_id__in=_aliases(Q(search_alias__startswith=phrase))),
            _every(
                _starts_a_word("product__search_name", _without_article(token) or token)
                | _starts_a_word("search_name", _without_article(token) or token)
                for token in query.tokens
            ),
            Q(search_name__contains=phrase) | Q(product__search_name__contains=phrase),
            _every(
                _contains_word("product__search_name", token)
                | _contains_word("search_name", token)
                for token in query.tokens
            ),
        )

    def code_tiers(self, code):
        def tier(lookup):
            return (
                Q(**{f"sku__{lookup}": code})
                | Q(**{f"barcode__{lookup}": code})
                | Q(product_id__in=_unit_barcodes(Q(**{f"barcode__{lookup}": code})))
            )

        return (tier("iexact"), tier("istartswith"), tier("icontains"))


class _Search:
    """One search over one queryset. Subclasses say how rows are ordered and
    whether there are wider bases to fall back to."""

    RELEVANCE_ALIAS = "search_relevance"
    CLOSENESS_ALIAS = "search_closeness"
    rows = None
    surface = "other"

    def __init__(self, *, request, view, query, scope):
        self.request = request
        self.view = view
        self.query = query
        self.names = scope != SEARCH_IN_CODE
        self.codes = scope != SEARCH_IN_NAME
        self.outcome = SearchOutcome(query=query.raw)
        setattr(request, _OUTCOME_ATTR, self.outcome)

    # -- the ordinary search -------------------------------------------------

    def _matching(self, queryset, query):
        return queryset.filter(
            _every(
                self.rows.word(token, names=self.names, codes=self.codes)
                for token in query.tokens
            )
        )

    def _strict(self, queryset, query):
        name_tiers = self.rows.name_tiers(query) if self.names else ()
        code_tiers = (
            self.rows.code_tiers(query.code) if (self.codes and query.code) else ()
        )
        # Every word matched as spelled, somewhere — above rows that only the
        # loanword key found.
        spelled = (
            _every(
                self.rows.word(
                    token, names=self.names, codes=self.codes, sounds_alike=False
                )
                for token in query.tokens
            ),
        )
        tiers = _scored(query.is_code, code_tiers, name_tiers, spelled)
        relevance = Case(
            *[When(condition, then=Value(score)) for condition, score in tiers],
            default=Value(0),
            output_field=IntegerField(),
        )
        found = self._matching(queryset, query).annotate(
            **{self.RELEVANCE_ALIAS: relevance}
        )
        if self.names and supports_similarity(connections[queryset.db]):
            # Within a tier, the name closest to what was typed comes first — a
            # whole-word hit (similarity 1.0) above a word it merely starts, and
            # among names only the loanword key found, the likeliest spelling.
            closeness = None
            for token in query.tokens:
                similarity = WordSimilarity(Value(token), F(self.rows.name_field))
                closeness = similarity if closeness is None else closeness + similarity
            found = found.annotate(**{self.CLOSENESS_ALIAS: closeness})
        return self._order(found)

    def _order(self, queryset):  # pragma: no cover - subclasses
        raise NotImplementedError

    # -- when it found nothing ----------------------------------------------

    def _bases(self, queryset):
        return [queryset]

    def _hidden_by_stock(self, bases):
        return 0

    def _alternatives(self):
        """Other readings of the query, most certain first, built lazily."""
        raw = self.query.raw
        if (
            self.names
            and search_text.has_latin_letters(raw)
            and not search_text.has_arabic_letters(raw)
        ):
            retyped = _Query.parse(search_text.latin_to_arabic_layout(raw))
            if retyped is not None and retyped.tokens:
                yield MATCH_LAYOUT, retyped
        if self.codes and search_text.has_arabic_letters(raw) and " " not in raw:
            latin = search_text.arabic_to_latin_layout(raw)
            retyped = _Query.parse(latin) if _looks_like_scanned_code(latin) else None
            if retyped is not None and retyped.tokens:
                yield MATCH_LAYOUT, retyped
        if self.names:
            try:
                corrected = correct_tokens(list(self.query.tokens), shop_vocabulary())
            except Exception:  # noqa: BLE001 — a fallback must never fail a search
                logger.warning("search vocabulary unavailable", exc_info=True)
                corrected = None
            if corrected:
                yield MATCH_CORRECTED, _Query.of_tokens(corrected)

    def _fuzzy(self, queryset):
        """Near misses: each word matches, is similar to a word of the name, or
        shares its loanword key. Ranked by how similar, summed over the words."""
        connection = connections[queryset.db]
        if not self.names or not supports_similarity(connection):
            return None
        conditions = Q()
        score = None
        forgiving = False
        for token in self.query.tokens:
            spelled = self.rows.word(
                token, names=self.names, codes=self.codes, sounds_alike=False
            )
            match = spelled
            similarity = WordSimilarity(Value(token), F(self.rows.name_field))
            if len(token) >= 3 and not search_text.has_digits(token):
                forgiving = True
                match |= Q(GreaterThanOrEqual(similarity, FUZZY_THRESHOLD))
                key = _sounds_alike_key(token, min_letters=3)
                if key:
                    match |= _has_word(self.rows.skeleton_field, key)
            conditions &= match
            # A word spelled right counts in full; a near miss by how near.
            word_score = Case(
                When(spelled, then=Value(1.0)),
                default=similarity,
                output_field=FloatField(),
            )
            score = word_score if score is None else score + word_score
        if not forgiving:
            return None
        return self._order(
            queryset.filter(conditions).annotate(**{self.RELEVANCE_ALIAS: score})
        )

    def run(self, queryset):
        if not self.query.tokens:
            self.outcome.match = MATCH_NONE
            return queryset.none()
        bases = self._bases(queryset)
        first = None
        for index, base in enumerate(bases):
            found = self._strict(base, self.query)
            first = found if first is None else first
            if found.exists():
                self.outcome.category_fallback = index > 0
                return found

        hidden = self._hidden_by_stock(bases)
        if hidden:
            self.outcome.match = MATCH_NONE
            self.outcome.hidden_out_of_stock = hidden
            return first

        for kind, alternative in self._alternatives():
            for index, base in enumerate(bases):
                found = self._strict(base, alternative)
                if found.exists():
                    self.outcome.match = kind
                    self.outcome.corrected_query = alternative.raw
                    self.outcome.category_fallback = index > 0
                    return found

        for index, base in enumerate(bases):
            found = self._fuzzy(base)
            if found is None:
                break
            if found.exists():
                self.outcome.match = MATCH_FUZZY
                self.outcome.category_fallback = index > 0
                return found

        self.outcome.match = MATCH_NONE
        self._record_miss()
        return first

    def _record_miss(self):
        from .search_misses import record_search_miss

        try:
            record_search_miss(self.query.raw, surface=self.surface)
        except Exception:  # noqa: BLE001 — bookkeeping must never fail a search
            logger.warning("could not record a search miss", exc_info=True)


class _ProductSearch(_Search):
    rows = _ProductRows()

    def __init__(self, *, boost, **kwargs):
        super().__init__(**kwargs)
        self.boost = boost
        system = self.request.query_params.get("system")
        self.surface = {"sellable": "pos", "all": "catalog"}.get(system, "other")

    def _order(self, queryset):
        order = [f"-{_SUPPLIER_BOOST}"] if self.boost else []
        order.append(f"-{self.RELEVANCE_ALIAS}")
        if self.CLOSENESS_ALIAS in queryset.query.annotations:
            order.append(f"-{self.CLOSENESS_ALIAS}")
        order += ["-popularity", "name", "id"]
        return queryset.order_by(*order)

    def _rebuild(self, *, category, stock):
        rebuild = getattr(self.view, "search_base_queryset", None)
        if rebuild is None:
            return None
        return rebuild(category=category, stock=stock)

    def _category_fallback_allowed(self):
        """Whether a search may leave the category chip when nothing inside it
        matched.

        Field data (Sep 2026): 61% of a till's empty searches were typed with a
        category chip still on from browsing, and the product was one tap away
        in another category. So on the till a search looks in the chip's
        category first and then everywhere. ``?category_fallback=0|1`` says so
        explicitly; a till that predates the parameter — the frozen Windows 7/8
        build among them — is recognised by the ``?system=sellable`` it sends,
        so the fix reaches it with a server update alone.
        """
        value = (self.request.query_params.get(CATEGORY_FALLBACK_PARAM) or "").lower()
        if value in ("1", "true"):
            return True
        if value in ("0", "false"):
            return False
        return self.request.query_params.get("system") == "sellable"

    def _bases(self, queryset):
        from .views import requested_category_ids

        bases = [queryset]
        if requested_category_ids(self.request.query_params) and (
            self._category_fallback_allowed()
        ):
            wider = self._rebuild(category=False, stock=True)
            if wider is not None:
                bases.append(wider)
        return bases

    def _hidden_by_stock(self, bases):
        if self.request.query_params.get("in_stock") != "true":
            return 0
        unfiltered = self._rebuild(category=len(bases) == 1, stock=False)
        if unfiltered is None:
            return 0
        return self._matching(unfiltered, self.query).count()


class _VariantSearch(_Search):
    rows = _VariantRows()
    surface = "purchasing"

    def _order(self, queryset):
        order = [f"-{self.RELEVANCE_ALIAS}"]
        if self.CLOSENESS_ALIAS in queryset.query.annotations:
            order.append(f"-{self.CLOSENESS_ALIAS}")
        order += ["-product__popularity", "product__name", "name", "id"]
        return queryset.order_by(*order)


class CatalogRelevanceFilter(BaseFilterBackend):
    """Search + stable ordering for the product list. See module docs."""

    RELEVANCE_ALIAS = _Search.RELEVANCE_ALIAS

    def filter_queryset(self, request, queryset, view):
        boost = self._supplier_boost_active(request, queryset)
        query = _Query.parse(request.query_params.get("search", ""))
        if query is None:
            return self._order_browse(request, queryset, boost)
        return _ProductSearch(
            request=request,
            view=view,
            query=query,
            scope=_search_scope(request),
            boost=boost,
        ).run(queryset)

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
    """The same search for ``/api/product-variants/`` — the purchasing picker and
    the stock-count item search. A variant's own name and codes are columns and
    its product's name joins 1:1; aliases and carton barcodes are the product's
    and are reached by membership. No category or stock fallback: those
    screens show everything and have no chip to lift."""

    RELEVANCE_ALIAS = _Search.RELEVANCE_ALIAS

    def filter_queryset(self, request, queryset, view):
        query = _Query.parse(request.query_params.get("search", ""))
        if query is None:
            base = _VARIANT_ORDERING_MAP.get(
                request.query_params.get("ordering", ""), _VARIANT_DEFAULT_ORDERING
            )
            return queryset.order_by(*base)
        return _VariantSearch(
            request=request, view=view, query=query, scope=_search_scope(request)
        ).run(queryset)
