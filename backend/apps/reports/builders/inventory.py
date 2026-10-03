"""What is on the shelf, what it cost, and what moved.

The stock report used to answer only one of those and only for right now. It
took a period and ignored it, so year-end's closing stock — the one number the
accounts cannot be prepared without — was obtainable on 31 December and never
again. And its schedule listed retail value per line under a *cost* total, so
the supporting table could not be added up to the figure it supported.

Both are fixed here by asking the valued ledger the questions it could always
answer: what each variant's position was at the close of a given day, and what
it was worth.
"""

from datetime import timedelta
from decimal import Decimal

from django.db.models import (
    Count,
    DecimalField,
    ExpressionWrapper,
    F,
    Max,
    Prefetch,
    Q,
    Sum,
    Value,
)
from django.db.models.functions import Abs, Coalesce, Greatest

from apps.catalog.models import ProductVariant, VariantOptionValue
from apps.inventory.consignment import custody_units_by_variant
from apps.inventory.models import StockItem, StockMovement, Warehouse
from apps.inventory.reporting import (
    shrinkage_value,
    stock_cost_value,
    stock_movement_values,
    stock_position_by_variant,
)

from ..sections import (
    Column,
    ColumnType,
    bounded_queryset,
    decimal_from,
    money,
    note,
    quantity,
    report_section,
)
from .scope import in_window, with_variant_labels

QTY = DecimalField(max_digits=16, decimal_places=3)


def stocked_lines():
    """The stock lines a shop keeps, counts and reorders: in a place it sells
    or stores from — not the transit warehouse every transfer opens, not a
    closed location — of a product it still stocks. A service, a made-to-order
    dish or a provider's system product holds no shelf stock to run low; an
    archived or deactivated product is not reordered. Left in, the transit
    rows alone (reorder level 5, never any stock) read as a page of things to
    buy that nobody can buy."""
    return StockItem.objects.filter(
        warehouse__is_active=True,
        variant__is_active=True,
        variant__product__is_active=True,
        variant__product__archived_at__isnull=True,
        variant__product__is_system=False,
        variant__product__is_service=False,
        variant__product__is_prepared=False,
    ).exclude(warehouse__kind=Warehouse.Kind.TRANSIT)


def inventory_status(context):
    """Stock on hand at the close of the period, valued at what it cost.

    Two claims live in this report and they must never be confused. "Stock at
    30 September" is a historical position, read from the ledger's running
    balances. "Stock right now" is the live shelf, valued from the live bins.
    A report run over a past period states the first; one run to today states
    the second, and they are the same number by construction on the day they
    meet.

    Retail value is stated only for a live run, and deliberately. Retail is
    quantity times *today's* selling price; applied to a past quantity it is a
    number that was never true on any day — the goods were not on the shelf at
    that price. Cost is the figure the accounts need, and it is the one the
    ledger can honestly give for a past date. The same goes for what is low or
    out of stock: those are today's shelves against today's reorder levels,
    so a past period states neither rather than today's under its date.

    Retail is the shop's own goods at their selling price: consigned articles
    are somebody else's, and stock below zero holds no goods to value.
    """
    as_of = context.as_of_date()
    historical = context.is_historical()

    cost_position = stock_position_by_variant(as_of=as_of if historical else None)
    cost_value = stock_cost_value(as_of=as_of if historical else None)
    shelf = None if historical else _live_shelf()
    if historical:
        held = [
            variant_id
            for variant_id, (held_quantity, _value) in cost_position.items()
            if held_quantity > 0
        ]
    else:
        held = [
            variant_id
            for variant_id, line in shelf.items()
            if decimal_from(line["on_hand"]) > 0
        ]

    figures = {
        "cost_stock_value": money(cost_value),
        # What was on the shelf at the date: the variants holding stock, and
        # the products they belong to. It used to count every product in the
        # catalogue and every stock row — archived, service and transit rows
        # included — today, under a past date.
        "product_count": (
            ProductVariant.objects.filter(pk__in=held)
            .values("product_id")
            .distinct()
            .count()
        ),
        "stock_item_count": len(held),
    }
    retail_value = None
    if not historical:
        lines = stocked_lines()
        figures["low_stock_count"] = lines.filter(
            quantity_on_hand__lte=F("reorder_level")
        ).count()
        figures["out_of_stock_count"] = lines.filter(quantity_on_hand__lte=0).count()
        retail_value = _retail_value(shelf)
        figures["retail_stock_value"] = money(retail_value)
        figures["unrealised_margin"] = money(
            decimal_from(retail_value) - decimal_from(cost_value)
        )

    sections = [context.metrics(figures)]
    if context.wants_detail():
        sections.extend(
            [
                _stock_movement_section(context),
                _inventory_items_section(
                    context,
                    cost_position,
                    shelf,
                    cost_value=cost_value,
                    retail_value=retail_value,
                ),
            ]
        )
    return {
        "summary": figures,
        "sections": sections,
        "notes": [
            note("stock_as_of", date=as_of),
            note("stock_valued_at_cost"),
            note("stock_historical" if historical else "stock_live"),
        ],
    }


def _live_shelf():
    """``{variant_id: line}`` — what is on the shelf now, per variant, summed
    across every location it sits in: on hand, spoken for, on its way, the
    reorder level of the lines the shop keeps, and the consigned units among
    it. The quantity is the shelf's own, not the valuation's: an article whose
    cost was never recorded is still on the shelf and still sells."""
    keeps = stocked_lines().values("pk")
    shelf = {
        row["variant_id"]: row
        for row in StockItem.objects.order_by().values("variant_id").annotate(
            on_hand=Sum("quantity_on_hand"),
            committed=Sum("quantity_committed"),
            expected=Sum("quantity_expected"),
            reorder=Sum("reorder_level", filter=Q(pk__in=keeps)),
            unit_price=Max("variant__unit_price"),
        )
    }
    for variant_id, consigned in custody_units_by_variant().items():
        if variant_id in shelf:
            shelf[variant_id]["consigned"] = consigned
    return shelf


def _owned(line):
    return decimal_from(line["on_hand"]) - line.get("consigned", 0)


def _retail_value(shelf):
    """The shop's own goods on the shelf at today's selling prices."""
    return sum(
        (
            max(_owned(line), Decimal("0")) * decimal_from(line["unit_price"])
            for line in shelf.values()
        ),
        Decimal("0"),
    ).quantize(Decimal("0.01"))


def _inventory_items_section(
    context, cost_position, shelf, *, cost_value, retail_value
):
    """One line per variant at the close of the period, valued at cost — and,
    when the period ends today, at its selling price and with today's
    committed, expected and reorder figures (``shelf`` is ``None`` for a past
    period, which states none of them).

    One line per *variant*, the unit the valuation is kept in. It used to be
    one per stock row — a variant in the shop and the store room, plus the
    empty transit row every transfer opens, printed three times, each time
    carrying the variant's whole cost, so the column added up to three times
    the figure it supported. Largest value first, so a cut schedule keeps the
    lines that matter.
    """
    historical = shelf is None
    if historical:
        lines = {
            variant_id: {"on_hand": held_quantity}
            for variant_id, (held_quantity, _value) in cost_position.items()
        }
    else:
        lines = shelf
    zero = (Decimal("0"), Decimal("0.00"))
    ordered = sorted(
        (
            variant_id
            for variant_id in set(lines) | set(cost_position)
            # A variant with nothing on hand and nothing at cost is not a line
            # of the schedule — a bin left at zero by its last sale.
            if decimal_from(lines.get(variant_id, {}).get("on_hand"))
            or cost_position.get(variant_id, zero)[1]
        ),
        key=lambda variant_id: (
            -cost_position.get(variant_id, zero)[1],
            -decimal_from(lines.get(variant_id, {}).get("on_hand")),
            variant_id,
        ),
    )
    limit = context.row_limit("inventory_items")
    kept = ordered[:limit]
    variants = {
        variant.pk: variant
        for variant in ProductVariant.objects.filter(pk__in=kept)
        .select_related("product")
        .prefetch_related(
            Prefetch(
                "option_values",
                queryset=VariantOptionValue.objects.select_related("option"),
            )
        )
    }

    rows = []
    for variant_id in kept:
        variant = variants.get(variant_id)
        line = lines.get(variant_id, {"on_hand": Decimal("0")})
        cost = cost_position.get(variant_id, zero)[1]
        # The shop's own units: consigned ones sit in the quantity at no cost,
        # and dividing by them stated a 1,200 handset at 360.
        owned = _owned(line)
        row = {
            "product_name": variant.full_name if variant else "",
            "sku": variant.sku if variant else "",
            "quantity_on_hand": quantity(line["on_hand"]),
            "unit_cost": money(cost / owned if owned > 0 else Decimal("0")),
            "cost_value": money(cost),
        }
        if not historical:
            row.update(
                {
                    "quantity_committed": quantity(line.get("committed")),
                    "quantity_expected": quantity(line.get("expected")),
                    "reorder_level": quantity(line.get("reorder")),
                    "retail_value": money(
                        max(owned, Decimal("0")) * decimal_from(line.get("unit_price"))
                    ),
                }
            )
        rows.append(row)

    columns = [
        Column("product_name"),
        Column("sku"),
        Column("quantity_on_hand", ColumnType.QUANTITY),
    ]
    if not historical:
        columns.extend(
            [
                Column("quantity_committed", ColumnType.QUANTITY),
                Column("quantity_expected", ColumnType.QUANTITY),
                Column("reorder_level", ColumnType.QUANTITY),
            ]
        )
    columns.extend(
        [
            Column("unit_cost", ColumnType.MONEY),
            Column("cost_value", ColumnType.MONEY, total=True),
        ]
    )
    section_totals = {"cost_value": money(cost_value)}
    if not historical:
        columns.append(Column("retail_value", ColumnType.MONEY, total=True))
        section_totals["retail_value"] = money(retail_value)
    return report_section(
        "inventory_items",
        columns,
        rows,
        total_count=len(ordered),
        limit=limit,
        # The full totals, so a truncated schedule still foots to the figure
        # above it and says so.
        totals=section_totals,
    )


def _stock_movement_section(context):
    """Opening, in, out, closing — the four figures a stock total is tested by.

    A closing stock value nobody can reconcile to last period's is an assertion,
    not a schedule. These are the same ledger rows the closing figure is read
    from, grouped by what caused them.
    """
    period = context.period
    movement = stock_movement_values(period.start_date, period.end_date)
    opening = stock_cost_value(as_of=period.start_date - timedelta(days=1))
    closing = stock_cost_value(
        as_of=period.end_date if context.is_historical() else None
    )
    rows = [
        {"line": "opening_value", "value": money(opening)},
        {"line": "received_value", "value": money(movement["received_value"])},
        {"line": "issued_value", "value": money(-movement["issued_value"])},
        {"line": "closing_value", "value": money(closing)},
        {
            "line": "unexplained_difference",
            "value": money(
                decimal_from(closing)
                - decimal_from(opening)
                - decimal_from(movement["received_value"])
                + decimal_from(movement["issued_value"])
            ),
        },
    ]
    return report_section(
        "stock_reconciliation",
        [Column("line", ColumnType.LABEL), Column("value", ColumnType.MONEY)],
        rows,
    )


def stock_movements(context):
    movements = StockMovement.objects.select_related(
        "variant",
        "variant__product",
        "created_by",
    )
    movements = in_window(movements, context.period)

    mix_rows = bounded_queryset(
        movements.values("movement_type")
        .annotate(quantity=Sum("quantity"), count=Count("id"))
        .order_by("movement_type"),
        limit=context.row_limit("movement_mix"),
    )
    mix = [
        {
            "movement_type": row["movement_type"],
            "quantity": quantity(row["quantity"]),
            "count": row["count"],
        }
        for row in mix_rows.rows
    ]
    # Units that moved on or off a shelf: the change each movement made to
    # what is on hand. Summed off the movement's own quantity this took in
    # stock merely ordered ("expected"), cancelled orders and damaged goods
    # that never reached the shelf, so a 100-unit order received read as 200.
    quantity_moved = movements.aggregate(
        quantity=Coalesce(
            Sum(Abs(F("on_hand_after") - F("on_hand_before"))),
            Value(Decimal("0")),
            output_field=QTY,
        )
    )["quantity"]
    shrinkage = shrinkage_value(context.period.start_date, context.period.end_date)
    valued = stock_movement_values(context.period.start_date, context.period.end_date)

    figures = {
        "movement_count": movements.count(),
        "quantity_moved": quantity(quantity_moved),
        "received_value": money(valued["received_value"]),
        "issued_value": money(valued["issued_value"]),
        "shrinkage_total": money(shrinkage),
    }
    sections = [
        context.metrics(figures),
        report_section(
            "movement_mix",
            [
                Column("movement_type", ColumnType.CHOICE),
                Column("count", ColumnType.COUNT, total=True),
                Column("quantity", ColumnType.QUANTITY, total=True),
            ],
            mix,
            total_count=mix_rows.total_count,
            limit=mix_rows.limit,
            totals={"count": figures["movement_count"]},
        ),
    ]
    if context.wants_detail():
        sections.append(_movement_list_section(movements, context))
    return {
        "summary": figures,
        "sections": sections,
        "notes": [note("shrinkage_is_count_and_adjustment"), note("movement_quantity_base_units")],
    }


def _movement_list_section(movements, context):
    """Every movement in the period, newest first."""
    movement_rows = bounded_queryset(
        with_variant_labels(movements.order_by("-created_at", "-id")),
        limit=context.row_limit("stock_movements"),
    )
    rows = [
        {
            "created_at": movement.created_at.isoformat(),
            "product_name": movement.variant.full_name,
            "sku": movement.variant.sku,
            "movement_type": movement.movement_type,
            "quantity": quantity(movement.quantity),
            "on_hand_before": quantity(movement.on_hand_before),
            "on_hand_after": quantity(movement.on_hand_after),
            "created_by": (
                movement.created_by.username if movement.created_by_id else ""
            ),
            "note": movement.note,
        }
        for movement in movement_rows.rows
    ]
    return report_section(
        "stock_movements",
        [
            Column("created_at", ColumnType.DATETIME),
            Column("product_name"),
            Column("sku"),
            Column("movement_type", ColumnType.CHOICE),
            # Not totalled: ins and outs share the column unsigned, so its sum
            # is no quantity at all.
            Column("quantity", ColumnType.QUANTITY),
            Column("on_hand_before", ColumnType.QUANTITY),
            Column("on_hand_after", ColumnType.QUANTITY),
            Column("created_by"),
            Column("note"),
        ],
        rows,
        total_count=movement_rows.total_count,
        limit=movement_rows.limit,
    )


#: Back to twice the reorder level, less what is on hand and on the way, never
#: below nothing — the row's own arithmetic, as SQL, so the headline can be
#: summed over every line rather than over the ones the table printed.
_SUGGESTED_QUANTITY = Greatest(
    ExpressionWrapper(
        F("reorder_level") * 2 - F("quantity_on_hand") - F("quantity_expected"),
        output_field=QTY,
    ),
    Value(Decimal("0"), output_field=QTY),
    output_field=QTY,
)


def reorder_items(context):
    stock = stocked_lines().select_related("variant", "variant__product").filter(
        quantity_on_hand__lte=F("reorder_level"),
    )
    limit = context.row_limit("reorder_items")
    bounded = bounded_queryset(
        with_variant_labels(
            stock.order_by(
                "quantity_on_hand",
                "variant__product__name",
                "variant__name",
            )
        ),
        limit=limit,
    )
    rows = []
    for item in bounded.rows:
        # Restock back to twice the reorder level, counting stock already on
        # the way so the owner does not double-order.
        suggested = max(
            item.reorder_level * 2 - item.quantity_on_hand - item.quantity_expected,
            Decimal("0"),
        )
        rows.append(
            {
                "product_name": item.variant.full_name,
                "sku": item.variant.sku,
                "quantity_on_hand": quantity(item.quantity_on_hand),
                "quantity_expected": quantity(item.quantity_expected),
                "reorder_level": quantity(item.reorder_level),
                "suggested_quantity": quantity(suggested),
            }
        )

    # Counted and summed over every line that needs reordering, not over the
    # lines the table kept: summed from the rows, a summary cut to ten stated
    # ten lines' worth of units, and a headline-only pass stated none at all.
    suggested_units = stock.aggregate(
        total=Coalesce(Sum(_SUGGESTED_QUANTITY), Value(Decimal("0")), output_field=QTY)
    )["total"]
    figures = {
        "reorder_item_count": stock.count(),
        "out_of_stock_count": stock.filter(quantity_on_hand__lte=0).count(),
        "suggested_units": quantity(suggested_units),
    }
    return {
        "summary": figures,
        "sections": [
            context.metrics(figures),
            report_section(
                "reorder_items",
                [
                    Column("product_name"),
                    Column("sku"),
                    Column("quantity_on_hand", ColumnType.QUANTITY),
                    Column("quantity_expected", ColumnType.QUANTITY),
                    Column("reorder_level", ColumnType.QUANTITY),
                    Column("suggested_quantity", ColumnType.QUANTITY, total=True),
                ],
                rows,
                total_count=bounded.total_count,
                limit=bounded.limit,
                totals={"suggested_quantity": quantity(suggested_units)},
            ),
        ],
        "notes": [note("reorder_target_is_twice_level"), note("reorder_counts_incoming")],
    }


__all__ = ["inventory_status", "reorder_items", "stock_movements"]
