"""What the shop sold, what it earned on it, and what it gave away."""

from decimal import Decimal

from django.db.models import Count, DecimalField, Q, Sum, Value
from django.db.models.functions import Coalesce, ExtractHour

from apps.catalog.models import Product
from apps.sales.models import (
    Order,
    OrderAdjustment,
    OrderLine,
    SOLD_COST_EXPRESSION,
    gross_profit_total,
    net_product_rollups,
    rank_rollups,
    returned_items_total,
)

from ..sections import (
    Column,
    ColumnType,
    bounded_queryset,
    bounded_rows,
    decimal_from,
    money,
    note,
    percent,
    quantity,
    report_section,
)
from .scope import (
    daily_totals,
    in_period,
    money_sum,
    order_adjustments,
    settled_orders,
)

#: What the discount-rules breakdown calls the discounts that came from no rule
#: at all — the cashier's own, typed at the till. Arabic, like every other label
#: a shop reads, and named as the authority behind it rather than as a rule.
MANUAL_DISCOUNT_ROW_NAME = "خصم من الكاشير (بدون قاعدة)"

MONEY_FIELD = DecimalField(max_digits=12, decimal_places=2)
QTY_FIELD = DecimalField(max_digits=14, decimal_places=3)
ZERO_QTY = Value(Decimal("0"), output_field=QTY_FIELD)


def sales_summary(context):
    orders = in_period(settled_orders(context.user), context.period)
    adjustments = in_period(order_adjustments(context.user), context.period)
    figures = _sales_figures(orders, adjustments)

    sections = [context.metrics(figures)]
    if context.period.wants_daily_breakdown:
        sections.append(_daily_sales_section(orders, adjustments, context))
    sections.extend(
        [
            _top_products_section(orders, adjustments, context),
            _recent_orders_section(orders, context),
        ]
    )
    return {
        "summary": figures,
        "sections": sections,
        "notes": [
            note("basis_accrual_sales"),
            note("gross_includes_void"),
            note("returns_reverse_margin"),
        ],
    }


def sales_summary_figures(context, *, orders=None, adjustments=None):
    """The headline figures alone — reused by the month-end pack."""
    orders = orders if orders is not None else in_period(
        settled_orders(context.user), context.period
    )
    adjustments = adjustments if adjustments is not None else in_period(
        order_adjustments(context.user), context.period
    )
    return _sales_figures(orders, adjustments)


def _sales_figures(orders, adjustments):
    order_values = orders.aggregate(
        gross_sales=money_sum("subtotal"),
        discount_total=money_sum("discount_total"),
        order_total=money_sum("total"),
        paid_order_count=Count("id", filter=Q(status=Order.Status.PAID)),
        voided_order_count=Count("id", filter=Q(status=Order.Status.VOID)),
        credit_order_count=Count(
            "id",
            filter=Q(sale_type=Order.SaleType.CREDIT, status=Order.Status.OPEN),
        ),
        credit_total=money_sum_filtered(
            "total",
            Q(sale_type=Order.SaleType.CREDIT, status=Order.Status.OPEN),
        ),
    )
    adjustment_values = adjustments.aggregate(
        refund_total=money_sum("amount"),
        return_count=Count(
            "id",
            filter=Q(adjustment_type=OrderAdjustment.AdjustmentType.RETURN),
        ),
    )
    line_values = OrderLine.objects.filter(order__in=orders).aggregate(
        items_rung_up=Coalesce(Sum("quantity"), ZERO_QTY),
        sold_cost=Coalesce(
            Sum(SOLD_COST_EXPRESSION, output_field=MONEY_FIELD),
            Value(Decimal("0.00")),
            output_field=MONEY_FIELD,
        ),
    )
    items_sold = (line_values["items_rung_up"] or Decimal("0")) - returned_items_total(
        adjustments
    )
    net_sales = order_values["order_total"] - adjustment_values["refund_total"]
    # Revenue comes from the same ``Sum(Order.total)`` ``net_sales`` is built
    # from, so the report states one revenue rather than two; a refund reverses
    # margin, not margin *plus* cost, because the goods are restocked.
    profit = gross_profit_total(
        revenue=order_values["order_total"],
        sold_cost=line_values["sold_cost"],
        refund_total=adjustment_values["refund_total"],
        adjustments=adjustments,
    )
    return {
        "gross_sales": money(order_values["gross_sales"]),
        "discount_total": money(order_values["discount_total"]),
        "refund_total": money(adjustment_values["refund_total"]),
        "net_sales": money(net_sales),
        "gross_profit": money(profit),
        "profit_margin_percent": percent(profit, net_sales),
        "cost_of_sales": money(line_values["sold_cost"]),
        "credit_sales_total": money(order_values["credit_total"]),
        "paid_order_count": order_values["paid_order_count"],
        "credit_order_count": order_values["credit_order_count"],
        "voided_order_count": order_values["voided_order_count"],
        "return_count": adjustment_values["return_count"],
        "items_sold": quantity(items_sold),
    }


def money_sum_filtered(field, condition):
    return Coalesce(
        Sum(field, filter=condition),
        Value(Decimal("0.00")),
        output_field=MONEY_FIELD,
    )


def _daily_sales_section(orders, adjustments, context):
    sold = daily_totals(
        orders,
        context.period,
        order_total=money_sum("total"),
        order_count=Count("id"),
    )
    handed_back = daily_totals(adjustments, context.period, refund_total=money_sum("amount"))
    rows = []
    for day in context.period.days():
        sales = sold.get(day, {})
        refunds = handed_back.get(day, {})
        gross = decimal_from(sales.get("order_total"))
        refund = decimal_from(refunds.get("refund_total"))
        if gross == 0 and refund == 0:
            continue
        rows.append(
            {
                "date": day.isoformat(),
                "order_count": sales.get("order_count", 0),
                "gross_sales": money(gross),
                "refund_total": money(refund),
                "net_sales": money(gross - refund),
            }
        )
    return report_section(
        "daily_sales",
        [
            Column("date", ColumnType.DATE),
            Column("order_count", ColumnType.COUNT, total=True),
            Column("gross_sales", ColumnType.MONEY, total=True),
            Column("refund_total", ColumnType.MONEY, total=True),
            Column("net_sales", ColumnType.MONEY, total=True),
        ],
        rows,
    )


def _top_products_section(orders, adjustments, context):
    """Top products by revenue, net of everything handed back over the period.

    Stated gross this ranked a wholly voided sale as the shop's best seller —
    the row sat directly under a ``net_sales`` of 0.00 in the same report. The
    netting, the ordering and the tie-break live in ``net_product_rollups`` and
    ``rank_rollups`` so this section and the dashboard's cannot drift apart.
    """
    limit = context.row_limit("top_products")
    rows = net_product_rollups(orders, adjustments)
    ranked = [
        {
            "product_name": row["product_name"],
            "quantity": quantity(row["quantity"]),
            "revenue": money(row["revenue"]),
            "profit": money(row["profit"]),
        }
        for row in rank_rollups(rows, order_by="-revenue", limit=limit)
    ]
    return report_section(
        "top_products",
        [
            Column("product_name"),
            Column("quantity", ColumnType.QUANTITY),
            Column("revenue", ColumnType.MONEY, total=True),
            Column("profit", ColumnType.MONEY, total=True),
        ],
        ranked,
        total_count=len(rows),
        limit=limit,
        totals=_rollup_totals(rows),
    )


def _rollup_totals(rows):
    return {
        "revenue": money(sum((decimal_from(row["revenue"]) for row in rows), Decimal("0"))),
        "profit": money(sum((decimal_from(row["profit"]) for row in rows), Decimal("0"))),
    }


def _recent_orders_section(orders, context):
    """The newest orders, and what *every* order in the period came to.

    A sample that carries a total of its own visible rows and nothing else is
    the shape a reader mistakes for the whole period. The section states both:
    what the printed rows add up to, and what the period actually did.
    """
    limit = context.row_limit("recent_orders")
    bounded = bounded_queryset(orders.order_by("-created_at"), limit=limit)
    period_total = orders.aggregate(total=money_sum("total"))["total"]
    rows = [
        {
            "receipt_number": order.receipt_number,
            "status": order.status,
            "sale_type": order.sale_type,
            "total": money(order.total),
            "created_at": order.created_at.isoformat(),
        }
        for order in bounded.rows
    ]
    return report_section(
        "recent_orders",
        [
            Column("receipt_number"),
            Column("status", ColumnType.CHOICE),
            Column("sale_type", ColumnType.CHOICE),
            Column("total", ColumnType.MONEY, total=True),
            Column("created_at", ColumnType.DATETIME),
        ],
        rows,
        total_count=bounded.total_count,
        limit=bounded.limit,
        totals={"total": money(period_total)},
    )


# --------------------------------------------------------------------------
# Gross margin by product
# --------------------------------------------------------------------------


def product_margin(context):
    """What each product earns, worst margins first.

    A top-sellers list answers "what moves"; this answers "what is worth
    moving", which is the question behind every pricing decision. Losses lead
    because a line selling below cost is the one finding in this report that
    needs acting on today — and the report is built from the same netted
    rollups as the sales summary, so its total ties to that report's profit.
    """
    orders = in_period(settled_orders(context.user), context.period)
    adjustments = in_period(order_adjustments(context.user), context.period)
    rows = net_product_rollups(orders, adjustments)

    revenue_total = sum((decimal_from(row["revenue"]) for row in rows), Decimal("0"))
    profit_total = sum((decimal_from(row["profit"]) for row in rows), Decimal("0"))
    priced = [
        {
            "product_name": row["product_name"],
            "quantity": quantity(row["quantity"]),
            "revenue": money(row["revenue"]),
            "cost": money(decimal_from(row["revenue"]) - decimal_from(row["profit"])),
            "profit": money(row["profit"]),
            "margin_percent": percent(row["profit"], row["revenue"]),
            "sort_name": row["sort_name"],
        }
        for row in rows
    ]
    losing = [row for row in priced if decimal_from(row["profit"]) < 0]
    limit = context.row_limit("product_margin")

    by_margin = sorted(
        priced,
        key=lambda row: (decimal_from(row["margin_percent"]), row["sort_name"]),
    )
    bounded_losses = bounded_rows(
        sorted(losing, key=lambda row: decimal_from(row["profit"])),
        limit=context.row_limit("margin_losses"),
    )
    bounded_all = bounded_rows(by_margin, limit=limit)

    return {
        "summary": {
            "revenue_total": money(revenue_total),
            "profit_total": money(profit_total),
            "margin_percent": percent(profit_total, revenue_total),
            "product_count": len(rows),
            "loss_making_count": len(losing),
            "loss_making_total": money(
                sum((decimal_from(row["profit"]) for row in losing), Decimal("0"))
            ),
        },
        "sections": [
            context.metrics(
                {
                    "revenue_total": money(revenue_total),
                    "profit_total": money(profit_total),
                    "margin_percent": percent(profit_total, revenue_total),
                    "product_count": len(rows),
                    "loss_making_count": len(losing),
                    "loss_making_total": money(
                        sum((decimal_from(row["profit"]) for row in losing), Decimal("0"))
                    ),
                }
            ),
            report_section(
                "margin_losses",
                _MARGIN_COLUMNS,
                _strip(bounded_losses.rows),
                total_count=bounded_losses.total_count,
                limit=bounded_losses.limit,
            ),
            report_section(
                "category_margin",
                [
                    Column("category_name"),
                    Column("quantity", ColumnType.QUANTITY),
                    Column("revenue", ColumnType.MONEY, total=True),
                    Column("profit", ColumnType.MONEY, total=True),
                    Column("margin_percent", ColumnType.PERCENT),
                ],
                _category_margin_rows(rows, context),
            ),
            report_section(
                "product_margin",
                _MARGIN_COLUMNS,
                _strip(bounded_all.rows),
                total_count=bounded_all.total_count,
                limit=bounded_all.limit,
                totals={"revenue": money(revenue_total), "profit": money(profit_total)},
            ),
        ],
        "notes": [note("margin_net_of_returns"), note("margin_cost_from_ledger")],
    }


_MARGIN_COLUMNS = [
    Column("product_name"),
    Column("quantity", ColumnType.QUANTITY),
    Column("revenue", ColumnType.MONEY, total=True),
    Column("cost", ColumnType.MONEY, total=True),
    Column("profit", ColumnType.MONEY, total=True),
    Column("margin_percent", ColumnType.PERCENT),
]


def _strip(rows):
    return [{key: value for key, value in row.items() if key != "sort_name"} for row in rows]


def _category_margin_rows(rows, context):
    """Margin per category, with every product counted exactly once.

    A product belongs to many categories, so grouping the sale by the relation
    would count a product filed under both "drinks" and "cold" twice and the
    column would not foot to the report's own revenue. Each product is placed
    in its *first* category instead — the same ordering the catalogue itself
    uses — so the schedule adds up, and the note says which category a
    multi-filed product landed in.
    """
    primary = _primary_categories([row["product_id"] for row in rows])
    grouped = {}
    for row in rows:
        name = primary.get(row["product_id"], "")
        bucket = grouped.setdefault(
            name,
            {"quantity": Decimal("0"), "revenue": Decimal("0"), "profit": Decimal("0")},
        )
        bucket["quantity"] += decimal_from(row["quantity"])
        bucket["revenue"] += decimal_from(row["revenue"])
        bucket["profit"] += decimal_from(row["profit"])

    ranked = sorted(
        grouped.items(), key=lambda item: (-item[1]["revenue"], item[0])
    )[: context.row_limit("category_margin")]
    return [
        {
            "category_name": name,
            "quantity": quantity(totals["quantity"]),
            "revenue": money(totals["revenue"]),
            "profit": money(totals["profit"]),
            "margin_percent": percent(totals["profit"], totals["revenue"]),
        }
        for name, totals in ranked
    ]


def _primary_categories(product_ids):
    """``{product_id: category_name}`` for the first category of each product.

    One query over the through table, ordered so the first row seen per product
    is the one the catalogue would show first.
    """
    if not product_ids:
        return {}
    links = (
        Product.categories.through.objects.filter(product_id__in=set(product_ids))
        .select_related("productcategory")
        .order_by(
            "product_id",
            "productcategory__display_order",
            "productcategory__name",
        )
    )
    primary = {}
    for link in links:
        primary.setdefault(link.product_id, link.productcategory.name)
    return primary


# --------------------------------------------------------------------------
# Discounts, voids and returns
# --------------------------------------------------------------------------


def discount_audit(context):
    """Everything the shop gave away, and who authorised it.

    Discounts, voids and refunds are the three ways money leaves a till without
    goods leaving the shelf, and they are the three an owner is asked about
    first. Kept in one report because they are one question.
    """
    orders = in_period(settled_orders(context.user), context.period)
    adjustments = in_period(order_adjustments(context.user), context.period)

    totals = orders.aggregate(
        given_discount=money_sum("discount_total"),
        gross_sales=money_sum("subtotal"),
        void_total=money_sum_filtered("total", Q(status=Order.Status.VOID)),
        void_count=Count("id", filter=Q(status=Order.Status.VOID)),
        discounted_order_count=Count("id", filter=Q(discount_total__gt=0)),
        manual_discount=money_sum("extra_discount_amount"),
        manual_discount_count=Count(
            "id", filter=Q(extra_discount_amount__gt=0)
        ),
    )
    adjustment_totals = adjustments.aggregate(
        refund_total=money_sum("amount"),
        refund_count=Count("id"),
    )
    figures = {
        "discount_total": money(totals["given_discount"]),
        "discount_rate_percent": percent(totals["given_discount"], totals["gross_sales"]),
        "discounted_order_count": totals["discounted_order_count"],
        "void_total": money(totals["void_total"]),
        "void_count": totals["void_count"],
        "refund_total": money(adjustment_totals["refund_total"]),
        "refund_count": adjustment_totals["refund_count"],
    }

    return {
        "summary": figures,
        "sections": [
            context.metrics(figures),
            _discount_rule_section(orders, context, totals),
            _giveaway_by_staff_section(orders, adjustments, context),
            _voids_and_refunds_section(orders, adjustments, context),
        ],
        "notes": [note("void_is_reversal"), note("discount_at_line_and_document")],
    }


def _discount_rule_section(orders, context, totals):
    """What each discount rule gave away — plus what the counter gave away on
    its own authority, which belongs in the same list.

    A cashier's one-off discount has no rule and therefore no ``AppliedDiscount``
    row, so without its own line here the breakdown stops adding up to the
    headline above it: the owner reads a shop that gave away 400 and a list that
    accounts for 250, with nothing saying where the rest went. It is also the
    line they most want, because it is the one nobody authorised in advance.
    """
    from apps.discounts.models import AppliedDiscount

    limit = context.row_limit("discount_rules")
    values = (
        AppliedDiscount.objects.filter(
            document_content_type__app_label="sales",
            document_content_type__model="order",
            document_object_id__in=orders.values("id"),
        )
        .values("rule_id", "rule_name")
        .annotate(amount=money_sum("discount_amount"), times_used=Count("id"))
        .order_by("-amount", "rule_name")
    )
    bounded = bounded_queryset(values, limit=limit)
    rows = [
        {
            "rule_name": row["rule_name"] or "",
            "times_used": row["times_used"],
            "amount": money(row["amount"]),
        }
        for row in bounded.rows
    ]
    manual_total = decimal_from(money(totals["manual_discount"]))
    extra_rows = 0
    if manual_total > 0:
        extra_rows = 1
        rows.append(
            {
                "rule_name": MANUAL_DISCOUNT_ROW_NAME,
                "times_used": totals["manual_discount_count"],
                "amount": money(totals["manual_discount"]),
            }
        )
        rows.sort(key=lambda row: decimal_from(row["amount"]), reverse=True)
    return report_section(
        "discount_rules",
        [
            Column("rule_name"),
            Column("times_used", ColumnType.COUNT, total=True),
            Column("amount", ColumnType.MONEY, total=True),
        ],
        rows,
        total_count=bounded.total_count + extra_rows,
        limit=bounded.limit,
    )


def _giveaway_by_staff_section(orders, adjustments, context):
    """Who gave what away. Not an accusation — a distribution.

    A single cashier holding most of the shop's discounts is either its best
    negotiator or its biggest leak, and the owner is the only one who can tell
    which. The report's job is to make the concentration visible.
    """
    discounts = {
        row["register_session__owner__username"] or "": row
        for row in orders.values("register_session__owner__username").annotate(
            discount_total=money_sum("discount_total"),
            void_total=money_sum_filtered("total", Q(status=Order.Status.VOID)),
            order_count=Count("id"),
        )
    }
    refunds = {
        row["register_session__owner__username"] or "": row
        for row in adjustments.values("register_session__owner__username").annotate(
            refund_total=money_sum("amount"),
        )
    }
    rows = []
    for name in sorted(set(discounts) | set(refunds)):
        sold = discounts.get(name, {})
        handed_back = refunds.get(name, {})
        rows.append(
            {
                "staff_name": name,
                "order_count": sold.get("order_count", 0),
                "discount_total": money(sold.get("discount_total")),
                "void_total": money(sold.get("void_total")),
                "refund_total": money(handed_back.get("refund_total")),
            }
        )
    rows.sort(key=lambda row: decimal_from(row["discount_total"]), reverse=True)
    bounded = bounded_rows(rows, limit=context.row_limit("giveaway_by_staff"))
    return report_section(
        "giveaway_by_staff",
        [
            Column("staff_name"),
            Column("order_count", ColumnType.COUNT, total=True),
            Column("discount_total", ColumnType.MONEY, total=True),
            Column("void_total", ColumnType.MONEY, total=True),
            Column("refund_total", ColumnType.MONEY, total=True),
        ],
        bounded.rows,
        total_count=bounded.total_count,
        limit=bounded.limit,
    )


def _voids_and_refunds_section(orders, adjustments, context):
    limit = context.row_limit("voids_and_refunds")
    voided = orders.filter(status=Order.Status.VOID).select_related(
        "register_session__owner"
    )
    bounded_voids = bounded_queryset(voided.order_by("-created_at"), limit=limit)
    rows = [
        {
            "document": order.receipt_number,
            "kind": "void",
            "amount": money(order.total),
            "reason": "",
            "staff_name": _owner_name(order.register_session),
            "occurred_at": order.created_at.isoformat(),
        }
        for order in bounded_voids.rows
    ]

    refunds = adjustments.select_related("order", "created_by").order_by("-created_at")
    bounded_refunds = bounded_queryset(refunds, limit=limit)
    rows.extend(
        {
            "document": adjustment.order.receipt_number if adjustment.order_id else "",
            "kind": adjustment.adjustment_type,
            "amount": money(adjustment.amount),
            "reason": adjustment.reason,
            "staff_name": (
                adjustment.created_by.username if adjustment.created_by_id else ""
            ),
            "occurred_at": adjustment.created_at.isoformat(),
        }
        for adjustment in bounded_refunds.rows
    )
    rows.sort(key=lambda row: row["occurred_at"], reverse=True)
    return report_section(
        "voids_and_refunds",
        [
            Column("occurred_at", ColumnType.DATETIME),
            Column("document"),
            Column("kind", ColumnType.CHOICE),
            Column("amount", ColumnType.MONEY, total=True),
            Column("staff_name"),
            Column("reason"),
        ],
        rows,
        total_count=bounded_voids.total_count + bounded_refunds.total_count,
        limit=limit * 2,
    )


def _owner_name(session):
    if session is None or session.owner_id is None:
        return ""
    return session.owner.username


# --------------------------------------------------------------------------
# Sales by staff, day and hour
# --------------------------------------------------------------------------


def sales_by_staff(context):
    """Who sold what, and when the shop is actually busy.

    Two questions that share one set of documents: staffing (which hours carry
    the trade) and accountability (which till took the money). Splitting them
    into two reports would mean two aggregations of the same orders and two
    chances for them to disagree about the period's total.
    """
    orders = in_period(settled_orders(context.user), context.period)
    adjustments = in_period(order_adjustments(context.user), context.period)

    staff_rows, totals = _staff_rows(orders, adjustments)
    hour_rows = _hour_rows(orders)
    busiest = max(hour_rows, key=lambda row: decimal_from(row["net_sales"]), default=None)

    figures = {
        "net_sales": money(totals["net_sales"]),
        "order_count": totals["order_count"],
        "staff_count": len(staff_rows),
        "average_sale": money(
            totals["net_sales"] / totals["order_count"]
            if totals["order_count"]
            else Decimal("0")
        ),
        "busiest_hour": busiest["hour"] if busiest else "",
    }
    sections = [
        context.metrics(figures),
        report_section(
            "sales_by_staff",
            [
                Column("staff_name"),
                Column("order_count", ColumnType.COUNT, total=True),
                Column("gross_sales", ColumnType.MONEY, total=True),
                Column("refund_total", ColumnType.MONEY, total=True),
                Column("net_sales", ColumnType.MONEY, total=True),
                Column("average_sale", ColumnType.MONEY),
            ],
            staff_rows,
        ),
        report_section(
            "sales_by_hour",
            [
                Column("hour"),
                Column("order_count", ColumnType.COUNT, total=True),
                Column("net_sales", ColumnType.MONEY, total=True),
            ],
            hour_rows,
        ),
    ]
    if context.period.wants_daily_breakdown:
        sections.append(_daily_sales_section(orders, adjustments, context))
    return {
        "summary": figures,
        "sections": sections,
        "notes": [note("staff_is_register_owner"), note("hours_on_report_clock")],
    }


def _staff_rows(orders, adjustments):
    sold = {
        (row["register_session__owner__username"] or ""): row
        for row in orders.values("register_session__owner__username").annotate(
            gross=money_sum("total"),
            order_count=Count("id"),
        )
    }
    handed_back = {
        (row["register_session__owner__username"] or ""): row
        for row in adjustments.values("register_session__owner__username").annotate(
            refund_total=money_sum("amount"),
        )
    }
    rows = []
    net_total = Decimal("0.00")
    order_total = 0
    for name in sorted(set(sold) | set(handed_back)):
        gross = decimal_from(sold.get(name, {}).get("gross"))
        refund = decimal_from(handed_back.get(name, {}).get("refund_total"))
        count = sold.get(name, {}).get("order_count", 0)
        net = gross - refund
        net_total += net
        order_total += count
        rows.append(
            {
                "staff_name": name,
                "order_count": count,
                "gross_sales": money(gross),
                "refund_total": money(refund),
                "net_sales": money(net),
                "average_sale": money(net / count if count else Decimal("0")),
            }
        )
    rows.sort(key=lambda row: decimal_from(row["net_sales"]), reverse=True)
    return rows, {"net_sales": net_total, "order_count": order_total}


def _hour_rows(orders):
    values = (
        orders.annotate(_hour=ExtractHour("created_at"))
        .values("_hour")
        .annotate(net_sales=money_sum("total"), order_count=Count("id"))
        .order_by("_hour")
    )
    return [
        {
            "hour": f"{row['_hour']:02d}:00",
            "order_count": row["order_count"],
            "net_sales": money(row["net_sales"]),
        }
        for row in values
        if row["_hour"] is not None
    ]


__all__ = [
    "discount_audit",
    "product_margin",
    "sales_by_staff",
    "sales_summary",
    "sales_summary_figures",
]
