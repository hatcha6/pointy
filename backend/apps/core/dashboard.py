from collections import defaultdict
from datetime import timedelta
from decimal import Decimal

from django.db.models import (
    Count,
    DecimalField,
    F,
    Q,
    Sum,
    Value,
)
from django.db.models.functions import Coalesce, ExtractHour, TruncDate
from django.utils import timezone
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from apps.catalog.models import Product, ProductCategory
from apps.core.permissions import HasPointyPermission
from apps.core.roles import user_is_manager
from apps.customers.models import Customer
from apps.discounts.models import DiscountRedemption, DiscountRule
from apps.employees.models import Employee, PayrollRun
from apps.inventory.models import StockItem, StockMovement
from apps.payments.models import Payment
from apps.printing.models import PrintAgent, PrintJob
from apps.purchasing.models import PurchaseOrder, Supplier, SupplierPayment
from apps.sales.models import Order, OrderAdjustment, OrderLine, RegisterSession

MONEY_PLACES = Decimal("0.01")
MONEY_FIELD = DecimalField(max_digits=12, decimal_places=2)


class DashboardView(APIView):
    permission_classes = [IsAuthenticated, HasPointyPermission]

    def get_required_permissions(self, request):
        return ()

    def get(self, request):
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
        }

        if _can_any(request.user, ("sales.view_order", "sales.view_registersession")):
            data["sections"]["sales"] = _sales_section(request, period)
        if _can(request.user, "payments.view_payment"):
            data["sections"]["payments"] = _payments_section(request, period)
        if _can_any(request.user, ("inventory.view_stockitem", "inventory.view_stockmovement")):
            data["sections"]["inventory"] = _inventory_section(period)
        if _can_any(request.user, ("purchasing.view_purchaseorder", "purchasing.view_supplier")):
            data["sections"]["purchasing"] = _purchasing_section(period)
        if _can(request.user, "employees.view_payrollrun"):
            data["sections"]["payroll"] = _payroll_section(period)
        if _can(request.user, "sales.view_order"):
            data["sections"]["profitability"] = _profitability_section(request, period)
        if _can(request.user, "customers.view_customer"):
            data["sections"]["customers"] = _customers_section(period)
        if _can(request.user, "discounts.view_discountrule"):
            data["sections"]["discounts"] = _discounts_section(period)
        if _can(request.user, "printing.view_printjob"):
            data["sections"]["printing"] = _printing_section(request, period)

        return Response(data)


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
        "registers": _register_summary(request, period),
    }


def _payments_section(request, period):
    payments = _payments(request).filter(
        created_at__gte=period["start"],
        created_at__lt=period["end"],
    )
    rows = payments.values("method").annotate(
        total=Coalesce(Sum("amount"), Value(Decimal("0.00")), output_field=MONEY_FIELD),
        commission=Coalesce(
            Sum("commission_amount"),
            Value(Decimal("0.00")),
            output_field=MONEY_FIELD,
        ),
        count=Count("id"),
    )
    methods = [
        {
            "method": row["method"],
            "total": _money(row["total"]),
            "commission": _money(row["commission"]),
            "count": row["count"],
        }
        for row in rows.order_by("-total")
    ]
    total = sum((_decimal_from(row["total"]) for row in methods), Decimal("0.00"))
    commission_total = payments.aggregate(
        total=Coalesce(
            Sum("commission_amount"),
            Value(Decimal("0.00")),
            output_field=MONEY_FIELD,
        )
    )["total"]
    return {
        "summary": {
            "total": _money(total),
            "commission_total": _money(commission_total),
            "payment_count": payments.count(),
        },
        "methods": methods,
    }


def _inventory_section(period):
    stock = StockItem.objects.select_related("variant", "variant__product")
    low_stock = stock.filter(quantity_on_hand__lte=F("reorder_level"))
    out_of_stock = stock.filter(quantity_on_hand__lte=0)
    value_expr = F("quantity_on_hand") * F("variant__unit_price")
    retail_value = stock.aggregate(
        total=Coalesce(
            Sum(value_expr, output_field=MONEY_FIELD),
            Value(Decimal("0.00")),
            output_field=MONEY_FIELD,
        )
    )["total"]

    sold_variant_ids = OrderLine.objects.filter(
        order__status__in=(Order.Status.PAID, Order.Status.VOID),
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
            movement_quantity=Coalesce(Sum("quantity"), Value(0)),
            count=Count("id"),
        )
        .order_by("movement_type")
    )

    return {
        "summary": {
            "product_count": Product.objects.count(),
            "active_product_count": Product.objects.filter(is_active=True).count(),
            "stock_item_count": stock.count(),
            "low_stock_count": low_stock.count(),
            "out_of_stock_count": out_of_stock.count(),
            "committed_units": stock.aggregate(total=Coalesce(Sum("quantity_committed"), Value(0)))[
                "total"
            ],
            "expected_units": stock.aggregate(total=Coalesce(Sum("quantity_expected"), Value(0)))[
                "total"
            ],
            "retail_stock_value": _money(retail_value),
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
    balance_rows = orders.annotate(
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
    today = timezone.localdate()
    open_orders = orders.exclude(status=PurchaseOrder.Status.RECEIVED)
    purchase_total = period_orders.aggregate(
        total=Coalesce(Sum("total"), Value(Decimal("0.00")), output_field=MONEY_FIELD)
    )["total"]
    due_total = Decimal("0.00")
    overdue_orders = []
    for order in balance_rows.select_related("supplier"):
        balance = max(
            order.total - order.dashboard_paid_total - order.dashboard_credit_total,
            Decimal("0.00"),
        )
        due_total += balance
        if order.due_date is not None and order.due_date < today and balance > 0:
            overdue_orders.append((order, balance))
    overdue_orders.sort(key=lambda item: (item[0].due_date, -item[1]))

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
                "order_number": order.order_number,
                "supplier_name": order.supplier.name,
                "due_date": order.due_date.isoformat() if order.due_date else None,
                "balance_due": _money(balance),
            }
            for order, balance in overdue_orders[:6]
        ],
        "top_supplier_balances": _top_supplier_balances(),
    }


def _payroll_section(period):
    period_start = period["start"].date()
    period_end = period["end"].date()
    payroll_runs = PayrollRun.objects.exclude(status=PayrollRun.Status.VOID)
    period_runs = payroll_runs.filter(
        period_end__gte=period_start,
        period_start__lte=period_end,
    )
    paid_runs = payroll_runs.filter(
        status=PayrollRun.Status.PAID,
        payment_date__gte=period_start,
        payment_date__lte=period_end,
    )
    pending_runs = payroll_runs.filter(status=PayrollRun.Status.APPROVED)

    salary_expense = period_runs.filter(
        status__in=(PayrollRun.Status.APPROVED, PayrollRun.Status.PAID),
    ).aggregate(
        total=Coalesce(Sum("net_total"), Value(Decimal("0.00")), output_field=MONEY_FIELD)
    )["total"]
    paid_total = paid_runs.aggregate(
        total=Coalesce(Sum("net_total"), Value(Decimal("0.00")), output_field=MONEY_FIELD)
    )["total"]
    pending_total = pending_runs.aggregate(
        total=Coalesce(Sum("net_total"), Value(Decimal("0.00")), output_field=MONEY_FIELD)
    )["total"]

    return {
        "summary": {
            "salary_expense": _money(salary_expense),
            "paid_total": _money(paid_total),
            "pending_total": _money(pending_total),
            "active_employee_count": Employee.objects.filter(
                status=Employee.Status.ACTIVE,
            ).count(),
            "payroll_run_count": period_runs.count(),
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
        payroll_paid = PayrollRun.objects.filter(
            status=PayrollRun.Status.PAID,
            payment_date__gte=period_start,
            payment_date__lte=period_end,
        ).aggregate(
            total=Coalesce(Sum("net_total"), Value(Decimal("0.00")), output_field=MONEY_FIELD)
        )["total"]
        payroll_accrued = PayrollRun.objects.filter(
            status__in=(PayrollRun.Status.APPROVED, PayrollRun.Status.PAID),
            period_end__gte=period_start,
            period_start__lte=period_end,
        ).aggregate(
            total=Coalesce(Sum("net_total"), Value(Decimal("0.00")), output_field=MONEY_FIELD)
        )["total"]

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

    operating_expenses = payroll_paid + payment_commissions
    return {
        "summary": {
            "gross_profit": _money(gross_profit),
            "payroll_paid_total": _money(payroll_paid),
            "payroll_accrued_total": _money(payroll_accrued),
            "payment_commission_total": _money(payment_commissions),
            "purchase_spend_total": _money(purchase_spend),
            "operating_expense_total": _money(operating_expenses),
            "net_operating_profit": _money(gross_profit - operating_expenses),
        }
    }


def _customers_section(period):
    active = Customer.objects.filter(is_active=True)
    order_filter = Q(orders__status__in=(Order.Status.PAID, Order.Status.VOID))
    repeat_customers = active.annotate(order_count=Count("orders", filter=order_filter)).filter(
        order_count__gte=2
    )
    top_customers = (
        Customer.objects.filter(
            orders__status__in=(Order.Status.PAID, Order.Status.VOID),
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
                Order.objects.filter(
                    created_at__gte=period["start"],
                    created_at__lt=period["end"],
                    status__in=(Order.Status.PAID, Order.Status.VOID),
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
    return {
        "summary": {
            "queued_count": jobs.filter(status=PrintJob.Status.QUEUED).count(),
            "claimed_count": jobs.filter(status=PrintJob.Status.CLAIMED).count(),
            "failed_count": period_jobs.filter(status=PrintJob.Status.FAILED).count(),
            "printed_count": period_jobs.filter(status=PrintJob.Status.PRINTED).count(),
            "active_agent_count": PrintAgent.objects.filter(
                is_active=True,
                last_seen_at__gte=stale_before,
            ).count(),
            "stale_agent_count": PrintAgent.objects.filter(
                is_active=True,
            )
            .filter(Q(last_seen_at__lt=stale_before) | Q(last_seen_at__isnull=True))
            .count(),
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


def _sales_summary(orders, adjustments):
    order_values = orders.aggregate(
        gross_sales=Coalesce(Sum("subtotal"), Value(Decimal("0.00")), output_field=MONEY_FIELD),
        discount_total=Coalesce(
            Sum("discount_total"),
            Value(Decimal("0.00")),
            output_field=MONEY_FIELD,
        ),
        order_total=Coalesce(Sum("total"), Value(Decimal("0.00")), output_field=MONEY_FIELD),
        order_count=Count("id", filter=Q(status=Order.Status.PAID)),
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
        items_sold=Coalesce(Sum("quantity"), Value(0)),
        profit=Coalesce(
            Sum(
                F("quantity") * (F("unit_price") - F("unit_cost")) - F("discount_total"),
                output_field=MONEY_FIELD,
            ),
            Value(Decimal("0.00")),
            output_field=MONEY_FIELD,
        ),
    )
    net_sales = order_values["order_total"] - adjustment_values["refund_total"]
    profit = line_values["profit"] - adjustment_values["refund_total"]
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
        "items_sold": line_values["items_sold"] or 0,
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
            count=Count("id", filter=Q(status=Order.Status.PAID)),
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


def _top_products(orders):
    return _product_sales_report(orders, order_by="-revenue", limit=8)


def _sales_reports(orders):
    return {
        "products": {
            "top_sold": _product_sales_report(orders, order_by="-quantity", limit=24),
            "revenue": _product_sales_report(orders, order_by="-revenue", limit=24),
            "profit": _product_sales_report(orders, order_by="-profit", limit=24),
        },
        "variants": {
            "top_sold": _variant_sales_report(orders, order_by="-quantity", limit=24),
            "revenue": _variant_sales_report(orders, order_by="-revenue", limit=24),
            "profit": _variant_sales_report(orders, order_by="-profit", limit=24),
        },
    }


def _product_sales_report(orders, *, order_by, limit):
    revenue_expr = F("quantity") * F("unit_price") - F("discount_total")
    profit_expr = F("quantity") * (F("unit_price") - F("unit_cost")) - F("discount_total")
    rows = (
        OrderLine.objects.filter(order__in=orders)
        .values(
            "variant__product_id",
            "variant__product__name",
        )
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
            variant_count=Count("variant_id", distinct=True),
        )
        .order_by(_sales_report_ordering(order_by), "variant__product__name")[:limit]
    )
    return [
        {
            "product_id": row["variant__product_id"],
            "product_name": row["variant__product__name"],
            "sku": "",
            "quantity": row["units_sold"],
            "revenue": _money(row["revenue"]),
            "profit": _money(row["profit"]),
            "variant_count": row["variant_count"],
        }
        for row in rows
    ]


def _variant_sales_report(orders, *, order_by, limit):
    revenue_expr = F("quantity") * F("unit_price") - F("discount_total")
    profit_expr = F("quantity") * (F("unit_price") - F("unit_cost")) - F("discount_total")
    rows = (
        OrderLine.objects.filter(order__in=orders)
        .values(
            "variant__product_id",
            "variant_id",
            "variant__product__name",
            "variant__name",
            "variant__sku",
            "variant__barcode",
        )
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
        .order_by(
            _sales_report_ordering(order_by),
            "variant__product__name",
            "variant__name",
        )[:limit]
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
            "quantity": row["units_sold"],
            "revenue": _money(row["revenue"]),
            "profit": _money(row["profit"]),
        }
        for row in rows
    ]


def _variant_full_name(product_name, variant_name):
    variant_name = (variant_name or "").strip()
    if not variant_name:
        return product_name
    return f"{product_name} - {variant_name}"


def _sales_report_ordering(order_by):
    return order_by.replace("quantity", "units_sold")


def _top_categories(orders):
    revenue_expr = F("quantity") * F("unit_price") - F("discount_total")
    rows = (
        OrderLine.objects.filter(order__in=orders)
        .values("variant__product__categories__name")
        .annotate(
            revenue=Coalesce(
                Sum(revenue_expr, output_field=MONEY_FIELD),
                Value(Decimal("0.00")),
                output_field=MONEY_FIELD,
            ),
            units_sold=Coalesce(Sum("quantity"), Value(0)),
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
    if not user_is_manager(request.user):
        sessions = sessions.filter(owner_key=_owner_key(request))
    period_sessions = sessions.filter(
        created_at__gte=period["start"],
        created_at__lt=period["end"],
    )
    variance_count = 0
    variance_total = Decimal("0.00")
    if user_is_manager(request.user):
        for session in period_sessions.filter(status=RegisterSession.Status.CLOSED):
            if session.cash_variance is not None and session.cash_variance != Decimal("0.00"):
                variance_count += 1
                variance_total += session.cash_variance
    return {
        "open_count": sessions.filter(status=RegisterSession.Status.OPEN).count(),
        "closed_count": period_sessions.filter(status=RegisterSession.Status.CLOSED).count(),
        "variance_count": variance_count,
        "variance_total": _money(variance_total),
    }


def _top_supplier_balances():
    rows = []
    for supplier in Supplier.objects.filter(is_active=True):
        balance = supplier.net_balance
        if balance > 0:
            rows.append((supplier, balance))
    rows.sort(key=lambda item: (-item[1], item[0].name))
    return [
        {
            "supplier_name": supplier.name,
            "net_balance": _money(balance),
        }
        for supplier, balance in rows[:6]
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
    queryset = Order.objects.filter(status__in=(Order.Status.PAID, Order.Status.VOID))
    if user_is_manager(request.user):
        return queryset
    return queryset.filter(register_session__owner_key=_owner_key(request))


def _order_adjustments(request):
    queryset = OrderAdjustment.objects.all()
    if user_is_manager(request.user):
        return queryset
    return queryset.filter(register_session__owner_key=_owner_key(request))


def _payments(request):
    queryset = Payment.objects.select_related("order", "order__register_session")
    if user_is_manager(request.user):
        return queryset
    return queryset.filter(order__register_session__owner_key=_owner_key(request))


def _print_jobs(request):
    queryset = PrintJob.objects.all()
    if user_is_manager(request.user):
        return queryset
    return queryset.filter(order__register_session__owner_key=_owner_key(request))


def _owner_key(request):
    return f"user:{request.user.pk}"


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
