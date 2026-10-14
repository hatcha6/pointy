"""Designer-built POS cards the assistant fills with data, never lays out.

ChatGPT's rich answers are mostly fixed widgets a designer drew once — the model
only supplies which record. These are Pointy's equivalents: ``show_product``,
``show_customer`` and ``show_sales_summary``. The server reads the record
through the same permission-scoped paths as every other tool, composes the card
itself and validates it against the catalog, and the loop draws it. The model
gets a compact summary back so it can add one line of judgement — it never
copies or invents the card's figures.

Cost, profit and margin appear only for the reporting roles (``_sees_margins``),
the same line the read tools draw.
"""

from __future__ import annotations

import logging
from datetime import timedelta
from decimal import Decimal

from django.db.models import Count, Sum
from django.db.models.functions import TruncDate, TruncMonth
from django.utils import timezone

from .ui_catalog import UiValidationError, validate_surface

logger = logging.getLogger(__name__)

PERIOD_LABELS = {
    "today": "اليوم",
    "yesterday": "أمس",
    "this_week": "هذا الأسبوع",
    "last_week": "الأسبوع الماضي",
    "this_month": "هذا الشهر",
    "last_month": "الشهر الماضي",
    "this_year": "هذه السنة",
    "last_year": "السنة الماضية",
    "last_7_days": "آخر ٧ أيام",
    "last_30_days": "آخر ٣٠ يومًا",
    "last_90_days": "آخر ٩٠ يومًا",
}

_VELOCITY_DAYS = 30


def _number(value):
    if value in (None, ""):
        return None
    try:
        return float(Decimal(str(value)))
    except Exception:  # noqa: BLE001
        return None


def _surface(surface_id, title, component):
    """One card as a whole surface, validated like anything the model draws."""
    try:
        return validate_surface(
            {
                "surface_id": surface_id,
                "title": title,
                "components": [{"id": "root", **component}],
            }
        )
    except UiValidationError:
        # A card we compose ourselves failing validation is a bug here, and a
        # stale exported catalog is the usual cause; never show half a card.
        logger.exception("AI POS card %s failed catalog validation", component.get("component"))
        return None


def _units_sold(user, *, product_id=None, customer_id=None, days=_VELOCITY_DAYS):
    from apps.sales.models import OrderLine

    from .tools import _scoped_orders

    start = timezone.localdate() - timedelta(days=days - 1)
    orders, err = _scoped_orders(user, start=start)
    if err is not None:
        return None
    lines = OrderLine.objects.filter(order__in=orders.committed_sales())
    if product_id is not None:
        lines = lines.filter(variant__product_id=product_id)
    return _number(lines.aggregate(units=Sum("quantity"))["units"]) or 0.0


def show_product(*, user, product_id):
    """The product card: price, stock, how fast it sells and how long the stock
    lasts at that pace."""
    from .tools import get_resource

    found = get_resource(user=user, resource="products", id=product_id)
    if not found.get("ok"):
        return found, None
    data = found.get("data") or {}
    variant = data.get("default_variant") or {}
    stock = _number(data.get("quantity_on_hand"))
    is_service = bool(data.get("is_service") or data.get("is_prepared"))
    sold = _units_sold(user, product_id=product_id)
    props = {
        "component": "ProductCard",
        "productId": int(data.get("id") or product_id),
        "name": data.get("name") or "",
        "price": _number(variant.get("unit_price")),
        "code": variant.get("barcode") or variant.get("sku") or "",
        "category": ", ".join(
            c.get("name", "") for c in (data.get("category_details") or []) if isinstance(c, dict)
        )[:80],
        "isService": is_service,
        "active": bool(data.get("is_active", True)) and not data.get("is_archived"),
    }
    if not is_service and stock is not None:
        props["stock"] = stock
    if sold is not None:
        props["soldLast30Days"] = sold
        if not is_service and stock is not None and sold > 0:
            props["daysOfCover"] = int(stock / (sold / _VELOCITY_DAYS))
    props = {key: value for key, value in props.items() if value not in (None, "")}
    surface = _surface(f"product-{props['productId']}", props["name"], props)
    summary = {
        key: props.get(key)
        for key in ("name", "price", "stock", "soldLast30Days", "daysOfCover", "active")
    }
    return {"ok": True, "shown": surface is not None, "product": summary}, surface


def _customer_debt(user, customer_id):
    from .tools import _account_debts, _scoped_orders

    orders, err = _scoped_orders(user)
    if err is not None:
        return None
    total = Decimal("0.00")
    for source in (orders.open_credit(), _account_debts(user)):
        for order in source.filter(customer_id=customer_id).with_balance_relations():
            total += order.balance_due
    return float(total)


def show_customer(*, user, customer_id):
    """The customer card: who they are, what they owe, and how they buy."""
    from .tools import get_resource

    found = get_resource(user=user, resource="customers", id=customer_id)
    if not found.get("ok"):
        return found, None
    data = found.get("data") or {}
    last = data.get("rfm_last_purchase_at")
    props = {
        "component": "CustomerCard",
        "customerId": int(data.get("id") or customer_id),
        "name": data.get("full_name") or "",
        "phone": data.get("phone") or "",
        "segment": data.get("rfm_segment") or "",
        "segmentLabel": data.get("rfm_segment_display") or "",
        "balanceDue": _customer_debt(user, customer_id),
        "creditLimit": _number(data.get("effective_credit_limit")),
        "lastPurchase": (str(last)[:10] if last else ""),
        "lifetimeSpend": _number(data.get("rfm_monetary")),
        "orderCount": data.get("rfm_frequency"),
    }
    props = {key: value for key, value in props.items() if value not in (None, "")}
    surface = _surface(f"customer-{props['customerId']}", props["name"], props)
    summary = {
        key: props.get(key)
        for key in ("name", "balanceDue", "creditLimit", "segmentLabel", "lastPurchase")
    }
    return {"ok": True, "shown": surface is not None, "customer": summary}, surface


def _trend(orders, start, end):
    """Daily revenue for windows up to ~3 months, monthly beyond that."""
    monthly = (end - start).days > 92
    bucket = TruncMonth("created_at") if monthly else TruncDate("created_at")
    rows = (
        orders.committed_sales()
        # Drop the viewset's ordering: an ORDER BY column would join the GROUP BY.
        .order_by()
        .annotate(bucket=bucket)
        .values("bucket")
        .annotate(revenue=Sum("total"), orders=Count("id"))
        .order_by("bucket")
    )
    points = []
    for row in rows:
        label = row["bucket"]
        label = label.strftime("%Y-%m" if monthly else "%m-%d") if label else ""
        points.append({"label": label, "value": _number(row["revenue"]) or 0.0})
    return points


def _top_products(orders, limit=3):
    from apps.sales.models import OrderLine

    from .tools import _line_revenue_expr

    rows = (
        OrderLine.objects.filter(order__in=orders.committed_sales())
        .values("variant__product_id", "variant__product__name")
        .annotate(revenue=Sum(_line_revenue_expr()), units=Sum("quantity"))
        .order_by("-revenue")[:limit]
    )
    return [
        {
            "productId": row["variant__product_id"],
            "name": row["variant__product__name"] or "",
            "revenue": _number(row["revenue"]) or 0.0,
            "units": _number(row["units"]) or 0.0,
        }
        for row in rows
    ]


def show_sales_summary(*, user, period=None):
    """The sales card: the period's takings against the one before it, the shape
    of the period, and what sold best."""
    from .tools import _resolve_period, _scoped_orders, compare_periods

    period = period if period in PERIOD_LABELS else "last_30_days"
    compared = compare_periods(user=user, period=period)
    if not compared.get("ok"):
        return compared, None
    figures = compared["data"]
    current, change = figures["current"], figures["change"]
    start, end = _resolve_period(period, timezone.localdate())
    orders, err = _scoped_orders(user, start=start, end=end)
    if err is not None:
        return err, None
    revenue = _number(current.get("revenue")) or 0.0
    order_count = current.get("order_count") or 0
    props = {
        "component": "SalesSummaryCard",
        "periodLabel": PERIOD_LABELS[period],
        "revenue": revenue,
        "orders": order_count,
        "averageTicket": round(revenue / order_count, 2) if order_count else 0.0,
        "revenueChange": change.get("revenue_percent"),
        "ordersChange": change.get("orders_percent"),
        "trend": _trend(orders, start, end),
        "topProducts": _top_products(orders),
    }
    if "profit" in current:
        props["profit"] = _number(current.get("profit"))
        props["marginPercent"] = current.get("margin_percent")
    props = {key: value for key, value in props.items() if value is not None}
    surface = _surface(f"sales-{period}", props["periodLabel"], props)
    summary = {
        key: props.get(key)
        for key in ("periodLabel", "revenue", "orders", "averageTicket", "revenueChange", "profit")
    }
    summary["top_products"] = [p["name"] for p in props["topProducts"]]
    return {"ok": True, "shown": surface is not None, "sales": summary}, surface


SURFACE_TOOLS = {
    "show_product": lambda user, args: show_product(user=user, product_id=args.get("product_id")),
    "show_customer": lambda user, args: show_customer(user=user, customer_id=args.get("customer_id")),
    "show_sales_summary": lambda user, args: show_sales_summary(user=user, period=args.get("period")),
}


def pos_card_tool_definitions():
    """The three card tools, advertised with the other UI tools."""
    note = (
        " البطاقة تُرسم تلقائيًا من البيانات الحقيقية؛ لا تكرّر أرقامها في النص — "
        "اكتب سطرًا واحدًا بالخلاصة أو ما يستحق الانتباه."
    )
    return [
        {
            "type": "function",
            "function": {
                "name": "show_product",
                "description": (
                    "اعرض بطاقة منتج: السعر والمخزون وما بيع منه في آخر ٣٠ يومًا وكم يكفي "
                    "المخزون. استخدمها عند السؤال عن منتج بعينه (سعره، مخزونه، حركته)." + note
                ),
                "parameters": {
                    "type": "object",
                    "properties": {"product_id": {"type": "integer", "description": "معرّف المنتج."}},
                    "required": ["product_id"],
                    "additionalProperties": False,
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "show_customer",
                "description": (
                    "اعرض بطاقة عميل: بياناته ودَينه الحالي وحدّه الائتماني وتصنيفه وآخر "
                    "شراء. استخدمها عند السؤال عن عميل بعينه." + note
                ),
                "parameters": {
                    "type": "object",
                    "properties": {"customer_id": {"type": "integer", "description": "معرّف العميل."}},
                    "required": ["customer_id"],
                    "additionalProperties": False,
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "show_sales_summary",
                "description": (
                    "اعرض بطاقة ملخّص المبيعات لفترة: الإيراد وعدد الفواتير ومتوسط الفاتورة "
                    "مقارنةً بالفترة السابقة، ومنحنى الفترة، والأكثر مبيعًا. استخدمها لأسئلة "
                    "«كيف المبيعات؟» و«كم بعنا هذا الأسبوع؟»." + note
                ),
                "parameters": {
                    "type": "object",
                    "properties": {
                        "period": {
                            "type": "string",
                            "enum": list(PERIOD_LABELS),
                            "description": "الفترة؛ الافتراضي آخر ٣٠ يومًا.",
                        }
                    },
                    "additionalProperties": False,
                },
            },
        },
    ]
