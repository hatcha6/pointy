import hashlib
import json
import time as monotonic_time
from dataclasses import dataclass
from datetime import datetime, time, timedelta
from decimal import Decimal

from django.db.models import Count, DecimalField, F, Q, Sum, Value
from django.db.models.functions import Coalesce
from django.utils import timezone
from django.utils.dateparse import parse_date

QTY_FIELD = DecimalField(max_digits=14, decimal_places=3)
ZERO_QTY = Value(Decimal("0"), output_field=QTY_FIELD)

from apps.analytics.models import AnalyticsEvent
from apps.analytics.services import record_domain_event
from apps.catalog.models import Product
from apps.core.roles import user_is_manager
from apps.employees.models import Employee, PayrollLine, PayrollRun
from apps.expenses.models import Expense
from apps.inventory.models import StockItem, StockMovement
from apps.payments.models import Payment
from apps.purchasing.models import (
    prime_supplier_balances,
    PurchaseOrder,
    Supplier,
    SupplierPayment,
)
from apps.sales.models import (
    Order,
    OrderAdjustment,
    OrderLine,
    RegisterCashMovement,
    RegisterSession,
    returned_cost_total,
)

from .models import ReportRun

MONEY_PLACES = Decimal("0.01")
MONEY_FIELD = DecimalField(max_digits=12, decimal_places=2)
DEFAULT_DETAIL_ROW_LIMIT = 120
SHORT_DETAIL_ROW_LIMIT = 24
CHOICE_DETAIL_ROW_LIMIT = 32

REPORT_SECTION_ROW_LIMITS = {
    "top_products": SHORT_DETAIL_ROW_LIMIT,
    "recent_orders": SHORT_DETAIL_ROW_LIMIT,
    "payment_methods": CHOICE_DETAIL_ROW_LIMIT,
    "register_sessions": DEFAULT_DETAIL_ROW_LIMIT,
    "inventory_items": DEFAULT_DETAIL_ROW_LIMIT,
    "movement_mix": CHOICE_DETAIL_ROW_LIMIT,
    "stock_movements": DEFAULT_DETAIL_ROW_LIMIT,
    "purchase_orders": DEFAULT_DETAIL_ROW_LIMIT,
    "supplier_balances": DEFAULT_DETAIL_ROW_LIMIT,
    "reorder_items": DEFAULT_DETAIL_ROW_LIMIT,
    "payroll_runs": DEFAULT_DETAIL_ROW_LIMIT,
    "employee_totals": DEFAULT_DETAIL_ROW_LIMIT,
    "cost_breakdown": CHOICE_DETAIL_ROW_LIMIT,
}


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


@dataclass(frozen=True)
class BoundedRows:
    rows: list
    total_count: int
    limit: int | None = None


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
    ReportRun.ReportType.REORDER_ITEMS: ReportDefinition(
        key=ReportRun.ReportType.REORDER_ITEMS,
        category="inventory",
        permissions=("inventory.view_stockitem",),
    ),
    ReportRun.ReportType.PAYROLL_SUMMARY: ReportDefinition(
        key=ReportRun.ReportType.PAYROLL_SUMMARY,
        category="employees",
        permissions=("employees.view_payrollrun",),
    ),
    ReportRun.ReportType.PROFIT_COSTS: ReportDefinition(
        key=ReportRun.ReportType.PROFIT_COSTS,
        category="sales",
        permissions=("sales.view_order", "employees.view_payrollrun"),
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
    started_at = monotonic_time.perf_counter()
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
        record_domain_event(
            name="reports.run.failed",
            event_type=AnalyticsEvent.EventType.ERROR,
            severity=AnalyticsEvent.Severity.ERROR,
            user=user,
            entity_type="report_run",
            entity_id=run.pk,
            attributes={
                "report_type": report_type,
                "output_format": output_format,
                "params_keys": sorted((params or {}).keys()),
                "error_type": exc.__class__.__name__,
                "error_message": str(exc)[:512],
            },
            metrics={
                "duration_ms": round(
                    (monotonic_time.perf_counter() - started_at) * 1000,
                    3,
                )
            },
        )
        raise

    checksum = report_checksum(payload)
    run.mark_success(
        payload=payload,
        row_count=_row_count(payload),
        checksum=checksum,
    )
    record_domain_event(
        name="reports.run.completed",
        event_type=AnalyticsEvent.EventType.AUDIT,
        user=user,
        entity_type="report_run",
        entity_id=run.pk,
        attributes={
            "report_type": report_type,
            "output_format": output_format,
            "status": run.status,
            "params_keys": sorted((params or {}).keys()),
            "checksum": checksum,
        },
        metrics={
            "row_count": run.row_count,
            "duration_ms": round(
                (monotonic_time.perf_counter() - started_at) * 1000,
                3,
            ),
        },
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
        ReportRun.ReportType.REORDER_ITEMS: _reorder_items_report,
        ReportRun.ReportType.PAYROLL_SUMMARY: _payroll_summary_report,
        ReportRun.ReportType.PROFIT_COSTS: _profit_costs_report,
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
    payload["audit"] = _payload_audit(payload)
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
        items_sold=Coalesce(Sum("quantity"), ZERO_QTY),
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
    # A refund reverses margin, not margin *plus* cost: the goods are restocked,
    # so their cost comes back with them.
    profit = (
        line_values["profit"]
        - adjustment_values["refund_total"]
        + returned_cost_total(adjustments)
    )
    top_products = _product_sales_rows(orders)
    recent_orders = _bounded_queryset(
        orders.order_by("-created_at"),
        limit=_section_row_limit("recent_orders"),
    )
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
            _report_section(
                "top_products",
                ["product_name", "quantity", "revenue", "profit"],
                top_products.rows,
                total_count=top_products.total_count,
                limit=top_products.limit,
            ),
            _report_section(
                "recent_orders",
                ["receipt_number", "status", "total", "created_at"],
                [
                    {
                        "receipt_number": order.receipt_number,
                        "status": order.status,
                        "total": _money(order.total),
                        "created_at": order.created_at.isoformat(),
                    }
                    for order in recent_orders.rows
                ],
                total_count=recent_orders.total_count,
                limit=recent_orders.limit,
            ),
        ],
    }


def _payment_methods_report(user, period):
    payments = _payments(user).filter(
        created_at__gte=period["start"],
        created_at__lt=period["end"],
    )
    method_rows = _bounded_queryset(
        payments.values("method")
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
        .order_by("-total", "method"),
        limit=_section_row_limit("payment_methods"),
    )
    rows = [
        {
            "method": row["method"],
            "total": _money(row["total"]),
            "commission": _money(row["commission"]),
            "count": row["count"],
        }
        for row in method_rows.rows
    ]
    total = sum((_decimal_from(row["total"]) for row in rows), Decimal("0.00"))
    commission = sum(
        (_decimal_from(row["commission"]) for row in rows),
        Decimal("0.00"),
    )
    payment_count = payments.count()
    return {
        "summary": {
            "payment_total": _money(total),
            "commission_total": _money(commission),
            "payment_count": payment_count,
        },
        "sections": [
            _metric_section(
                [
                    ("payment_total", _money(total)),
                    ("commission_total", _money(commission)),
                    ("payment_count", payment_count),
                ]
            ),
            _report_section(
                "payment_methods",
                ["method", "total", "commission", "count"],
                rows,
                total_count=method_rows.total_count,
                limit=method_rows.limit,
            ),
        ],
    }


def _register_closure_report(user, period):
    sessions = _register_sessions(user).filter(
        created_at__gte=period["start"],
        created_at__lt=period["end"],
    )
    session_count = sessions.count()
    open_count = sessions.filter(status=RegisterSession.Status.OPEN).count()
    closed_sessions = sessions.filter(status=RegisterSession.Status.CLOSED)
    closed_count = closed_sessions.count()
    cash_totals = _register_session_cash_totals(sessions)
    session_rows = _bounded_queryset(
        sessions.order_by("-opened_at"),
        limit=_section_row_limit("register_sessions"),
    )
    rows = [
        _register_session_row(session, cash_totals.get(session.pk, {}))
        for session in session_rows.rows
    ]
    variance_total = _register_variance_total(closed_sessions, cash_totals)
    return {
        "summary": {
            "open_count": open_count,
            "closed_count": closed_count,
            "variance_total": _money(variance_total),
            "session_count": session_count,
        },
        "sections": [
            _metric_section(
                [
                    ("session_count", session_count),
                    ("open_count", open_count),
                    ("closed_count", closed_count),
                    ("variance_total", _money(variance_total)),
                ]
            ),
            _report_section(
                "register_sessions",
                [
                    "session_number",
                    "status",
                    "opening_cash",
                    "closing_cash",
                    "expected_cash",
                    "cash_variance",
                    "opened_at",
                    "closed_at",
                ],
                rows,
                total_count=session_rows.total_count,
                limit=session_rows.limit,
            ),
        ],
    }


def _register_session_cash_totals(sessions):
    session_ids = sessions.values_list("pk", flat=True)
    totals = {}

    cash_sales = (
        # Attribute cash to the session that collected the payment (its own
        # register_session), independent of order status — see
        # RegisterSession.cash_sales_total.
        Payment.objects.filter(
            register_session_id__in=session_ids,
            method=Payment.Method.CASH,
            amount__gt=0,
        )
        .values("register_session_id")
        .annotate(
            total=Coalesce(
                Sum("amount"),
                Value(Decimal("0.00")),
                output_field=MONEY_FIELD,
            )
        )
    )
    for row in cash_sales:
        totals.setdefault(row["register_session_id"], {})["cash_sales_total"] = (
            row["total"]
        )

    cash_refunds = (
        # ``cash_amount`` is the cash-drawer share of each refund, so summing it
        # reconciles the drawer correctly for cash, card and split-tender refunds
        # alike (a card refund contributes 0).
        OrderAdjustment.objects.filter(
            register_session_id__in=session_ids,
        )
        .values("register_session_id")
        .annotate(
            total=Coalesce(
                Sum("cash_amount"),
                Value(Decimal("0.00")),
                output_field=MONEY_FIELD,
            )
        )
    )
    for row in cash_refunds:
        totals.setdefault(row["register_session_id"], {})["cash_refund_total"] = row[
            "total"
        ]

    cash_movements = (
        RegisterCashMovement.objects.filter(register_session_id__in=session_ids)
        .values("register_session_id", "movement_type")
        .annotate(
            total=Coalesce(
                Sum("amount"),
                Value(Decimal("0.00")),
                output_field=MONEY_FIELD,
            )
        )
    )
    for row in cash_movements:
        key = (
            "pay_in_total"
            if row["movement_type"] == RegisterCashMovement.MovementType.PAY_IN
            else "pay_out_total"
        )
        totals.setdefault(row["register_session_id"], {})[key] = row["total"]

    return totals


def _register_session_row(session, totals):
    expected_cash = _register_expected_cash(session, totals)
    cash_variance = _register_cash_variance(session, expected_cash)
    return {
        "session_number": session.session_number,
        "status": session.status,
        "opened_at": session.opened_at.isoformat(),
        "closed_at": session.closed_at.isoformat() if session.closed_at else "",
        "opening_cash": _money(session.opening_cash),
        "closing_cash": _money(session.closing_cash),
        "expected_cash": _money(expected_cash),
        "cash_variance": _money(cash_variance),
        "pay_in_total": _money(totals.get("pay_in_total")),
        "pay_out_total": _money(totals.get("pay_out_total")),
    }


def _register_variance_total(sessions, cash_totals):
    total = Decimal("0.00")
    for session in sessions.only("id", "opening_cash", "closing_cash"):
        expected_cash = _register_expected_cash(
            session,
            cash_totals.get(session.pk, {}),
        )
        cash_variance = _register_cash_variance(session, expected_cash)
        total += _decimal_from(cash_variance)
    return total


def _register_expected_cash(session, totals):
    total = (
        _decimal_from(session.opening_cash)
        + _decimal_from(totals.get("cash_sales_total"))
        + _decimal_from(totals.get("pay_in_total"))
    )
    total -= _decimal_from(totals.get("pay_out_total"))
    total -= _decimal_from(totals.get("cash_refund_total"))
    return total.quantize(MONEY_PLACES)


def _register_cash_variance(session, expected_cash):
    if session.closing_cash is None:
        return None
    return (_decimal_from(session.closing_cash) - expected_cash).quantize(MONEY_PLACES)


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
    stock_rows = _bounded_queryset(
        stock.order_by(
            "quantity_on_hand",
            "variant__product__name",
            "variant__name",
        ),
        limit=_section_row_limit("inventory_items"),
    )
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
        for item in stock_rows.rows
    ]
    product_count = Product.objects.count()
    stock_item_count = stock.count()
    low_stock_count = low_stock.count()
    out_of_stock_count = stock.filter(quantity_on_hand__lte=0).count()
    return {
        "summary": {
            "product_count": product_count,
            "stock_item_count": stock_item_count,
            "low_stock_count": low_stock_count,
            "out_of_stock_count": out_of_stock_count,
            "retail_stock_value": _money(retail_value),
        },
        "sections": [
            _metric_section(
                [
                    ("product_count", product_count),
                    ("stock_item_count", stock_item_count),
                    ("low_stock_count", low_stock_count),
                    ("out_of_stock_count", out_of_stock_count),
                    ("retail_stock_value", _money(retail_value)),
                ]
            ),
            _report_section(
                "inventory_items",
                [
                    "product_name",
                    "sku",
                    "quantity_on_hand",
                    "quantity_committed",
                    "quantity_expected",
                    "reorder_level",
                    "retail_value",
                ],
                rows,
                total_count=stock_rows.total_count,
                limit=stock_rows.limit,
            ),
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
    movement_rows = _bounded_queryset(
        movements.order_by("-created_at", "-id"),
        limit=_section_row_limit("stock_movements"),
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
            "created_by": (
                movement.created_by.username if movement.created_by_id else ""
            ),
            "note": movement.note,
        }
        for movement in movement_rows.rows
    ]
    mix_row_values = _bounded_queryset(
        movements.values("movement_type")
        .annotate(quantity=Coalesce(Sum("quantity"), ZERO_QTY), count=Count("id"))
        .order_by("movement_type"),
        limit=_section_row_limit("movement_mix"),
    )
    mix_rows = [
        {
            "movement_type": row["movement_type"],
            "quantity": row["quantity"],
            "count": row["count"],
        }
        for row in mix_row_values.rows
    ]
    quantity_moved = movements.aggregate(
        quantity=Coalesce(Sum("quantity"), ZERO_QTY),
    )["quantity"]
    movement_count = movements.count()
    return {
        "summary": {
            "movement_count": movement_count,
            "quantity_moved": quantity_moved,
        },
        "sections": [
            _metric_section(
                [
                    ("movement_count", movement_count),
                    ("quantity_moved", quantity_moved),
                ]
            ),
            _report_section(
                "movement_mix",
                ["movement_type", "quantity", "count"],
                mix_rows,
                total_count=mix_row_values.total_count,
                limit=mix_row_values.limit,
            ),
            _report_section(
                "stock_movements",
                [
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
                rows,
                total_count=movement_rows.total_count,
                limit=movement_rows.limit,
            ),
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
    purchase_rows = _bounded_queryset(
        period_orders.order_by("-created_at"),
        limit=_section_row_limit("purchase_orders"),
    )
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
        for order in purchase_rows.rows
    ]
    supplier_row_values = _bounded_queryset(
        Supplier.objects.filter(is_active=True).order_by("name"),
        limit=_section_row_limit("supplier_balances"),
    )
    # Each row reads payable/credit/net — 6 queries per supplier unless primed.
    prime_supplier_balances(supplier_row_values.rows)
    supplier_rows = [
        {
            "supplier_name": supplier.name,
            "payable_balance": _money(supplier.payable_balance),
            "credit_balance": _money(supplier.credit_balance),
            "net_balance": _money(supplier.net_balance),
        }
        for supplier in supplier_row_values.rows
    ]
    purchase_order_count = period_orders.count()
    open_order_count = orders.exclude(status=PurchaseOrder.Status.RECEIVED).count()
    supplier_count = Supplier.objects.filter(is_active=True).count()
    return {
        "summary": {
            "purchase_total": _money(purchase_total),
            "purchase_order_count": purchase_order_count,
            "open_order_count": open_order_count,
            "supplier_count": supplier_count,
        },
        "sections": [
            _metric_section(
                [
                    ("purchase_total", _money(purchase_total)),
                    ("purchase_order_count", purchase_order_count),
                    ("open_order_count", open_order_count),
                    ("supplier_count", supplier_count),
                ]
            ),
            _report_section(
                "purchase_orders",
                [
                    "order_number",
                    "supplier_name",
                    "status",
                    "total",
                    "balance_due",
                    "created_at",
                    "due_date",
                ],
                rows,
                total_count=purchase_rows.total_count,
                limit=purchase_rows.limit,
            ),
            _report_section(
                "supplier_balances",
                [
                    "supplier_name",
                    "payable_balance",
                    "credit_balance",
                    "net_balance",
                ],
                supplier_rows,
                total_count=supplier_row_values.total_count,
                limit=supplier_row_values.limit,
            ),
        ],
    }


def _reorder_items_report(user, period):
    stock = StockItem.objects.select_related("variant", "variant__product").filter(
        quantity_on_hand__lte=F("reorder_level"),
    )
    bounded = _bounded_queryset(
        stock.order_by(
            "quantity_on_hand",
            "variant__product__name",
            "variant__name",
        ),
        limit=_section_row_limit("reorder_items"),
    )
    rows = []
    suggested_units = 0
    for item in bounded.rows:
        # Restock back to twice the reorder level, counting stock already on
        # the way so the owner does not double-order.
        suggested = max(
            item.reorder_level * 2
            - item.quantity_on_hand
            - item.quantity_expected,
            0,
        )
        suggested_units += suggested
        rows.append(
            {
                "product_name": item.variant.full_name,
                "sku": item.variant.sku,
                "quantity_on_hand": item.quantity_on_hand,
                "quantity_expected": item.quantity_expected,
                "reorder_level": item.reorder_level,
                "suggested_quantity": suggested,
            }
        )

    out_of_stock_count = stock.filter(quantity_on_hand__lte=0).count()
    return {
        "summary": {
            "reorder_item_count": bounded.total_count,
            "out_of_stock_count": out_of_stock_count,
            "suggested_units": suggested_units,
        },
        "sections": [
            _metric_section(
                [
                    ("reorder_item_count", bounded.total_count),
                    ("out_of_stock_count", out_of_stock_count),
                    ("suggested_units", suggested_units),
                ]
            ),
            _report_section(
                "reorder_items",
                [
                    "product_name",
                    "sku",
                    "quantity_on_hand",
                    "quantity_expected",
                    "reorder_level",
                    "suggested_quantity",
                ],
                rows,
                total_count=bounded.total_count,
                limit=bounded.limit,
            ),
        ],
    }


def _payroll_summary_report(user, period):
    runs = PayrollRun.objects.exclude(status=PayrollRun.Status.VOID).filter(
        period_end__gte=period["start_date"],
        period_start__lte=period["end_date"],
    )
    money_sum = lambda field: Coalesce(  # noqa: E731
        Sum(field),
        Value(Decimal("0.00")),
        output_field=MONEY_FIELD,
    )
    salary_expense = runs.filter(
        status__in=(PayrollRun.Status.APPROVED, PayrollRun.Status.PAID),
    ).aggregate(total=money_sum("net_total"))["total"]
    paid_total = runs.filter(status=PayrollRun.Status.PAID).aggregate(
        total=money_sum("net_total"),
    )["total"]
    pending_total = runs.filter(status=PayrollRun.Status.APPROVED).aggregate(
        total=money_sum("net_total"),
    )["total"]

    bounded_runs = _bounded_queryset(
        runs.order_by("-period_end", "-id"),
        limit=_section_row_limit("payroll_runs"),
    )
    run_rows = [
        {
            "run_number": run.run_number,
            "status": run.status,
            "period_start": run.period_start.isoformat(),
            "period_end": run.period_end.isoformat(),
            "gross_total": _money(run.gross_total),
            "deductions_total": _money(run.deductions_total),
            "net_total": _money(run.net_total),
        }
        for run in bounded_runs.rows
    ]

    employee_values = (
        PayrollLine.objects.filter(payroll_run__in=runs)
        .values("employee__full_name")
        .annotate(
            gross_total=money_sum("gross_amount"),
            additions_total=money_sum("additions_amount"),
            deductions_total=money_sum("deductions_amount"),
            net_total=money_sum("net_amount"),
        )
        .order_by("-net_total")
    )
    bounded_employees = _bounded_queryset(
        employee_values,
        limit=_section_row_limit("employee_totals"),
    )
    employee_rows = [
        {
            "employee_name": row["employee__full_name"],
            "gross_total": _money(row["gross_total"]),
            "additions_total": _money(row["additions_total"]),
            "deductions_total": _money(row["deductions_total"]),
            "net_total": _money(row["net_total"]),
        }
        for row in bounded_employees.rows
    ]

    payroll_run_count = runs.count()
    active_employee_count = Employee.objects.filter(
        status=Employee.Status.ACTIVE,
    ).count()
    return {
        "summary": {
            "salary_expense": _money(salary_expense),
            "paid_total": _money(paid_total),
            "pending_total": _money(pending_total),
            "payroll_run_count": payroll_run_count,
            "active_employee_count": active_employee_count,
        },
        "sections": [
            _metric_section(
                [
                    ("salary_expense", _money(salary_expense)),
                    ("paid_total", _money(paid_total)),
                    ("pending_total", _money(pending_total)),
                    ("payroll_run_count", payroll_run_count),
                    ("active_employee_count", active_employee_count),
                ]
            ),
            _report_section(
                "payroll_runs",
                [
                    "run_number",
                    "status",
                    "period_start",
                    "period_end",
                    "gross_total",
                    "deductions_total",
                    "net_total",
                ],
                run_rows,
                total_count=bounded_runs.total_count,
                limit=bounded_runs.limit,
            ),
            _report_section(
                "employee_totals",
                [
                    "employee_name",
                    "gross_total",
                    "additions_total",
                    "deductions_total",
                    "net_total",
                ],
                employee_rows,
                total_count=bounded_employees.total_count,
                limit=bounded_employees.limit,
            ),
        ],
    }


def _profit_costs_report(user, period):
    orders = _settled_orders(user).filter(
        created_at__gte=period["start"],
        created_at__lt=period["end"],
    )
    adjustments = _order_adjustments(user).filter(
        created_at__gte=period["start"],
        created_at__lt=period["end"],
    )
    refund_total = adjustments.aggregate(
        total=Coalesce(
            Sum("amount"),
            Value(Decimal("0.00")),
            output_field=MONEY_FIELD,
        )
    )["total"]
    line_profit = OrderLine.objects.filter(order__in=orders).aggregate(
        total=Coalesce(
            Sum(
                F("quantity") * (F("unit_price") - F("unit_cost"))
                - F("discount_total"),
                output_field=MONEY_FIELD,
            ),
            Value(Decimal("0.00")),
            output_field=MONEY_FIELD,
        )
    )["total"]
    # Restocked returns give their cost back, so only the margin is reversed.
    gross_profit = line_profit - refund_total + returned_cost_total(adjustments)

    payroll_paid = PayrollRun.objects.filter(
        status=PayrollRun.Status.PAID,
        payment_date__gte=period["start_date"],
        payment_date__lte=period["end_date"],
    ).aggregate(
        total=Coalesce(
            Sum("net_total"),
            Value(Decimal("0.00")),
            output_field=MONEY_FIELD,
        )
    )["total"]
    payment_commissions = Payment.objects.filter(
        created_at__gte=period["start"],
        created_at__lt=period["end"],
    ).aggregate(
        total=Coalesce(
            Sum("commission_amount"),
            Value(Decimal("0.00")),
            output_field=MONEY_FIELD,
        )
    )["total"]
    purchase_spend = (
        PurchaseOrder.objects.exclude(status=PurchaseOrder.Status.CANCELLED)
        .filter(
            created_at__gte=period["start"],
            created_at__lt=period["end"],
        )
        .aggregate(
            total=Coalesce(
                Sum("total"),
                Value(Decimal("0.00")),
                output_field=MONEY_FIELD,
            )
        )["total"]
    )
    ad_hoc_expenses = Expense.objects.filter(
        spent_at__gte=period["start_date"],
        spent_at__lte=period["end_date"],
    ).aggregate(
        total=Coalesce(
            Sum("amount"),
            Value(Decimal("0.00")),
            output_field=MONEY_FIELD,
        )
    )["total"]
    operating_expense = payroll_paid + payment_commissions + ad_hoc_expenses
    net_operating_profit = gross_profit - operating_expense

    return {
        "summary": {
            "gross_profit": _money(gross_profit),
            "payroll_paid_total": _money(payroll_paid),
            "payment_commission_total": _money(payment_commissions),
            "ad_hoc_expense_total": _money(ad_hoc_expenses),
            "purchase_spend_total": _money(purchase_spend),
            "operating_expense_total": _money(operating_expense),
            "net_operating_profit": _money(net_operating_profit),
        },
        "sections": [
            _metric_section(
                [
                    ("gross_profit", _money(gross_profit)),
                    ("payroll_paid_total", _money(payroll_paid)),
                    ("payment_commission_total", _money(payment_commissions)),
                    ("ad_hoc_expense_total", _money(ad_hoc_expenses)),
                    ("purchase_spend_total", _money(purchase_spend)),
                    ("operating_expense_total", _money(operating_expense)),
                    ("net_operating_profit", _money(net_operating_profit)),
                ]
            ),
            _report_section(
                "cost_breakdown",
                ["cost_item", "amount"],
                [
                    {
                        "cost_item": "payroll_paid_total",
                        "amount": _money(payroll_paid),
                    },
                    {
                        "cost_item": "payment_commission_total",
                        "amount": _money(payment_commissions),
                    },
                    {
                        "cost_item": "ad_hoc_expense_total",
                        "amount": _money(ad_hoc_expenses),
                    },
                    {
                        "cost_item": "purchase_spend_total",
                        "amount": _money(purchase_spend),
                    },
                ],
            ),
        ],
    }


def _metric_section(metrics):
    rows = [{"metric": metric, "value": value} for metric, value in metrics]
    return _report_section("summary", ["metric", "value"], rows)


def _report_section(key, columns, rows, *, total_count=None, limit=None):
    returned_count = len(rows)
    total_count = returned_count if total_count is None else total_count
    omitted_count = max(total_count - returned_count, 0)
    metadata = {
        "returned_count": returned_count,
        "total_count": total_count,
        "omitted_count": omitted_count,
        "truncated": omitted_count > 0,
    }
    if limit is not None:
        metadata["limit"] = limit
    return {
        "key": key,
        "columns": columns,
        "rows": rows,
        "metadata": metadata,
    }


def _bounded_queryset(queryset, *, limit):
    return BoundedRows(
        rows=list(queryset[:limit]),
        total_count=queryset.count(),
        limit=limit,
    )


def _section_row_limit(key):
    return REPORT_SECTION_ROW_LIMITS.get(key, DEFAULT_DETAIL_ROW_LIMIT)


def _payload_audit(payload):
    sections = []
    for section in payload.get("sections", []):
        rows = section.get("rows", [])
        metadata = section.get("metadata", {})
        section_audit = {
            "key": section.get("key", ""),
            "returned_count": metadata.get("returned_count", len(rows)),
            "total_count": metadata.get("total_count", len(rows)),
            "omitted_count": metadata.get("omitted_count", 0),
            "truncated": metadata.get("truncated", False),
        }
        if "limit" in metadata:
            section_audit["limit"] = metadata["limit"]
        sections.append(section_audit)

    return {
        "row_count": _row_count(payload),
        "truncated": any(section["truncated"] for section in sections),
        "sections": sections,
    }


def _product_sales_rows(orders):
    revenue_expr = F("quantity") * F("unit_price") - F("discount_total")
    profit_expr = F("quantity") * (F("unit_price") - F("unit_cost")) - F(
        "discount_total"
    )
    row_values = (
        OrderLine.objects.filter(order__in=orders)
        .values("variant__product__name")
        .annotate(
            units_sold=Coalesce(Sum("quantity"), ZERO_QTY),
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
        .order_by("-revenue", "variant__product__name")
    )
    bounded_rows = _bounded_queryset(
        row_values,
        limit=_section_row_limit("top_products"),
    )
    return BoundedRows(
        rows=[
            {
                "product_name": row["variant__product__name"],
                "quantity": row["units_sold"],
                "revenue": _money(row["revenue"]),
                "profit": _money(row["profit"]),
            }
            for row in bounded_rows.rows
        ],
        total_count=bounded_rows.total_count,
        limit=bounded_rows.limit,
    )


def _settled_orders(user):
    queryset = Order.objects.transactional()
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
    return str(
        ((_decimal_from(numerator) / denominator) * Decimal("100")).quantize(
            MONEY_PLACES
        )
    )
