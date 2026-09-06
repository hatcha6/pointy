from collections import defaultdict
from datetime import timedelta
from decimal import Decimal

from django.core.cache import cache
from django.db.models import (
    Count,
    DecimalField,
    ExpressionWrapper,
    F,
    IntegerField,
    OuterRef,
    Q,
    Subquery,
    Sum,
    Value,
)
from django.db.models.functions import Coalesce, ExtractHour, Greatest, TruncDate
from django.utils import timezone
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from apps.catalog.models import Product, ProductCategory
from apps.core.permissions import HasPointyPermission
from apps.core.roles import user_has_full_visibility
from apps.customers.models import Customer
from apps.discounts.models import DiscountRedemption, DiscountRule
from apps.employees.models import Employee, EmployeeLoan, PayrollRun
from apps.expenses.models import Expense
from apps.fraud.models import FraudFinding
from apps.inventory.models import StockItem, StockMovement
from apps.payments.models import Payment
from apps.printing.models import PrintAgent, PrintJob
from apps.purchasing.models import (
    PurchaseOrder,
    Supplier,
    SupplierCredit,
    SupplierPayment,
)
from apps.sales.models import (
    Order,
    recognized_sale_q,
    OrderAdjustment,
    OrderLine,
    RegisterCashMovement,
    RegisterSession,
    SOLD_COST_EXPRESSION,
    SOLD_REVENUE_EXPRESSION,
    gross_profit_total,
    net_line_rollups,
    prime_register_session_cash_totals,
    net_product_rollups,
    rank_rollups,
    returned_items_total,
)

MONEY_PLACES = Decimal("0.01")
MONEY_FIELD = DecimalField(max_digits=12, decimal_places=2)
QTY_FIELD = DecimalField(max_digits=14, decimal_places=3)
ZERO_QTY = Value(Decimal("0"), output_field=QTY_FIELD)
DASHBOARD_SECTION_CACHE_SECONDS = 30
# The background warmer writes sections with a much longer TTL so the (heavy,
# ~7.5s cold) aggregates stay hot between the infrequent, spread-out dashboard
# loads a small shop actually makes — comfortably longer than the beat interval
# so a few missed ticks don't leave the cache cold.
DASHBOARD_WARM_CACHE_SECONDS = 20 * 60
DASHBOARD_CACHE_VERSION = 1

__all__ = [
    "MONEY_PLACES", "MONEY_FIELD", "QTY_FIELD", "ZERO_QTY",
    "DASHBOARD_SECTION_CACHE_SECONDS", "DASHBOARD_WARM_CACHE_SECONDS",
    "DASHBOARD_CACHE_VERSION",
    "_sales_summary", "_sales_trend", "_hourly_sales",
    "_sales_reports", "_sales_rankings", "_product_rows", "_variant_rows",
    "_rank",
    "_variant_full_name", "_top_categories",
    "_recent_orders", "_register_summary", "_register_variance_summary",
    "_totals_by_key",
    "_purchase_order_balance_rows", "_purchase_order_balance_due",
    "_top_supplier_balances", "_stock_item_row", "_settled_orders",
    "_order_adjustments", "_payments", "_print_jobs", "_owner_key",
    "_views_shop_wide", "_can", "_can_any", "_money", "_decimal_from",
    "_percent", "_change_percent",
]

def _sales_summary(orders, adjustments):
    order_values = orders.aggregate(
        gross_sales=Coalesce(Sum("subtotal"), Value(Decimal("0.00")), output_field=MONEY_FIELD),
        discount_total=Coalesce(
            Sum("discount_total"),
            Value(Decimal("0.00")),
            output_field=MONEY_FIELD,
        ),
        order_total=Coalesce(Sum("total"), Value(Decimal("0.00")), output_field=MONEY_FIELD),
        order_count=Count("id", filter=recognized_sale_q()),
    )
    adjustment_values = adjustments.aggregate(
        refund_total=Coalesce(Sum("amount"), Value(Decimal("0.00")), output_field=MONEY_FIELD),
        void_count=Count("id", filter=Q(adjustment_type=OrderAdjustment.AdjustmentType.VOID)),
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
    # from, so the card states one revenue rather than two; a refund reverses
    # margin, not margin *plus* cost, because the goods are restocked.
    profit = gross_profit_total(
        revenue=order_values["order_total"],
        sold_cost=line_values["sold_cost"],
        refund_total=adjustment_values["refund_total"],
        adjustments=adjustments,
    )
    order_count = order_values["order_count"]
    return {
        "gross_sales": _money(order_values["gross_sales"]),
        "discount_total": _money(order_values["discount_total"]),
        "refund_total": _money(adjustment_values["refund_total"]),
        "net_sales": _money(net_sales),
        "net_sales_raw": net_sales,
        "gross_profit": _money(profit),
        "profit_margin_percent": _percent(profit, net_sales),
        "order_count": order_count,
        "average_order_value": _money(net_sales / order_count if order_count else Decimal("0.00")),
        "items_sold": items_sold,
        "void_count": adjustment_values["void_count"],
        "return_count": adjustment_values["return_count"],
    }


def _sales_trend(orders, adjustments, period):
    sales_by_day = defaultdict(lambda: {"sales": Decimal("0.00"), "orders": 0})
    for row in (
        orders.annotate(day=TruncDate("created_at"))
        .values("day")
        .annotate(
            total=Coalesce(Sum("total"), Value(Decimal("0.00")), output_field=MONEY_FIELD),
            count=Count("id", filter=recognized_sale_q()),
        )
    ):
        sales_by_day[row["day"]]["sales"] += row["total"]
        sales_by_day[row["day"]]["orders"] += row["count"]
    for row in (
        adjustments.annotate(day=TruncDate("created_at"))
        .values("day")
        .annotate(total=Coalesce(Sum("amount"), Value(Decimal("0.00")), output_field=MONEY_FIELD))
    ):
        sales_by_day[row["day"]]["sales"] -= row["total"]

    points = []
    current_day = timezone.localtime(period["start"]).date()
    end_day = timezone.localtime(period["end"]).date()
    while current_day <= end_day:
        point = sales_by_day[current_day]
        points.append(
            {
                "date": current_day.isoformat(),
                "net_sales": _money(point["sales"]),
                "order_count": point["orders"],
            }
        )
        current_day += timedelta(days=1)
    return points


def _hourly_sales(orders):
    hourly = {hour: Decimal("0.00") for hour in range(24)}
    for row in (
        orders.annotate(hour=ExtractHour("created_at"))
        .values("hour")
        .annotate(total=Coalesce(Sum("total"), Value(Decimal("0.00")), output_field=MONEY_FIELD))
    ):
        hourly[row["hour"] or 0] = row["total"]
    return [{"hour": hour, "net_sales": _money(total)} for hour, total in hourly.items()]


def _sales_rankings(orders, adjustments):
    """The top-products card and the six ranking tables, from one pass.

    Each grain is rolled up ONCE and ranked several ways in Python: seven
    rankings over four aggregate queries, where the seven separate ``ORDER BY
    … LIMIT`` queries they replace could not net returns out at all (see
    ``rank_rollups``).
    """
    products = _product_rows(orders, adjustments)
    variants = _variant_rows(orders, adjustments)
    return (
        _rank(products, order_by="-revenue", limit=8),
        _sales_reports(products, variants),
    )


def _sales_reports(products, variants):
    return {
        "products": {
            "top_sold": _rank(products, order_by="-quantity", limit=24),
            "revenue": _rank(products, order_by="-revenue", limit=24),
            "profit": _rank(products, order_by="-profit", limit=24),
        },
        "variants": {
            "top_sold": _rank(variants, order_by="-quantity", limit=24),
            "revenue": _rank(variants, order_by="-revenue", limit=24),
            "profit": _rank(variants, order_by="-profit", limit=24),
        },
    }


def _product_rows(orders, adjustments):
    return [
        {**row, "sku": ""} for row in net_product_rollups(orders, adjustments)
    ]


def _variant_rows(orders, adjustments):
    rows = net_line_rollups(
        orders,
        adjustments,
        "variant_id",
        labels=(
            "variant__product_id",
            "variant__product__name",
            "variant__name",
            "variant__sku",
            "variant__barcode",
        ),
    )
    return [
        {
            "product_id": row["variant__product_id"],
            "variant_id": row["variant_id"],
            "product_name": _variant_full_name(
                row["variant__product__name"],
                row["variant__name"],
            ),
            "parent_product_name": row["variant__product__name"],
            "variant_name": row["variant__name"] or row["variant__product__name"],
            "sku": row["variant__sku"],
            "barcode": row["variant__barcode"],
            "quantity": row["quantity"],
            "revenue": row["revenue"],
            "profit": row["profit"],
            "sort_name": (
                (row["variant__product__name"] or ""),
                (row["variant__name"] or ""),
            ),
        }
        for row in rows
    ]


def _rank(rows, *, order_by, limit):
    """Rank, then drop the sort key and round the money once."""
    return [
        {
            name: (_money(value) if name in ("revenue", "profit") else value)
            for name, value in row.items()
            if name != "sort_name"
        }
        for row in rank_rollups(rows, order_by=order_by, limit=limit)
    ]


def _variant_full_name(product_name, variant_name):
    variant_name = (variant_name or "").strip()
    if not variant_name:
        return product_name
    return f"{product_name} - {variant_name}"


def _top_categories(orders):
    # A product can belong to several categories (M2M). Joining order lines to
    # ``categories`` repeats each line once per category, so summing the raw
    # revenue would credit a product in N categories N times over. Divide each
    # line's revenue and units evenly across its product's categories so the
    # breakdown reconciles with real sales; lines on uncategorised products
    # (count 0) divide by 1 and fall into the blank "uncategorised" bucket.
    category_count = Greatest(
        Coalesce(
            Subquery(
                Product.objects.filter(pk=OuterRef("variant__product_id"))
                .annotate(_count=Count("categories"))
                .values("_count")[:1],
                output_field=IntegerField(),
            ),
            Value(0),
        ),
        Value(1),
    )
    revenue_expr = SOLD_REVENUE_EXPRESSION
    allocated_revenue = ExpressionWrapper(
        revenue_expr / category_count,
        output_field=MONEY_FIELD,
    )
    allocated_units = ExpressionWrapper(
        F("quantity") / category_count,
        output_field=QTY_FIELD,
    )
    rows = (
        OrderLine.objects.filter(order__in=orders)
        .values("variant__product__categories__name")
        .annotate(
            revenue=Coalesce(
                Sum(allocated_revenue),
                Value(Decimal("0.00")),
                output_field=MONEY_FIELD,
            ),
            units_sold=Coalesce(Sum(allocated_units), ZERO_QTY),
        )
        .order_by("-revenue")[:6]
    )
    return [
        {
            "category_name": row["variant__product__categories__name"] or "",
            "quantity": row["units_sold"],
            "revenue": _money(row["revenue"]),
        }
        for row in rows
    ]


def _recent_orders(orders):
    return [
        {
            "receipt_number": order.receipt_number,
            "customer_name": order.customer.full_name if order.customer_id else "",
            "status": order.status,
            "total": _money(order.total),
            "created_at": order.created_at.isoformat(),
        }
        for order in orders.select_related("customer").order_by("-created_at")[:6]
    ]


def _register_summary(request, period):
    sessions = RegisterSession.objects.all()
    if not _views_shop_wide(request):
        sessions = sessions.filter(owner_key=_owner_key(request))
    period_filter = Q(created_at__gte=period["start"], created_at__lt=period["end"])
    closed_period_filter = Q(status=RegisterSession.Status.CLOSED) & period_filter
    values = sessions.aggregate(
        open_count=Count("id", filter=Q(status=RegisterSession.Status.OPEN)),
        closed_count=Count("id", filter=closed_period_filter),
    )
    variance = (
        _register_variance_summary(sessions.filter(closed_period_filter))
        if _views_shop_wide(request)
        else {"count": 0, "total": Decimal("0.00")}
    )
    return {
        "open_count": values["open_count"],
        "closed_count": values["closed_count"],
        "variance_count": variance["count"],
        "variance_total": _money(variance["total"]),
    }


def _register_variance_summary(closed_sessions):
    """How many closed drawers disagreed with Pointy, and by how much.

    The arithmetic is ``RegisterSession.expected_cash`` — the one definition —
    reached through ``prime_register_session_cash_totals``, which batches the
    four aggregates behind it into three queries. This function used to inline
    its own copy of that sum, which is how the dashboard, the register-closure
    report and the register screen came to state the same figure three ways.
    """
    sessions = prime_register_session_cash_totals(
        closed_sessions.only("id", "opening_cash", "closing_cash")
    )
    if not sessions:
        return {"count": 0, "total": Decimal("0.00")}

    variance_count = 0
    variance_total = Decimal("0.00")
    for session in sessions:
        variance = session.cash_variance
        if variance is None or variance == Decimal("0.00"):
            continue
        variance_count += 1
        variance_total += variance
    return {"count": variance_count, "total": variance_total}


def _totals_by_key(rows, *, key):
    totals = defaultdict(lambda: Decimal("0.00"))
    for row in rows:
        totals[row[key]] = row["total"]
    return totals


def _purchase_order_balance_rows(orders):
    # Streamed, not list()ed: the purchasing section consumes this in a single
    # pass, so a 12k-PO history never has to sit in memory per cache miss.
    return (
        orders.values(
            "id",
            "order_number",
            "supplier_id",
            "supplier__name",
            "due_date",
            "total",
            "cancelled_total",
        )
        .annotate(
            dashboard_paid_total=Coalesce(
                Sum(
                    "supplier_payments__amount",
                    filter=~Q(supplier_payments__method=SupplierPayment.Method.SUPPLIER_CREDIT),
                ),
                Value(Decimal("0.00")),
                output_field=MONEY_FIELD,
            ),
            dashboard_credit_total=Coalesce(
                Sum(
                    "supplier_payments__amount",
                    filter=Q(supplier_payments__method=SupplierPayment.Method.SUPPLIER_CREDIT),
                ),
                Value(Decimal("0.00")),
                output_field=MONEY_FIELD,
            ),
        )
        .order_by("due_date", "id")
        .iterator(chunk_size=2000)
    )


def _purchase_order_balance_due(row):
    # ``cancelled_total`` is the goods a receipt closed as never-arriving; the
    # order cannot bill for them, so the dashboard's payables must agree with
    # ``PurchaseOrder.raw_balance_due`` and drop them too.
    return max(
        row["total"]
        - row["cancelled_total"]
        - row["dashboard_paid_total"]
        - row["dashboard_credit_total"],
        Decimal("0.00"),
    )


def _top_supplier_balances(balances_by_supplier):
    """``balances_by_supplier`` is the per-supplier sum of PO balances, already
    accumulated by the purchasing section's single pass over the balance rows."""
    active_suppliers = {
        row["id"]: row["name"]
        for row in Supplier.objects.filter(is_active=True).values("id", "name")
    }
    if not active_suppliers:
        return []

    supplier_ids = set(active_suppliers)

    unallocated_payments_by_supplier = {
        row["supplier_id"]: row["total"]
        for row in SupplierPayment.objects.live()
        .filter(
            supplier_id__in=supplier_ids,
            purchase_order__isnull=True,
        )
        .exclude(method=SupplierPayment.Method.SUPPLIER_CREDIT)
        .values("supplier_id")
        .annotate(
            total=Coalesce(
                Sum("amount"),
                Value(Decimal("0.00")),
                output_field=MONEY_FIELD,
            )
        )
    }
    open_credits_by_supplier = {
        row["supplier_id"]: row["total"]
        for row in SupplierCredit.objects.filter(
            supplier_id__in=supplier_ids,
            status=SupplierCredit.Status.OPEN,
        )
        .values("supplier_id")
        .annotate(
            total=Coalesce(
                Sum("remaining_amount"),
                Value(Decimal("0.00")),
                output_field=MONEY_FIELD,
            )
        )
    }

    rows = []
    for supplier_id, supplier_name in active_suppliers.items():
        payable = max(
            balances_by_supplier.get(supplier_id, Decimal("0.00"))
            - unallocated_payments_by_supplier.get(supplier_id, Decimal("0.00")),
            Decimal("0.00"),
        )
        net_balance = payable - open_credits_by_supplier.get(
            supplier_id,
            Decimal("0.00"),
        )
        if net_balance > 0:
            rows.append((supplier_name, net_balance))
    rows.sort(key=lambda item: (-item[1], item[0]))
    return [
        {
            "supplier_name": supplier_name,
            "net_balance": _money(balance),
        }
        for supplier_name, balance in rows[:6]
    ]


def _stock_item_row(item):
    return {
        "product_id": item.variant.product_id,
        "variant_id": item.variant_id,
        "product_name": item.variant.product.name,
        "variant_name": item.variant.display_name,
        "sku": item.variant.sku,
        "quantity_on_hand": item.quantity_on_hand,
        "quantity_expected": item.quantity_expected,
        "quantity_committed": item.quantity_committed,
        "reorder_level": item.reorder_level,
    }


def _settled_orders(request):
    queryset = Order.objects.transactional()
    if _views_shop_wide(request):
        return queryset
    return queryset.filter(register_session__owner_key=_owner_key(request))


def _order_adjustments(request):
    queryset = OrderAdjustment.objects.all()
    if _views_shop_wide(request):
        return queryset
    return queryset.filter(register_session__owner_key=_owner_key(request))


def _payments(request):
    queryset = Payment.objects.select_related("order", "order__register_session")
    if _views_shop_wide(request):
        return queryset
    return queryset.filter(order__register_session__owner_key=_owner_key(request))


def _print_jobs(request):
    queryset = PrintJob.objects.all()
    if _views_shop_wide(request):
        return queryset
    return queryset.filter(order__register_session__owner_key=_owner_key(request))


def _owner_key(request):
    return f"user:{request.user.pk}"


def _views_shop_wide(request):
    """Whether dashboard data may span all registers instead of the caller's.

    Reporting roles (managers, accountants, supervisors, auditors) see shop-wide
    aggregates; anyone else is scoped to their own register sessions so a cashier
    can never read totals that would let them fake a clean drawer count.
    """
    return user_has_full_visibility(request.user)


def _can(user, permission):
    return user.has_perm(permission)


def _can_any(user, permissions):
    return any(_can(user, permission) for permission in permissions)


def _money(value):
    return str(_decimal_from(value).quantize(MONEY_PLACES))


def _decimal_from(value):
    if value is None:
        return Decimal("0.00")
    if isinstance(value, Decimal):
        return value
    return Decimal(str(value))


def _percent(numerator, denominator):
    denominator = _decimal_from(denominator)
    if denominator == 0:
        return "0.00"
    return str(((_decimal_from(numerator) / denominator) * Decimal("100")).quantize(MONEY_PLACES))


def _change_percent(current, previous):
    previous = _decimal_from(previous)
    current = _decimal_from(current)
    if previous == 0:
        return "0.00" if current == 0 else "100.00"
    return str((((current - previous) / previous) * Decimal("100")).quantize(MONEY_PLACES))
