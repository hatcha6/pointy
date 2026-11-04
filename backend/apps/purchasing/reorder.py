"""«إعادة الطلب»: what to buy next, and the draft order that buys it.

One row per variant, because thresholds and quantities live on variants. Only
watched variants can appear (``apps.inventory.low_stock``): a blank threshold
means the owner never asked, so the queue can never become the whole catalog.

Two kinds of row:

* **low** / **out** — at or below the threshold, exactly the rule every other
  surface uses. Stock already on the way does not hide these: the owner asked
  to see what is low, and the on-order figure sits right beside it.
* **approaching** — above the threshold but about to cross it. The margin is the
  larger of a small fixed cushion (:func:`piece_margin`, the "one or two pieces
  above" a shop expects) and a week of this variant's actual sales, so a fast
  mover shows up while there is still time to order and a slow one only when
  it is genuinely close. Stock on the way counts against the margin here: an
  order that already covers the week is nothing to act on.

The caller can switch approaching rows off and get exactly at-or-below.
"""

from datetime import timedelta
from decimal import ROUND_CEILING, Decimal

from django.db.models import DecimalField, Exists, ExpressionWrapper, F, OuterRef, Subquery, Sum
from django.utils import timezone
from rest_framework import serializers

from apps.catalog.models import ProductVariant
from apps.inventory.low_stock import watched_variants
from apps.sales.models import OrderLine, recognized_sale_q

from .models import PurchaseLine, PurchaseOrder

#: Sales over this many days set the rate. Four whole weeks, so a weekly rhythm
#: (a Friday rush) weighs the same whichever day the screen is opened.
SALES_WINDOW_DAYS = 28
#: How far ahead "about to cross the threshold" looks.
HORIZON_DAYS = 7
#: The screen shows the most urgent rows first; a queue longer than this is not
#: a list anybody works through in one sitting.
QUEUE_LIMIT = 500

_STATUS_RANK = {"out": 0, "low": 1, "approaching": 2}
_QTY = DecimalField(max_digits=18, decimal_places=3)
_COST_PLACES = Decimal("0.000001")


def piece_margin(threshold):
    """The fixed cushion: a fifth of the threshold, between one and two units."""
    return min(max(threshold * Decimal("0.2"), Decimal("1")), Decimal("2"))


def _live_lines():
    return PurchaseLine.objects.exclude(
        purchase_order__status=PurchaseOrder.Status.CANCELLED
    )


def _base_quantity_by_variant(lines):
    """``{variant_id: quantity in base units}`` over one group-by. Quantities are
    in each line's own unit, so they are converted before they are summed."""
    rows = (
        lines.order_by()
        .values("variant_id")
        .annotate(
            total=Sum(
                ExpressionWrapper(F("quantity") * F("unit_factor"), output_field=_QTY)
            )
        )
    )
    return {row["variant_id"]: row["total"] or Decimal("0") for row in rows}


def _weekly_demand():
    since = timezone.now() - timedelta(days=SALES_WINDOW_DAYS)
    sold = _base_quantity_by_variant(
        OrderLine.objects.filter(
            recognized_sale_q("order"),
            order__created_at__gte=since,
            variant__low_stock_threshold__isnull=False,
        )
    )
    weeks_per_window = Decimal(SALES_WINDOW_DAYS) / Decimal(HORIZON_DAYS)
    return {variant_id: total / weeks_per_window for variant_id, total in sold.items()}


def _queue_variants(supplier_id):
    newest_line = (
        _live_lines()
        .filter(variant_id=OuterRef("pk"))
        .order_by("-created_at", "-id")
    )
    variants = (
        watched_variants()
        .filter(merged_into__isnull=True)
        .select_related("product")
        .prefetch_related("option_values__option")
        .annotate(
            last_supplier_id=Subquery(
                newest_line.values("purchase_order__supplier_id")[:1]
            ),
            last_supplier_name=Subquery(
                newest_line.values("purchase_order__supplier__name")[:1]
            ),
        )
    )
    if supplier_id is not None:
        # The catalog's own meaning of "from this supplier" (see
        # ``ProductViewSet._filter_by_supplier``): the product has been on one of
        # the supplier's orders. A colour added since still belongs to them.
        variants = variants.filter(
            Exists(
                _live_lines().filter(
                    purchase_order__supplier_id=supplier_id,
                    variant__product_id=OuterRef("product_id"),
                )
            )
        )
    return variants


def _classify(*, on_hand, expected, threshold, weekly_demand):
    if on_hand <= 0:
        return "out"
    if on_hand <= threshold:
        return "low"
    margin = max(piece_margin(threshold), weekly_demand)
    return "approaching" if on_hand + expected - threshold <= margin else None


def order_quantity(*, on_hand, expected, threshold, weekly_demand):
    """Enough to stand a threshold (or a week of sales, if that is more) clear of
    the threshold, less what is on hand and on the way. Rounded up to a whole
    number, and never nothing: this is what fills the row's quantity, and a
    buyer who ticks a row wants a line on the order."""
    target = threshold + max(threshold, weekly_demand)
    needed = target - on_hand - expected
    return max(needed.to_integral_value(rounding=ROUND_CEILING), Decimal("1"))


def _days_left(*, on_hand, threshold, weekly_demand):
    """Days of sales before the threshold is reached; None with no sales rate."""
    if weekly_demand <= 0 or on_hand <= threshold:
        return None
    daily = weekly_demand / Decimal(HORIZON_DAYS)
    return int((on_hand - threshold) / daily)


def reorder_queue(*, supplier_id=None, include_approaching=True):
    """The rows, most urgent first, plus how many there were before the cap."""
    weekly = _weekly_demand()
    drafts = _base_quantity_by_variant(
        PurchaseLine.objects.filter(
            purchase_order__status=PurchaseOrder.Status.DRAFT,
            variant__low_stock_threshold__isnull=False,
        )
    )
    rows = []
    for variant in _queue_variants(supplier_id):
        threshold = variant.low_stock_threshold
        demand = weekly.get(variant.pk, Decimal("0"))
        status = _classify(
            on_hand=variant.on_hand,
            expected=variant.expected,
            threshold=threshold,
            weekly_demand=demand,
        )
        if status is None or (status == "approaching" and not include_approaching):
            continue
        rows.append(
            {
                "variant": variant.pk,
                "product": variant.product_id,
                "product_name": variant.product.name,
                "variant_name": _variant_label(variant),
                "sku": variant.sku or "",
                "barcode": variant.barcode or "",
                "status": status,
                "on_hand": variant.on_hand,
                "threshold": threshold,
                "expected": variant.expected,
                "in_draft": drafts.get(variant.pk, Decimal("0")),
                "weekly_demand": demand.quantize(Decimal("0.001")),
                "days_left": _days_left(
                    on_hand=variant.on_hand,
                    threshold=threshold,
                    weekly_demand=demand,
                ),
                "order_quantity": order_quantity(
                    on_hand=variant.on_hand,
                    expected=variant.expected,
                    threshold=threshold,
                    weekly_demand=demand,
                ),
                "last_supplier": variant.last_supplier_id,
                "last_supplier_name": variant.last_supplier_name or "",
            }
        )
    rows.sort(
        key=lambda row: (
            _STATUS_RANK[row["status"]],
            -row["weekly_demand"],
            row["product_name"],
            row["variant"],
        )
    )
    return rows[:QUEUE_LIMIT], len(rows)


def _variant_label(variant):
    """Blank for a product's only variant, whose name would repeat the product's."""
    label = variant.name.strip() or variant.option_values_label
    return "" if label == variant.product.name else label


class ReorderLineSerializer(serializers.Serializer):
    variant = serializers.IntegerField(min_value=1)
    quantity = serializers.DecimalField(
        max_digits=12, decimal_places=3, min_value=Decimal("0.001")
    )


class ReorderOrderSerializer(serializers.Serializer):
    supplier = serializers.IntegerField(min_value=1)
    lines = ReorderLineSerializer(many=True, allow_empty=False, max_length=QUEUE_LIMIT)

    def validate_lines(self, lines):
        variant_ids = [line["variant"] for line in lines]
        if len(set(variant_ids)) != len(variant_ids):
            raise serializers.ValidationError("A variant appears twice.")
        return lines


def _last_base_costs(variant_ids, supplier_id):
    """``{variant_id: cost per base unit}``: what this supplier charged last, else
    what anybody did. A variant never bought has no entry, and its line starts
    at zero for the buyer to fill in on the draft."""
    newest = _live_lines().filter(variant_id=OuterRef("pk")).order_by(
        "-created_at", "-id"
    )
    variants = ProductVariant.objects.filter(pk__in=variant_ids).annotate(
        supplier_line=Subquery(
            newest.filter(purchase_order__supplier_id=supplier_id).values("pk")[:1]
        ),
        any_line=Subquery(newest.values("pk")[:1]),
    )
    chosen = {
        variant.pk: variant.supplier_line or variant.any_line
        for variant in variants
        if variant.supplier_line or variant.any_line
    }
    lines = PurchaseLine.objects.only("unit_cost", "unit_factor").in_bulk(
        chosen.values()
    )
    costs = {}
    for variant_id, line_id in chosen.items():
        line = lines[line_id]
        factor = line.unit_factor or Decimal("1")
        costs[variant_id] = (line.unit_cost / factor).quantize(_COST_PLACES)
    return costs


def reorder_order_payload(*, supplier_id, lines):
    """What ``PurchaseOrderSerializer`` takes for a draft of these lines, in base
    units at the last known cost.

    Cost warnings are acknowledged up front: they exist to catch a figure a
    person typed, and here nobody typed one. The buyer reads the draft before it
    goes anywhere, and submitting it is a separate step."""
    costs = _last_base_costs([line["variant"] for line in lines], supplier_id)
    return {
        "supplier": supplier_id,
        "acknowledge_cost_warnings": True,
        "lines": [
            {
                "variant": line["variant"],
                "quantity": str(line["quantity"]),
                "unit_cost": str(costs.get(line["variant"], Decimal("0"))),
            }
            for line in lines
        ],
    }
