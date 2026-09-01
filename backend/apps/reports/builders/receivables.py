"""Who owes the shop, how old the debt is, and what one customer's account says.

Credit selling (<bdi>آجل</bdi>) is universal in this market and unrecoverable
credit is the owner's largest single risk — and it was the one thing the report
catalogue did not cover at all. There was no receivables figure, no aging, and
no customer statement, while the PDF layer already declared a
``customerStatement`` type with nothing behind it.

Two decisions worth stating, because both change the numbers:

**What counts as a receivable.** A credit invoice that is still open, less what
has been paid against it. Deliberately *not* "any order whose payments are less
than its total": a voided sale keeps its total and carries a reversing negative
payment, so that definition reads every refunded sale as a debt.

**How it ages.** From the invoice date, because credit invoices carry no agreed
due date anywhere in the data model. Aging from a due date the shop never
recorded would be an invention; aging from the invoice date is the standard
fallback and the report says which it used.

**As of a date, not "now".** Balances are rebuilt from the invoices raised and
the payments received on or before the period end, so a receivables report run
in November for 30 September states what was owed on 30 September — including
debts that have since been collected.
"""

from datetime import timedelta
from decimal import Decimal

from django.db.models import DecimalField, F, OuterRef, Subquery, Sum, Value
from django.db.models.functions import Coalesce, TruncDate

from apps.core.money_dates import day_range_end
from apps.payments.models import Payment
from apps.sales.models import Order

from ..sections import (
    Column,
    ColumnType,
    bounded_rows,
    decimal_from,
    money,
    note,
    percent,
    report_section,
)
from .scope import in_period

MONEY = DecimalField(max_digits=12, decimal_places=2)
ZERO = Decimal("0.00")

# Age brackets, oldest last. The boundaries are the ones every aging report in
# the world uses, so an owner comparing ours to a bank's or an auditor's sees
# the same shape.
BUCKETS = ("d0_30", "d31_60", "d61_90", "d90_plus")
BUCKET_DAYS = {"d0_30": 30, "d31_60": 60, "d61_90": 90}


def receivables_aging(context):
    as_of = context.as_of_date()
    rows, totals = _customer_balances(as_of, context)

    bounded = bounded_rows(rows, limit=context.row_limit("receivables"))
    overdue = sum(
        (decimal_from(totals[bucket]) for bucket in ("d31_60", "d61_90", "d90_plus")),
        ZERO,
    )
    figures = {
        "receivable_total": money(totals["total"]),
        "overdue_total": money(overdue),
        "overdue_percent": percent(overdue, totals["total"]),
        "customer_count": len(rows),
        "invoice_count": totals["invoice_count"],
        "oldest_days": totals["oldest_days"],
        **{bucket: money(totals[bucket]) for bucket in BUCKETS},
    }
    return {
        "summary": figures,
        "sections": [
            context.metrics(figures),
            report_section(
                "receivables_aging",
                [
                    Column("customer_name"),
                    Column("invoice_count", ColumnType.COUNT, total=True),
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
                    "invoice_count": totals["invoice_count"],
                },
            ),
        ],
        "notes": [
            note("receivable_is_open_credit"),
            note("aged_from_invoice_date"),
            note("receivables_as_of", date=as_of),
        ],
    }


def receivables_total(context):
    """The one figure the month-end pack needs, without the schedule."""
    _rows, totals = _customer_balances(context.as_of_date(), context, detail=False)
    return totals


def _customer_balances(as_of, context, *, detail=True):
    """One row per customer with an outstanding balance, aged.

    One query. The per-invoice balances are folded into per-customer
    accumulators in Python rather than a second GROUP BY, because the balance
    is ``total − payments`` and the payment sum is a correlated subquery: asking
    the database to group by customer *and* carry that subquery makes it group
    by the invoice's own primary key, which is a different report. Memory stays
    proportional to the number of customers, not invoices.
    """
    invoices = _outstanding_invoices(as_of)
    thresholds = {
        bucket: as_of - timedelta(days=days) for bucket, days in BUCKET_DAYS.items()
    }

    per_customer = {}
    totals = {bucket: ZERO for bucket in BUCKETS}
    totals.update({"total": ZERO, "invoice_count": 0, "oldest_days": 0})

    for invoice in invoices:
        balance = decimal_from(invoice["balance"])
        if balance <= 0:
            continue
        invoice_date = invoice["invoice_date"]
        bucket = _bucket_for(invoice_date, thresholds)
        age = (as_of - invoice_date).days if invoice_date else 0

        key = invoice["customer_id"]
        row = per_customer.setdefault(
            key,
            {
                "customer_name": invoice["customer__full_name"] or "",
                "invoice_count": 0,
                "oldest_days": 0,
                **{name: ZERO for name in BUCKETS},
                "total": ZERO,
            },
        )
        row["invoice_count"] += 1
        row["oldest_days"] = max(row["oldest_days"], age)
        row[bucket] += balance
        row["total"] += balance

        totals[bucket] += balance
        totals["total"] += balance
        totals["invoice_count"] += 1
        totals["oldest_days"] = max(totals["oldest_days"], age)

    if not detail:
        return [], totals

    rows = sorted(per_customer.values(), key=lambda row: row["total"], reverse=True)
    return [
        {
            "customer_name": row["customer_name"],
            "invoice_count": row["invoice_count"],
            "oldest_days": row["oldest_days"],
            **{bucket: money(row[bucket]) for bucket in BUCKETS},
            "total": money(row["total"]),
        }
        for row in rows
    ], totals


def _outstanding_invoices(as_of):
    cutoff = day_range_end(as_of)
    paid = (
        Payment.objects.filter(order=OuterRef("pk"), paid_at__lt=cutoff)
        .order_by()
        .values("order")
        .annotate(total=Sum("amount"))
        .values("total")[:1]
    )
    return (
        Order.objects.filter(
            sale_type=Order.SaleType.CREDIT,
            created_at__lt=cutoff,
        )
        .exclude(status=Order.Status.VOID)
        .annotate(
            paid_amount=Coalesce(
                Subquery(paid, output_field=MONEY), Value(ZERO), output_field=MONEY
            ),
            invoice_date=TruncDate("created_at"),
        )
        .annotate(balance=F("total") - F("paid_amount"))
        .filter(balance__gt=0)
        .values("customer_id", "customer__full_name", "invoice_date", "balance")
    )


def _bucket_for(invoice_date, thresholds):
    if invoice_date is None:
        return "d90_plus"
    if invoice_date >= thresholds["d0_30"]:
        return "d0_30"
    if invoice_date >= thresholds["d31_60"]:
        return "d31_60"
    if invoice_date >= thresholds["d61_90"]:
        return "d61_90"
    return "d90_plus"


# --------------------------------------------------------------------------
# Customer statement (كشف حساب)
# --------------------------------------------------------------------------


def customer_statement(context):
    """One customer's account: opening balance, every document, closing balance.

    The document a wholesale customer asks for by name. Built as a running
    balance rather than a list of invoices and a list of payments, because a
    statement is only useful if the customer can follow it line by line down to
    the figure at the bottom and agree with each step.
    """
    from apps.customers.models import Customer

    customer = Customer.objects.filter(pk=context.param("customer_id")).first()
    if customer is None:
        raise context.validation_error("Customer not found.")

    period = context.period
    opening = _customer_balance_at(customer, period.start_date - timedelta(days=1))
    entries = _statement_entries(customer, period)

    balance = opening
    rows = []
    for entry in entries:
        balance += entry["debit"] - entry["credit"]
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

    invoiced = sum((entry["debit"] for entry in entries), ZERO)
    received = sum((entry["credit"] for entry in entries), ZERO)
    bounded = bounded_rows(rows, limit=context.row_limit("statement_entries"))

    figures = {
        "customer_name": customer.full_name,
        "opening_balance": money(opening),
        "invoiced_total": money(invoiced),
        "received_total": money(received),
        "closing_balance": money(balance),
        "entry_count": len(entries),
    }
    return {
        "summary": figures,
        "party": {
            "id": customer.pk,
            "name": customer.full_name,
            "reference": customer.customer_number,
            "phone": customer.phone,
        },
        "sections": [
            context.metrics(figures),
            report_section(
                "statement_entries",
                [
                    Column("date", ColumnType.DATE),
                    Column("document"),
                    Column("kind", ColumnType.CHOICE),
                    Column("debit", ColumnType.MONEY, total=True),
                    Column("credit", ColumnType.MONEY, total=True),
                    Column("balance", ColumnType.MONEY),
                ],
                bounded.rows,
                total_count=bounded.total_count,
                limit=bounded.limit,
                totals={"debit": money(invoiced), "credit": money(received)},
            ),
        ],
        "notes": [
            note("statement_running_balance"),
            note("statement_credit_only"),
        ],
    }


def _customer_balance_at(customer, when):
    """What this customer owed at the close of ``when``."""
    cutoff = day_range_end(when)
    invoiced = (
        Order.objects.filter(
            customer=customer,
            sale_type=Order.SaleType.CREDIT,
            created_at__lt=cutoff,
        )
        .exclude(status=Order.Status.VOID)
        .aggregate(total=Coalesce(Sum("total"), Value(ZERO), output_field=MONEY))
    )["total"]
    paid = Payment.objects.filter(
        order__customer=customer,
        order__sale_type=Order.SaleType.CREDIT,
        paid_at__lt=cutoff,
    ).aggregate(total=Coalesce(Sum("amount"), Value(ZERO), output_field=MONEY))["total"]
    return decimal_from(invoiced) - decimal_from(paid)


def _statement_entries(customer, period):
    """Every movement on the account inside the period, in date order.

    Invoices debit the account, payments credit it. Returns arrive as their own
    line rather than being netted into the invoice, because a customer reading
    a statement needs to see the credit note that explains why the balance
    fell.
    """
    entries = []

    invoices = in_period(
        Order.objects.filter(
            customer=customer, sale_type=Order.SaleType.CREDIT
        ).exclude(status=Order.Status.VOID),
        period,
    ).values("receipt_number", "created_at", "total")
    for invoice in invoices:
        entries.append(
            {
                "date": invoice["created_at"].date(),
                "document": invoice["receipt_number"],
                "kind": "invoice",
                "debit": decimal_from(invoice["total"]),
                "credit": ZERO,
            }
        )

    payments = in_period(
        Payment.objects.filter(
            order__customer=customer, order__sale_type=Order.SaleType.CREDIT
        ),
        period,
    ).values("order__receipt_number", "paid_at", "amount", "method")
    for payment in payments:
        amount = decimal_from(payment["amount"])
        entries.append(
            {
                "date": payment["paid_at"].date(),
                "document": payment["order__receipt_number"],
                # A negative payment row is a refund handed back, which raises
                # the balance again — so it is a debit, not a negative credit.
                "kind": "payment" if amount >= 0 else "refund",
                "debit": ZERO if amount >= 0 else -amount,
                "credit": amount if amount >= 0 else ZERO,
            }
        )

    entries.sort(key=lambda entry: (entry["date"], entry["kind"], entry["document"]))
    return entries


__all__ = ["customer_statement", "receivables_aging", "receivables_total"]
