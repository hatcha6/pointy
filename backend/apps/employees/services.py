from datetime import timedelta
from decimal import Decimal

from django.db import transaction

from apps.core.period_lock import assert_period_open
from apps.documents import services as document_services
from apps.documents.statuses import DocumentStatus
from apps.employees import documents as payroll_documents
from django.db.models import Q, Sum
from django.utils import timezone
from rest_framework import serializers

from apps.analytics.models import AnalyticsEvent
from apps.analytics.services import record_domain_event
from apps.sales.models import Order, OrderAdjustment

from .models import (
    CompensationPlan,
    Employee,
    EmployeeLoan,
    EmployeeLoanPayment,
    PayrollAdjustment,
    PayrollLine,
    PayrollRun,
)


MONEY_PLACES = Decimal("0.01")


def employee_created_by(request):
    if request is not None and request.user.is_authenticated:
        return request.user
    return None


def record_employee_event(
    *,
    name,
    user,
    entity_type,
    entity_id,
    attributes=None,
    metrics=None,
    severity=AnalyticsEvent.Severity.INFO,
):
    record_domain_event(
        name=name,
        event_type=AnalyticsEvent.EventType.AUDIT,
        severity=severity,
        user=user,
        entity_type=entity_type,
        entity_id=entity_id,
        attributes=attributes or {},
        metrics=metrics or {},
    )


def ensure_employee_for_user(user, *, created_by=None):
    """Create an Employee profile linked to ``user`` unless one already
    exists, so every account holder shows up in payroll automatically."""
    existing = Employee.objects.filter(user=user).first()
    if existing is not None:
        return existing

    full_name = (user.get_full_name() or "").strip() or user.username
    employee = Employee.objects.create(user=user, full_name=full_name)
    record_employee_event(
        name="employees.employee.created",
        user=created_by,
        entity_type="employee",
        entity_id=employee.pk,
        attributes={
            "linked_user_id": user.pk,
            "auto_created": True,
        },
    )
    return employee


@transaction.atomic
def save_payroll_run_with_lines(
    *,
    payroll_run=None,
    lines_data=None,
    request=None,
    **run_fields,
):
    is_create = payroll_run is None
    if payroll_run is None:
        payroll_run = PayrollRun.objects.create(**run_fields)
    else:
        if payroll_run.status != PayrollRun.Status.DRAFT:
            raise serializers.ValidationError(
                {"detail": "Only draft payroll runs can be changed."}
            )
        for field, value in run_fields.items():
            setattr(payroll_run, field, value)
        payroll_run.full_clean()
        payroll_run.save()
        if lines_data is not None:
            payroll_run.lines.all().delete()

    if lines_data is not None:
        for line_data in lines_data:
            adjustments_data = line_data.pop("adjustments", [])
            line = PayrollLine.objects.create(payroll_run=payroll_run, **line_data)
            PayrollAdjustment.objects.bulk_create(
                [
                    PayrollAdjustment(payroll_line=line, **adjustment)
                    for adjustment in adjustments_data
                ]
            )
            line.recalculate(save=True)

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
    record_employee_event(
        name=(
            "employees.payroll_run.created"
            if is_create
            else "employees.payroll_run.updated"
        ),
        user=employee_created_by(request),
        entity_type="payroll_run",
        entity_id=payroll_run.pk,
        attributes={
            "run_number": payroll_run.run_number,
            "status": payroll_run.status,
            "line_count": payroll_run.lines.count(),
        },
        metrics={"net_total": float(payroll_run.net_total)},
    )
    return payroll_run


def previous_month_period(reference_date=None):
    reference_date = reference_date or timezone.localdate()
    first_day = reference_date.replace(day=1)
    period_end = first_day - timedelta(days=1)
    return period_end.replace(day=1), period_end


@transaction.atomic
def draft_monthly_payroll_run(
    *,
    period_start=None,
    period_end=None,
    request=None,
):
    if period_start is None or period_end is None:
        period_start, period_end = previous_month_period()
    if period_end < period_start:
        raise serializers.ValidationError(
            {"period_end": "Period end cannot be before start."}
        )

    existing = (
        PayrollRun.objects.select_for_update()
        .exclude(status=PayrollRun.Status.VOID)
        .filter(period_start=period_start, period_end=period_end)
        .order_by("-created_at", "-id")
        .first()
    )
    if existing is not None:
        return existing, False

    line_inputs = _monthly_payroll_line_inputs(period_start, period_end)
    if not line_inputs:
        return None, False

    payroll_run = PayrollRun.objects.create(
        period_start=period_start,
        period_end=period_end,
        notes="Monthly salary draft generated automatically.",
    )
    for line_input in line_inputs:
        line = PayrollLine.objects.create(
            payroll_run=payroll_run,
            employee=line_input["employee"],
            compensation_plan=line_input["plan"],
            units=line_input["units"],
            description=line_input["description"],
        )
        if line_input["commission_amount"] > Decimal("0.00"):
            PayrollAdjustment.objects.create(
                payroll_line=line,
                direction=PayrollAdjustment.Direction.ADDITION,
                adjustment_type=PayrollAdjustment.AdjustmentType.COMMISSION,
                amount=line_input["commission_amount"],
                notes=(
                    f"{line_input['commission_percent']}% commission on "
                    f"{line_input['commission_base']} "
                    f"{'repairs' if line_input['commission_basis'] == 'operations' else 'sales'}"
                ),
            )
        for loan_deduction in line_input["loan_deductions"]:
            PayrollAdjustment.objects.create(
                payroll_line=line,
                direction=PayrollAdjustment.Direction.DEDUCTION,
                adjustment_type=PayrollAdjustment.AdjustmentType.LOAN,
                amount=loan_deduction["amount"],
                loan=loan_deduction["loan"],
                notes=f"Loan installment for loan #{loan_deduction['loan'].pk}",
            )
        line.recalculate(save=True)

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
    record_employee_event(
        name="employees.payroll_run.monthly_draft_created",
        user=employee_created_by(request),
        entity_type="payroll_run",
        entity_id=payroll_run.pk,
        attributes={
            "run_number": payroll_run.run_number,
            "period_start": period_start.isoformat(),
            "period_end": period_end.isoformat(),
            "line_count": payroll_run.lines.count(),
        },
        metrics={"net_total": float(payroll_run.net_total)},
    )
    return payroll_run, True


def _monthly_payroll_line_inputs(period_start, period_end):
    line_inputs = []
    employees = Employee.objects.filter(
        status__in=(Employee.Status.ACTIVE, Employee.Status.ON_LEAVE),
    ).select_related("user")
    for employee in employees:
        plan = _plan_for_period(employee, period_end)
        if plan is None:
            continue
        commission_base = Decimal("0.00")
        commission_percent = Decimal("0.00")
        commission_amount = Decimal("0.00")
        commission_basis = ""
        if plan.uses_sales_commission:
            commission_base = _commissionable_sales_total(
                employee, period_start, period_end
            )
            commission_basis = "sales"
        elif plan.uses_operations_commission:
            commission_base = _commissionable_jobs_total(
                employee,
                period_start,
                period_end,
                plan.operations_commission_base,
            )
            commission_basis = "operations"
        if commission_basis:
            commission_percent = Decimal(plan.commission_percent or "0.00")
            commission_amount = (
                commission_base * commission_percent / Decimal("100")
            ).quantize(MONEY_PLACES)
        units = (
            Decimal(plan.expected_units_per_period or "0.00")
            if plan.uses_expected_units
            else Decimal("1.00")
        )
        gross_amount = plan.amount_for_units(units)
        loan_deductions = _loan_deduction_inputs(
            employee,
            available_pay=gross_amount + commission_amount,
        )
        line_inputs.append(
            {
                "employee": employee,
                "plan": plan,
                "units": units,
                "gross_amount": gross_amount,
                "commission_base": commission_base,
                "commission_basis": commission_basis,
                "commission_percent": commission_percent,
                "commission_amount": commission_amount,
                "loan_deductions": loan_deductions,
                "description": (
                    f"Monthly salary for {period_start:%Y-%m-%d} - "
                    f"{period_end:%Y-%m-%d}"
                ),
            }
        )
    return line_inputs


def _plan_for_period(employee, period_end):
    return (
        employee.compensation_plans.filter(
            is_active=True,
            effective_from__lte=period_end,
        )
        .filter(Q(effective_to__isnull=True) | Q(effective_to__gte=period_end))
        .filter(
            Q(
                salary_type__in=[
                    *CompensationPlan.SalaryType.values,
                ]
            )
            | Q(salary_type="", pay_type=CompensationPlan.PayType.MONTHLY_SALARY)
            | Q(
                salary_type="",
                pay_type=CompensationPlan.PayType.COMMISSION,
                amount=Decimal("0.00"),
                commission_percent__gt=Decimal("0.00"),
            )
        )
        .order_by("-effective_from", "-id")
        .first()
    )


def _commissionable_sales_total(employee, period_start, period_end):
    """Net value of the cashier's own recognized sales in the period.

    ``committed_sales`` already drops voids, so goods that came back earn no
    commission — but a *partial* return leaves the order PAID and never touches
    ``Order.total``, so the refunded portion has to be subtracted here or the
    same rule stops applying the moment one item of the basket is kept. Without
    it, returning three of four units still pays commission on all four, and a
    cashier who refunds everything but one line keeps the full commission that a
    complete return would have taken away.

    The refunds are netted against the period the *sale* falls in, which is how
    voids already behave (a void removes the sale from its own period whenever
    it happens). Adjustments are summed in a second query on purpose: joining
    them into the ``Sum("total")`` aggregate would fan the order rows out and
    multiply the sales total by the number of returns against it.
    """
    if employee.user_id is None:
        return Decimal("0.00")
    orders = Order.objects.committed_sales().filter(
        register_session__owner_id=employee.user_id,
        created_at__date__gte=period_start,
        created_at__date__lte=period_end,
    )
    total = orders.aggregate(total=Sum("total"))["total"] or Decimal("0.00")
    refunded = OrderAdjustment.objects.filter(order__in=orders).aggregate(
        total=Sum("amount")
    )["total"] or Decimal("0.00")
    return max(total - refunded, Decimal("0.00")).quantize(MONEY_PLACES)


def _commissionable_jobs_total(employee, period_start, period_end, base):
    """Total value of the commissionable jobs the employee completed in the period.

    Only customer-priced service jobs (repairs and work orders) are
    commissionable; internal kitchen/production jobs are excluded below.

    The valuation depends on the plan's ``operations_commission_base``:

    - ``approved_price`` — the full price agreed with the customer (default);
    - ``labor`` — that price minus the consumed parts (at their sale price), i.e.
      the labor portion, available even before the job is invoiced;
    - ``order_total`` — the total of the job's invoice, net of any void or
      return against it (invoiced jobs only).
    """
    from apps.operations.models import Job, WorkflowTemplate

    jobs = Job.objects.filter(
        assigned_employee=employee,
        status=Job.Status.COMPLETED,
        completed_at__date__gte=period_start,
        completed_at__date__lte=period_end,
    ).exclude(
        # Operations commission is for customer-priced service work (repairs and
        # work orders). Kitchen and production jobs are internal, auto-created,
        # and never carry a customer-approved price — they must never earn a
        # technician commission even if one is somehow assigned and priced.
        job_type__in=[
            WorkflowTemplate.JobType.KITCHEN,
            WorkflowTemplate.JobType.PRODUCTION,
        ]
    )

    if base == CompensationPlan.OperationsCommissionBase.ORDER_TOTAL:
        # Only invoices whose revenue is actually recognized count, and only
        # net of what came back: a voided repair invoice was never collected,
        # and a partially returned one collected less than its ``total`` says.
        # Summing ``order__total`` off the job rows counts both in full (and
        # counts one invoice twice when two of the employee's jobs share it).
        invoices = Order.objects.committed_sales().filter(
            pk__in=jobs.filter(order__isnull=False).values("order_id")
        )
        total = invoices.aggregate(total=Sum("total"))["total"] or Decimal("0.00")
        refunded = OrderAdjustment.objects.filter(order__in=invoices).aggregate(
            total=Sum("amount")
        )["total"] or Decimal("0.00")
        return max(total - refunded, Decimal("0.00")).quantize(MONEY_PLACES)

    jobs = jobs.filter(approved_price__isnull=False)

    if base == CompensationPlan.OperationsCommissionBase.LABOR:
        total = Decimal("0.00")
        for job in jobs.prefetch_related("materials"):
            parts = sum(
                (
                    material.unit_price * material.quantity
                    for material in job.materials.all()
                    if material.is_consumed
                ),
                Decimal("0.00"),
            )
            labor = job.approved_price - parts
            if labor > Decimal("0.00"):
                total += labor
        return total.quantize(MONEY_PLACES)

    total = jobs.aggregate(total=Sum("approved_price"))["total"]
    return (total or Decimal("0.00")).quantize(MONEY_PLACES)


def _loan_deduction_inputs(employee, *, available_pay):
    available_pay = Decimal(available_pay or "0.00").quantize(MONEY_PLACES)
    if available_pay <= Decimal("0.00"):
        return []

    deductions = []
    loans = EmployeeLoan.objects.filter(
        employee=employee,
        status=EmployeeLoan.Status.APPROVED,
        outstanding_balance__gt=Decimal("0.00"),
    ).order_by("reviewed_at", "created_at", "id")
    for loan in loans:
        remaining_balance = (
            Decimal(loan.outstanding_balance or "0.00")
            - _scheduled_unpaid_loan_deductions(loan)
        ).quantize(MONEY_PLACES)
        if remaining_balance <= Decimal("0.00"):
            continue

        amount = min(loan.monthly_deduction, remaining_balance, available_pay).quantize(
            MONEY_PLACES
        )
        if amount <= Decimal("0.00"):
            continue

        deductions.append({"loan": loan, "amount": amount})
        available_pay = (available_pay - amount).quantize(MONEY_PLACES)
        if available_pay <= Decimal("0.00"):
            break
    return deductions


def _scheduled_unpaid_loan_deductions(loan):
    total = PayrollAdjustment.objects.filter(
        loan=loan,
        direction=PayrollAdjustment.Direction.DEDUCTION,
        adjustment_type=PayrollAdjustment.AdjustmentType.LOAN,
        payroll_line__payroll_run__status__in=(
            PayrollRun.Status.DRAFT,
            PayrollRun.Status.APPROVED,
        ),
    ).aggregate(total=Sum("amount"))["total"]
    return (total or Decimal("0.00")).quantize(MONEY_PLACES)


@transaction.atomic
def approve_payroll_run(payroll_run, *, request=None):
    payroll_run = PayrollRun.objects.select_for_update().get(pk=payroll_run.pk)
    if payroll_run.status != PayrollRun.Status.DRAFT:
        raise serializers.ValidationError(
            {"detail": "Only draft payroll runs can be approved."}
        )
    if not payroll_run.lines.exists():
        raise serializers.ValidationError(
            {"lines": "Payroll run must include at least one employee."}
        )
    payroll_run.recalculate(save_lines=True)
    payroll_run.approved_at = timezone.now()
    payroll_run.approved_by = employee_created_by(request)
    payroll_run.save(
        update_fields=[
            "approved_at",
            "approved_by",
            "gross_total",
            "additions_total",
            "deductions_total",
            "net_total",
            "updated_at",
        ]
    )
    # Approval is a gate on paying, not a state of the document: the run is
    # still a draft, and its progress field says "approved" because the stamp
    # above is there.
    payroll_documents.recompute_progress(payroll_run)
    record_employee_event(
        name="employees.payroll_run.approved",
        user=employee_created_by(request),
        entity_type="payroll_run",
        entity_id=payroll_run.pk,
        attributes={"run_number": payroll_run.run_number},
        metrics={"net_total": float(payroll_run.net_total)},
    )
    return payroll_run


@transaction.atomic
def mark_payroll_run_paid(payroll_run, *, payment_date=None, request=None):
    payroll_run = PayrollRun.objects.select_for_update().get(pk=payroll_run.pk)
    if payroll_run.status != PayrollRun.Status.APPROVED:
        raise serializers.ValidationError(
            {"detail": "Only approved payroll runs can be marked paid."}
        )
    payment_date = payment_date or timezone.localdate()
    # ``payment_date`` is caller-supplied, so a wage run can be dated into a
    # month that has already been closed and reported.
    assert_period_open(
        payment_date,
        user=getattr(request, "user", None),
        entity_type="payroll_run",
        entity_id=payroll_run.pk,
        action="payroll.mark_paid",
    )
    payroll_run.payment_date = payment_date
    payroll_run.paid_at = timezone.now()
    payroll_run.paid_by = employee_created_by(request)
    payroll_run.save(
        update_fields=[
            "payment_date",
            "paid_at",
            "paid_by",
            "updated_at",
        ]
    )
    # Paying is what submits a run: it is the moment the money leaves and the
    # moment its figures stop being a proposal. From here it is frozen.
    payroll_run = document_services.submit(payroll_run, request=request)
    _apply_payroll_loan_payments(payroll_run)
    record_employee_event(
        name="employees.payroll_run.paid",
        user=employee_created_by(request),
        entity_type="payroll_run",
        entity_id=payroll_run.pk,
        attributes={
            "run_number": payroll_run.run_number,
            "payment_date": payroll_run.payment_date,
        },
        metrics={"net_total": float(payroll_run.net_total)},
    )
    return payroll_run


def _apply_payroll_loan_payments(payroll_run):
    loan_adjustments = (
        PayrollAdjustment.objects.select_related("loan", "payroll_line")
        .filter(
            payroll_line__payroll_run=payroll_run,
            loan__isnull=False,
            direction=PayrollAdjustment.Direction.DEDUCTION,
            adjustment_type=PayrollAdjustment.AdjustmentType.LOAN,
        )
        .order_by("payroll_line_id", "id")
    )
    for adjustment in loan_adjustments:
        if EmployeeLoanPayment.objects.filter(
            loan_id=adjustment.loan_id,
            payroll_line_id=adjustment.payroll_line_id,
        ).exists():
            continue

        loan = EmployeeLoan.objects.select_for_update().get(pk=adjustment.loan_id)
        if loan.status not in (EmployeeLoan.Status.APPROVED, EmployeeLoan.Status.PAID):
            continue
        amount = min(
            Decimal(adjustment.amount or "0.00"),
            Decimal(loan.outstanding_balance or "0.00"),
        ).quantize(MONEY_PLACES)
        if amount <= Decimal("0.00"):
            continue

        EmployeeLoanPayment.objects.create(
            loan=loan,
            payroll_line=adjustment.payroll_line,
            amount=amount,
            paid_at=payroll_run.paid_at or timezone.now(),
        )
        loan.outstanding_balance = (
            Decimal(loan.outstanding_balance or "0.00") - amount
        ).quantize(MONEY_PLACES)
        update_fields = ["outstanding_balance", "updated_at"]
        if loan.outstanding_balance == Decimal("0.00"):
            loan.status = EmployeeLoan.Status.PAID
            loan.paid_at = payroll_run.paid_at or timezone.now()
            update_fields.extend(["status", "paid_at"])
        loan.full_clean()
        loan.save(update_fields=update_fields)


@transaction.atomic
def void_payroll_run(payroll_run, *, request=None, reason=""):
    """Retract a run.

    A paid one can be retracted now, where before it could not be: a run paid
    by mistake was permanent, and the only way out was a second run correcting
    it. What paying it collected — every loan instalment — comes back with it,
    and the money position stops counting it because it is no longer a paid run.
    """
    payroll_run = PayrollRun.objects.select_for_update().get(pk=payroll_run.pk)
    if payroll_run.doc_status == DocumentStatus.CANCELLED:
        return payroll_run
    payroll_run = document_services.cancel(
        payroll_run, reason=reason, request=request
    )
    record_employee_event(
        name="employees.payroll_run.voided",
        user=employee_created_by(request),
        entity_type="payroll_run",
        entity_id=payroll_run.pk,
        attributes={"run_number": payroll_run.run_number},
        metrics={"net_total": float(payroll_run.net_total)},
        severity=AnalyticsEvent.Severity.WARNING,
    )
    return payroll_run


def payroll_expense_between(start, end):
    total = PayrollRun.objects.filter(
        status__in=(PayrollRun.Status.APPROVED, PayrollRun.Status.PAID),
        period_end__gte=start.date() if hasattr(start, "date") else start,
        period_start__lte=end.date() if hasattr(end, "date") else end,
    ).aggregate(total=models_sum_net())["total"]
    return (total or Decimal("0.00")).quantize(Decimal("0.01"))


def models_sum_net():
    from django.db.models import DecimalField, Sum, Value
    from django.db.models.functions import Coalesce

    return Coalesce(
        Sum("net_total"),
        Value(Decimal("0.00")),
        output_field=DecimalField(max_digits=12, decimal_places=2),
    )


def active_employee_count():
    return Employee.objects.filter(status=Employee.Status.ACTIVE).count()


@transaction.atomic
def request_employee_loan(*, user, amount, monthly_deduction, purpose=""):
    try:
        employee = user.employee_profile
    except Employee.DoesNotExist as exc:
        raise serializers.ValidationError(
            {"employee": "Current user is not linked to an employee record."}
        ) from exc

    loan = EmployeeLoan(
        employee=employee,
        requested_by=user,
        amount=amount,
        monthly_deduction=monthly_deduction,
        purpose=purpose,
    )
    loan.full_clean()
    loan.save()
    record_employee_event(
        name="employees.loan.requested",
        user=user,
        entity_type="employee_loan",
        entity_id=loan.pk,
        attributes={"employee": employee.pk, "status": loan.status},
        metrics={
            "amount": float(loan.amount),
            "monthly_deduction": float(loan.monthly_deduction),
        },
    )
    return loan


@transaction.atomic
def approve_employee_loan(loan, *, request=None, review_notes=""):
    loan = EmployeeLoan.objects.select_for_update().get(pk=loan.pk)
    if loan.status != EmployeeLoan.Status.REQUESTED:
        raise serializers.ValidationError(
            {"detail": "Only requested loans can be approved."}
        )
    loan.status = EmployeeLoan.Status.APPROVED
    loan.outstanding_balance = loan.amount
    loan.reviewed_by = employee_created_by(request)
    loan.reviewed_at = timezone.now()
    loan.review_notes = review_notes
    loan.full_clean()
    loan.save(
        update_fields=[
            "status",
            "outstanding_balance",
            "reviewed_by",
            "reviewed_at",
            "review_notes",
            "updated_at",
        ]
    )
    record_employee_event(
        name="employees.loan.approved",
        user=employee_created_by(request),
        entity_type="employee_loan",
        entity_id=loan.pk,
        attributes={"employee": loan.employee_id, "status": loan.status},
        metrics={
            "amount": float(loan.amount),
            "monthly_deduction": float(loan.monthly_deduction),
        },
    )
    return loan


@transaction.atomic
def reject_employee_loan(loan, *, request=None, review_notes=""):
    loan = EmployeeLoan.objects.select_for_update().get(pk=loan.pk)
    if loan.status != EmployeeLoan.Status.REQUESTED:
        raise serializers.ValidationError(
            {"detail": "Only requested loans can be rejected."}
        )
    loan.status = EmployeeLoan.Status.REJECTED
    loan.reviewed_by = employee_created_by(request)
    loan.reviewed_at = timezone.now()
    loan.review_notes = review_notes
    loan.full_clean()
    loan.save(
        update_fields=[
            "status",
            "reviewed_by",
            "reviewed_at",
            "review_notes",
            "updated_at",
        ]
    )
    record_employee_event(
        name="employees.loan.rejected",
        user=employee_created_by(request),
        entity_type="employee_loan",
        entity_id=loan.pk,
        severity=AnalyticsEvent.Severity.WARNING,
        attributes={"employee": loan.employee_id, "status": loan.status},
    )
    return loan
