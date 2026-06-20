"""Suggest a retail sale price from a purchase cost, using the shop's own typical
markup so a freshly-created product is priced consistently with the rest of the
catalog (instead of a blind fixed margin).

Used by the AI when it creates a product mid purchase-order (e.g. an invoice line
with no matching product), but it has no AI dependency and is reusable anywhere.
"""

from decimal import Decimal, ROUND_HALF_UP

from django.db.models import DecimalField, F, OuterRef, Subquery

# Fallback markup when the shop has too little cost+price history to infer one.
DEFAULT_MARKUP_PERCENT = Decimal("30")
# Need at least this many priced+costed products before we trust an inferred markup.
_MIN_DATA_POINTS = 5
# Cap the sample so the median scan stays cheap on a huge catalogue.
_MARKUP_SAMPLE_CAP = 1000
# Guard rails on an inferred markup so one weird outlier set can't price wildly.
_MIN_MARKUP_PERCENT = Decimal("1")
_MAX_MARKUP_PERCENT = Decimal("500")
_CENT = Decimal("0.01")


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


def shop_typical_markup_percent():
    """The shop's median markup percent over products that have BOTH a known
    purchase cost and a sale price, or ``None`` when there's too little data.

    Markup = (price - cost) / cost * 100. Services, made-to-order/prepared items
    (their cost comes from a recipe, not a purchase), archived products, and
    zero/negative cost lines are excluded so they don't skew the figure."""
    from apps.catalog.models import ProductVariant

    rows = (
        ProductVariant.objects.filter(
            unit_price__gt=0,
            product__is_service=False,
            product__is_prepared=False,
            product__archived_at__isnull=True,
        )
        .annotate(
            _cost=Subquery(
                _latest_base_cost_subquery(),
                output_field=DecimalField(max_digits=18, decimal_places=6),
            )
        )
        .filter(_cost__gt=0)
        .values_list("unit_price", "_cost")[:_MARKUP_SAMPLE_CAP]
    )

    markups = []
    for price, cost in rows:
        if price is None or cost is None or cost <= 0:
            continue
        markups.append((Decimal(price) - Decimal(cost)) / Decimal(cost) * Decimal(100))

    if len(markups) < _MIN_DATA_POINTS:
        return None

    markups.sort()
    count = len(markups)
    middle = count // 2
    if count % 2:
        median = markups[middle]
    else:
        median = (markups[middle - 1] + markups[middle]) / Decimal(2)
    return max(_MIN_MARKUP_PERCENT, min(_MAX_MARKUP_PERCENT, median))


def suggest_sale_price(unit_cost, *, markup=None):
    """Suggest a sale price for a product bought at ``unit_cost`` (per base unit),
    applying the shop's typical markup (or the default fallback). Returns a
    ``Decimal`` rounded to the cent, or ``None`` when the cost is missing/<= 0
    (no sensible price can be derived from a zero cost). Pass ``markup`` to reuse
    an already-computed shop markup and skip the (non-trivial) median query."""
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
    price = cost * (Decimal(1) + markup / Decimal(100))
    return price.quantize(_CENT, rounding=ROUND_HALF_UP)


def pricing_suggestion(unit_cost):
    """A JSON-friendly suggestion bundle for the AI tool layer: the suggested
    price, the markup applied, and whether that markup was inferred from the
    shop's data or the default fallback. Computes the shop markup ONCE."""
    inferred_markup = shop_typical_markup_percent()
    markup = inferred_markup if inferred_markup is not None else DEFAULT_MARKUP_PERCENT
    price = suggest_sale_price(unit_cost, markup=markup)
    return {
        "suggested_price": None if price is None else f"{price:.2f}",
        "markup_percent": f"{markup:.2f}",
        "markup_source": "shop" if inferred_markup is not None else "default",
    }
