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
from django.db.models.functions import Coalesce, Greatest, TruncDate

from apps.balances.common import statement_kind
from apps.core.money_dates import day_range_end
from apps.purchasing.models import (
    PurchaseOrder,
    Supplier,
    SupplierCredit,
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
from .scope import in_period, in_window, money_sum

MONEY = DecimalField(max_digits=12, decimal_places=2)
ZERO = Decimal("0.00")

BUCKETS = ("d0_30", "d31_60", "d61_90", "d90_plus")
BUCKET_DAYS = {"d0_30": 30, "d31_60": 60, "d61_90": 90}
#: What an order bills: what was ordered, less what a receipt cancelled as
#: never arriving — the figure the statement and the aging owe on.
BILLABLE = F("total") - F("cancelled_total")
#: Payments that put no money anywhere: credit the supplier already owed the
#: shop, spent; and goods sent back against an order. The treasury leaves the
#: same two out of the cash that left (``treasury.position``).
NON_CASH_METHODS = (
    SupplierPayment.Method.SUPPLIER_CREDIT,
    SupplierPayment.Method.REFUND,
)


def placed_orders():
    """Purchase orders the shop actually placed: not a draft — a proposal, the
    AI intake's first reading of an invoice — and not cancelled."""
    return PurchaseOrder.objects.exclude(
        status__in=(PurchaseOrder.Status.DRAFT, PurchaseOrder.Status.CANCELLED)
    )


def placed_purchase_total(period):
    """What the shop bought in ``period``: the billable value of the orders it
    placed. Shared by the purchasing summary and the profit report's
    memorandum line, so the two state one figure."""
    return in_period(placed_orders(), period).aggregate(
        total=Coalesce(Sum(BILLABLE), Value(ZERO), output_field=MONEY)
    )["total"]


def purchasing_summary(context):
    orders = placed_orders().select_related("supplier")
    period_orders = in_period(orders, context.period)
    purchase_total = placed_purchase_total(context.period)

    # Money that left for suppliers: spending a supplier's own credit, or
    # sending goods back against an order, moved none — and counting the
    # credit a supplier's cash refund consumed made a refund *raise* this.
    paid_in_period = in_period(
        SupplierPayment.objects.live().exclude(method__in=NON_CASH_METHODS),
        context.period,
    ).aggregate(total=money_sum("amount"))["total"]
    figures = {
        "purchase_total": money(purchase_total),
        "supplier_paid_total": money(paid_in_period),
        "purchase_order_count": period_orders.count(),
        "open_order_count": orders.exclude(
            status=PurchaseOrder.Status.RECEIVED
        ).count(),
        "supplier_count": Supplier.objects.filter(is_active=True).count(),
    }
    sections = [context.metrics(figures), _supplier_balances_section(context)]
    if context.wants_detail():
        sections.append(_purchase_orders_section(period_orders, purchase_total, context))
    return {
        "summary": figures,
        "sections": sections,
        "notes": [note("purchase_is_stock_not_expense"), note("balance_nets_credit")],
    }


def _supplier_balances_section(context):
    """What the shop owes each supplier now, the largest first.

    Every active supplier is primed — 4 queries whatever their number — so the
    table can lead with the largest debts rather than with whichever names
    come first in the alphabet, and its totals are every supplier's. A supplier
    the shop neither owes nor holds credit with has no line: a balances table
    of zeros is not a summary of anything.
    """
    # Each supplier reads payable/credit/net — 6 queries apiece unless primed.
    suppliers = prime_supplier_balances(
        Supplier.objects.filter(is_active=True).order_by("name")
    )
    rows = sorted(
        (
            {
                "supplier_name": supplier.name,
                "payable_balance": money(supplier.payable_balance),
                "credit_balance": money(supplier.credit_balance),
                "net_balance": money(supplier.net_balance),
            }
            for supplier in suppliers
            if supplier.payable_balance or supplier.credit_balance
        ),
        key=lambda row: -decimal_from(row["net_balance"]),
    )
    bounded = bounded_rows(rows, limit=context.row_limit("supplier_balances"))
    return report_section(
        "supplier_balances",
        [
            Column("supplier_name"),
            Column("payable_balance", ColumnType.MONEY, total=True),
            Column("credit_balance", ColumnType.MONEY, total=True),
            Column("net_balance", ColumnType.MONEY, total=True),
        ],
        bounded.rows,
        total_count=bounded.total_count,
        limit=bounded.limit,
        totals={
            column: money(sum((decimal_from(row[column]) for row in rows), ZERO))
            for column in ("payable_balance", "credit_balance", "net_balance")
        },
    )


def _purchase_orders_section(period_orders, purchase_total, context):
    """Every purchase order raised in the period, newest first."""
    purchase_rows = bounded_queryset(
        # Each row reads ``balance_due``, which sums ``supplier_payments`` twice
        # (paid + credit-applied) in Python — 2 queries per order unless the
        # payments ride along. Same reason the supplier rows are primed.
        period_orders.order_by("-created_at").prefetch_related("supplier_payments"),
        limit=context.row_limit("purchase_orders"),
    )
    rows = [
        {
            "order_number": order.order_number,
            "supplier_name": order.supplier.name,
            "status": order.status,
            "total": money(order.total - order.cancelled_total),
            "balance_due": money(order.balance_due),
            "created_at": order.created_at.isoformat(),
            "due_date": order.due_date.isoformat() if order.due_date else "",
        }
        for order in purchase_rows.rows
    ]
    # What every order in the period still owes, for the totals line under a
    # cut table: the same per-order arithmetic ``balance_due`` uses, summed.
    paid = (
        SupplierPayment.objects.live()
        .filter(purchase_order=OuterRef("pk"))
        .order_by()
        .values("purchase_order")
        .annotate(total=Sum("amount"))
        .values("total")[:1]
    )
    still_owed = (
        period_orders.annotate(
            _paid=Coalesce(Subquery(paid, output_field=MONEY), Value(ZERO), output_field=MONEY)
        )
        .annotate(_due=Greatest(BILLABLE - F("_paid"), Value(ZERO), output_field=MONEY))
        .aggregate(total=Coalesce(Sum("_due"), Value(ZERO), output_field=MONEY))
    )["total"]
    return report_section(
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
        totals={"total": money(purchase_total), "balance_due": money(still_owed)},
    )


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


def supplier_credits_total(as_of):
    """What suppliers owed the shop in credit notes at the close of ``as_of``.

    A credit note is issued when goods already paid for go back, and is spent
    by settling a later order with it. Rebuilt from the notes issued by then
    less the credit spent by then, because ``remaining_amount`` is today's
    figure — the same reason every other balance here is rebuilt rather than
    read. A cancelled settlement gave its credit back, so it does not count.
    """
    cutoff = day_range_end(as_of)
    issued = SupplierCredit.objects.filter(created_at__lt=cutoff).aggregate(
        total=Coalesce(Sum("amount"), Value(ZERO), output_field=MONEY)
    )["total"]
    spent = (
        SupplierPayment.objects.live()
        .filter(method=SupplierPayment.Method.SUPPLIER_CREDIT, paid_at__lt=cutoff)
        .aggregate(total=Coalesce(Sum("amount"), Value(ZERO), output_field=MONEY))
    )["total"]
    return decimal_from(issued) - decimal_from(spent)


def _supplier_balances(as_of, *, detail=True):
    """Outstanding purchase orders, aged and folded into per-supplier rows.

    Ages from the agreed due date when there is one and the order date when
    there is not — the due date is what a supplier will chase on, and falling
    back to the order date keeps an undated order visible rather than dropping
    it into a bucket it did not earn.

    Two kinds of payment are read the way the supplier's own balance
    (``Supplier.payable_balance``) reads them, so the report and the supplier
    screen cannot state two different debts:

    * **A cancelled payment never happened.** It stays in the table with its
      amount, so counting it cleared a debt the shop still owes.
    * **A payment on account** — made to the supplier, not to one order — pays
      that supplier's orders oldest first. Leaving it out stated a debt the
      shop had already settled.

    A balance the shop owes on the supplier's account with no order behind it
    (an opening balance, an adjustment — ``apps.balances``) is aged beside the
    orders from the day it applies from, and settled by the payments that name
    it exactly as an order is by its own.
    """
    cutoff = day_range_end(as_of)
    paid = (
        SupplierPayment.objects.live()
        .filter(purchase_order=OuterRef("pk"), paid_at__lt=cutoff)
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
        .order_by("supplier_id", "reference_date", "created_at", "pk")
        .values("supplier_id", "supplier__name", "reference_date", "balance")
    )
    # Oldest first within each supplier, orders and account entries together:
    # the order a payment on account settles them in. On the same day an
    # account entry — usually the opening balance — goes first; the sort is
    # stable, so orders keep the order the database gave them.
    outstanding = sorted(
        [
            *_payable_entries_at(as_of),
            *outstanding,
        ],
        key=lambda row: (row["supplier_id"], row["reference_date"]),
    )
    on_account = {
        row["supplier_id"]: decimal_from(row["total"])
        for row in SupplierPayment.objects.live()
        .filter(
            purchase_order__isnull=True,
            balance_entry__isnull=True,
            paid_at__lt=cutoff,
        )
        .exclude(method=SupplierPayment.Method.SUPPLIER_CREDIT)
        .order_by()
        .values("supplier_id")
        .annotate(total=Sum("amount"))
    }
    thresholds = {
        bucket: as_of - timedelta(days=days) for bucket, days in BUCKET_DAYS.items()
    }

    per_supplier = {}
    totals = {bucket: ZERO for bucket in BUCKETS}
    totals.update({"total": ZERO, "order_count": 0, "oldest_days": 0})

    for order in outstanding:
        balance = decimal_from(order["balance"])
        unapplied = on_account.get(order["supplier_id"], ZERO)
        if unapplied > 0:
            applied = min(unapplied, balance)
            on_account[order["supplier_id"]] = unapplied - applied
            balance -= applied
        if balance <= 0:
            continue
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


def _payable_entries_at(as_of):
    """Balances the shop owed on suppliers' accounts at the close of ``as_of``,
    in the rows ``_supplier_balances`` ages: each entry less the payments that
    named it by then."""
    from apps.balances.models import SupplierBalanceEntry

    cutoff = day_range_end(as_of)
    paid = (
        SupplierPayment.objects.live()
        .filter(balance_entry=OuterRef("pk"), paid_at__lt=cutoff)
        .order_by()
        .values("balance_entry")
        .annotate(total=Sum("amount"))
        .values("total")[:1]
    )
    rows = (
        SupplierBalanceEntry.objects.live()
        .filter(
            direction=SupplierBalanceEntry.Direction.WE_OWE_THEM,
            effective_date__lte=as_of,
        )
        .annotate(
            paid_amount=Coalesce(
                Subquery(paid, output_field=MONEY), Value(ZERO), output_field=MONEY
            ),
        )
        .annotate(balance=F("amount") - F("paid_amount"))
        .filter(balance__gt=0)
        .values("supplier_id", "supplier__name", "effective_date", "balance")
    )
    return [
        {
            "supplier_id": row["supplier_id"],
            "supplier__name": row["supplier__name"],
            "reference_date": row["effective_date"],
            "balance": row["balance"],
        }
        for row in rows
    ]


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

    # Each figure is one kind of line, as on the customer's statement, never a
    # whole column: summed whole, «إجمالي الفواتير» took in opening balances
    # and money the supplier refunded, and the paid figure took in goods sent
    # back. So opening + account entries + purchases − returns − paid =
    # closing, and every term says what it is.
    by_kind = {}
    for entry in entries:
        kind = by_kind.setdefault(entry["kind"], {"credit": ZERO, "debit": ZERO})
        kind["credit"] += entry["credit"]
        kind["debit"] += entry["debit"]

    def kind_total(kinds, side):
        return sum((by_kind.get(kind, {}).get(side, ZERO) for kind in kinds), ZERO)

    account_entries = kind_total(_ACCOUNT_ENTRY_KINDS, "credit") - kind_total(
        _ACCOUNT_ENTRY_KINDS, "debit"
    )
    invoiced = kind_total(("purchase",), "credit")
    returned = kind_total(("supplier_credit", SupplierPayment.Method.REFUND), "debit")
    paid = sum(
        (
            totals["debit"]
            for kind, totals in by_kind.items()
            if kind in _CASH_PAYMENT_KINDS
        ),
        ZERO,
    )
    column_credit = sum((entry["credit"] for entry in entries), ZERO)
    column_debit = sum((entry["debit"] for entry in entries), ZERO)

    figures = {
        "supplier_name": supplier.name,
        "opening_balance": money(opening),
        "account_entries_total": money(account_entries),
        "invoiced_total": money(invoiced),
        "returned_total": money(returned),
        "paid_to_supplier_total": money(paid),
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
            *(
                [
                    _statement_entries_section(
                        rows,
                        context,
                        columns=[
                            Column("date", ColumnType.DATE),
                            Column("document"),
                            Column("kind", ColumnType.CHOICE),
                            Column("credit", ColumnType.MONEY, total=True),
                            Column("debit", ColumnType.MONEY, total=True),
                            Column("balance", ColumnType.MONEY),
                        ],
                        totals={
                            "credit": money(column_credit),
                            "debit": money(column_debit),
                        },
                    )
                ]
                if context.wants_detail()
                else []
            ),
        ],
        "notes": [
            # The running balance is a column of the entries, so the sentence
            # about it goes where they go.
            note("statement_running_balance") if context.wants_detail() else None,
            note("supplier_credit_is_owed"),
        ],
    }


def _statement_entries_section(rows, context, *, columns, totals):
    """The statement's lines, oldest first, each with the balance after it."""
    bounded = bounded_rows(rows, limit=context.row_limit("statement_entries"))
    return report_section(
        "statement_entries",
        columns,
        bounded.rows,
        total_count=bounded.total_count,
        limit=bounded.limit,
        totals=totals,
    )


def _statement_payments(supplier):
    """The money paid to a supplier. Supplier credit spent on an order is left
    out: the statement already credits the shop with that credit on the day
    the supplier came to owe it (a return settled as credit, a balance entry),
    so counting it again when it was spent would count it twice."""
    return (
        SupplierPayment.objects.live()
        .filter(supplier=supplier)
        .exclude(method=SupplierPayment.Method.SUPPLIER_CREDIT)
    )


def _supplier_balance_at(supplier, when):
    """What the shop owed this supplier at the close of ``when`` — negative
    when the supplier owed the shop."""
    from apps.balances.models import SupplierBalanceEntry

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
    owed_on_account = (
        SupplierBalanceEntry.objects.live()
        .filter(
            supplier=supplier,
            direction=SupplierBalanceEntry.Direction.WE_OWE_THEM,
            effective_date__lte=when,
        )
        .aggregate(total=Coalesce(Sum("amount"), Value(ZERO), output_field=MONEY))
    )["total"]
    paid = (
        _statement_payments(supplier)
        .filter(paid_at__lt=cutoff)
        .aggregate(total=Coalesce(Sum("amount"), Value(ZERO), output_field=MONEY))
    )["total"]
    credited = (
        SupplierCredit.objects.filter(supplier=supplier, created_at__lt=cutoff)
        .aggregate(total=Coalesce(Sum("amount"), Value(ZERO), output_field=MONEY))
    )["total"]
    return (
        decimal_from(billed)
        + decimal_from(owed_on_account)
        - decimal_from(paid)
        - decimal_from(credited)
    )


def _supplier_entries(supplier, period):
    from apps.balances.models import BalanceEntry, SupplierBalanceEntry

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

    # What the shop owes, or is owed, on the account itself: opening balances
    # and adjustments, on the day each applies from.
    account_entries = in_period(
        SupplierBalanceEntry.objects.live().filter(supplier=supplier), period
    ).values("number", "effective_date", "amount", "direction", "kind")
    for entry in account_entries:
        amount = decimal_from(entry["amount"])
        owed_by_shop = entry["direction"] == BalanceEntry.Direction.WE_OWE_THEM
        entries.append(
            {
                "date": entry["effective_date"],
                "document": entry["number"],
                "kind": statement_kind(entry["kind"]),
                "credit": amount if owed_by_shop else ZERO,
                "debit": ZERO if owed_by_shop else amount,
            }
        )

    # Credit a purchase return earned the shop, on the day it was issued. (A
    # balance entry's credit note is the entry above, so it is not repeated.)
    returns_credited = in_window(
        SupplierCredit.objects.filter(supplier=supplier, balance_entry__isnull=True),
        period,
    ).values("purchase_order__order_number", "created_at", "amount")
    for credit in returns_credited:
        entries.append(
            {
                "date": credit["created_at"].date(),
                "document": credit["purchase_order__order_number"] or "",
                "kind": "supplier_credit",
                "credit": ZERO,
                "debit": decimal_from(credit["amount"]),
            }
        )

    payments = in_period(_statement_payments(supplier), period).values(
        "purchase_order__order_number",
        "balance_entry__number",
        "paid_at",
        "amount",
        "method",
    )
    for payment in payments:
        entries.append(
            {
                "date": payment["paid_at"].date(),
                "document": (
                    payment["purchase_order__order_number"]
                    or payment["balance_entry__number"]
                    or ""
                ),
                "kind": payment["method"],
                "credit": ZERO,
                "debit": decimal_from(payment["amount"]),
            }
        )

    entries.sort(key=_statement_order)
    return entries


# The lines written straight onto the supplier's account rather than bought or
# paid (``apps.balances.common.statement_kind``).
_ACCOUNT_ENTRY_KINDS = ("opening_balance", "balance_adjustment", "balance_refund")
#: Payment lines that are money leaving for the supplier.
_CASH_PAYMENT_KINDS = tuple(
    method
    for method in SupplierPayment.Method.values
    if method not in NON_CASH_METHODS
)
#: Same-day order: the opening balance and the other entries written onto the
#: account first, then the purchase, then what was sent back against it, then
#: the money that paid it. Alphabetical, "cash" paid an order before it was
#: bought and the running balance dipped below zero in the middle of the day.
_SAME_DAY_ORDER = {
    "opening_balance": 0,
    "balance_adjustment": 1,
    "balance_refund": 2,
    "purchase": 3,
    "supplier_credit": 4,
    SupplierPayment.Method.REFUND: 5,
}


def _statement_order(entry):
    """Date order, and on one day the order the lines were written in."""
    return (
        entry["date"],
        _SAME_DAY_ORDER.get(entry["kind"], 6),
        entry["kind"],
        entry["document"],
    )


__all__ = [
    "payables_aging",
    "payables_total",
    "purchasing_summary",
    "supplier_credits_total",
    "supplier_statement",
]
