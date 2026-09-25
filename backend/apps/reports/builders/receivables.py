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
payment, so that definition reads every refunded sale as a debt. A *part*-
returned invoice has the same shape on a smaller scale — the money handed back
is a negative payment and the total never drops — so what came back is taken
off as well: owed is the total less returns less net payments, exactly as
``Order.balance_due`` has it.

**How it ages.** From the due date where the invoice records one, and from the
invoice date where it does not — the same ``COALESCE`` the payables side has
always used, and the same fallback ERPNext applies (``row.due_date or
row.posting_date``). Until credit invoices could carry a due date this report
had only the second half of that rule and said so; it now has both, so an
invoice sold on 30-day terms stops reading as a month overdue on the day it is
issued.

**"Not yet due" is not an age.** An invoice inside its terms is outstanding but
not late, and putting it in the youngest bucket would let a shop with generous
terms read as though it were chasing money it had not yet asked for. It gets its
own column, outside the aged buckets — ERPNext keeps the same separation
(``range0``, excluded from ``total_due``). Only an invoice with a recorded due
date can land there, so a shop that has never set terms sees a column of zeros
and every other figure exactly where it was.

**Overdue keeps its existing definition** — outstanding more than 30 days past
whichever of those two dates applies. It is stated once, in ``OVERDUE_BUCKETS``,
and deliberately not redefined to mean "past the due date": that is a different
figure, and this codebase adds a new name rather than re-pointing an old one.

**As of a date, not "now".** Balances are rebuilt from the invoices raised and
the payments received on or before the period end, so a receivables report run
in November for 30 September states what was owed on 30 September — including
debts that have since been collected.
"""

from datetime import timedelta
from decimal import Decimal

from django.db.models import DecimalField, F, OuterRef, Subquery, Sum, Value
from django.db.models.functions import Coalesce, TruncDate

from apps.balances.common import statement_kind
from apps.core.money_dates import day_range_end
from apps.documents.statuses import DocumentStatus
from apps.payments.models import Payment
from apps.sales.models import Order, OrderAdjustment

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
# Outstanding that is still inside its agreed terms. Not one of BUCKETS: it is
# reported alongside them, never aged, and never summed into an age band.
NOT_YET_DUE = "not_yet_due"
# What "overdue" has always meant in this report. Named so that the definition
# lives in one place and a future change to it is a visible edit rather than a
# drifting sum (see apps/core/test_money_definitions.py).
OVERDUE_BUCKETS = ("d31_60", "d61_90", "d90_plus")


def receivables_aging(context):
    as_of = context.as_of_date()
    rows, totals = _customer_balances(as_of, context)

    bounded = bounded_rows(rows, limit=context.row_limit("receivables"))
    overdue = sum(
        (decimal_from(totals[bucket]) for bucket in OVERDUE_BUCKETS),
        ZERO,
    )
    figures = {
        "receivable_total": money(totals["total"]),
        "overdue_total": money(overdue),
        "overdue_percent": percent(overdue, totals["total"]),
        "customer_count": len(rows),
        "invoice_count": totals["invoice_count"],
        "oldest_days": totals["oldest_days"],
        NOT_YET_DUE: money(totals[NOT_YET_DUE]),
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
                    Column(NOT_YET_DUE, ColumnType.MONEY, total=True),
                    *[Column(bucket, ColumnType.MONEY, total=True) for bucket in BUCKETS],
                    Column("total", ColumnType.MONEY, total=True),
                ],
                bounded.rows,
                total_count=bounded.total_count,
                limit=bounded.limit,
                totals={
                    NOT_YET_DUE: money(totals[NOT_YET_DUE]),
                    **{bucket: money(totals[bucket]) for bucket in BUCKETS},
                    "total": money(totals["total"]),
                    "invoice_count": totals["invoice_count"],
                },
            ),
        ],
        "notes": [
            note("receivable_is_open_credit"),
            note("aged_from_due_or_invoice_date"),
            note("not_yet_due_excluded_from_ages"),
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
    is ``total − returns − payments`` and both sums are correlated subqueries:
    asking the database to group by customer *and* carry them makes it group
    by the invoice's own primary key, which is a different report. Memory stays
    proportional to the number of customers, not invoices.
    """
    invoices = _outstanding_invoices(as_of)
    thresholds = {
        bucket: as_of - timedelta(days=days) for bucket, days in BUCKET_DAYS.items()
    }

    per_customer = {}
    totals = {bucket: ZERO for bucket in BUCKETS}
    totals.update(
        {NOT_YET_DUE: ZERO, "total": ZERO, "invoice_count": 0, "oldest_days": 0}
    )

    for invoice in invoices:
        balance = decimal_from(invoice["balance"])
        if balance <= 0:
            continue
        reference = invoice["reference_date"] or invoice["invoice_date"]
        bucket = _bucket_for(reference, as_of, thresholds)
        # Days past the date it is aged against, floored at zero: an invoice
        # still inside its terms is not "-6 days old", it has no age yet.
        age = max((as_of - reference).days, 0) if reference else 0

        key = invoice["customer_id"]
        row = per_customer.setdefault(
            key,
            {
                "customer_name": invoice["customer__full_name"] or "",
                "invoice_count": 0,
                "oldest_days": 0,
                NOT_YET_DUE: ZERO,
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
            NOT_YET_DUE: money(row[NOT_YET_DUE]),
            **{bucket: money(row[bucket]) for bucket in BUCKETS},
            "total": money(row["total"]),
        }
        for row in rows
    ], totals


def _per_invoice_sum(queryset):
    """``Σ amount`` of ``queryset``'s rows for the invoice in the outer query."""
    return Coalesce(
        Subquery(
            queryset.filter(order=OuterRef("pk"))
            .order_by()
            .values("order")
            .annotate(total=Sum("amount"))
            .values("total")[:1],
            output_field=MONEY,
        ),
        Value(ZERO),
        output_field=MONEY,
    )


def _outstanding_invoices(as_of):
    """Every debt open at the close of ``as_of``: آجل invoices, and the debts
    written straight onto customers' accounts (an opening balance, an
    adjustment — carried on ``ACCOUNT_ENTRY`` orders dated the day they apply
    from). Credit the shop holds for a customer is not netted in here: it is a
    liability of its own (:func:`customer_credits_total`), stated beside this
    figure the way an advance sits beside the debts on any balance sheet.
    """
    cutoff = day_range_end(as_of)
    return (
        Order.objects.filter(
            sale_type__in=Order.RECEIVABLE_SALE_TYPES,
            created_at__lt=cutoff,
        )
        .exclude(status=Order.Status.VOID)
        .annotate(
            paid_amount=_per_invoice_sum(Payment.objects.filter(paid_at__lt=cutoff)),
            # What came back by the same moment. Its money went back as a
            # negative payment, already inside ``paid_amount``, so without this
            # every part-returned invoice ages as owing its refund.
            returned_amount=_per_invoice_sum(
                OrderAdjustment.objects.filter(created_at__lt=cutoff)
            ),
            invoice_date=TruncDate("created_at"),
            # The date this invoice is aged against. Mirrors the payables side
            # (``purchasing._supplier_balances``) exactly, so the two halves of
            # the ledger answer "how old is this" the same way.
            reference_date=Coalesce("due_date", TruncDate("created_at")),
        )
        .annotate(balance=F("total") - F("returned_amount") - F("paid_amount"))
        .filter(balance__gt=0)
        .values(
            "customer_id",
            "customer__full_name",
            "invoice_date",
            "reference_date",
            "balance",
        )
    )


def _bucket_for(reference, as_of, thresholds):
    """Which column this balance belongs in, aged against ``reference``.

    A reference date in the future can only be a due date the shop agreed to,
    so the balance is not late — it has not been asked for yet.
    """
    if reference is None:
        return "d90_plus"
    if reference > as_of:
        return NOT_YET_DUE
    if reference >= thresholds["d0_30"]:
        return "d0_30"
    if reference >= thresholds["d31_60"]:
        return "d31_60"
    if reference >= thresholds["d61_90"]:
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
        due = entry.get("due_date")
        rows.append(
            {
                "date": entry["date"].isoformat(),
                "document": entry["document"],
                "kind": entry["kind"],
                "due_date": due.isoformat() if due else "",
                "debit": money(entry["debit"]),
                "credit": money(entry["credit"]),
                "balance": money(balance),
            }
        )

    # Each figure is one kind of line, never a column total: the debit column
    # also carries refunds and the credit column returns, and summed whole
    # they would put money handed back under «إجمالي الفواتير» and goods taken
    # back under «المحصَّل». The balances written onto the account (an opening
    # balance, an adjustment, a refund against one) run either way, so they
    # are one figure, debit less credit. So opening + account entries +
    # invoiced − returned − received + refunded = closing, and every term says
    # what it is.
    by_kind = {kind: {"debit": ZERO, "credit": ZERO} for kind in _STATEMENT_KIND_ORDER}
    for entry in entries:
        by_kind[entry["kind"]]["debit"] += entry["debit"]
        by_kind[entry["kind"]]["credit"] += entry["credit"]
    account_entries = sum(
        (by_kind[kind]["debit"] - by_kind[kind]["credit"] for kind in _ACCOUNT_ENTRY_KINDS),
        ZERO,
    )
    bounded = bounded_rows(rows, limit=context.row_limit("statement_entries"))

    figures = {
        "customer_name": customer.full_name,
        "opening_balance": money(opening),
        "account_entries_total": money(account_entries),
        "invoiced_total": money(by_kind["invoice"]["debit"]),
        "returned_total": money(by_kind["return"]["credit"]),
        "received_total": money(by_kind["payment"]["credit"]),
        "refunded_total": money(by_kind["refund"]["debit"]),
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
                    Column("due_date", ColumnType.DATE),
                    Column("debit", ColumnType.MONEY, total=True),
                    Column("credit", ColumnType.MONEY, total=True),
                    Column("balance", ColumnType.MONEY),
                ],
                bounded.rows,
                total_count=bounded.total_count,
                limit=bounded.limit,
                totals={
                    "debit": money(sum((entry["debit"] for entry in entries), ZERO)),
                    "credit": money(sum((entry["credit"] for entry in entries), ZERO)),
                },
            ),
        ],
        "notes": [
            note("statement_running_balance"),
            note("statement_credit_and_account_entries"),
        ],
    }


def _statement_payments(customer):
    """The money that moved on this customer's account: payments against their
    آجل invoices and against the debts written onto the account.

    Credit spent against a debt (``ACCOUNT_CREDIT``) is left out on purpose. It
    moved no money: the statement already credited the account on the day the
    shop came to owe that credit, so crediting it again when it was spent would
    count it twice.
    """
    return Payment.objects.filter(
        order__customer=customer,
        order__sale_type__in=Order.RECEIVABLE_SALE_TYPES,
    ).exclude(method=Payment.Method.ACCOUNT_CREDIT)


def _customer_balance_at(customer, when):
    """What this customer owed at the close of ``when`` — negative when the
    shop owed them."""
    from apps.balances.models import CustomerBalanceEntry

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
    returned = _statement_returns(customer).filter(created_at__lt=cutoff).aggregate(
        total=Coalesce(Sum("amount"), Value(ZERO), output_field=MONEY)
    )["total"]
    paid = (
        _statement_payments(customer)
        .filter(paid_at__lt=cutoff)
        .aggregate(total=Coalesce(Sum("amount"), Value(ZERO), output_field=MONEY))
    )["total"]
    entries = (
        CustomerBalanceEntry.objects.live()
        .filter(customer=customer, effective_date__lte=when)
        .order_by()
        .values("direction")
        .annotate(total=Sum("amount"))
    )
    written = ZERO
    for row in entries:
        amount = decimal_from(row["total"])
        written += (
            amount
            if row["direction"] == CustomerBalanceEntry.Direction.THEY_OWE_US
            else -amount
        )
    return (
        decimal_from(invoiced)
        + written
        - decimal_from(returned)
        - decimal_from(paid)
    )


def _statement_returns(customer):
    """The returns that credit this customer's account.

    Only against the invoices the statement shows. A voided invoice is left
    off whole — no debit, and so no credit either — while its payments and
    refunds still appear and cancel each other out.
    """
    return OrderAdjustment.objects.filter(
        order__customer=customer, order__sale_type=Order.SaleType.CREDIT
    ).exclude(order__status=Order.Status.VOID)


def _statement_entries(customer, period):
    """Every movement on the account inside the period, in date order.

    Invoices debit the account, payments credit it. Returns arrive as their own
    line rather than being netted into the invoice, because a customer reading
    a statement needs to see the credit note that explains why the balance
    fell. Opening balances and adjustments arrive as their own lines too, on the
    day they apply from, debit or credit by which way they run.
    """
    from apps.balances.models import CustomerBalanceEntry

    entries = []

    invoices = in_period(
        Order.objects.filter(
            customer=customer, sale_type=Order.SaleType.CREDIT
        ).exclude(status=Order.Status.VOID),
        period,
    ).values("receipt_number", "created_at", "total", "due_date")
    for invoice in invoices:
        entries.append(
            {
                "date": invoice["created_at"].date(),
                "document": invoice["receipt_number"],
                "kind": "invoice",
                "debit": decimal_from(invoice["total"]),
                "credit": ZERO,
                # Blank rather than null on the payment rows below: a statement
                # is read as a table, and a due date on the line that credits an
                # invoice would suggest the payment itself was scheduled.
                "due_date": invoice["due_date"],
            }
        )

    balance_entries = in_period(
        CustomerBalanceEntry.objects.live().filter(customer=customer), period
    ).values("number", "effective_date", "amount", "direction", "kind")
    for entry in balance_entries:
        amount = decimal_from(entry["amount"])
        owed_by_them = entry["direction"] == CustomerBalanceEntry.Direction.THEY_OWE_US
        entries.append(
            {
                "date": entry["effective_date"],
                "document": entry["number"],
                "kind": statement_kind(entry["kind"]),
                "debit": amount if owed_by_them else ZERO,
                "credit": ZERO if owed_by_them else amount,
                "due_date": None,
            }
        )

    payments = in_period(_statement_payments(customer), period).values(
        "order__receipt_number", "paid_at", "amount", "method"
    )
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
                "due_date": None,
            }
        )

    # The credit note: the goods that came back, which is what the refund
    # above is paying out. Without it a return reads as the customer owing
    # its own refund.
    returns = in_period(_statement_returns(customer), period).values(
        "order__receipt_number", "created_at", "amount"
    )
    for returned in returns:
        entries.append(
            {
                "date": returned["created_at"].date(),
                "document": returned["order__receipt_number"],
                "kind": "return",
                "debit": ZERO,
                "credit": decimal_from(returned["amount"]),
                "due_date": None,
            }
        )

    entries.sort(
        key=lambda entry: (
            entry["date"],
            _STATEMENT_KIND_ORDER[entry["kind"]],
            entry["document"],
        )
    )
    return entries


# Same-day order. An opening balance comes first on its day — it is the
# position everything else that day started from — and the other entries
# written onto the account follow it, ahead of the documents, where they have
# always sorted. Then a return's credit note before the refund that pays it
# out — the order the two are written in — so the refund line reads as
# settling a credit the reader has just seen. The documents otherwise keep the
# alphabetical order they have always had.
_STATEMENT_KIND_ORDER = {
    "opening_balance": 0,
    "balance_adjustment": 1,
    "balance_refund": 2,
    "invoice": 3,
    "payment": 4,
    "return": 5,
    "refund": 6,
}

# The lines written straight onto the account rather than invoiced or paid
# (``apps.balances.common.statement_kind``).
_ACCOUNT_ENTRY_KINDS = ("opening_balance", "balance_adjustment", "balance_refund")


def customer_credits_total(as_of):
    """What the shop owed its customers in account credit at the close of
    ``as_of``: the credit written onto their accounts by then, less what had
    been spent against their debts by then.

    Rebuilt from dated rows, like every figure here, so a report for last month
    states last month's credit even after it has since been spent. A cancelled
    entry never counted — the same rule as a cancelled payment.
    """
    from apps.balances.models import CustomerBalanceEntry, CustomerCreditApplication

    cutoff = day_range_end(as_of)
    issued = (
        CustomerBalanceEntry.objects.live()
        .filter(
            direction=CustomerBalanceEntry.Direction.WE_OWE_THEM,
            effective_date__lte=as_of,
        )
        .aggregate(total=Coalesce(Sum("amount"), Value(ZERO), output_field=MONEY))
    )["total"]
    spent = (
        CustomerCreditApplication.objects.filter(payment__paid_at__lt=cutoff)
        .exclude(entry__doc_status=DocumentStatus.CANCELLED)
        .aggregate(total=Coalesce(Sum("amount"), Value(ZERO), output_field=MONEY))
    )["total"]
    return max(decimal_from(issued) - decimal_from(spent), ZERO)


__all__ = [
    "customer_credits_total",
    "customer_statement",
    "receivables_aging",
    "receivables_total",
]
