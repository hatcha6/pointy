"""Which variants are running low — the one answer every surface reads.

Notifications, the dashboard, the inventory and reorder reports and the
assistant's tools all ask the same question, and before this module each asked
it of ``StockItem.reorder_level`` row by row. That gave a variant kept in two
locations two verdicts (and two alerts sharing one fingerprint), and it judged
every row against a 5 nobody had chosen.

The rules, in one place:

* The threshold lives on the variant (``ProductVariant.low_stock_threshold``).
  A blank threshold means the variant is not watched: it is never low, never
  reported out of stock, never suggested for reordering.
* It is compared with the **shop-wide** position: on hand summed across every
  line the shop keeps (``stocked_lines``), not location by location.
* A variant is low when that total is at or below its threshold, so a
  threshold of 0 still warns when the shelf empties.
"""

from decimal import Decimal

from django.db.models import (
    DecimalField,
    Exists,
    ExpressionWrapper,
    F,
    OuterRef,
    Subquery,
    Sum,
    Value,
)
from django.db.models.functions import Coalesce, Greatest

from apps.catalog.models import ProductVariant

from .models import StockItem, Warehouse

QTY = DecimalField(max_digits=14, decimal_places=3)
ZERO_QTY = Value(Decimal("0"), output_field=QTY)


def stocked_lines():
    """The stock lines a shop keeps, counts and reorders: in a place it sells
    or stores from — not the transit warehouse every transfer opens, not a
    closed location — of a product it still stocks. A service, a made-to-order
    dish or a provider's system product holds no shelf stock to run low; an
    archived or deactivated product is not reordered. Left in, the transit
    rows alone (never any stock) read as a page of things to buy that nobody
    can buy."""
    return StockItem.objects.filter(
        warehouse__is_active=True,
        variant__is_active=True,
        variant__product__is_active=True,
        variant__product__archived_at__isnull=True,
        variant__product__is_system=False,
        variant__product__is_service=False,
        variant__product__is_prepared=False,
    ).exclude(warehouse__kind=Warehouse.Kind.TRANSIT)


def _line_total(field):
    lines = (
        stocked_lines()
        .filter(variant_id=OuterRef("pk"))
        .order_by()
        .values("variant_id")
        .annotate(total=Sum(field))
        .values("total")
    )
    return Coalesce(Subquery(lines, output_field=QTY), ZERO_QTY, output_field=QTY)


def watched_variants():
    """Every variant with a threshold that the shop actually keeps on a shelf,
    annotated with its shop-wide ``on_hand``, ``expected`` and ``committed``
    quantities.

    One correlated sum per watched variant, and only watched variants are
    visited — a catalog of 30k items with a dozen thresholds reads a dozen."""
    return (
        ProductVariant.objects.filter(low_stock_threshold__isnull=False)
        .filter(Exists(stocked_lines().filter(variant_id=OuterRef("pk"))))
        .annotate(
            on_hand=_line_total("quantity_on_hand"),
            expected=_line_total("quantity_expected"),
            committed=_line_total("quantity_committed"),
        )
    )


def low_stock_variants():
    """Watched variants at or below their threshold. Unordered: callers sort."""
    return watched_variants().filter(on_hand__lte=F("low_stock_threshold"))


#: ``suggested_reorder_quantity`` as SQL over ``watched_variants()``, so a
#: headline can be summed over every line rather than the ones a table printed.
SUGGESTED_REORDER = Greatest(
    ExpressionWrapper(
        F("low_stock_threshold") * 2 - F("on_hand") - F("expected"),
        output_field=QTY,
    ),
    ZERO_QTY,
    output_field=QTY,
)


def suggested_reorder_quantity(variant):
    """Back to twice the threshold, less what is on hand and on the way, never
    below nothing — so an owner who already ordered does not order twice."""
    threshold = variant.low_stock_threshold or Decimal("0")
    return max(
        threshold * 2 - (variant.on_hand or 0) - (variant.expected or 0),
        Decimal("0"),
    )
