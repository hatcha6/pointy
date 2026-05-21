import hashlib
import json
from dataclasses import dataclass
from datetime import datetime, time, timedelta
from decimal import Decimal

from django.db.models import Count, DecimalField, F, Q, Sum, Value
from django.db.models.functions import Coalesce
from django.utils import timezone
from django.utils.dateparse import parse_date

from apps.catalog.models import Product
from apps.core.roles import user_is_manager
from apps.inventory.models import StockItem, StockMovement
from apps.payments.models import Payment
from apps.purchasing.models import PurchaseOrder, Supplier, SupplierPayment
from apps.sales.models import Order, OrderAdjustment, OrderLine, RegisterSession

from .models import ReportRun

MONEY_PLACES = Decimal("0.01")
MONEY_FIELD = DecimalField(max_digits=12, decimal_places=2)


class ReportValidationError(ValueError):
    pass


class ReportAccessDenied(PermissionError):
    pass


@dataclass(frozen=True)
class ReportDefinition:
    key: str
    category: str
    permissions: tuple[str, ...]
    default_output_format: str = ReportRun.OutputFormat.PDF

    def is_allowed(self, user):
        if user_is_manager(user):
            return True
        return all(user.has_perm(permission) for permission in self.permissions)


REPORT_DEFINITIONS = {
    ReportRun.ReportType.SALES_SUMMARY: ReportDefinition(
        key=ReportRun.ReportType.SALES_SUMMARY,
        category="sales",
        permissions=("sales.view_order",),
    ),
    ReportRun.ReportType.PAYMENT_METHODS: ReportDefinition(
        key=ReportRun.ReportType.PAYMENT_METHODS,
        category="payments",
        permissions=("payments.view_payment",),
    ),
    ReportRun.ReportType.REGISTER_CLOSURE: ReportDefinition(
        key=ReportRun.ReportType.REGISTER_CLOSURE,
        category="sales",
        permissions=("sales.view_registersession",),
    ),
    ReportRun.ReportType.INVENTORY_STATUS: ReportDefinition(
        key=ReportRun.ReportType.INVENTORY_STATUS,
        category="inventory",
        permissions=("inventory.view_stockitem",),
    ),
    ReportRun.ReportType.STOCK_MOVEMENTS: ReportDefinition(
        key=ReportRun.ReportType.STOCK_MOVEMENTS,
        category="inventory",
        permissions=("inventory.view_stockmovement",),
    ),
    ReportRun.ReportType.PURCHASING_SUMMARY: ReportDefinition(
        key=ReportRun.ReportType.PURCHASING_SUMMARY,
        category="purchasing",
        permissions=("purchasing.view_purchaseorder",),
    ),
}


def report_catalog_for_user(user):
    return [
        {
            "key": definition.key,
            "category": definition.category,
            "default_output_format": definition.default_output_format,
            "permissions": definition.permissions,
        }
        for definition in REPORT_DEFINITIONS.values()
        if definition.is_allowed(user)
    ]


def create_report_run(*, user, report_type, params, output_format):
    run = ReportRun.objects.create(
        requested_by=user if user.is_authenticated else None,
        report_type=report_type,
        params=params or {},
        output_format=output_format,
    )
    try:
        payload = generate_report_payload(
            report_type=report_type,
            params=params or {},
            user=user,
        )
    except Exception as exc:
        run.mark_failed(exc)
        raise

    checksum = report_checksum(payload)
    run.mark_success(
        payload=payload,
        row_count=_row_count(payload),
        checksum=checksum,
    )
    return run


def generate_report_payload(*, report_type, params, user):
    definition = REPORT_DEFINITIONS.get(report_type)
    if definition is None:
        raise ReportValidationError("Unknown report type.")
    if not definition.is_allowed(user):
        raise ReportAccessDenied("You do not have permission to run this report.")

    period = _period_from_params(params)
    builder = {
        ReportRun.ReportType.SALES_SUMMARY: _sales_summary_report,
        ReportRun.ReportType.PAYMENT_METHODS: _payment_methods_report,
        ReportRun.ReportType.REGISTER_CLOSURE: _register_closure_report,
        ReportRun.ReportType.INVENTORY_STATUS: _inventory_status_report,
        ReportRun.ReportType.STOCK_MOVEMENTS: _stock_movements_report,
        ReportRun.ReportType.PURCHASING_SUMMARY: _purchasing_summary_report,
    }[report_type]
    payload = builder(user, period)
    payload.update(
        {
            "report_type": report_type,
            "category": definition.category,
            "period": {
                "start_date": period["start_date"].isoformat(),
                "end_date": period["end_date"].isoformat(),
            },
            "generated_at": timezone.now().isoformat(),
        }
    )
    return payload


def report_checksum(payload):
    encoded = json.dumps(payload, sort_keys=True, default=str).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def _sales_summary_report(user, period):
    orders = _settled_orders(user).filter(
        created_at__gte=period["start"],
        created_at__lt=period["end"],
    )
    adjustments = _order_adjustments(user).filter(
        created_at__gte=period["start"],
        created_at__lt=period["end"],
    )
    order_values = orders.aggregate(
        gross_sales=Coalesce(
            Sum("subtotal"),
            Value(Decimal("0.00")),
            output_field=MONEY_FIELD,
        ),
        discount_total=Coalesce(
            Sum("discount_total"),
            Value(Decimal("0.00")),
            output_field=MONEY_FIELD,
        ),
        order_total=Coalesce(
            Sum("total"),
            Value(Decimal("0.00")),
            output_field=MONEY_FIELD,
        ),
        paid_order_count=Count("id", filter=Q(status=Order.Status.PAID)),
        voided_order_count=Count("id", filter=Q(status=Order.Status.VOID)),
    )
    adjustment_values = adjustments.aggregate(
        refund_total=Coalesce(
            Sum("amount"),
            Value(Decimal("0.00")),
            output_field=MONEY_FIELD,
        ),
        return_count=Count(
            "id",
            filter=Q(adjustment_type=OrderAdjustment.AdjustmentType.RETURN),
        ),
    )
    line_values = OrderLine.objects.filter(order__in=orders).aggregate(
        items_sold=Coalesce(Sum("quantity"), Value(0)),
        profit=Coalesce(
            Sum(
                F("quantity") * (F("unit_price") - F("unit_cost"))
                - F("discount_total"),
                output_field=MONEY_FIELD,
            ),
            Value(Decimal("0.00")),
            output_field=MONEY_FIELD,
        ),
    )
    net_sales = order_values["order_total"] - adjustment_values["refund_total"]
    profit = line_values["profit"] - adjustment_values["refund_total"]
    top_products = _product_sales_rows(orders)
    return {
        "summary": {
            "gross_sales": _money(order_values["gross_sales"]),
            "discount_total": _money(order_values["discount_total"]),
            "refund_total": _money(adjustment_values["refund_total"]),
            "net_sales": _money(net_sales),
            "gross_profit": _money(profit),
            "profit_margin_percent": _percent(profit, net_sales),
            "paid_order_count": order_values["paid_order_count"],
            "voided_order_count": order_values["voided_order_count"],
            "return_count": adjustment_values["return_count"],
            "items_sold": line_values["items_sold"] or 0,
        },
        "sections": [
            _metric_section(
                [
                    ("gross_sales", _money(order_values["gross_sales"])),
                    ("discount_total", _money(order_values["discount_total"])),
                    ("refund_total", _money(adjustment_values["refund_total"])),
                    ("net_sales", _money(net_sales)),
                    ("gross_profit", _money(profit)),
                    ("profit_margin_percent", _percent(profit, net_sales)),
                    ("paid_order_count", order_values["paid_order_count"]),
                    ("voided_order_count", order_values["voided_order_count"]),
                    ("return_count", adjustment_values["return_count"]),
                    ("items_sold", line_values["items_sold"] or 0),
                ]
            ),
            {
                "key": "top_products",
                "columns": ["product_name", "quantity", "revenue", "profit"],
                "rows": top_products,
            },
            {
                "key": "recent_orders",
                "columns": ["receipt_number", "status", "total", "created_at"],
                "rows": [
                    {
                        "receipt_number": order.receipt_number,
                        "status": order.status,
                        "total": _money(order.total),
                        "created_at": order.created_at.isoformat(),
                    }
                    for order in orders.order_by("-created_at")[:24]
                ],
            },
        ],
    }


def _payment_methods_report(user, period):
    payments = _payments(user).filter(
        created_at__gte=period["start"],
        created_at__lt=period["end"],
    )
    rows = [
        {
            "method": row["method"],
            "total": _money(row["total"]),
            "commission": _money(row["commission"]),
            "count": row["count"],
        }
        for row in payments.values("method")
        .annotate(
            total=Coalesce(
                Sum("amount"),
                Value(Decimal("0.00")),
                output_field=MONEY_FIELD,
            ),
            commission=Coalesce(
                Sum("commission_amount"),
                Value(Decimal("0.00")),
                output_field=MONEY_FIELD,
            ),
            count=Count("id"),
        )
        .order_by("-total", "method")
    ]
    total = sum((_decimal_from(row["total"]) for row in rows), Decimal("0.00"))
    commission = sum(
        (_decimal_from(row["commission"]) for row in rows),
        Decimal("0.00"),
    )
    return {
        "summary": {
            "payment_total": _money(total),
            "commission_total": _money(commission),
            "payment_count": payments.count(),
        },
        "sections": [
            _metric_section(
                [
                    ("payment_total", _money(total)),
                    ("commission_total", _money(commission)),
                    ("payment_count", payments.count()),
                ]
            ),
            {
                "key": "payment_methods",
                "columns": ["method", "total", "commission", "count"],
                "rows": rows,
            },
        ],
    }


def _register_closure_report(user, period):
    sessions = _register_sessions(user).filter(
        created_at__gte=period["start"],
        created_at__lt=period["end"],
    )
    rows = [
        {
            "session_number": session.session_number,
            "status": session.status,
            "opened_at": session.opened_at.isoformat(),
            "closed_at": session.closed_at.isoformat() if session.closed_at else "",
            "opening_cash": _money(session.opening_cash),
            "closing_cash": _money(session.closing_cash),
            "expected_cash": _money(session.expected_cash),
            "cash_variance": _money(session.cash_variance),
            "pay_in_total": _money(session.pay_in_total),
            "pay_out_total": _money(session.pay_out_total),
        }
        for session in sessions.order_by("-opened_at")[:200]
    ]
    variance_total = sum(
        (_decimal_from(row["cash_variance"]) for row in rows),
        Decimal("0.00"),
    )
    return {
        "summary": {
            "open_count": sessions.filter(status=RegisterSession.Status.OPEN).count(),
            "closed_count": sessions.filter(
                status=RegisterSession.Status.CLOSED,
            ).count(),
            "variance_total": _money(variance_total),
            "session_count": sessions.count(),
        },
        "sections": [
            _metric_section(
                [
                    ("session_count", sessions.count()),
                    ("open_count", sessions.filter(status=RegisterSession.Status.OPEN).count()),
                    (
                        "closed_count",
                        sessions.filter(status=RegisterSession.Status.CLOSED).count(),
                    ),
                    ("variance_total", _money(variance_total)),
                ]
            ),
            {
                "key": "register_sessions",
                "columns": [
                    "session_number",
                    "status",
                    "opening_cash",
                    "closing_cash",
                    "expected_cash",
                    "cash_variance",
                    "opened_at",
                    "closed_at",
                ],
                "rows": rows,
            },
        ],
    }


def _inventory_status_report(user, period):
    stock = StockItem.objects.select_related("variant", "variant__product")
    value_expr = F("quantity_on_hand") * F("variant__unit_price")
    retail_value = stock.aggregate(
        total=Coalesce(
            Sum(value_expr, output_field=MONEY_FIELD),
            Value(Decimal("0.00")),
            output_field=MONEY_FIELD,
        )
    )["total"]
    low_stock = stock.filter(quantity_on_hand__lte=F("reorder_level"))
    rows = [
        {
            "product_name": item.variant.full_name,
            "sku": item.variant.sku,
            "quantity_on_hand": item.quantity_on_hand,
            "quantity_committed": item.quantity_committed,
            "quantity_expected": item.quantity_expected,
            "reorder_level": item.reorder_level,
            "retail_value": _money(item.quantity_on_hand * item.variant.unit_price),
        }
        for item in stock.order_by(
            "quantity_on_hand",
            "variant__product__name",
            "variant__name",
        )[:250]
    ]
    return {
        "summary": {
            "product_count": Product.objects.count(),
            "stock_item_count": stock.count(),
            "low_stock_count": low_stock.count(),
            "out_of_stock_count": stock.filter(quantity_on_hand__lte=0).count(),
            "retail_stock_value": _money(retail_value),
        },
        "sections": [
            _metric_section(
                [
                    ("product_count", Product.objects.count()),
                    ("stock_item_count", stock.count()),
                    ("low_stock_count", low_stock.count()),
                    ("out_of_stock_count", stock.filter(quantity_on_hand__lte=0).count()),
                    ("retail_stock_value", _money(retail_value)),
                ]
            ),
            {
                "key": "inventory_items",
                "columns": [
                    "product_name",
                    "sku",
                    "quantity_on_hand",
                    "quantity_committed",
                    "quantity_expected",
                    "reorder_level",
                    "retail_value",
                ],
                "rows": rows,
            },
        ],
    }


def _stock_movements_report(user, period):
    movements = StockMovement.objects.select_related(
        "variant",
        "variant__product",
        "created_by",
    ).filter(
        created_at__gte=period["start"],
        created_at__lt=period["end"],
    )
    rows = [
        {
            "created_at": movement.created_at.isoformat(),
            "product_name": movement.variant.full_name,
            "sku": movement.variant.sku,
            "movement_type": movement.movement_type,
            "quantity": movement.quantity,
            "on_hand_before": movement.on_hand_before,
            "on_hand_after": movement.on_hand_after,
            "created_by": movement.created_by.username if movement.created_by_id else "",
            "note": movement.note,
        }
        for movement in movements.order_by("-created_at", "-id")[:300]
    ]
    mix_rows = [
        {
            "movement_type": row["movement_type"],
            "quantity": row["quantity"],
            "count": row["count"],
        }
        for row in movements.values("movement_type")
        .annotate(quantity=Coalesce(Sum("quantity"), Value(0)), count=Count("id"))
        .order_by("movement_type")
    ]
    return {
        "summary": {
            "movement_count": movements.count(),
            "quantity_moved": sum((row["quantity"] for row in mix_rows), 0),
        },
        "sections": [
            _metric_section(
                [
                    ("movement_count", movements.count()),
                    ("quantity_moved", sum((row["quantity"] for row in mix_rows), 0)),
                ]
            ),
            {
                "key": "movement_mix",
                "columns": ["movement_type", "quantity", "count"],
                "rows": mix_rows,
            },
            {
                "key": "stock_movements",
                "columns": [
                    "created_at",
                    "product_name",
                    "sku",
                    "movement_type",
                    "quantity",
                    "on_hand_before",
                    "on_hand_after",
                    "created_by",
                    "note",
                ],
                "rows": rows,
            },
        ],
    }


def _purchasing_summary_report(user, period):
    orders = PurchaseOrder.objects.select_related("supplier").exclude(
        status=PurchaseOrder.Status.CANCELLED,
    )
    period_orders = orders.filter(
        created_at__gte=period["start"],
        created_at__lt=period["end"],
    )
    purchase_total = period_orders.aggregate(
        total=Coalesce(
            Sum("total"),
            Value(Decimal("0.00")),
            output_field=MONEY_FIELD,
        )
    )["total"]
    rows = [
        {
            "order_number": order.order_number,
            "supplier_name": order.supplier.name,
            "status": order.status,
            "total": _money(order.total),
            "balance_due": _money(order.balance_due),
            "created_at": order.created_at.isoformat(),
            "due_date": order.due_date.isoformat() if order.due_date else "",
        }
        for order in period_orders.order_by("-created_at")[:200]
    ]
    supplier_rows = [
        {
            "supplier_name": supplier.name,
            "payable_balance": _money(supplier.payable_balance),
            "credit_balance": _money(supplier.credit_balance),
            "net_balance": _money(supplier.net_balance),
        }
        for supplier in Supplier.objects.filter(is_active=True).order_by("name")[:100]
    ]
    return {
        "summary": {
            "purchase_total": _money(purchase_total),
            "purchase_order_count": period_orders.count(),
            "open_order_count": orders.exclude(
                status=PurchaseOrder.Status.RECEIVED,
            ).count(),
            "supplier_count": Supplier.objects.filter(is_active=True).count(),
        },
        "sections": [
            _metric_section(
                [
                    ("purchase_total", _money(purchase_total)),
                    ("purchase_order_count", period_orders.count()),
                    (
                        "open_order_count",
                        orders.exclude(status=PurchaseOrder.Status.RECEIVED).count(),
                    ),
                    ("supplier_count", Supplier.objects.filter(is_active=True).count()),
                ]
            ),
            {
                "key": "purchase_orders",
                "columns": [
                    "order_number",
                    "supplier_name",
                    "status",
                    "total",
                    "balance_due",
                    "created_at",
                    "due_date",
                ],
                "rows": rows,
            },
            {
                "key": "supplier_balances",
                "columns": [
                    "supplier_name",
                    "payable_balance",
                    "credit_balance",
                    "net_balance",
                ],
                "rows": supplier_rows,
            },
        ],
    }


def _metric_section(metrics):
    return {
        "key": "summary",
        "columns": ["metric", "value"],
        "rows": [{"metric": metric, "value": value} for metric, value in metrics],
    }


def _product_sales_rows(orders):
    revenue_expr = F("quantity") * F("unit_price") - F("discount_total")
    profit_expr = F("quantity") * (F("unit_price") - F("unit_cost")) - F(
        "discount_total"
    )
    rows = (
        OrderLine.objects.filter(order__in=orders)
        .values("variant__product__name")
        .annotate(
            units_sold=Coalesce(Sum("quantity"), Value(0)),
            revenue=Coalesce(
                Sum(revenue_expr, output_field=MONEY_FIELD),
                Value(Decimal("0.00")),
                output_field=MONEY_FIELD,
            ),
            profit=Coalesce(
                Sum(profit_expr, output_field=MONEY_FIELD),
                Value(Decimal("0.00")),
                output_field=MONEY_FIELD,
            ),
        )
        .order_by("-revenue", "variant__product__name")[:24]
    )
    return [
        {
            "product_name": row["variant__product__name"],
            "quantity": row["units_sold"],
            "revenue": _money(row["revenue"]),
            "profit": _money(row["profit"]),
        }
        for row in rows
    ]


def _settled_orders(user):
    queryset = Order.objects.filter(status__in=(Order.Status.PAID, Order.Status.VOID))
    if user_is_manager(user):
        return queryset
    return queryset.filter(register_session__owner_key=_owner_key(user))


def _order_adjustments(user):
    queryset = OrderAdjustment.objects.all()
    if user_is_manager(user):
        return queryset
    return queryset.filter(register_session__owner_key=_owner_key(user))


def _payments(user):
    queryset = Payment.objects.select_related("order", "order__register_session")
    if user_is_manager(user):
        return queryset
    return queryset.filter(order__register_session__owner_key=_owner_key(user))


def _register_sessions(user):
    queryset = RegisterSession.objects.all()
    if user_is_manager(user):
        return queryset
    return queryset.filter(owner_key=_owner_key(user))


def _owner_key(user):
    return f"user:{user.pk}"


def _period_from_params(params):
    today = timezone.localdate()
    end_date = _parse_date_param(params.get("end_date"), default=today)
    start_date = _parse_date_param(
        params.get("start_date"),
        default=end_date - timedelta(days=29),
    )
    if start_date > end_date:
        raise ReportValidationError("Start date must be before end date.")
    if (end_date - start_date).days > 366:
        raise ReportValidationError("Report period cannot be longer than 366 days.")

    current_tz = timezone.get_current_timezone()
    start = timezone.make_aware(datetime.combine(start_date, time.min), current_tz)
    end = timezone.make_aware(
        datetime.combine(end_date + timedelta(days=1), time.min),
        current_tz,
    )
    return {
        "start_date": start_date,
        "end_date": end_date,
        "start": start,
        "end": end,
    }


def _parse_date_param(value, *, default):
    if value in (None, ""):
        return default
    parsed = parse_date(str(value))
    if parsed is None:
        raise ReportValidationError("Dates must use YYYY-MM-DD format.")
    return parsed


def _row_count(payload):
    return sum(len(section.get("rows", [])) for section in payload.get("sections", []))


def _money(value):
    return str(_decimal_from(value).quantize(MONEY_PLACES))


def _decimal_from(value):
    if value is None or value == "":
        return Decimal("0.00")
    if isinstance(value, Decimal):
        return value
    return Decimal(str(value))


def _percent(numerator, denominator):
    denominator = _decimal_from(denominator)
    if denominator == 0:
        return "0.00"
    return str(((_decimal_from(numerator) / denominator) * Decimal("100")).quantize(MONEY_PLACES))
