"""What the shop bought, what it still owes for it, and one supplier's account.

The purchasing summary already listed supplier balances — as a single flat
figure per supplier, which answers "how much" and not "how late", and there was
no supplier statement at all. Both are what a payables conversation actually
runs on.

The outstanding balance is the same arithmetic the payables screen uses:
billable total (what was ordered, less anything a receipt cancelled as
never-arriving) minus everything paid against it, cash or applied credit. One
definition, so a report row and the screen cannot disagree about what is owed.
"""

from datetime import timedelta
from decimal import Decimal

from django.db.models import DecimalField, F, OuterRef, Subquery, Sum, Value
from django.db.models.functions import Coalesce, TruncDate

from apps.core.money_dates import day_range_end
from apps.purchasing.models import (
    PurchaseOrder,
    Supplier,
    SupplierPayment,
    prime_supplier_balances,
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
    report_section,
)
from .scope import in_period, money_sum

MONEY = DecimalField(max_digits=12, decimal_places=2)
ZERO = Decimal("0.00")

BUCKETS = ("d0_30", "d31_60", "d61_90", "d90_plus")
BUCKET_DAYS = {"d0_30": 30, "d31_60": 60, "d61_90": 90}


def purchasing_summary(context):
    orders = PurchaseOrder.objects.select_related("supplier").exclude(
        status=PurchaseOrder.Status.CANCELLED,
    )
    period_orders = in_period(orders, context.period)
    purchase_total = period_orders.aggregate(total=money_sum("total"))["total"]

    limit = context.row_limit("purchase_orders")
    purchase_rows = bounded_queryset(
        # Each row reads ``balance_due``, which sums ``supplier_payments`` twice
        # (paid + credit-applied) in Python — 2 queries per order unless the
        # payments ride along. Same reason the supplier rows below are primed.
        period_orders.order_by("-created_at").prefetch_related("supplier_payments"),
        limit=limit,
    )
    rows = [
        {
            "order_number": order.order_number,
            "supplier_name": order.supplier.name,
            "status": order.status,
            "total": money(order.total),
            "balance_due": money(order.balance_due),
            "created_at": order.created_at.isoformat(),
            "due_date": order.due_date.isoformat() if order.due_date else "",
        }
        for order in purchase_rows.rows
    ]

    supplier_rows_values = bounded_queryset(
        Supplier.objects.filter(is_active=True).order_by("name"),
        limit=context.row_limit("supplier_balances"),
    )
    # Each row reads payable/credit/net — 6 queries per supplier unless primed.
    prime_supplier_balances(supplier_rows_values.rows)
    supplier_rows = [
        {
            "supplier_name": supplier.name,
            "payable_balance": money(supplier.payable_balance),
            "credit_balance": money(supplier.credit_balance),
            "net_balance": money(supplier.net_balance),
        }
        for supplier in supplier_rows_values.rows
    ]

    paid_in_period = in_period(SupplierPayment.objects.all(), context.period).aggregate(
        total=money_sum("amount")
    )["total"]
    figures = {
        "purchase_total": money(purchase_total),
        "supplier_paid_total": money(paid_in_period),
        "purchase_order_count": period_orders.count(),
        "open_order_count": orders.exclude(
            status=PurchaseOrder.Status.RECEIVED
        ).count(),
        "supplier_count": Supplier.objects.filter(is_active=True).count(),
    }
    return {
        "summary": figures,
        "sections": [
            context.metrics(figures),
            report_section(
                "purchase_orders",
                [
                    Column("order_number"),
                    Column("supplier_name"),
                    Column("status", ColumnType.CHOICE),
                    Column("total", ColumnType.MONEY, total=True),
                    Column("balance_due", ColumnType.MONEY, total=True),
                    Column("created_at", ColumnType.DATETIME),
                    Column("due_date", ColumnType.DATE),
                ],
                rows,
                total_count=purchase_rows.total_count,
                limit=purchase_rows.limit,
                totals={"total": money(purchase_total)},
            ),
            report_section(
                "supplier_balances",
                [
                    Column("supplier_name"),
                    Column("payable_balance", ColumnType.MONEY, total=True),
                    Column("credit_balance", ColumnType.MONEY, total=True),
                    Column("net_balance", ColumnType.MONEY, total=True),
                ],
                supplier_rows,
                total_count=supplier_rows_values.total_count,
                limit=supplier_rows_values.limit,
            ),
        ],
        "notes": [note("purchase_is_stock_not_expense"), note("balance_nets_credit")],
    }


# --------------------------------------------------------------------------
# Payables aging
# --------------------------------------------------------------------------


def payables_aging(context):
    as_of = context.as_of_date()
    rows, totals = _supplier_balances(as_of)

    bounded = bounded_rows(rows, limit=context.row_limit("payables"))
    overdue = sum(
        (decimal_from(totals[bucket]) for bucket in ("d31_60", "d61_90", "d90_plus")),
        ZERO,
    )
    figures = {
        "payable_total": money(totals["total"]),
        "overdue_total": money(overdue),
        "overdue_percent": percent(overdue, totals["total"]),
        "supplier_count": len(rows),
        "order_count": totals["order_count"],
        "oldest_days": totals["oldest_days"],
        **{bucket: money(totals[bucket]) for bucket in BUCKETS},
    }
    return {
        "summary": figures,
        "sections": [
            context.metrics(figures),
            report_section(
                "payables_aging",
                [
                    Column("supplier_name"),
                    Column("order_count", ColumnType.COUNT, total=True),
                    Column("oldest_days", ColumnType.COUNT),
                    *[Column(bucket, ColumnType.MONEY, total=True) for bucket in BUCKETS],
                    Column("total", ColumnType.MONEY, total=True),
                ],
                bounded.rows,
                total_count=bounded.total_count,
                limit=bounded.limit,
                totals={
                    **{bucket: money(totals[bucket]) for bucket in BUCKETS},
                    "total": money(totals["total"]),
                    "order_count": totals["order_count"],
                },
            ),
        ],
        "notes": [
            note("payable_is_billable_less_paid"),
            note("aged_from_due_or_order_date"),
            note("payables_as_of", date=as_of),
        ],
    }


def payables_total(context):
    _rows, totals = _supplier_balances(context.as_of_date(), detail=False)
    return totals


def _supplier_balances(as_of, *, detail=True):
    """Outstanding purchase orders, aged and folded into per-supplier rows.

    Ages from the agreed due date when there is one and the order date when
    there is not — the due date is what a supplier will chase on, and falling
    back to the order date keeps an undated order visible rather than dropping
    it into a bucket it did not earn.
    """
    cutoff = day_range_end(as_of)
    paid = (
        SupplierPayment.objects.filter(purchase_order=OuterRef("pk"), paid_at__lt=cutoff)
        .order_by()
        .values("purchase_order")
        .annotate(total=Sum("amount"))
        .values("total")[:1]
    )
    outstanding = (
        PurchaseOrder.objects.exclude(status=PurchaseOrder.Status.CANCELLED)
        .filter(created_at__lt=cutoff)
        .annotate(
            paid_amount=Coalesce(
                Subquery(paid, output_field=MONEY), Value(ZERO), output_field=MONEY
            ),
            reference_date=Coalesce("due_date", TruncDate("created_at")),
        )
        .annotate(balance=F("total") - F("cancelled_total") - F("paid_amount"))
        .filter(balance__gt=0)
        .values("supplier_id", "supplier__name", "reference_date", "balance")
    )
    thresholds = {
        bucket: as_of - timedelta(days=days) for bucket, days in BUCKET_DAYS.items()
    }

    per_supplier = {}
    totals = {bucket: ZERO for bucket in BUCKETS}
    totals.update({"total": ZERO, "order_count": 0, "oldest_days": 0})

    for order in outstanding:
        balance = decimal_from(order["balance"])
        reference = order["reference_date"]
        bucket = _bucket_for(reference, thresholds)
        age = max((as_of - reference).days, 0) if reference else 0

        row = per_supplier.setdefault(
            order["supplier_id"],
            {
                "supplier_name": order["supplier__name"] or "",
                "order_count": 0,
                "oldest_days": 0,
                **{name: ZERO for name in BUCKETS},
                "total": ZERO,
            },
        )
        row["order_count"] += 1
        row["oldest_days"] = max(row["oldest_days"], age)
        row[bucket] += balance
        row["total"] += balance

        totals[bucket] += balance
        totals["total"] += balance
        totals["order_count"] += 1
        totals["oldest_days"] = max(totals["oldest_days"], age)

    if not detail:
        return [], totals

    rows = sorted(per_supplier.values(), key=lambda row: row["total"], reverse=True)
    return [
        {
            "supplier_name": row["supplier_name"],
            "order_count": row["order_count"],
            "oldest_days": row["oldest_days"],
            **{bucket: money(row[bucket]) for bucket in BUCKETS},
            "total": money(row["total"]),
        }
        for row in rows
    ], totals


def _bucket_for(reference, thresholds):
    if reference is None:
        return "d90_plus"
    if reference >= thresholds["d0_30"]:
        return "d0_30"
    if reference >= thresholds["d31_60"]:
        return "d31_60"
    if reference >= thresholds["d61_90"]:
        return "d61_90"
    return "d90_plus"


# --------------------------------------------------------------------------
# Supplier statement
# --------------------------------------------------------------------------


def supplier_statement(context):
    supplier = Supplier.objects.filter(pk=context.param("supplier_id")).first()
    if supplier is None:
        raise context.validation_error("Supplier not found.")

    period = context.period
    opening = _supplier_balance_at(supplier, period.start_date - timedelta(days=1))
    entries = _supplier_entries(supplier, period)

    balance = opening
    rows = []
    for entry in entries:
        balance += entry["credit"] - entry["debit"]
        rows.append(
            {
                "date": entry["date"].isoformat(),
                "document": entry["document"],
                "kind": entry["kind"],
                "debit": money(entry["debit"]),
                "credit": money(entry["credit"]),
                "balance": money(balance),
            }
        )

    invoiced = sum((entry["credit"] for entry in entries), ZERO)
    paid = sum((entry["debit"] for entry in entries), ZERO)
    bounded = bounded_rows(rows, limit=context.row_limit("statement_entries"))

    figures = {
        "supplier_name": supplier.name,
        "opening_balance": money(opening),
        "invoiced_total": money(invoiced),
        "paid_total": money(paid),
        "closing_balance": money(balance),
        "entry_count": len(entries),
    }
    return {
        "summary": figures,
        "party": {
            "id": supplier.pk,
            "name": supplier.name,
            "reference": getattr(supplier, "phone", "") or "",
        },
        "sections": [
            context.metrics(figures),
            report_section(
                "statement_entries",
                [
                    Column("date", ColumnType.DATE),
                    Column("document"),
                    Column("kind", ColumnType.CHOICE),
                    Column("credit", ColumnType.MONEY, total=True),
                    Column("debit", ColumnType.MONEY, total=True),
                    Column("balance", ColumnType.MONEY),
                ],
                bounded.rows,
                total_count=bounded.total_count,
                limit=bounded.limit,
                totals={"credit": money(invoiced), "debit": money(paid)},
            ),
        ],
        "notes": [note("statement_running_balance"), note("supplier_credit_is_owed")],
    }


def _supplier_balance_at(supplier, when):
    cutoff = day_range_end(when)
    billed = (
        PurchaseOrder.objects.filter(supplier=supplier, created_at__lt=cutoff)
        .exclude(status=PurchaseOrder.Status.CANCELLED)
        .aggregate(
            total=Coalesce(
                Sum(F("total") - F("cancelled_total")),
                Value(ZERO),
                output_field=MONEY,
            )
        )
    )["total"]
    paid = SupplierPayment.objects.filter(
        supplier=supplier, paid_at__lt=cutoff
    ).aggregate(total=Coalesce(Sum("amount"), Value(ZERO), output_field=MONEY))["total"]
    return decimal_from(billed) - decimal_from(paid)


def _supplier_entries(supplier, period):
    entries = []

    orders = in_period(
        PurchaseOrder.objects.filter(supplier=supplier).exclude(
            status=PurchaseOrder.Status.CANCELLED
        ),
        period,
    ).values("order_number", "created_at", "total", "cancelled_total")
    for order in orders:
        entries.append(
            {
                "date": order["created_at"].date(),
                "document": order["order_number"],
                "kind": "purchase",
                "credit": decimal_from(order["total"])
                - decimal_from(order["cancelled_total"]),
                "debit": ZERO,
            }
        )

    payments = in_period(
        SupplierPayment.objects.filter(supplier=supplier), period
    ).values("purchase_order__order_number", "paid_at", "amount", "method")
    for payment in payments:
        entries.append(
            {
                "date": payment["paid_at"].date(),
                "document": payment["purchase_order__order_number"] or "",
                "kind": payment["method"],
                "credit": ZERO,
                "debit": decimal_from(payment["amount"]),
            }
        )

    entries.sort(key=lambda entry: (entry["date"], entry["kind"], entry["document"]))
    return entries


__all__ = [
    "payables_aging",
    "payables_total",
    "purchasing_summary",
    "supplier_statement",
]
