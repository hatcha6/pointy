"""Opening balances and adjustments on an employee's account — settled by payroll.

* **They owe us** — a salary advance from before the shop kept its books here,
  a shortage the employee has agreed to make good, goods they damaged. The
  next payroll run deducts it, oldest entry first, never more than the pay can
  carry and never more than the entry's own ``payroll_deduction_limit``.
* **We owe them** — wages left unpaid by the old system, a bonus promised, an
  expense they paid for the shop out of their own pocket. The next payroll run
  pays it with the wage.

Paying the run is what settles an entry, and voiding the run gives it back: the
run's ``account_balance`` rows are the settlement, so nothing is stored that a
void would have to undo. Cash can settle either side through a drawer
(:func:`settle_employee_balance`), for the employee who is leaving or the one
who would rather pay now.

How it reaches the books — the rule the reports follow:

* an **opening balance** is a position brought onto the books, not something
  this period cost; it sits on the balance sheet and is bridged out of the
  period's result, like a customer's;
* an **adjustment** is part of what the shop's labour cost on its day — the
  shop owing an employee more is a cost, an employee owing it more is a
  recovery — counted in ``apps.employees.reporting.payroll_cost``, exactly as a
  bonus or a penalty typed into a run is;
* **settling** either one — through a run or in cash — is neither: the wage
  paid out bigger or smaller by a balance is a debt changing hands, so the
  labour cost adds back what a run deducted for a balance and leaves out what
  it paid for one.
"""

from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass
from decimal import Decimal, InvalidOperation

from django.db import transaction
from django.db.models import DecimalField, OuterRef, Q, Subquery, Sum, Value
from django.db.models.functions import Coalesce
from rest_framework import serializers

from apps.analytics.models import AnalyticsEvent
from apps.analytics.services import record_domain_event
from apps.core.money_dates import money_period

from . import common
from .models import MONEY, EmployeeBalanceAllocation, EmployeeBalanceEntry

ZERO = Decimal("0.00")
MONEY_FIELD = DecimalField(max_digits=12, decimal_places=2)
ENTITY = "employee_balance_entry"

#: The kinds that carry a balance. A refund is the cash that settles one.
BALANCE_KINDS = (common.Kind.OPENING, common.Kind.ADJUSTMENT)


def _run_status():
    from apps.employees.models import PayrollRun

    return PayrollRun.Status


def _balance_rows(queryset):
    from apps.employees.models import PayrollAdjustment

    return queryset.filter(
        adjustment_type=PayrollAdjustment.AdjustmentType.ACCOUNT_BALANCE
    )


# ---------------------------------------------------------------------------
# Writing an entry
# ---------------------------------------------------------------------------


def clean_deduction_limit(limit, *, direction):
    """The per-run cap on a debt the employee owes, or ``None`` for none."""
    if limit in (None, ""):
        return None
    try:
        limit = Decimal(str(limit)).quantize(MONEY)
    except (InvalidOperation, TypeError, ValueError):
        limit = None
    if limit is None or limit <= 0:
        raise serializers.ValidationError(
            {"payroll_deduction_limit": "The deduction per payroll must be more than zero."}
        )
    if limit > common.MAX_AMOUNT:
        raise serializers.ValidationError(
            {"payroll_deduction_limit": "The deduction per payroll is too large."}
        )
    if direction != common.Direction.THEY_OWE_US:
        # What the shop owes is paid in full with the next wage; there is
        # nothing to spread.
        raise serializers.ValidationError(
            {
                "payroll_deduction_limit": (
                    "Only a debt the employee owes is deducted in instalments."
                )
            }
        )
    return limit


@transaction.atomic
def create_employee_entry(
    *,
    employee,
    kind,
    direction,
    amount,
    effective_date=None,
    note="",
    payroll_deduction_limit=None,
    actor=None,
):
    """Record an opening balance or an adjustment on ``employee``'s account.

    The next payroll run drafted or approved for them takes it; nothing else
    has to be done for it to be paid or deducted.
    """
    from apps.employees.models import Employee

    common.refuse_written_refund(kind)
    cleaned = common.clean_entry_input(
        kind=kind,
        direction=direction,
        amount=amount,
        effective_date=effective_date,
        note=note,
    )
    limit = clean_deduction_limit(payroll_deduction_limit, direction=cleaned.direction)
    employee = Employee.objects.select_for_update().get(pk=employee.pk)
    if cleaned.kind == common.Kind.OPENING:
        common.refuse_second_opening(
            employee.balance_entries.live().filter(kind=common.Kind.OPENING),
            party_label="employee",
        )
    common.assert_entry_period_open(
        cleaned.effective_date, user=actor, entity_type=ENTITY
    )

    entry = EmployeeBalanceEntry.objects.create(
        employee=employee,
        kind=cleaned.kind,
        direction=cleaned.direction,
        amount=cleaned.amount,
        effective_date=cleaned.effective_date,
        note=cleaned.note,
        payroll_deduction_limit=limit,
        created_by=actor,
    )
    common.record_issued(entry, actor=actor)
    record_domain_event(
        name="balances.employee_entry.created",
        event_type=AnalyticsEvent.EventType.AUDIT,
        user=actor,
        entity_type=ENTITY,
        entity_id=entry.pk,
        attributes={
            "number": entry.number,
            "employee_id": employee.pk,
            "kind": entry.kind,
            "direction": entry.direction,
            "effective_date": entry.effective_date.isoformat(),
        },
        metrics={"amount": float(entry.amount)},
    )
    return entry


def _opposite(direction):
    if direction == common.Direction.THEY_OWE_US:
        return common.Direction.WE_OWE_THEM
    return common.Direction.THEY_OWE_US


@transaction.atomic
def settle_employee_balance(*, employee, settles, amount, note="", actor=None):
    """Settle an employee's balance with cash, through the actor's own drawer.

    ``settles`` names the side being settled: ``we_owe_them`` pays the employee
    what the shop owes them (a pay-out), ``they_owe_us`` takes in what they owe
    (a pay-in). The cash is a ``refund``-kind entry of its own, set against the
    open entries of that side oldest first (:class:`EmployeeBalanceAllocation`)
    and, like any payment, final once made. A run already drafted or approved
    with those entries on it takes only what is left of them when it is paid.
    """
    from apps.employees.models import Employee

    if settles not in common.Direction.values:
        raise serializers.ValidationError(
            {"settles": "Say whether the employee is being paid or is paying."}
        )
    paying = settles == common.Direction.WE_OWE_THEM
    cleaned = common.clean_entry_input(
        kind=common.Kind.REFUND,
        direction=_opposite(settles),
        amount=amount,
        note=note,
    )
    session = common.open_drawer_for(actor)
    employee = Employee.objects.select_for_update().get(pk=employee.pk)
    targets = _open_entries(employee_ids=[employee.pk], direction=settles, lock=True)
    available = sum((left for _entry, left in targets), ZERO)
    if cleaned.amount > available:
        raise serializers.ValidationError(
            {
                "amount": (
                    f"The balance to settle is {available:.2f}; it cannot "
                    f"settle {cleaned.amount:.2f}."
                ),
                "code": "refund_exceeds_credit",
                "available": f"{available:.2f}",
            }
        )

    entry = EmployeeBalanceEntry(
        employee=employee,
        kind=common.Kind.REFUND,
        direction=cleaned.direction,
        amount=cleaned.amount,
        effective_date=cleaned.effective_date,
        note=cleaned.note,
        created_by=actor,
    )
    # Numbered before it is written, so the drawer movement can name it; the
    # entry is frozen from the moment it exists.
    common.allocate_number(entry)
    name = employee.display_name
    entry.cash_movement = common.drawer_movement(
        session,
        outgoing=paying,
        amount=entry.amount,
        reason=(
            f"صرف مستحقات للموظف {name} ({entry.number})"
            if paying
            else f"تحصيل من الموظف {name} ({entry.number})"
        ),
        actor=actor,
    )
    entry.save()

    remaining = entry.amount
    allocations = []
    for target, left in targets:
        if remaining <= 0:
            break
        take = min(left, remaining)
        allocations.append(
            EmployeeBalanceAllocation(entry=target, refund=entry, amount=take)
        )
        remaining -= take
    EmployeeBalanceAllocation.objects.bulk_create(allocations)

    common.record_issued(entry, actor=actor)
    record_domain_event(
        name=(
            "balances.employee_balance.paid"
            if paying
            else "balances.employee_balance.collected"
        ),
        event_type=AnalyticsEvent.EventType.AUDIT,
        user=actor,
        entity_type=ENTITY,
        entity_id=entry.pk,
        attributes={
            "number": entry.number,
            "employee_id": employee.pk,
            "register_session_id": session.pk,
            "settles": settles,
        },
        metrics={"amount": float(entry.amount)},
    )
    return entry


def reverse_entry(entry, *, at, actor, reason="", context=None):
    """What cancelling an entry gives back — the registry's ``reverse`` hook.

    Cash set against it is refused by the registration's ``blocks_cancel``
    before this runs. A payroll run that has been *paid* with it on is refused
    here: its wage went out bigger or smaller by the entry, and withdrawing the
    entry would leave that money with no reason. A run not paid yet simply
    drops it, and its totals follow.
    """
    from apps.employees.models import PayrollAdjustment, PayrollRun

    common.refuse_refund_cancel(entry)
    status = _run_status()
    rows = _balance_rows(PayrollAdjustment.objects.filter(balance_entry=entry))
    paid = list(
        rows.filter(payroll_line__payroll_run__status=status.PAID).select_related(
            "payroll_line__payroll_run"
        )
    )
    if paid:
        raise common.blocked(
            entry,
            label="مسير رواتب مدفوع سوّى هذا الرصيد",
            rows=[row.payroll_line.payroll_run for row in paid],
        )
    pending = rows.filter(
        payroll_line__payroll_run__status__in=(status.DRAFT, status.APPROVED)
    )
    run_ids = set(pending.values_list("payroll_line__payroll_run_id", flat=True))
    pending.delete()
    for run in PayrollRun.objects.filter(pk__in=run_ids):
        run.recalculate(save_lines=True)
        run.save(
            update_fields=[
                "gross_total",
                "additions_total",
                "deductions_total",
                "net_total",
                "updated_at",
            ]
        )
    return None


# ---------------------------------------------------------------------------
# What is settled, and what is still open
# ---------------------------------------------------------------------------


def _payroll_total(*, statuses=None, paid_by=None):
    """What runs have deducted or paid against one entry, as a subquery."""
    from apps.employees.models import PayrollAdjustment

    rows = _balance_rows(PayrollAdjustment.objects).filter(
        balance_entry_id=OuterRef("pk")
    )
    status = _run_status()
    if paid_by is not None:
        rows = rows.filter(
            payroll_line__payroll_run__status=status.PAID,
            payroll_line__payroll_run__payment_date__lte=paid_by,
        )
    else:
        rows = rows.filter(payroll_line__payroll_run__status__in=statuses)
    return (
        rows.order_by()
        .values("balance_entry_id")
        .annotate(total=Sum("amount"))
        .values("total")[:1]
    )


def _cash_total(*, settled_by=None):
    rows = EmployeeBalanceAllocation.objects.filter(entry_id=OuterRef("pk"))
    if settled_by is not None:
        rows = rows.filter(refund__effective_date__lte=settled_by)
    return (
        rows.order_by()
        .values("entry_id")
        .annotate(total=Sum("amount"))
        .values("total")[:1]
    )


def _money(subquery):
    return Coalesce(Subquery(subquery, output_field=MONEY_FIELD), Value(ZERO))


def annotate_settlement(queryset):
    """What each entry has been settled by — paid runs and cash — and what
    runs not yet paid have put on themselves to settle."""
    status = _run_status()
    return queryset.annotate(
        payroll_settled=_money(_payroll_total(statuses=(status.PAID,))),
        cash_settled=_money(_cash_total()),
        payroll_scheduled=_money(
            _payroll_total(statuses=(status.DRAFT, status.APPROVED))
        ),
    )


def entries_with_settlement(queryset):
    """The listing's queryset, with what the serializer states about each entry."""
    return annotate_settlement(queryset.select_related("created_by", "cancelled_by"))


def _settled_cold(entry):
    from apps.employees.models import PayrollAdjustment

    status = _run_status()
    payroll = _balance_rows(PayrollAdjustment.objects).filter(
        balance_entry=entry, payroll_line__payroll_run__status=status.PAID
    ).aggregate(total=Sum("amount"))["total"] or ZERO
    cash = entry.cash_settlements.aggregate(total=Sum("amount"))["total"] or ZERO
    return payroll + cash


def settled_amount(entry) -> Decimal:
    """How much of an entry has been paid, deducted or settled in cash."""
    if not entry.is_submitted:
        return ZERO
    if entry.kind == common.Kind.REFUND:
        # The cash that settles a balance is itself settled the moment it moves.
        return entry.amount
    payroll = getattr(entry, "payroll_settled", None)
    cash = getattr(entry, "cash_settled", None)
    total = _settled_cold(entry) if payroll is None or cash is None else payroll + cash
    return min(max(Decimal(total), ZERO), entry.amount).quantize(MONEY)


def scheduled_amount(entry) -> Decimal:
    """What runs drafted or approved but not paid have put on themselves."""
    if not entry.is_submitted or entry.kind == common.Kind.REFUND:
        return ZERO
    scheduled = getattr(entry, "payroll_scheduled", None)
    if scheduled is None:
        from apps.employees.models import PayrollAdjustment

        status = _run_status()
        scheduled = _balance_rows(PayrollAdjustment.objects).filter(
            balance_entry=entry,
            payroll_line__payroll_run__status__in=(status.DRAFT, status.APPROVED),
        ).aggregate(total=Sum("amount"))["total"] or ZERO
    return Decimal(scheduled).quantize(MONEY)


def _open_entries(*, employee_ids, direction=None, lock=False):
    """Every live balance entry of these employees with something left on it,
    oldest first, as ``(entry, left)``. ``left`` is what paid runs and cash
    have not settled; runs not yet paid are not counted against it."""
    queryset = EmployeeBalanceEntry.objects.filter(
        employee_id__in=employee_ids, kind__in=BALANCE_KINDS
    ).live()
    if direction is not None:
        queryset = queryset.filter(direction=direction)
    if lock:
        # Locked on their own: the settlement annotations below are aggregate
        # subqueries, and the entries are what two settlements would race for.
        list(queryset.select_for_update().values_list("pk", flat=True))
    rows = []
    for entry in annotate_settlement(queryset).order_by("effective_date", "id"):
        left = (entry.amount - entry.payroll_settled - entry.cash_settled).quantize(MONEY)
        if left > 0:
            rows.append((entry, left))
    return rows


@dataclass(frozen=True)
class EmployeePosition:
    """Both sides of an employee's account, never netted into one figure
    alone: a wage run pays the one and deducts the other."""

    owed_by_employee: Decimal
    owed_to_employee: Decimal
    #: What runs drafted or approved but not yet paid already carry.
    scheduled_deduction: Decimal
    scheduled_payment: Decimal
    has_opening: bool

    @property
    def net(self) -> Decimal:
        """Positive when the employee owes the shop."""
        return (self.owed_by_employee - self.owed_to_employee).quantize(MONEY)


EMPTY_POSITION = EmployeePosition(ZERO, ZERO, ZERO, ZERO, False)


def positions_by_employee(employee_ids) -> dict:
    """Every listed employee's position, in one query."""
    employee_ids = [pk for pk in employee_ids if pk is not None]
    if not employee_ids:
        return {}
    totals = defaultdict(lambda: [ZERO, ZERO, ZERO, ZERO, False])
    rows = annotate_settlement(
        EmployeeBalanceEntry.objects.filter(
            employee_id__in=employee_ids, kind__in=BALANCE_KINDS
        ).live()
    ).values_list(
        "employee_id",
        "kind",
        "direction",
        "amount",
        "payroll_settled",
        "cash_settled",
        "payroll_scheduled",
    )
    for employee_id, kind, direction, amount, paid, cash, scheduled in rows:
        row = totals[employee_id]
        left = max(amount - paid - cash, ZERO)
        owed_to_us = direction == common.Direction.THEY_OWE_US
        row[0 if owed_to_us else 1] += left
        row[2 if owed_to_us else 3] += min(scheduled, left)
        if kind == common.Kind.OPENING:
            row[4] = True
    return {
        employee_id: EmployeePosition(
            owed_by_employee=row[0].quantize(MONEY),
            owed_to_employee=row[1].quantize(MONEY),
            scheduled_deduction=row[2].quantize(MONEY),
            scheduled_payment=row[3].quantize(MONEY),
            has_opening=row[4],
        )
        for employee_id, row in totals.items()
    }


def account_position(employee) -> EmployeePosition:
    return positions_by_employee([employee.pk]).get(employee.pk, EMPTY_POSITION)


def has_live_opening(employee) -> bool:
    return (
        EmployeeBalanceEntry.objects.live()
        .filter(employee_id=employee.pk, kind=common.Kind.OPENING)
        .exists()
    )


# ---------------------------------------------------------------------------
# Payroll
# ---------------------------------------------------------------------------


@transaction.atomic
def refresh_payroll_balance_adjustments(payroll_run):
    """Re-derive every account-balance row on a draft run from what is open now.

    Run whenever a draft is made, saved or approved, and always before the
    staff purchases are derived, which take what these leave. What the shop
    owes an employee is added in full; what they owe is deducted oldest entry
    first, up to each entry's per-run limit and the pay the line has left —
    what does not fit stays owed for the next run. An entry another unpaid run
    has already put on itself is not taken twice.
    """
    from apps.employees.models import PayrollAdjustment

    status = _run_status()
    if payroll_run.status != status.DRAFT:
        raise serializers.ValidationError(
            {"detail": "Only draft payroll runs can be changed."}
        )
    _balance_rows(
        PayrollAdjustment.objects.filter(payroll_line__payroll_run=payroll_run)
    ).delete()

    lines = list(
        payroll_run.lines.select_related("employee", "compensation_plan", "payroll_run")
        .prefetch_related("adjustments")
        .order_by("id")
    )
    employee_ids = {line.employee_id for line in lines}
    if not employee_ids:
        return payroll_run
    open_by_employee = defaultdict(list)
    queryset = EmployeeBalanceEntry.objects.filter(
        employee_id__in=employee_ids, kind__in=BALANCE_KINDS
    ).live()
    # This run's own rows were deleted above, so what is "scheduled" here is
    # what the other unpaid runs carry.
    for entry in annotate_settlement(queryset).order_by("effective_date", "id"):
        left = (
            entry.amount
            - entry.payroll_settled
            - entry.cash_settled
            - entry.payroll_scheduled
        ).quantize(MONEY)
        if left > 0:
            open_by_employee[entry.employee_id].append((entry, left))

    rows = []
    for line in lines:
        entries = open_by_employee.get(line.employee_id)
        if not entries:
            continue
        added = ZERO
        for entry, left in entries:
            if entry.direction != common.Direction.WE_OWE_THEM:
                continue
            rows.append(
                PayrollAdjustment(
                    payroll_line=line,
                    direction=PayrollAdjustment.Direction.ADDITION,
                    adjustment_type=PayrollAdjustment.AdjustmentType.ACCOUNT_BALANCE,
                    amount=left,
                    balance_entry=entry,
                    notes=entry.number,
                )
            )
            added += left
        debts = [
            (entry, left)
            for entry, left in entries
            if entry.direction == common.Direction.THEY_OWE_US
        ]
        if not debts:
            continue
        line.recalculate()
        room = line.room_for_debts + added
        for entry, left in debts:
            if room <= 0:
                break
            take = min(left, room)
            if entry.payroll_deduction_limit is not None:
                take = min(take, entry.payroll_deduction_limit)
            if take <= 0:
                continue
            rows.append(
                PayrollAdjustment(
                    payroll_line=line,
                    direction=PayrollAdjustment.Direction.DEDUCTION,
                    adjustment_type=PayrollAdjustment.AdjustmentType.ACCOUNT_BALANCE,
                    amount=take,
                    balance_entry=entry,
                    notes=entry.number,
                )
            )
            room -= take
    # Created oldest entry first, so the newest is the first to give way if the
    # line's pay later shrinks (``PayrollLine.recalculate``).
    PayrollAdjustment.objects.bulk_create(rows)
    return payroll_run


def settle_payroll_balance_adjustments(payroll_run):
    """Cut the run's account-balance rows to what their entries still have
    open. Called while paying the run, before it is submitted.

    An entry settled in cash since the run was approved, or withdrawn, must
    not be paid or deducted a second time. Only settlements that have happened
    count against it — a paid run, cash — so the run being paid takes
    precedence over another that is still waiting.
    """
    from apps.employees.models import PayrollAdjustment, PayrollRun

    rows = list(
        _balance_rows(
            PayrollAdjustment.objects.filter(payroll_line__payroll_run=payroll_run)
        ).order_by("payroll_line_id", "id")
    )
    if not rows:
        return payroll_run
    entry_ids = {row.balance_entry_id for row in rows}
    list(
        EmployeeBalanceEntry.objects.select_for_update()
        .filter(pk__in=entry_ids)
        .values_list("pk", flat=True)
    )
    open_now = {}
    for entry in annotate_settlement(EmployeeBalanceEntry.objects.filter(pk__in=entry_ids)):
        open_now[entry.pk] = (
            max(entry.amount - entry.payroll_settled - entry.cash_settled, ZERO)
            if entry.is_submitted
            else ZERO
        )
    shrunk = False
    for row in rows:
        left = open_now.get(row.balance_entry_id, ZERO)
        amount = min(row.amount, left)
        open_now[row.balance_entry_id] = left - amount
        if amount == row.amount:
            continue
        shrunk = True
        if amount <= 0:
            row.delete()
        else:
            row.amount = amount
            row.save(update_fields=["amount", "updated_at"])
    if shrunk:
        payroll_run = PayrollRun.objects.get(pk=payroll_run.pk)
        payroll_run.recalculate(save_lines=True)
        payroll_run.save(
            update_fields=[
                "gross_total",
                "additions_total",
                "deductions_total",
                "net_total",
                "updated_at",
            ]
        )
    return payroll_run


def payroll_balance_totals(runs) -> tuple[Decimal, Decimal]:
    """What ``runs`` deducted for employees' debts and paid for what the shop
    owed them, as ``(deducted, added)``."""
    from apps.employees.models import PayrollAdjustment

    rows = _balance_rows(
        PayrollAdjustment.objects.filter(payroll_line__payroll_run__in=runs)
    ).aggregate(
        deducted=Coalesce(
            Sum("amount", filter=Q(direction=PayrollAdjustment.Direction.DEDUCTION)),
            Value(ZERO),
            output_field=MONEY_FIELD,
        ),
        added=Coalesce(
            Sum("amount", filter=Q(direction=PayrollAdjustment.Direction.ADDITION)),
            Value(ZERO),
            output_field=MONEY_FIELD,
        ),
    )
    return rows["deducted"].quantize(MONEY), rows["added"].quantize(MONEY)


# ---------------------------------------------------------------------------
# The books
# ---------------------------------------------------------------------------


def adjustments_labour_cost(start, end) -> Decimal:
    """What the adjustments dated in the period added to labour cost.

    The shop owing an employee more is a cost of the day it was recorded; an
    employee owing the shop more is a recovery. Opening balances are not here:
    they are what the account already was.
    """
    rows = (
        money_period(
            EmployeeBalanceEntry.objects.live().filter(kind=common.Kind.ADJUSTMENT),
            start,
            end,
        )
        .order_by()
        .values("direction")
        .annotate(total=Sum("amount"))
    )
    total = ZERO
    for row in rows:
        amount = row["total"] or ZERO
        if row["direction"] == common.Direction.WE_OWE_THEM:
            total += amount
        else:
            total -= amount
    return total.quantize(MONEY)


def balances_as_of_by_employee(as_of) -> dict:
    """Each employee's account at the close of ``as_of``, as
    ``{employee_id: (owed_by_employee, owed_to_employee)}`` — only those with
    something on it.

    Rebuilt from what was entered by then less what paid runs and cash had
    settled by then, each entry floored at zero on its own.
    """
    queryset = EmployeeBalanceEntry.objects.live().filter(
        kind__in=BALANCE_KINDS, effective_date__lte=as_of
    )
    rows = queryset.annotate(
        settled_by_payroll=_money(_payroll_total(paid_by=as_of)),
        settled_in_cash=_money(_cash_total(settled_by=as_of)),
    ).values_list(
        "employee_id", "direction", "amount", "settled_by_payroll", "settled_in_cash"
    )
    totals = defaultdict(lambda: [ZERO, ZERO])
    for employee_id, direction, amount, payroll, cash in rows:
        left = max(amount - payroll - cash, ZERO)
        if left <= 0:
            continue
        side = 0 if direction == common.Direction.THEY_OWE_US else 1
        totals[employee_id][side] += left
    return {
        employee_id: (owed_by.quantize(MONEY), owed_to.quantize(MONEY))
        for employee_id, (owed_by, owed_to) in totals.items()
    }


def balances_as_of(as_of) -> tuple[Decimal, Decimal]:
    """What employees owed the shop, and the shop owed them, on their
    accounts at the close of ``as_of`` — ``(owed_by_employees, owed_to_them)``."""
    owed_by = ZERO
    owed_to = ZERO
    for by, to in balances_as_of_by_employee(as_of).values():
        owed_by += by
        owed_to += to
    return owed_by.quantize(MONEY), owed_to.quantize(MONEY)


__all__ = [
    "BALANCE_KINDS",
    "EmployeePosition",
    "account_position",
    "adjustments_labour_cost",
    "annotate_settlement",
    "balances_as_of",
    "balances_as_of_by_employee",
    "clean_deduction_limit",
    "create_employee_entry",
    "entries_with_settlement",
    "has_live_opening",
    "payroll_balance_totals",
    "positions_by_employee",
    "refresh_payroll_balance_adjustments",
    "reverse_entry",
    "scheduled_amount",
    "settle_employee_balance",
    "settle_payroll_balance_adjustments",
    "settled_amount",
]
