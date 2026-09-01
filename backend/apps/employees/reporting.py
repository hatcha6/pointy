"""One definition each for "what labour cost" and "what wages were paid".

Two reports used to state the shop's staff cost for the same month and give two
different numbers. The payroll summary counted every run that had been approved
or paid; the profit report counted only the runs actually paid out. Both are
defensible figures and neither page said which one it was, so an owner holding
both saw two labour costs and no way to reconcile them.

They are different questions and both are worth answering:

* **Cost** is what the period's work was worth — every non-void run whose own
  pay period overlaps the report period, whether or not the money has left yet.
  This is the figure that belongs in a profit statement, next to the sales the
  labour produced.

* **Paid** is what actually left the shop inside the report period, dated by
  ``payment_date`` — the figure that belongs in a cash statement.

Naming them apart is the point. A report may now show both, but it can no
longer show one and call it the other.
"""

from decimal import Decimal

from django.db.models import DecimalField, Sum, Value
from django.db.models.functions import Coalesce

from apps.core.money_dates import money_period

from .models import PayrollRun

MONEY_FIELD = DecimalField(max_digits=12, decimal_places=2)
MONEY_PLACES = Decimal("0.01")
ZERO = Decimal("0.00")

# A void run is not a cost and not a payment; a draft is neither yet.
RECOGNISED_STATUSES = (PayrollRun.Status.APPROVED, PayrollRun.Status.PAID)


def payroll_runs_for_period(start, end):
    """Runs whose own pay period overlaps ``start``..``end``.

    Overlap rather than containment: a fortnightly run straddling the month end
    is part of both months' labour, and dropping it from both is how a month
    ends up with three weeks of wages against four weeks of sales.
    """
    return PayrollRun.objects.exclude(status=PayrollRun.Status.VOID).filter(
        period_end__gte=start, period_start__lte=end
    )


def payroll_cost(start, end) -> Decimal:
    """What the period's labour cost, paid or not."""
    total = (
        payroll_runs_for_period(start, end)
        .filter(status__in=RECOGNISED_STATUSES)
        .aggregate(total=_sum("net_total"))["total"]
    )
    return (total or ZERO).quantize(MONEY_PLACES)


def payroll_paid(start, end) -> Decimal:
    """What actually left the shop as wages inside the period."""
    total = money_period(
        PayrollRun.objects.filter(status=PayrollRun.Status.PAID), start, end
    ).aggregate(total=_sum("net_total"))["total"]
    return (total or ZERO).quantize(MONEY_PLACES)


def payroll_pending(start, end) -> Decimal:
    """Approved but not yet paid — the wage bill still to be settled."""
    total = (
        payroll_runs_for_period(start, end)
        .filter(status=PayrollRun.Status.APPROVED)
        .aggregate(total=_sum("net_total"))["total"]
    )
    return (total or ZERO).quantize(MONEY_PLACES)


def _sum(field):
    return Coalesce(Sum(field), Value(ZERO), output_field=MONEY_FIELD)


__all__ = [
    "RECOGNISED_STATUSES",
    "payroll_cost",
    "payroll_paid",
    "payroll_pending",
    "payroll_runs_for_period",
]
