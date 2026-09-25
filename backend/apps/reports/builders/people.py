"""What the staff cost, and what was paid to whom."""

from decimal import Decimal

from apps.balances.employees import balances_as_of_by_employee
from apps.employees.models import Employee, PayrollLine
from apps.employees.reporting import (
    payroll_cost,
    payroll_paid,
    payroll_pending,
    payroll_runs_for_period,
)

from ..sections import (
    Column,
    ColumnType,
    bounded_queryset,
    money,
    note,
    report_section,
)
from .scope import money_sum

ZERO = Decimal("0.00")


def payroll_summary(context):
    start, end = context.period.start_date, context.period.end_date
    runs = payroll_runs_for_period(start, end)

    limit = context.row_limit("payroll_runs")
    bounded_runs = bounded_queryset(runs.order_by("-period_end", "-id"), limit=limit)
    run_rows = [
        {
            "run_number": run.run_number,
            "status": run.status,
            "period_start": run.period_start.isoformat(),
            "period_end": run.period_end.isoformat(),
            "payment_date": run.payment_date.isoformat() if run.payment_date else "",
            "gross_total": money(run.gross_total),
            "deductions_total": money(run.deductions_total),
            "net_total": money(run.net_total),
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
    bounded_employees = bounded_queryset(
        employee_values, limit=context.row_limit("employee_totals")
    )
    employee_rows = [
        {
            "employee_name": row["employee__full_name"],
            "gross_total": money(row["gross_total"]),
            "additions_total": money(row["additions_total"]),
            "deductions_total": money(row["deductions_total"]),
            "net_total": money(row["net_total"]),
        }
        for row in bounded_employees.rows
    ]

    # ``salary_expense`` is the period's labour cost and ``paid_total`` is the
    # cash that left inside it. They are different questions, they used to be
    # reported as the same one under two names, and the definitions now live in
    # apps.employees.reporting so this report and the profit report cannot
    # disagree about either.
    # What is on the staff's accounts at the period's close (``apps.balances``)
    # — owed to the shop, and owed by it — each side on its own: the next run
    # deducts the one and pays the other, so a net figure would hide both.
    balances = balances_as_of_by_employee(end)
    owed_by_staff = sum((row[0] for row in balances.values()), ZERO)
    owed_to_staff = sum((row[1] for row in balances.values()), ZERO)
    figures = {
        "salary_expense": money(payroll_cost(start, end)),
        "paid_total": money(payroll_paid(start, end)),
        "pending_total": money(payroll_pending(start, end)),
        "payroll_run_count": runs.count(),
        "active_employee_count": Employee.objects.filter(
            status=Employee.Status.ACTIVE
        ).count(),
        "staff_owe_total": money(owed_by_staff),
        "owed_to_staff_total": money(owed_to_staff),
    }
    names = dict(
        Employee.objects.filter(pk__in=balances.keys()).values_list(
            "pk", "full_name"
        )
    )
    balance_rows = sorted(
        (
            {
                "employee_name": names.get(employee_id, ""),
                "owed_by_employee": money(owed_by),
                "owed_to_employee": money(owed_to),
            }
            for employee_id, (owed_by, owed_to) in balances.items()
        ),
        key=lambda row: row["employee_name"],
    )
    balance_limit = context.row_limit("employee_account_balances")
    return {
        "summary": figures,
        "sections": [
            context.metrics(figures),
            report_section(
                "payroll_runs",
                [
                    Column("run_number"),
                    Column("status", ColumnType.CHOICE),
                    Column("period_start", ColumnType.DATE),
                    Column("period_end", ColumnType.DATE),
                    Column("payment_date", ColumnType.DATE),
                    Column("gross_total", ColumnType.MONEY, total=True),
                    Column("deductions_total", ColumnType.MONEY, total=True),
                    Column("net_total", ColumnType.MONEY, total=True),
                ],
                run_rows,
                total_count=bounded_runs.total_count,
                limit=bounded_runs.limit,
            ),
            report_section(
                "employee_totals",
                [
                    Column("employee_name"),
                    Column("gross_total", ColumnType.MONEY, total=True),
                    Column("additions_total", ColumnType.MONEY, total=True),
                    Column("deductions_total", ColumnType.MONEY, total=True),
                    Column("net_total", ColumnType.MONEY, total=True),
                ],
                employee_rows,
                total_count=bounded_employees.total_count,
                limit=bounded_employees.limit,
            ),
            report_section(
                "employee_account_balances",
                [
                    Column("employee_name"),
                    Column("owed_by_employee", ColumnType.MONEY, total=True),
                    Column("owed_to_employee", ColumnType.MONEY, total=True),
                ],
                balance_rows[:balance_limit],
                total_count=len(balance_rows),
                limit=balance_limit,
            ),
        ],
        "notes": [
            note("payroll_cost_vs_paid"),
            note("payroll_period_overlap"),
            *([note("payroll_account_balances")] if balances else []),
        ],
    }


__all__ = ["payroll_summary"]
