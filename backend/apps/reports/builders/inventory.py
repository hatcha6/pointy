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

from django.db.models import Count, F, Sum

from apps.catalog.models import Product
from apps.inventory.models import StockItem, StockMovement
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


def inventory_status(context):
    """Stock on hand at the close of the period, valued at what it cost.

    Two claims live in this report and they must never be confused. "Stock at
    30 September" is a historical position, read from the ledger's running
    balances. "Stock right now" is the live bin value. A report run over a past
    period states the first; one run to today states the second, and they are
    the same number by construction on the day they meet.

    Retail value is stated only for a live run, and deliberately. Retail is
    quantity times *today's* selling price; applied to a past quantity it is a
    number that was never true on any day — the goods were not on the shelf at
    that price. Cost is the figure the accounts need, and it is the one the
    ledger can honestly give for a past date.
    """
    as_of = context.as_of_date()
    historical = context.is_historical()

    stock = StockItem.objects.select_related("variant", "variant__product")
    cost_position = stock_position_by_variant(as_of=as_of if historical else None)
    cost_value = stock_cost_value(as_of=as_of if historical else None)

    limit = context.row_limit("inventory_items")
    stock_rows = bounded_queryset(
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
    for item in stock_rows.rows:
        on_hand, cost = cost_position.get(
            item.variant_id, (Decimal("0"), Decimal("0.00"))
        )
        if not historical:
            on_hand = item.quantity_on_hand
        row = {
            "product_name": item.variant.full_name,
            "sku": item.variant.sku,
            "quantity_on_hand": quantity(on_hand),
            "quantity_committed": quantity(item.quantity_committed),
            "quantity_expected": quantity(item.quantity_expected),
            "reorder_level": quantity(item.reorder_level),
            "unit_cost": money(cost / on_hand if on_hand else Decimal("0")),
            "cost_value": money(cost),
        }
        if not historical:
            row["retail_value"] = money(
                decimal_from(on_hand) * item.variant.unit_price
            )
        rows.append(row)

    figures = {
        "cost_stock_value": money(cost_value),
        "product_count": Product.objects.count(),
        "stock_item_count": stock.count(),
        "low_stock_count": stock.filter(quantity_on_hand__lte=F("reorder_level")).count(),
        "out_of_stock_count": stock.filter(quantity_on_hand__lte=0).count(),
    }
    columns = [
        Column("product_name"),
        Column("sku"),
        Column("quantity_on_hand", ColumnType.QUANTITY),
        Column("quantity_committed", ColumnType.QUANTITY),
        Column("quantity_expected", ColumnType.QUANTITY),
        Column("reorder_level", ColumnType.QUANTITY),
        Column("unit_cost", ColumnType.MONEY),
        Column("cost_value", ColumnType.MONEY, total=True),
    ]
    section_totals = {"cost_value": money(cost_value)}
    if not historical:
        retail_value = _retail_value(stock)
        figures["retail_stock_value"] = money(retail_value)
        figures["unrealised_margin"] = money(
            decimal_from(retail_value) - decimal_from(cost_value)
        )
        columns.append(Column("retail_value", ColumnType.MONEY, total=True))
        section_totals["retail_value"] = money(retail_value)

    return {
        "summary": figures,
        "sections": [
            context.metrics(figures),
            _stock_movement_section(context),
            report_section(
                "inventory_items",
                columns,
                rows,
                total_count=stock_rows.total_count,
                limit=stock_rows.limit,
                # The full totals, so a truncated schedule still foots to the
                # figure above it and says so.
                totals=section_totals,
            ),
        ],
        "notes": [
            note("stock_as_of", date=as_of),
            note("stock_valued_at_cost"),
            note("stock_historical" if historical else "stock_live"),
        ],
    }


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


def _retail_value(stock):
    total = stock.aggregate(
        total=Sum(F("quantity_on_hand") * F("variant__unit_price"))
    )["total"]
    return decimal_from(total)


def stock_movements(context):
    movements = StockMovement.objects.select_related(
        "variant",
        "variant__product",
        "created_by",
    )
    movements = in_window(movements, context.period)

    limit = context.row_limit("stock_movements")
    movement_rows = bounded_queryset(
        with_variant_labels(movements.order_by("-created_at", "-id")),
        limit=limit,
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
    quantity_moved = movements.aggregate(quantity=Sum("quantity"))["quantity"]
    shrinkage = shrinkage_value(context.period.start_date, context.period.end_date)
    valued = stock_movement_values(context.period.start_date, context.period.end_date)

    figures = {
        "movement_count": movements.count(),
        "quantity_moved": quantity(quantity_moved),
        "received_value": money(valued["received_value"]),
        "issued_value": money(valued["issued_value"]),
        "shrinkage_total": money(shrinkage),
    }
    return {
        "summary": figures,
        "sections": [
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
            ),
            report_section(
                "stock_movements",
                [
                    Column("created_at", ColumnType.DATETIME),
                    Column("product_name"),
                    Column("sku"),
                    Column("movement_type", ColumnType.CHOICE),
                    Column("quantity", ColumnType.QUANTITY, total=True),
                    Column("on_hand_before", ColumnType.QUANTITY),
                    Column("on_hand_after", ColumnType.QUANTITY),
                    Column("created_by"),
                    Column("note"),
                ],
                rows,
                total_count=movement_rows.total_count,
                limit=movement_rows.limit,
            ),
        ],
        "notes": [note("shrinkage_is_count_and_adjustment"), note("movement_quantity_base_units")],
    }


def reorder_items(context):
    stock = StockItem.objects.select_related("variant", "variant__product").filter(
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
    suggested_units = Decimal("0")
    for item in bounded.rows:
        # Restock back to twice the reorder level, counting stock already on
        # the way so the owner does not double-order.
        suggested = max(
            item.reorder_level * 2 - item.quantity_on_hand - item.quantity_expected,
            Decimal("0"),
        )
        suggested_units += suggested
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

    figures = {
        "reorder_item_count": bounded.total_count,
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
            ),
        ],
        "notes": [note("reorder_target_is_twice_level"), note("reorder_counts_incoming")],
    }


__all__ = ["inventory_status", "reorder_items", "stock_movements"]
