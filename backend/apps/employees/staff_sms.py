"""What an employee hears by SMS: their salary was paid, and what it came to."""

from __future__ import annotations

from apps.messaging.automation import send_automatic
from apps.messaging.shop_values import money, shop_name


def _period(payroll_run) -> str:
    start, end = payroll_run.period_start, payroll_run.period_end
    if (start.year, start.month) == (end.year, end.month):
        return f"{end:%Y/%m}"
    return f"{start:%Y/%m/%d} - {end:%Y/%m/%d}"


def notify_payroll_paid(payroll_run) -> None:
    """Each employee with a phone and something paid hears their net pay, when
    the shop has that on."""
    period = _period(payroll_run)
    name = shop_name()
    for line in payroll_run.lines.select_related("employee"):
        phone = (getattr(line.employee, "phone", "") or "").strip()
        if not phone or line.net_amount <= 0:
            continue
        send_automatic(
            "payroll_paid",
            name,
            period,
            money(line.net_amount),
            to=phone,
            dedup_key=f"payroll_paid:{line.pk}",
            source_type="payroll_line",
            source_id=line.pk,
        )
