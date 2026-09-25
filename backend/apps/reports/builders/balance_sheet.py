"""الميزانية العمومية — what the shop owns and owes, at both ends of a period.

The report a shop arriving from its old system asks for by name. Its owner reads
it as two lists — لنا, what is ours, and علينا, what we owe — and one number
under them, الصافي. It is kept in that shape rather than an accountant's
classified statement: it is the page the owner already checks every year, and
it is the honest shape for a system that derives its balances instead of
posting them, with no fixed-asset register, accruals or equity accounts to
classify.

**Stated twice.** At the close of the day before the period (أول المدة) and at
the close of its last day (آخر المدة), because comparing the two is how a shop
without double-entry books has always found its year's result: the growth in
what it is worth once the money its owner put in or took out is set aside. That
bridge is printed, so the difference between the two columns is explained
rather than left for the reader to guess at.

**Nothing is re-derived here.** Every line is the definition some other module
owns, read as of a date: the stock ledger's cost, the money position, the
receivables and payables aging, the payroll and loan figures, the consignment
obligations. So the balance sheet cannot disagree with the report behind any
one of its lines.

**Zakat** is reckoned at the period's end on the one basis that differs: goods
at their selling price rather than their cost, which is how trade goods are
valued for it. It is an aid to the owner's own reckoning, not a ruling — whether
the wealth reached the nisab and was held for a year is theirs to judge, and the
page says so.
"""

from datetime import timedelta
from decimal import Decimal

from apps.employees.reporting import loans_outstanding, wages_payable
from apps.inventory.reporting import stock_cost_value, stock_retail_value
from apps.treasury.position import outside_money_totals, treasury_position

from ..sections import Column, ColumnType, decimal_from, money, note, report_section
from .purchasing import payables_total, supplier_credits_total
from .receivables import customer_credits_total, receivables_total

ZERO = Decimal("0.00")
#: A quarter of a tenth, on trade goods and money held for a lunar year.
ZAKAT_RATE = Decimal("0.025")

#: لنا, in the order the owner reads them.
ASSET_LINES = (
    "stock_at_cost",
    "cash_and_bank",
    "customer_receivables",
    "employee_loans",
    "provider_float",
    "supplier_credits",
    "consignor_advances",
)
#: علينا.
LIABILITY_LINES = (
    "supplier_payables",
    "employee_payables",
    "consignor_payables",
    # Credit written onto customers' accounts — money the shop owes them and
    # has not yet spent against anything they owe (``apps.balances``). Its own
    # line rather than netted into the receivables, the way an advance is
    # stated beside the debts rather than subtracted from them.
    "customer_credits",
)
#: The statement every shop gets. The other lines print only for a shop that has
#: something on them, so a grocer's page does not carry three rows of zeros
#: about consignments and provider floats.
ALWAYS_SHOWN = frozenset(
    {
        "stock_at_cost",
        "stock_at_selling_price",
        "cash_and_bank",
        "customer_receivables",
        "employee_loans",
        "supplier_payables",
        "employee_payables",
    }
)


def balance_sheet(context):
    period = context.period
    opening_date = period.start_date - timedelta(days=1)
    closing_date = period.end_date
    # A period that ends today is stated from the live stock bins, exactly as
    # the stock report states it; a past one from the ledger's history.
    live = not context.is_historical()

    opening = _position(context, opening_date)
    closing = _position(context, closing_date, live=live)
    opening_assets, opening_liabilities = _totals(opening)
    closing_assets, closing_liabilities = _totals(closing)
    opening_net = opening_assets - opening_liabilities
    closing_net = closing_assets - closing_liabilities

    outside = outside_money_totals(start=period.start_date, end=period.end_date)
    # An opening balance recorded during the period is the position the shop
    # was already in, brought onto the books — not something it earned. Left
    # in, the day a shop types its paper ledger in would read as the year's
    # profit.
    openings = opening_balances_recorded(start=period.start_date, end=period.end_date)
    period_result = (
        closing_net
        - opening_net
        - outside["added"]
        + outside["withdrawn"]
        - openings
    )
    zakat = _zakat(closing, closing_liabilities, closing_date, live=live)

    figures = {
        "net_position": money(closing_net),
        "total_assets": money(closing_assets),
        "total_liabilities": money(closing_liabilities),
        "zakat_due": money(zakat["due"]),
        "opening_net_position": money(opening_net),
        "net_position_change": money(closing_net - opening_net),
        "period_result": money(period_result),
        "zakat_base": money(zakat["base"]),
    }
    return {
        "summary": figures,
        "sections": [
            context.metrics(figures),
            _statement_section("balance_assets", ASSET_LINES, opening, closing),
            _statement_section(
                "balance_liabilities", LIABILITY_LINES, opening, closing
            ),
            _comparison_section(
                "balance_net",
                [
                    ("total_assets", opening_assets, closing_assets),
                    ("total_liabilities", opening_liabilities, closing_liabilities),
                    ("net_position", opening_net, closing_net),
                ],
            ),
            _amount_section(
                "net_position_movement",
                [
                    ("opening_net_position", opening_net),
                    ("outside_money_added", outside["added"]),
                    ("outside_money_withdrawn", -outside["withdrawn"]),
                    *(
                        [("opening_balances_recorded", openings)]
                        if openings
                        else []
                    ),
                    ("period_result", period_result),
                    ("closing_net_position", closing_net),
                ],
            ),
            _amount_section("zakat", zakat["rows"]),
        ],
        "notes": [
            note("balance_positions", opening=opening_date, closing=closing_date),
            note("balance_stock_at_cost"),
            note("balance_net_is_equity"),
            note("period_result_basis"),
            note("balances_are_derived"),
            note("zakat_basis"),
            None if live else note("zakat_prices_today", date=closing_date),
            note("zakat_conditions"),
        ],
    }


def _position(context, as_of, *, live=False):
    """Every line of the statement at the close of ``as_of``."""
    money_position = treasury_position(as_of=as_of)
    totals = money_position["totals"]
    obligations = money_position["obligations"]
    day = context.at(as_of)
    return {
        "stock_at_cost": stock_cost_value(as_of=None if live else as_of),
        "cash_and_bank": totals["total"],
        "customer_receivables": decimal_from(receivables_total(day)["total"]),
        "employee_loans": loans_outstanding(as_of),
        # The shop's money sitting with a resale provider. Kept off
        # ``cash_and_bank`` exactly as the money position keeps it off its
        # total — it cannot pay a wage — but it is the shop's all the same.
        "provider_float": totals["provider_float"],
        "supplier_credits": supplier_credits_total(as_of),
        "consignor_advances": obligations["consignor_receivable"],
        "supplier_payables": decimal_from(payables_total(day)["total"]),
        "employee_payables": wages_payable(as_of),
        "consignor_payables": obligations["consignor_payable"],
        "customer_credits": customer_credits_total(as_of),
    }


def opening_balances_recorded(*, start, end):
    """What the opening balances dated inside ``start``..``end`` added to the
    shop's net position.

    A customer who owes the shop, or a supplier who does, adds to it; a
    customer or a supplier the shop owes takes from it. Only *opening*
    balances: an adjustment is a real change in what the shop is owed or owes
    — a service nobody invoiced, a compensation — and belongs in the result.
    """
    from apps.balances.models import (
        BalanceEntry,
        CustomerBalanceEntry,
        SupplierBalanceEntry,
    )
    from apps.core.money_dates import money_period
    from django.db.models import Sum

    total = ZERO
    for model in (CustomerBalanceEntry, SupplierBalanceEntry):
        rows = (
            money_period(
                model.objects.live().filter(kind=BalanceEntry.Kind.OPENING),
                start,
                end,
            )
            .order_by()
            .values("direction")
            .annotate(amount=Sum("amount"))
        )
        for row in rows:
            amount = decimal_from(row["amount"])
            if row["direction"] == BalanceEntry.Direction.THEY_OWE_US:
                total += amount
            else:
                total -= amount
    return total


def _totals(position):
    assets = sum((position[line] for line in ASSET_LINES), ZERO)
    liabilities = sum((position[line] for line in LIABILITY_LINES), ZERO)
    return assets, liabilities


def _zakat(closing, liabilities, closing_date, *, live):
    """The zakat reckoning at the period's end.

    The same lines as the statement's closing column, with the one change
    zakat makes: goods at what they would sell for, not what they cost. What
    the shop owes comes off before the rate is applied, and nothing is due on
    a base that is not positive.
    """
    goods = stock_retail_value(as_of=None if live else closing_date)
    lines = [("stock_at_selling_price", goods)] + [
        (line, closing[line]) for line in ASSET_LINES if line != "stock_at_cost"
    ]
    assets = sum((amount for _line, amount in lines), ZERO)
    base = assets - liabilities
    due = base * ZAKAT_RATE if base > 0 else ZERO
    rows = [
        (line, amount)
        for line, amount in lines
        if line in ALWAYS_SHOWN or amount
    ]
    rows.extend(
        [
            ("zakat_assets_total", assets),
            ("zakat_liabilities", -liabilities),
            ("zakat_base", base),
            ("zakat_due", due),
        ]
    )
    return {"base": base, "due": due, "rows": rows}


def _statement_section(key, lines, opening, closing):
    """One side of the statement, footed at both dates.

    The totals row is the side's total — إجمالي الأصول or إجمالي الخصوم —
    summed from the rows printed above it, so the reader can add the column
    up and land on it.
    """
    rows = [
        _pair_row(line, opening[line], closing[line])
        for line in lines
        if line in ALWAYS_SHOWN or opening[line] or closing[line]
    ]
    return report_section(
        key,
        [
            Column("line", ColumnType.LABEL),
            Column("opening_balance", ColumnType.MONEY, total=True),
            Column("closing_balance", ColumnType.MONEY, total=True),
            Column("change", ColumnType.MONEY, total=True),
        ],
        rows,
    )


def _comparison_section(key, lines):
    return report_section(
        key,
        [
            Column("line", ColumnType.LABEL),
            Column("opening_balance", ColumnType.MONEY),
            Column("closing_balance", ColumnType.MONEY),
            Column("change", ColumnType.MONEY),
        ],
        [_pair_row(line, opening, closing) for line, opening, closing in lines],
    )


def _pair_row(line, opening, closing):
    return {
        "line": line,
        "opening_balance": money(opening),
        "closing_balance": money(closing),
        "change": money(closing - opening),
    }


def _amount_section(key, lines):
    """A statement read top to bottom, each line signed by what it does."""
    return report_section(
        key,
        [Column("line", ColumnType.LABEL), Column("amount", ColumnType.MONEY)],
        [{"line": line, "amount": money(amount)} for line, amount in lines],
    )


__all__ = ["ZAKAT_RATE", "balance_sheet"]
