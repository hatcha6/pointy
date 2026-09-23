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

Two more figures live here for the balance sheet, which asks the staff side the
question a position asks rather than a period: on a given evening, what did the
staff owe the shop (loans still being repaid), and what did the shop owe the
staff (wages approved and not yet handed over)?
"""

from decimal import Decimal

from django.db.models import DecimalField, Q, Sum, Value
from django.db.models.functions import Coalesce

from apps.core.money_dates import day_range_end, money_period

from .models import EmployeeLoan, EmployeeLoanPayment, PayrollAdjustment, PayrollRun

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


#: Loans whose money was handed over. A requested loan never was, and a rejected
#: or cancelled one never will be.
LENT_STATUSES = (EmployeeLoan.Status.APPROVED, EmployeeLoan.Status.PAID)


def loans_outstanding(as_of) -> Decimal:
    """What staff owed the shop in loans at the close of ``as_of``.

    Rebuilt from what was lent by then less the instalments collected by then,
    rather than read off ``outstanding_balance``: that column is today's figure,
    and a balance sheet for 30 June would state it with July's repayments
    already taken off.
    """
    cutoff = day_range_end(as_of)
    lent = EmployeeLoan.objects.filter(
        status__in=LENT_STATUSES, reviewed_at__lt=cutoff
    ).aggregate(total=_sum("amount"))["total"]
    repaid = EmployeeLoanPayment.objects.filter(
        loan__status__in=LENT_STATUSES,
        loan__reviewed_at__lt=cutoff,
        paid_at__lt=cutoff,
    ).aggregate(total=_sum("amount"))["total"]
    return ((lent or ZERO) - (repaid or ZERO)).quantize(MONEY_PLACES)


def wages_payable(as_of) -> Decimal:
    """Wages the shop owed its staff at the close of ``as_of``.

    A run is owed from the moment it is approved — a draft is still a proposal
    — until its ``payment_date``, the same money date the money position takes
    the cash out on, so the two cannot disagree about which side of a date a
    wage run sits. A void run was never owed.

    **Gross of the loan instalments it withholds.** An instalment is collected
    when the run is paid — that is when the loan's balance falls — so until then
    the shop owes the whole wage and is owed the whole loan. Counting the run
    net of the instalment while ``loans_outstanding`` still held the loan in
    full would knock the instalment off the shop's worth on the day the wages
    went out, for a payment that changed nothing it owned.
    """
    cutoff = day_range_end(as_of)
    owed = (
        PayrollRun.objects.exclude(status=PayrollRun.Status.VOID)
        .filter(approved_at__lt=cutoff)
        .filter(Q(payment_date__isnull=True) | Q(payment_date__gt=as_of))
    )
    net = owed.aggregate(total=_sum("net_total"))["total"]
    withheld = PayrollAdjustment.objects.filter(
        payroll_line__payroll_run__in=owed,
        loan__isnull=False,
        direction=PayrollAdjustment.Direction.DEDUCTION,
    ).aggregate(total=_sum("amount"))["total"]
    return ((net or ZERO) + (withheld or ZERO)).quantize(MONEY_PLACES)


def _sum(field):
    return Coalesce(Sum(field), Value(ZERO), output_field=MONEY_FIELD)


__all__ = [
    "LENT_STATUSES",
    "RECOGNISED_STATUSES",
    "loans_outstanding",
    "payroll_cost",
    "payroll_paid",
    "payroll_pending",
    "payroll_runs_for_period",
    "wages_payable",
]
