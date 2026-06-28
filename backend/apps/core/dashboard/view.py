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
from apps.core.roles import user_is_manager
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
    transactional_sale_q,
    OrderAdjustment,
    OrderLine,
    RegisterCashMovement,
    RegisterSession,
)
from apps.holidays.services import today_dashboard_special_days

from .helpers import *  # noqa: F401,F403

class DashboardView(APIView):
    permission_classes = [IsAuthenticated, HasPointyPermission]

    def get_required_permissions(self, request):
        return ()

    def get(self, request):
        return Response(build_dashboard_snapshot(request))


def build_dashboard_snapshot(request):
    """The dashboard payload (period + capability-gated sections + special days).

    Extracted from the view so other endpoints — notably the AI digest — can
    reuse the exact same capability-gated, per-section-cached snapshot the
    dashboard renders, instead of re-deriving the figures."""
    period = _period_from_request(request)
    data = {
        "generated_at": timezone.now().isoformat(),
        "period": {
            "days": period["days"],
            "start": period["start"].isoformat(),
            "end": period["end"].isoformat(),
            "previous_start": period["previous_start"].isoformat(),
            "previous_end": period["previous_end"].isoformat(),
        },
        "sections": {},
        # Today's special day(s), if any, for the festive dashboard banner.
        # Not permission-gated (every user sees it) and served from a cached,
        # query-free helper so it never adds load to the dashboard.
        "today_special_days": today_dashboard_special_days(),
    }
    # Revenue aggregates additionally require the reporting permission.
    # Cashiers hold ``sales.view_order``/``payments.view_payment`` to run
    # the register, but exposing shop-wide cash totals to them would defeat
    # the blind close: a cashier who can read today's cash sales can pocket
    # the difference and type in a "perfect" closing count.
    if _can(request.user, "reports.view_reportrun") and _can_any(
        request.user,
        ("sales.view_order", "sales.view_registersession"),
    ):
        data["sections"]["sales"] = _cached_dashboard_section(
            "sales",
            request,
            period,
            lambda: _sales_section(request, period),
        )
    if _can(request.user, "reports.view_reportrun") and _can(
        request.user,
        "payments.view_payment",
    ):
        data["sections"]["payments"] = _cached_dashboard_section(
            "payments",
            request,
            period,
            lambda: _payments_section(request, period),
        )
    if _can_any(request.user, ("inventory.view_stockitem", "inventory.view_stockmovement")):
        data["sections"]["inventory"] = _cached_dashboard_section(
            "inventory",
            request,
            period,
            lambda: _inventory_section(period),
        )
    if _can_any(request.user, ("purchasing.view_purchaseorder", "purchasing.view_supplier")):
        data["sections"]["purchasing"] = _cached_dashboard_section(
            "purchasing",
            request,
            period,
            lambda: _purchasing_section(period),
            scope="global",
        )
    if _can(request.user, "employees.view_payrollrun"):
        data["sections"]["payroll"] = _cached_dashboard_section(
            "payroll",
            request,
            period,
            lambda: _payroll_section(period),
        )
    if _can(request.user, "reports.view_reportrun") and _can(
        request.user,
        "sales.view_order",
    ):
        data["sections"]["profitability"] = _cached_dashboard_section(
            "profitability",
            request,
            period,
            lambda: _profitability_section(request, period),
        )
    if _can(request.user, "customers.view_customer"):
        data["sections"]["customers"] = _cached_dashboard_section(
            "customers",
            request,
            period,
            lambda: _customers_section(period),
        )
    if _can(request.user, "discounts.view_discountrule"):
        data["sections"]["discounts"] = _cached_dashboard_section(
            "discounts",
            request,
            period,
            lambda: _discounts_section(period),
        )
    if _can(request.user, "fraud.view_fraudfinding"):
        data["sections"]["fraud"] = _cached_dashboard_section(
            "fraud",
            request,
            period,
            lambda: _fraud_section(),
        )
    if _can(request.user, "printing.view_printjob"):
        data["sections"]["printing"] = _cached_dashboard_section(
            "printing",
            request,
            period,
            lambda: _printing_section(request, period),
        )

    return data


def _period_from_request(request):
    try:
        days = int(request.query_params.get("days", 30))
    except (TypeError, ValueError):
        days = 30
    days = min(max(days, 7), 90)

    end = timezone.now()
    start = end - timedelta(days=days)
    previous_end = start
    previous_start = previous_end - timedelta(days=days)
    return {
        "days": days,
        "start": start,
        "end": end,
        "previous_start": previous_start,
        "previous_end": previous_end,
    }


def _cached_dashboard_section(section, request, period, builder, *, scope=None):
    cache_key = _dashboard_section_cache_key(section, request, period, scope=scope)
    try:
        cached = cache.get(cache_key)
    except Exception:
        return builder()
    if cached is not None:
        return cached

    value = builder()
    try:
        cache.set(cache_key, value, timeout=DASHBOARD_SECTION_CACHE_SECONDS)
    except Exception:
        pass
    return value


def _dashboard_section_cache_key(section, request, period, *, scope=None):
    cache_scope = scope or _dashboard_cache_scope(request)
    return (
        f"dashboard:v{DASHBOARD_CACHE_VERSION}:{section}:"
        f"{cache_scope}:days:{period['days']}"
    )


def _dashboard_cache_scope(request):
    if _views_shop_wide(request):
        return "shop"
    return _owner_key(request)


def _sales_section(request, period):
    current_orders = _settled_orders(request).filter(
        created_at__gte=period["start"],
        created_at__lt=period["end"],
    )
    previous_orders = _settled_orders(request).filter(
        created_at__gte=period["previous_start"],
        created_at__lt=period["previous_end"],
    )
    current_adjustments = _order_adjustments(request).filter(
        created_at__gte=period["start"],
        created_at__lt=period["end"],
    )
    previous_adjustments = _order_adjustments(request).filter(
        created_at__gte=period["previous_start"],
        created_at__lt=period["previous_end"],
    )

    current = _sales_summary(current_orders, current_adjustments)
    previous = _sales_summary(previous_orders, previous_adjustments)
    current["net_sales_change_percent"] = _change_percent(
        current["net_sales_raw"],
        previous["net_sales_raw"],
    )
    current["order_count_change_percent"] = _change_percent(
        Decimal(current["order_count"]),
        Decimal(previous["order_count"]),
    )
    current.pop("net_sales_raw")

    trend = _sales_trend(current_orders, current_adjustments, period)
    return {
        "summary": current,
        "trend": trend,
        "hourly_sales": _hourly_sales(current_orders),
        "top_products": _top_products(current_orders),
        "reports": _sales_reports(current_orders),
        "top_categories": _top_categories(current_orders),
        "recent_orders": _recent_orders(current_orders),
        "registers": _cached_dashboard_section(
            "registers",
            request,
            period,
            lambda: _register_summary(request, period),
        ),
    }


def _payments_section(request, period):
    payments = _payments(request).filter(
        created_at__gte=period["start"],
        created_at__lt=period["end"],
    )
    rows = list(
        payments.values("method")
        .annotate(
            total=Coalesce(Sum("amount"), Value(Decimal("0.00")), output_field=MONEY_FIELD),
            commission=Coalesce(
                Sum("commission_amount"),
                Value(Decimal("0.00")),
                output_field=MONEY_FIELD,
            ),
            count=Count("id"),
        )
        .order_by("-total")
    )
    methods = [
        {
            "method": row["method"],
            "total": _money(row["total"]),
            "commission": _money(row["commission"]),
            "count": row["count"],
        }
        for row in rows
    ]
    total = sum((row["total"] for row in rows), Decimal("0.00"))
    commission_total = sum((row["commission"] for row in rows), Decimal("0.00"))
    payment_count = sum((row["count"] for row in rows), 0)
    return {
        "summary": {
            "total": _money(total),
            "commission_total": _money(commission_total),
            "payment_count": payment_count,
        },
        "methods": methods,
    }


def _inventory_section(period):
    stock = StockItem.objects.select_related("variant", "variant__product")
    low_stock = stock.filter(quantity_on_hand__lte=F("reorder_level"))
    value_expr = F("quantity_on_hand") * F("variant__unit_price")
    # One pass over the stock table for every count and sum the summary needs.
    stock_totals = stock.aggregate(
        stock_item_count=Count("id"),
        low_stock_count=Count("id", filter=Q(quantity_on_hand__lte=F("reorder_level"))),
        out_of_stock_count=Count("id", filter=Q(quantity_on_hand__lte=0)),
        committed_units=Coalesce(Sum("quantity_committed"), ZERO_QTY),
        expected_units=Coalesce(Sum("quantity_expected"), ZERO_QTY),
        retail_stock_value=Coalesce(
            Sum(value_expr, output_field=MONEY_FIELD),
            Value(Decimal("0.00")),
            output_field=MONEY_FIELD,
        ),
    )
    product_totals = Product.objects.aggregate(
        product_count=Count("id"),
        active_product_count=Count("id", filter=Q(is_active=True)),
    )

    sold_variant_ids = OrderLine.objects.filter(
        transactional_sale_q("order"),
        order__created_at__gte=period["start"],
        order__created_at__lt=period["end"],
    ).values("variant_id")
    dusty_items = (
        stock.filter(quantity_on_hand__gt=0)
        .exclude(variant_id__in=sold_variant_ids)
        .order_by("-quantity_on_hand", "variant__product__name", "variant__name")[:8]
    )

    movement_rows = (
        StockMovement.objects.filter(
            created_at__gte=period["start"],
            created_at__lt=period["end"],
        )
        .values("movement_type")
        .annotate(
            movement_quantity=Coalesce(Sum("quantity"), ZERO_QTY),
            count=Count("id"),
        )
        .order_by("movement_type")
    )

    return {
        "summary": {
            "product_count": product_totals["product_count"],
            "active_product_count": product_totals["active_product_count"],
            "stock_item_count": stock_totals["stock_item_count"],
            "low_stock_count": stock_totals["low_stock_count"],
            "out_of_stock_count": stock_totals["out_of_stock_count"],
            "committed_units": stock_totals["committed_units"],
            "expected_units": stock_totals["expected_units"],
            "retail_stock_value": _money(stock_totals["retail_stock_value"]),
        },
        "low_stock_items": [
            _stock_item_row(item)
            for item in low_stock.order_by(
                "quantity_on_hand",
                "variant__product__name",
                "variant__name",
            )[:8]
        ],
        "low_stock_variants": [
            _stock_item_row(item)
            for item in low_stock.order_by(
                "quantity_on_hand",
                "variant__product__name",
                "variant__name",
            )[:24]
        ],
        "dusty_items": [_stock_item_row(item) for item in dusty_items],
        "movement_mix": [
            {
                "movement_type": row["movement_type"],
                "quantity": row["movement_quantity"],
                "count": row["count"],
            }
            for row in movement_rows
        ],
        "recent_movements": [
            {
                "product_name": movement.variant.full_name,
                "movement_type": movement.movement_type,
                "quantity": movement.quantity,
                "created_at": movement.created_at.isoformat(),
            }
            for movement in StockMovement.objects.select_related(
                "variant",
                "variant__product",
            ).order_by("-created_at")[:6]
        ],
    }


def _purchasing_section(period):
    orders = PurchaseOrder.objects.exclude(status=PurchaseOrder.Status.CANCELLED)
    period_orders = orders.filter(
        created_at__gte=period["start"],
        created_at__lt=period["end"],
    )
    balance_rows = _purchase_order_balance_rows(orders)
    today = timezone.localdate()
    open_orders = orders.exclude(status=PurchaseOrder.Status.RECEIVED)
    purchase_total = period_orders.aggregate(
        total=Coalesce(Sum("total"), Value(Decimal("0.00")), output_field=MONEY_FIELD)
    )["total"]
    due_total = Decimal("0.00")
    overdue_orders = []
    for row in balance_rows:
        balance = _purchase_order_balance_due(row)
        due_total += balance
        if row["due_date"] is not None and row["due_date"] < today and balance > 0:
            overdue_orders.append((row, balance))
    overdue_orders.sort(key=lambda item: (item[0]["due_date"], -item[1]))

    return {
        "summary": {
            "purchase_total": _money(purchase_total),
            "open_order_count": open_orders.count(),
            "received_order_count": orders.filter(status=PurchaseOrder.Status.RECEIVED).count(),
            "due_total": _money(due_total),
            "overdue_order_count": len(overdue_orders),
            "supplier_count": Supplier.objects.filter(is_active=True).count(),
        },
        "status_counts": [
            {"status": row["status"], "count": row["count"]}
            for row in orders.values("status").annotate(count=Count("id")).order_by("status")
        ],
        "overdue_orders": [
            {
                "order_number": order["order_number"],
                "supplier_name": order["supplier__name"],
                "due_date": order["due_date"].isoformat() if order["due_date"] else None,
                "balance_due": _money(balance),
            }
            for order, balance in overdue_orders[:6]
        ],
        "top_supplier_balances": _top_supplier_balances(balance_rows),
    }


def _fraud_section():
    active = FraudFinding.objects.filter(status=FraudFinding.Status.ACTIVE)
    top_findings = active.order_by("-risk_score", "-last_detected_at")[:5]
    return {
        "summary": {
            "active_count": active.count(),
            "critical_count": active.filter(
                severity=FraudFinding.Severity.CRITICAL,
            ).count(),
            "top_risk_score": next(
                iter(active.values_list("risk_score", flat=True)[:1]),
                0,
            ),
        },
        "recent_findings": [
            {
                "id": finding.pk,
                "rule_code": finding.rule_code,
                "rule_title": finding.summary.get("rule_title", ""),
                "headline": finding.summary.get("headline", ""),
                "user_label": finding.target_user_label,
                "severity": finding.severity,
                "risk_score": finding.risk_score,
                "last_detected_at": finding.last_detected_at.isoformat(),
            }
            for finding in top_findings
        ],
    }


def _payroll_section(period):
    period_start = period["start"].date()
    period_end = period["end"].date()
    payroll_runs = PayrollRun.objects.exclude(status=PayrollRun.Status.VOID)
    in_period = Q(period_end__gte=period_start, period_start__lte=period_end)
    # Collapse every payroll total and count the summary needs into one pass.
    totals = payroll_runs.aggregate(
        salary_expense=Coalesce(
            Sum(
                "net_total",
                filter=in_period
                & Q(status__in=(PayrollRun.Status.APPROVED, PayrollRun.Status.PAID)),
            ),
            Value(Decimal("0.00")),
            output_field=MONEY_FIELD,
        ),
        paid_total=Coalesce(
            Sum(
                "net_total",
                filter=Q(
                    status=PayrollRun.Status.PAID,
                    payment_date__gte=period_start,
                    payment_date__lte=period_end,
                ),
            ),
            Value(Decimal("0.00")),
            output_field=MONEY_FIELD,
        ),
        pending_total=Coalesce(
            Sum("net_total", filter=Q(status=PayrollRun.Status.APPROVED)),
            Value(Decimal("0.00")),
            output_field=MONEY_FIELD,
        ),
        payroll_run_count=Count("id", filter=in_period),
        draft_run_count=Count("id", filter=Q(status=PayrollRun.Status.DRAFT)),
        pending_run_count=Count("id", filter=Q(status=PayrollRun.Status.APPROVED)),
    )

    return {
        "summary": {
            "salary_expense": _money(totals["salary_expense"]),
            "paid_total": _money(totals["paid_total"]),
            "pending_total": _money(totals["pending_total"]),
            "active_employee_count": Employee.objects.filter(
                status=Employee.Status.ACTIVE,
            ).count(),
            "payroll_run_count": totals["payroll_run_count"],
            "draft_run_count": totals["draft_run_count"],
            "pending_run_count": totals["pending_run_count"],
            "pending_loan_request_count": EmployeeLoan.objects.filter(
                status=EmployeeLoan.Status.REQUESTED,
            ).count(),
        },
        "recent_runs": [
            {
                "id": run.pk,
                "run_number": run.run_number,
                "status": run.status,
                "period_start": run.period_start.isoformat(),
                "period_end": run.period_end.isoformat(),
                "payment_date": run.payment_date.isoformat() if run.payment_date else None,
                "net_total": _money(run.net_total),
            }
            for run in payroll_runs.order_by("-period_end", "-created_at")[:6]
        ],
    }


def _profitability_section(request, period):
    current_orders = _settled_orders(request).filter(
        created_at__gte=period["start"],
        created_at__lt=period["end"],
    )
    current_adjustments = _order_adjustments(request).filter(
        created_at__gte=period["start"],
        created_at__lt=period["end"],
    )
    sales_summary = _sales_summary(current_orders, current_adjustments)
    gross_profit = _decimal_from(sales_summary["gross_profit"])

    payroll_paid = Decimal("0.00")
    payroll_accrued = Decimal("0.00")
    if _can(request.user, "employees.view_payrollrun"):
        period_start = period["start"].date()
        period_end = period["end"].date()
        payroll_totals = PayrollRun.objects.aggregate(
            paid=Coalesce(
                Sum(
                    "net_total",
                    filter=Q(
                        status=PayrollRun.Status.PAID,
                        payment_date__gte=period_start,
                        payment_date__lte=period_end,
                    ),
                ),
                Value(Decimal("0.00")),
                output_field=MONEY_FIELD,
            ),
            accrued=Coalesce(
                Sum(
                    "net_total",
                    filter=Q(
                        status__in=(PayrollRun.Status.APPROVED, PayrollRun.Status.PAID),
                        period_end__gte=period_start,
                        period_start__lte=period_end,
                    ),
                ),
                Value(Decimal("0.00")),
                output_field=MONEY_FIELD,
            ),
        )
        payroll_paid = payroll_totals["paid"]
        payroll_accrued = payroll_totals["accrued"]

    payment_commissions = Decimal("0.00")
    if _can(request.user, "payments.view_payment"):
        payment_commissions = _payments(request).filter(
            created_at__gte=period["start"],
            created_at__lt=period["end"],
        ).aggregate(
            total=Coalesce(
                Sum("commission_amount"),
                Value(Decimal("0.00")),
                output_field=MONEY_FIELD,
            )
        )["total"]

    purchase_spend = Decimal("0.00")
    if _can(request.user, "purchasing.view_purchaseorder"):
        purchase_spend = PurchaseOrder.objects.exclude(
            status=PurchaseOrder.Status.CANCELLED,
        ).filter(
            created_at__gte=period["start"],
            created_at__lt=period["end"],
        ).aggregate(
            total=Coalesce(Sum("total"), Value(Decimal("0.00")), output_field=MONEY_FIELD)
        )["total"]

    ad_hoc_expenses = Decimal("0.00")
    if _can(request.user, "expenses.view_expense"):
        ad_hoc_expenses = Expense.objects.filter(
            spent_at__gte=period["start"].date(),
            spent_at__lte=period["end"].date(),
        ).aggregate(
            total=Coalesce(Sum("amount"), Value(Decimal("0.00")), output_field=MONEY_FIELD)
        )["total"]

    operating_expenses = payroll_paid + payment_commissions + ad_hoc_expenses
    return {
        "summary": {
            "gross_profit": _money(gross_profit),
            "payroll_paid_total": _money(payroll_paid),
            "payroll_accrued_total": _money(payroll_accrued),
            "payment_commission_total": _money(payment_commissions),
            "ad_hoc_expense_total": _money(ad_hoc_expenses),
            "purchase_spend_total": _money(purchase_spend),
            "operating_expense_total": _money(operating_expenses),
            "net_operating_profit": _money(gross_profit - operating_expenses),
        }
    }


def _customers_section(period):
    active = Customer.objects.filter(is_active=True)
    order_filter = transactional_sale_q("orders")
    repeat_customers = active.annotate(order_count=Count("orders", filter=order_filter)).filter(
        order_count__gte=2
    )
    top_customers = (
        Customer.objects.filter(
            transactional_sale_q("orders"),
            orders__created_at__gte=period["start"],
            orders__created_at__lt=period["end"],
        )
        .annotate(
            sales_total=Coalesce(
                Sum("orders__total"),
                Value(Decimal("0.00")),
                output_field=MONEY_FIELD,
            ),
            order_count=Count("orders", distinct=True),
        )
        .order_by("-sales_total", "full_name")[:6]
    )
    return {
        "summary": {
            "active_customer_count": active.count(),
            "new_customer_count": active.filter(
                created_at__gte=period["start"],
                created_at__lt=period["end"],
            ).count(),
            "customers_with_sales_count": active.filter(
                orders__created_at__gte=period["start"],
                orders__created_at__lt=period["end"],
            )
            .distinct()
            .count(),
            "repeat_customer_count": repeat_customers.count(),
            "marketing_consent_count": active.filter(marketing_consent=True).count(),
        },
        "top_customers": [
            {
                "customer_name": customer.full_name,
                "sales_total": _money(customer.sales_total),
                "order_count": customer.order_count,
            }
            for customer in top_customers
        ],
        "recent_customers": [
            {
                "customer_name": customer.full_name,
                "customer_number": customer.customer_number,
                "created_at": customer.created_at.isoformat(),
            }
            for customer in active.order_by("-created_at")[:6]
        ],
    }


def _discounts_section(period):
    redemptions = DiscountRedemption.objects.filter(
        created_at__gte=period["start"],
        created_at__lt=period["end"],
    )
    top_rules = (
        redemptions.values("rule__name", "channel")
        .annotate(
            amount=Coalesce(
                Sum("discount_amount"),
                Value(Decimal("0.00")),
                output_field=MONEY_FIELD,
            ),
            count=Count("id"),
        )
        .order_by("-amount")[:6]
    )
    return {
        "summary": {
            "active_rule_count": DiscountRule.objects.filter(is_active=True).count(),
            "coupon_rule_count": DiscountRule.objects.filter(coupon_code__gt="").count(),
            "redemption_count": redemptions.count(),
            "sales_discount_total": _money(
                Order.objects.transactional().filter(
                    created_at__gte=period["start"],
                    created_at__lt=period["end"],
                ).aggregate(
                    total=Coalesce(
                        Sum("discount_total"),
                        Value(Decimal("0.00")),
                        output_field=MONEY_FIELD,
                    )
                )["total"]
            ),
            "purchase_discount_total": _money(
                PurchaseOrder.objects.filter(
                    created_at__gte=period["start"],
                    created_at__lt=period["end"],
                ).aggregate(
                    total=Coalesce(
                        Sum("discount_total"),
                        Value(Decimal("0.00")),
                        output_field=MONEY_FIELD,
                    )
                )["total"]
            ),
        },
        "top_rules": [
            {
                "rule_name": row["rule__name"] or "",
                "channel": row["channel"],
                "discount_total": _money(row["amount"]),
                "redemption_count": row["count"],
            }
            for row in top_rules
        ],
        "expiring_rules": [
            {
                "rule_name": rule.name,
                "channel": rule.channel,
                "ends_at": rule.ends_at.isoformat() if rule.ends_at else None,
            }
            for rule in DiscountRule.objects.filter(
                is_active=True,
                ends_at__gte=timezone.now(),
                ends_at__lte=timezone.now() + timedelta(days=7),
            ).order_by("ends_at")[:6]
        ],
    }


def _printing_section(request, period):
    jobs = _print_jobs(request)
    period_jobs = jobs.filter(
        created_at__gte=period["start"],
        created_at__lt=period["end"],
    )
    stale_before = timezone.now() - timedelta(minutes=15)
    job_summary = jobs.aggregate(
        queued_count=Count("id", filter=Q(status=PrintJob.Status.QUEUED)),
        claimed_count=Count("id", filter=Q(status=PrintJob.Status.CLAIMED)),
        failed_count=Count(
            "id",
            filter=Q(
                status=PrintJob.Status.FAILED,
                created_at__gte=period["start"],
                created_at__lt=period["end"],
            ),
        ),
        printed_count=Count(
            "id",
            filter=Q(
                status=PrintJob.Status.PRINTED,
                created_at__gte=period["start"],
                created_at__lt=period["end"],
            ),
        ),
    )
    agent_summary = PrintAgent.objects.filter(is_active=True).aggregate(
        active_agent_count=Count("id", filter=Q(last_seen_at__gte=stale_before)),
        stale_agent_count=Count(
            "id",
            filter=Q(last_seen_at__lt=stale_before) | Q(last_seen_at__isnull=True),
        ),
    )
    return {
        "summary": {
            "queued_count": job_summary["queued_count"],
            "claimed_count": job_summary["claimed_count"],
            "failed_count": job_summary["failed_count"],
            "printed_count": job_summary["printed_count"],
            "active_agent_count": agent_summary["active_agent_count"],
            "stale_agent_count": agent_summary["stale_agent_count"],
        },
        "status_counts": [
            {"status": row["status"], "count": row["count"]}
            for row in period_jobs.values("status").annotate(count=Count("id")).order_by("status")
        ],
        "recent_failures": [
            {
                "id": job.pk,
                "receipt_number": job.order.receipt_number if job.order_id else "",
                "error_message": job.error_message,
                "failed_at": job.failed_at.isoformat() if job.failed_at else None,
            }
            for job in jobs.select_related("order")
            .filter(status=PrintJob.Status.FAILED)
            .order_by("-failed_at", "-created_at")[:6]
        ],
    }


