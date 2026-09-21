"""Suggest a retail sale price from a purchase cost, using the shop's own typical
markup so a freshly-created product is priced consistently with the rest of the
catalog (instead of a blind fixed margin). The markup is inferred from the real
catalog — preferring the product's own category (its actual pricing strategy) and
falling back to the shop-wide median — and every suggestion is snapped to a
quarter-dinar denomination a Libyan till can actually make change for.

Used by the AI when it creates a product mid purchase-order (e.g. an invoice line
with no matching product), but it has no AI dependency and is reusable anywhere.
"""

from decimal import ROUND_CEILING, ROUND_HALF_UP, Decimal

from django.conf import settings
from django.db.models import DecimalField, F, OuterRef, Subquery

from apps.catalog.cache import catalog_version
from apps.core.caching import get_or_compute_single_flight

# Fallback markup when the shop has too little cost+price history to infer one.
DEFAULT_MARKUP_PERCENT = Decimal("30")
# Need at least this many priced+costed products before we trust an inferred
# shop-wide markup.
_MIN_DATA_POINTS = 5
# A category is a smaller peer group, so trust its markup on fewer data points —
# a handful of same-category products already captures that category's strategy.
_MIN_CATEGORY_DATA_POINTS = 3
# Cap the sample so the median scan stays cheap on a huge catalogue.
_MARKUP_SAMPLE_CAP = 1000
# Guard rails on an inferred markup so one weird outlier set can't price wildly.
_MIN_MARKUP_PERCENT = Decimal("1")
_MAX_MARKUP_PERCENT = Decimal("500")
_CENT = Decimal("0.01")

# Suggested prices snap to the quarter-dinar denominations Libyan shops actually
# charge (…, 2.00, 2.25, 2.50, 2.75, 3.00, …) — never a 2.24-style fraction no
# till can make change for. One place to change if a shop ever needs a finer step.
PRICE_STEP = Decimal("0.25")


def _snap_to_step(value, *, rounding=ROUND_HALF_UP):
    """Snap ``value`` to a multiple of :data:`PRICE_STEP`. ``rounding`` picks
    nearest (default) vs. up (``ROUND_CEILING``) — used so a markup calc like
    2.236 becomes a real 2.25 price instead of an unusable fraction."""
    value = Decimal(value)
    if PRICE_STEP <= 0:
        return value.quantize(_CENT, rounding=ROUND_HALF_UP)
    units = (value / PRICE_STEP).to_integral_value(rounding=rounding)
    return (units * PRICE_STEP).quantize(_CENT, rounding=ROUND_HALF_UP)


def _latest_base_cost_subquery():
    """Latest non-cancelled purchase line cost for each variant, re-expressed per
    base unit (``unit_cost / unit_factor`` — mirrors ``PurchaseLine.base_unit_cost``
    so a pack purchase doesn't inflate the apparent cost)."""
    from apps.purchasing.models import PurchaseLine, PurchaseOrder

    return (
        PurchaseLine.objects.filter(variant_id=OuterRef("pk"), unit_factor__gt=0)
        .exclude(purchase_order__status=PurchaseOrder.Status.CANCELLED)
        .order_by("-created_at", "-id")
        .annotate(_base_cost=F("unit_cost") / F("unit_factor"))
        .values("_base_cost")[:1]
    )


def _priced_costed_markups(category_ids=None):
    """Markup percents [(price - cost) / cost * 100] for every product that has
    BOTH a known base-unit purchase cost and a sale price, optionally narrowed to
    those sharing any of ``category_ids``.

    Services, made-to-order/prepared items (their cost comes from a recipe, not a
    purchase), archived products, and zero/negative cost lines are excluded so
    they don't skew the figure."""
    from apps.catalog.models import ProductVariant

    variants = ProductVariant.objects.filter(
        unit_price__gt=0,
        product__is_service=False,
        product__is_prepared=False,
        product__archived_at__isnull=True,
    )
    if category_ids:
        variants = variants.filter(product__categories__in=list(category_ids))

    # Select the pk too and dedupe by it in Python: a category filter joins the
    # M2M, so a product in several of the matched categories would otherwise be
    # counted once per matching category and skew the median toward multi-category
    # products. Doing it here (not via DISTINCT) keeps it DB-agnostic and avoids
    # collapsing genuinely distinct variants that happen to share a price+cost.
    rows = (
        variants.annotate(
            _cost=Subquery(
                _latest_base_cost_subquery(),
                output_field=DecimalField(max_digits=18, decimal_places=6),
            )
        )
        .filter(_cost__gt=0)
        .values_list("pk", "unit_price", "_cost")[:_MARKUP_SAMPLE_CAP]
    )

    markups = []
    seen = set()
    for pk, price, cost in rows:
        if pk in seen or price is None or cost is None or cost <= 0:
            continue
        seen.add(pk)
        markups.append((Decimal(price) - Decimal(cost)) / Decimal(cost) * Decimal(100))
    return markups


def _median(values):
    values = sorted(values)
    count = len(values)
    middle = count // 2
    if count % 2:
        return values[middle]
    return (values[middle - 1] + values[middle]) / Decimal(2)


# "Too little data to trust" is a real, cacheable answer, so it needs its own
# marker: a bare ``None`` is indistinguishable from a cache miss.
_NO_MARKUP = "__none__"


def _markup_cache_key(category_ids, min_points):
    version = catalog_version()
    if version is None:
        return None
    scope = ",".join(str(cid) for cid in sorted(category_ids)) if category_ids else "*"
    return f"purchasing:markup:v{version}:p{min_points}:{scope}"


def _median_markup_percent(category_ids=None, *, min_points=_MIN_DATA_POINTS):
    """The median markup percent over the matching priced+costed products, clamped
    to the guard rails, or ``None`` when there are fewer than ``min_points`` of
    them (too little data to trust).

    Cached against the catalog version, because this is a statistic about the
    whole catalogue and the question is asked per keystroke-ish: pricing a
    purchase line resolves a category markup and, when the category is too
    thin, the shop-wide one as well — each a scan of every priced variant
    carrying a correlated "latest purchase cost" subquery. The field export
    measured ``pricing-suggestion`` at 348ms, 247ms of it database time, for
    two or three queries. The answer only changes when the catalogue does, and
    the catalog version already moves on every product, price and stock write,
    so a stale markup is not reachable. Fail-open: no cache, same computation.
    """
    key = _markup_cache_key(category_ids, min_points)

    def compute():
        markups = _priced_costed_markups(category_ids)
        if len(markups) < min_points:
            return _NO_MARKUP
        median = _median(markups)
        clamped = max(_MIN_MARKUP_PERCENT, min(_MAX_MARKUP_PERCENT, median))
        # Stored as a string: a Decimal has to survive whatever the cache
        # backend serialises with, and this one is read on the checkout-adjacent
        # purchasing path.
        return str(clamped)

    if key is None:
        value = compute()
    else:
        value = get_or_compute_single_flight(key, compute, _markup_cache_ttl())
    if value == _NO_MARKUP:
        return None
    return Decimal(value)


def _markup_cache_ttl() -> int:
    return int(getattr(settings, "POINTY_MARKUP_CACHE_TTL", 0))


def shop_typical_markup_percent():
    """The shop's median markup percent over its whole catalogue, or ``None`` when
    there's too little data. See :func:`_median_markup_percent`."""
    return _median_markup_percent()


def category_markup_percent(category_ids):
    """The median markup percent over products sharing any of ``category_ids`` —
    that category's real pricing strategy — or ``None`` when the category has too
    little data to trust on its own."""
    if not category_ids:
        return None
    return _median_markup_percent(category_ids, min_points=_MIN_CATEGORY_DATA_POINTS)


def _resolve_markup(category_ids=None):
    """Pick the most specific markup we have data for, most-specific first: the
    product's own category (its actual pricing strategy), then the shop-wide
    median, then the default. Returns ``(markup_percent, source)``."""
    category_markup = category_markup_percent(category_ids)
    if category_markup is not None:
        return category_markup, "category"
    shop_markup = shop_typical_markup_percent()
    if shop_markup is not None:
        return shop_markup, "shop"
    return DEFAULT_MARKUP_PERCENT, "default"


def suggest_sale_price(unit_cost, *, markup=None):
    """Suggest a sale price for a product bought at ``unit_cost`` (per base unit),
    applying the shop's typical markup (or the default fallback) and snapping the
    result to a real quarter-dinar denomination. Returns a ``Decimal`` (a multiple
    of :data:`PRICE_STEP`), or ``None`` when the cost is missing/<= 0 (no sensible
    price can be derived from a zero cost). Pass ``markup`` to reuse an
    already-computed markup and skip the (non-trivial) median query."""
    try:
        cost = Decimal(str(unit_cost))
    except (TypeError, ValueError, ArithmeticError):
        return None
    if cost <= 0:
        return None
    if markup is None:
        markup = shop_typical_markup_percent()
    if markup is None:
        markup = DEFAULT_MARKUP_PERCENT
    target = cost * (Decimal(1) + markup / Decimal(100))
    price = _snap_to_step(target)
    # A positively-costed item must never be suggested free, and snapping to the
    # nearest step must never round the price below cost (turning a markup into a
    # loss) — step up to the next denomination at or above cost when it does.
    if price < PRICE_STEP:
        price = PRICE_STEP.quantize(_CENT)
    if price < cost:
        price = _snap_to_step(cost, rounding=ROUND_CEILING)
    return price


def pricing_suggestion(unit_cost, *, category_ids=None):
    """A JSON-friendly suggestion bundle for the reprice dialog and the AI tool
    layer: the suggested price, the markup applied, and whether that markup was
    inferred from the product's category, the shop's wider data, or the default
    fallback. Computes the markup ONCE."""
    markup, source = _resolve_markup(category_ids)
    price = suggest_sale_price(unit_cost, markup=markup)
    return {
        "suggested_price": None if price is None else f"{price:.2f}",
        "markup_percent": f"{markup:.2f}",
        "markup_source": source,
    }
