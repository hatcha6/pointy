"""What the shop earned, what it spent, and how the two reconcile to cash.

Three defects were fixed here at once, and they were all about *stating* things
rather than computing them:

**A basis.** Revenue was recognised when the sale happened (credit invoices
included, money not yet in) while wages were counted only once paid. The result
was neither a cash result nor an accrual one, and the page named neither. Every
figure below is now on the accrual basis — earned and incurred inside the
period, collected or not — stated on the page, with the cash bridge printed
underneath so a reader who wants the cash answer can see how to get there.

**A total that foots.** The cost breakdown listed purchases in the same column
as expenses, while the stated total excluded them — correctly, since buying
stock is not an expense — so anybody adding up the column got a number that
appeared nowhere. Purchases now sit below the total, labelled for what they are.

**A reconciliation.** Revenue recognised, less the movement in what customers
owe, is the cash the shop should have taken from them. That identity is now
printed with its residual, so the two reports an owner is most likely to
compare — this one and the payments report — explain their own difference
instead of leaving the reader to assume one of them is broken.
"""

from datetime import timedelta
from decimal import Decimal

from django.db.models import Count

from apps.employees.reporting import payroll_cost
from apps.expenses.models import Expense
from apps.inventory.reporting import shrinkage_value
from apps.payments.models import Payment
from apps.purchasing.models import PurchaseOrder

from ..sections import (
    Column,
    ColumnType,
    bounded_queryset,
    decimal_from,
    money,
    note,
    percent,
    report_section,
)
from .receivables import receivables_total
from .sales import sales_summary_figures
from .scope import in_period, money_sum, payments

ZERO = Decimal("0.00")


def profit_costs(context):
    period = context.period
    start, end = period.start_date, period.end_date

    sales = sales_summary_figures(context)
    revenue = decimal_from(sales["net_sales"])
    gross_profit = decimal_from(sales["gross_profit"])

    labour = payroll_cost(start, end)
    commissions = in_period(Payment.objects.all(), period).aggregate(
        total=money_sum("commission_amount")
    )["total"]
    ad_hoc = in_period(Expense.objects.live(), period).aggregate(
        total=money_sum("amount")
    )["total"]
    # Goods that left without being sold — a stock count's write-off, a manual
    # adjustment. The valued ledger has always known what they cost; until it
    # was surfaced, theft and spoilage never reached the profit statement.
    shrinkage = shrinkage_value(start, end)

    operating_expense = (
        decimal_from(labour)
        + decimal_from(commissions)
        + decimal_from(ad_hoc)
        + decimal_from(shrinkage)
    )
    net_operating_profit = gross_profit - operating_expense

    # Stated, but never added into the expense total: buying stock converts
    # money into goods, it does not consume it. It appears because an owner
    # comparing profit to their bank balance needs to see where the cash went.
    purchase_spend = in_period(
        PurchaseOrder.objects.exclude(status=PurchaseOrder.Status.CANCELLED), period
    ).aggregate(total=money_sum("total"))["total"]

    figures = {
        "net_sales": money(revenue),
        "cost_of_sales": sales["cost_of_sales"],
        "gross_profit": money(gross_profit),
        "gross_margin_percent": percent(gross_profit, revenue),
        "payroll_cost_total": money(labour),
        "payment_commission_total": money(commissions),
        "ad_hoc_expense_total": money(ad_hoc),
        "shrinkage_total": money(shrinkage),
        "operating_expense_total": money(operating_expense),
        "net_operating_profit": money(net_operating_profit),
        "net_margin_percent": percent(net_operating_profit, revenue),
        # Stated as a figure, never as a component of the expense total above.
        # An owner comparing profit to their bank balance needs to see where
        # the cash went; the goods it bought are on the shelf, not consumed.
        "purchase_spend_total": money(purchase_spend),
    }

    return {
        "summary": figures,
        "sections": [
            context.metrics(figures),
            _profit_statement_section(figures, purchase_spend),
            _expense_category_section(context),
            _cash_bridge_section(context, revenue),
        ],
        "notes": [
            note("basis_accrual"),
            note("payroll_is_period_cost"),
            note("purchases_are_not_expense"),
            note("shrinkage_is_non_cash_stock_loss"),
        ],
    }


def _profit_statement_section(figures, purchase_spend):
    """The statement itself, in the order it is read.

    ``is_total`` marks the two lines a reader's eye stops at, and
    ``below_total`` marks the memorandum line that must never be added into
    them. The row carries the distinction rather than the client inferring it
    from the label, because a client that guesses wrong prints a schedule that
    does not foot.
    """
    rows = [
        _line("net_sales", figures["net_sales"]),
        _line("cost_of_sales", "-" + figures["cost_of_sales"]),
        _line("gross_profit", figures["gross_profit"], is_total=True),
        _line("payroll_cost_total", "-" + figures["payroll_cost_total"]),
        _line("payment_commission_total", "-" + figures["payment_commission_total"]),
        _line("ad_hoc_expense_total", "-" + figures["ad_hoc_expense_total"]),
        _line("shrinkage_total", "-" + figures["shrinkage_total"]),
        _line(
            "operating_expense_total",
            "-" + figures["operating_expense_total"],
            is_total=True,
        ),
        _line("net_operating_profit", figures["net_operating_profit"], is_total=True),
        _line("purchase_spend_total", money(purchase_spend), below_total=True),
    ]
    return report_section(
        "profit_statement",
        [
            Column("line", ColumnType.LABEL),
            Column("amount", ColumnType.MONEY),
            Column("is_total"),
            Column("below_total"),
        ],
        rows,
    )


def _line(name, amount, *, is_total=False, below_total=False):
    return {
        "line": name,
        "amount": amount,
        "is_total": is_total,
        "below_total": below_total,
    }


def _expense_category_section(context):
    rows, _total = _expenses_by_category(context)
    return report_section(
        "expense_categories",
        [
            Column("category_name"),
            Column("expense_count", ColumnType.COUNT, total=True),
            Column("amount", ColumnType.MONEY, total=True),
        ],
        rows[: context.row_limit("expense_categories")],
        total_count=len(rows),
        limit=context.row_limit("expense_categories"),
    )


def _cash_bridge_section(context, revenue):
    """Revenue recognised, less the movement in what customers owe, is the cash
    the shop should have taken. Printed with its residual so the two reports an
    owner compares most — this one and the payments report — explain their own
    difference instead of one of them looking broken.
    """
    period = context.period
    opening = _receivables_at(context, period.start_date - timedelta(days=1))
    closing = _receivables_at(context, period.end_date)
    movement = closing - opening
    period_payments = in_period(payments(context.user), period)
    received = decimal_from(
        period_payments.money_received().aggregate(total=money_sum("amount"))["total"]
    )
    # Staff purchases settled out of wages clear a receivable without any cash
    # arriving. Named on a line of their own, only when there are any, rather
    # than passed off as cash received.
    settled_from_wages = decimal_from(
        period_payments.filter(method=Payment.Method.SALARY_DEDUCTION).aggregate(
            total=money_sum("amount")
        )["total"]
    )
    # Debts settled from credit the shop already owed the customer: the
    # receivable fell and no money arrived. Named, like the wages line, rather
    # than left to surface as an unexplained difference.
    settled_from_credit = decimal_from(
        period_payments.filter(method=Payment.Method.ACCOUNT_CREDIT).aggregate(
            total=money_sum("amount")
        )["total"]
    )
    # Debts written straight onto customers' accounts (an opening balance, an
    # adjustment) raised what they owe without anything being sold.
    written_on_account = account_debts_recorded(context)
    residual = (
        revenue
        - movement
        - received
        - settled_from_wages
        - settled_from_credit
        + written_on_account
    )

    rows = [
        _line("revenue_recognised", money(revenue)),
        _line("opening_receivables", money(opening)),
        _line("closing_receivables", money(closing)),
        _line("movement_in_receivables", "-" + money(movement)),
        _line("cash_received_from_customers", money(received), is_total=True),
    ]
    if settled_from_wages:
        rows.append(_line("settled_from_wages", money(settled_from_wages)))
    if settled_from_credit:
        rows.append(_line("settled_from_account_credit", money(settled_from_credit)))
    if written_on_account:
        rows.append(_line("debts_recorded_on_account", money(written_on_account)))
    rows.append(_line("unreconciled_difference", money(residual)))
    return report_section(
        "cash_bridge",
        [
            Column("line", ColumnType.LABEL),
            Column("amount", ColumnType.MONEY),
            Column("is_total"),
            Column("below_total"),
        ],
        rows,
    )


def account_debts_recorded(context):
    """Debts written onto customers' accounts during the period — the
    receivable they added, which no revenue line accounts for."""
    from apps.balances.models import CustomerBalanceEntry

    return decimal_from(
        in_period(
            CustomerBalanceEntry.objects.live().filter(
                direction=CustomerBalanceEntry.Direction.THEY_OWE_US
            ),
            context.period,
        ).aggregate(total=money_sum("amount"))["total"]
    )


def _receivables_at(context, when):
    totals = receivables_total(context.at(when))
    return decimal_from(totals["total"])


# --------------------------------------------------------------------------
# Expenses by category
# --------------------------------------------------------------------------


def expense_breakdown(context):
    """Where the money went, by category, with the biggest first.

    The profit statement carried one line called "expenses" and an owner asked
    about a cost overrun cannot act on one line. The categories already existed
    in the data; nothing ever grouped by them.
    """
    category_rows, total = _expenses_by_category(context)
    period_expenses = in_period(Expense.objects.live(), context.period)

    limit = context.row_limit("expenses")
    detail = bounded_queryset(
        period_expenses.select_related("category", "created_by").order_by(
            "-spent_at", "-id"
        ),
        limit=limit,
    )
    detail_rows = [
        {
            "spent_at": expense.spent_at.isoformat(),
            "category_name": expense.category.name if expense.category_id else "",
            "description": expense.description,
            "payment_method": expense.payment_method,
            "amount": money(expense.amount),
            "recorded_by": (
                expense.created_by.username if expense.created_by_id else ""
            ),
        }
        for expense in detail.rows
    ]

    figures = {
        "expense_total": money(total),
        "category_count": len(category_rows),
        "expense_count": period_expenses.count(),
        "largest_category": category_rows[0]["category_name"] if category_rows else "",
    }
    sections = [
        context.metrics(figures),
        report_section(
            "expense_categories",
            [
                Column("category_name"),
                Column("expense_count", ColumnType.COUNT, total=True),
                Column("amount", ColumnType.MONEY, total=True),
                Column("share_percent", ColumnType.PERCENT),
            ],
            category_rows[: context.row_limit("expense_categories")],
            total_count=len(category_rows),
            limit=context.row_limit("expense_categories"),
            totals={"amount": money(total)},
        ),
        report_section(
            "expenses",
            [
                Column("spent_at", ColumnType.DATE),
                Column("category_name"),
                Column("description"),
                Column("payment_method", ColumnType.CHOICE),
                Column("recorded_by"),
                Column("amount", ColumnType.MONEY, total=True),
            ],
            detail_rows,
            total_count=detail.total_count,
            limit=detail.limit,
            totals={"amount": money(total)},
        ),
    ]
    return {
        "summary": figures,
        "sections": sections,
        "notes": [note("expense_dated_when_spent"), note("expense_excludes_stock")],
    }


def _expenses_by_category(context):
    values = (
        in_period(Expense.objects.live(), context.period)
        .values("category_id", "category__name")
        .annotate(amount=money_sum("amount"), expense_count=Count("id"))
        .order_by("-amount")
    )
    rows = list(values)
    total = sum((decimal_from(row["amount"]) for row in rows), ZERO)
    return [
        {
            "category_name": row["category__name"] or "",
            "expense_count": row["expense_count"],
            "amount": money(row["amount"]),
            "share_percent": percent(row["amount"], total),
        }
        for row in rows
    ], total


# --------------------------------------------------------------------------
# Month-end pack
# --------------------------------------------------------------------------


def month_end_pack(context):
    """Every statement a close needs, in one document.

    Assembled from the reports themselves rather than re-deriving their figures,
    so the pack and the individual reports can never disagree. Parts the running
    user may not see are skipped and *named* in the summary — a pack that
    silently omits the payroll section reads exactly like a pack whose payroll
    was nil.
    """
    from .. import registry

    included = []
    omitted = []
    sections = []
    figures = {}

    for key in context.definition.composed_of:
        part = registry.definition(key)
        if part is None or not part.is_allowed(context.user):
            omitted.append(key)
            continue
        payload = registry.build(key, context.for_report(key))
        included.append(key)
        figures.update(
            {
                f"{key}__{name}": value
                for name, value in payload["summary"].items()
                if name in part.headline
            }
        )
        sections.append(
            report_section(
                f"pack_{key}",
                [Column("metric"), Column("value")],
                [
                    {"metric": name, "value": value}
                    for name, value in payload["summary"].items()
                ],
            )
        )
        sections.extend(
            section
            for section in payload["sections"]
            if section["key"] != "summary"
        )

    headline = {
        "sections_included": len(included),
        "sections_omitted": len(omitted),
        **figures,
    }
    return {
        "summary": headline,
        "sections": [context.metrics(headline), *sections],
        "included_reports": included,
        "omitted_reports": omitted,
        "notes": [
            note("pack_is_assembled"),
            note("pack_omitted", reports=", ".join(omitted)) if omitted else None,
        ],
    }


__all__ = ["expense_breakdown", "month_end_pack", "profit_costs"]
