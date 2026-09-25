"""Where the money went, and whether it is still there.

Three reports that answer one owner's question in three resolutions: how it was
tendered (payment methods), what each shift's drawer did (register closure), and
what the shop should be holding across every box and bank account right now
(cash position).
"""

from decimal import Decimal

from django.db.models import Count

from apps.sales.models import RegisterSession, prime_register_session_cash_totals
from apps.treasury.position import treasury_statement

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
from .scope import daily_totals, in_period, money_sum, payments, register_sessions


def payment_methods(context):
    # What customers paid with — so not a salary deduction, which is a staff
    # purchase settled out of wages and put no money anywhere.
    period_payments = in_period(payments(context.user).money_received(), context.period)
    limit = context.row_limit("payment_methods")
    method_rows = bounded_queryset(
        period_payments.values("method")
        .annotate(
            total=money_sum("amount"),
            commission=money_sum("commission_amount"),
            count=Count("id"),
        )
        .order_by("-total", "method"),
        limit=limit,
    )
    rows = [
        {
            "method": row["method"],
            "total": money(row["total"]),
            "commission": money(row["commission"]),
            "net_banked": money(
                decimal_from(row["total"]) - decimal_from(row["commission"])
            ),
            "count": row["count"],
        }
        for row in method_rows.rows
    ]
    total = sum((decimal_from(row["total"]) for row in rows), Decimal("0.00"))
    commission = sum((decimal_from(row["commission"]) for row in rows), Decimal("0.00"))
    payment_count = period_payments.count()

    figures = {
        "payment_total": money(total),
        "commission_total": money(commission),
        "net_banked_total": money(total - commission),
        "commission_rate_percent": percent(commission, total),
        "payment_count": payment_count,
    }
    sections = [
        context.metrics(figures),
        report_section(
            "payment_methods",
            [
                Column("method", ColumnType.CHOICE),
                Column("count", ColumnType.COUNT, total=True),
                Column("total", ColumnType.MONEY, total=True),
                Column("commission", ColumnType.MONEY, total=True),
                Column("net_banked", ColumnType.MONEY, total=True),
            ],
            rows,
            total_count=method_rows.total_count,
            limit=method_rows.limit,
        ),
    ]
    if context.period.wants_daily_breakdown:
        sections.append(_daily_payments_section(period_payments, context))
    return {
        "summary": figures,
        "sections": sections,
        "notes": [note("payments_are_cash_received"), note("refunds_net_in_payments")],
    }


def _daily_payments_section(period_payments, context):
    by_day = daily_totals(
        period_payments,
        context.period,
        total=money_sum("amount"),
        commission=money_sum("commission_amount"),
        count=Count("id"),
    )
    rows = [
        {
            "date": day.isoformat(),
            "count": values["count"],
            "total": money(values["total"]),
            "commission": money(values["commission"]),
        }
        for day, values in sorted(by_day.items())
    ]
    return report_section(
        "daily_payments",
        [
            Column("date", ColumnType.DATE),
            Column("count", ColumnType.COUNT, total=True),
            Column("total", ColumnType.MONEY, total=True),
            Column("commission", ColumnType.MONEY, total=True),
        ],
        rows,
    )


def register_closure(context):
    sessions = in_period(register_sessions(context.user), context.period)
    session_count = sessions.count()
    open_count = sessions.filter(status=RegisterSession.Status.OPEN).count()
    closed_sessions = sessions.filter(status=RegisterSession.Status.CLOSED)
    closed_count = closed_sessions.count()

    limit = context.row_limit("register_sessions")
    session_rows = bounded_queryset(
        sessions.order_by("-opened_at").select_related("owner"), limit=limit
    )
    # The drawer arithmetic lives on RegisterSession and nowhere else; priming
    # only batches the *fetching*, so a report row and the register screen can
    # never state a different expected cash.
    prime_register_session_cash_totals(session_rows.rows)
    rows = [_session_row(session) for session in session_rows.rows]

    variance_total, short_count, over_count = _variance_figures(closed_sessions)
    figures = {
        "session_count": session_count,
        "open_count": open_count,
        "closed_count": closed_count,
        "variance_total": money(variance_total),
        "short_session_count": short_count,
        "over_session_count": over_count,
    }
    return {
        "summary": figures,
        "sections": [
            context.metrics(figures),
            report_section(
                "register_sessions",
                [
                    Column("session_number"),
                    Column("staff_name"),
                    Column("status", ColumnType.CHOICE),
                    Column("opening_cash", ColumnType.MONEY, total=True),
                    Column("closing_cash", ColumnType.MONEY, total=True),
                    Column("expected_cash", ColumnType.MONEY, total=True),
                    Column("cash_variance", ColumnType.MONEY, total=True),
                    Column("pay_in_total", ColumnType.MONEY, total=True),
                    Column("pay_out_total", ColumnType.MONEY, total=True),
                    Column("opened_at", ColumnType.DATETIME),
                    Column("closed_at", ColumnType.DATETIME),
                ],
                rows,
                total_count=session_rows.total_count,
                limit=session_rows.limit,
                totals={"cash_variance": money(variance_total)},
            ),
        ],
        "notes": [note("variance_closed_sessions_only"), note("open_session_no_variance")],
    }


def _session_row(session):
    return {
        "session_number": session.session_number,
        "staff_name": session.owner.username if session.owner_id else "",
        "status": session.status,
        "opened_at": session.opened_at.isoformat(),
        "closed_at": session.closed_at.isoformat() if session.closed_at else "",
        "opening_cash": money(session.opening_cash),
        "closing_cash": money(session.closing_cash),
        "expected_cash": money(session.expected_cash),
        "cash_variance": money(session.cash_variance),
        "pay_in_total": money(session.pay_in_total),
        "pay_out_total": money(session.pay_out_total),
    }


def _variance_figures(closed_sessions):
    """Total drift, and how it splits between short and over.

    A net variance of zero can be one till 200 short and another 200 over — two
    problems, not none. The split is the figure that says which.
    """
    primed = prime_register_session_cash_totals(
        closed_sessions.only("id", "opening_cash", "closing_cash")
    )
    total = Decimal("0.00")
    short = over = 0
    for session in primed:
        variance = decimal_from(session.cash_variance)
        total += variance
        if variance < 0:
            short += 1
        elif variance > 0:
            over += 1
    return total, short, over


def cash_position(context):
    """What the shop should be holding, and how it got there.

    The treasury has derived these balances since it was built; nothing could
    print them, so the one figure a close cannot be filed without — the cash and
    bank position at the period end — was visible on screen and unavailable on
    paper. Stated as opening + movements = closing so the statement foots.
    """
    statement = treasury_statement(
        start=context.period.start_date, end=context.period.end_date
    )
    totals = statement["totals"]

    account_rows = [
        {
            "account_name": row["account"].name,
            "kind": row["account"].kind,
            "opening_balance": money(row["opening_balance"]),
            "movement_total": money(row["movement_total"]),
            "closing_balance": money(row["closing_balance"]),
            "last_counted_at": (
                row["last_count"].counted_at.isoformat() if row["last_count"] else ""
            ),
            "counted_variance": (
                money(row["counted_variance"])
                if row["counted_variance"] is not None
                else ""
            ),
        }
        for row in statement["accounts"]
    ]
    movement_rows = [
        {
            "account_name": row["account"].name,
            "component": part["code"],
            "direction": part["direction"],
            "amount": money(part["amount"]),
        }
        for row in statement["accounts"]
        for part in row["components"]
    ]

    figures = {
        "opening_total": money(totals["opening_total"]),
        "movement_total": money(totals["movement_total"]),
        "closing_total": money(totals["closing_total"]),
        "counted_variance_total": money(totals["counted_variance_total"]),
        "accounts_counted": totals["accounts_counted"],
        "accounts_total": totals["accounts_total"],
    }
    return {
        "summary": figures,
        "sections": [
            context.metrics(figures),
            report_section(
                "account_balances",
                [
                    Column("account_name"),
                    Column("kind", ColumnType.CHOICE),
                    Column("opening_balance", ColumnType.MONEY, total=True),
                    Column("movement_total", ColumnType.MONEY, total=True),
                    Column("closing_balance", ColumnType.MONEY, total=True),
                    Column("last_counted_at", ColumnType.DATETIME),
                    Column("counted_variance", ColumnType.MONEY),
                ],
                account_rows,
            ),
            report_section(
                "cash_movements",
                [
                    Column("account_name"),
                    Column("component", ColumnType.LABEL),
                    Column("direction", ColumnType.CHOICE),
                    Column("amount", ColumnType.MONEY, total=True),
                ],
                movement_rows,
            ),
        ],
        "notes": [
            note("balances_are_derived"),
            note("payroll_assumed_cash"),
            note("commission_assumed_bank"),
        ],
    }


def cash_position_figures(context):
    statement = treasury_statement(
        start=context.period.start_date, end=context.period.end_date
    )
    return statement["totals"]


__all__ = [
    "cash_position",
    "cash_position_figures",
    "payment_methods",
    "register_closure",
]
