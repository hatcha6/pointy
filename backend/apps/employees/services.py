from datetime import timedelta
from decimal import Decimal

from django.db import transaction
from django.db.models import Q, Sum
from django.utils import timezone
from rest_framework import serializers

from apps.analytics.models import AnalyticsEvent
from apps.analytics.services import record_domain_event
from apps.sales.models import Order

from .models import CompensationPlan, Employee, PayrollAdjustment, PayrollLine, PayrollRun


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
            units=Decimal("1.00"),
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
                    f"{line_input['sales_total']} sales"
                ),
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
        sales_total = Decimal("0.00")
        commission_percent = Decimal("0.00")
        commission_amount = Decimal("0.00")
        if plan.uses_sales_commission:
            sales_total = _commissionable_sales_total(employee, period_start, period_end)
            commission_percent = Decimal(plan.commission_percent or "0.00")
            commission_amount = (
                sales_total * commission_percent / Decimal("100")
            ).quantize(MONEY_PLACES)
        line_inputs.append(
            {
                "employee": employee,
                "plan": plan,
                "sales_total": sales_total,
                "commission_percent": commission_percent,
                "commission_amount": commission_amount,
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
                    CompensationPlan.SalaryType.MONTHLY_FIXED,
                    CompensationPlan.SalaryType.SALES_COMMISSION_ONLY,
                    CompensationPlan.SalaryType.MONTHLY_FIXED_PLUS_SALES_COMMISSION,
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
    if employee.user_id is None:
        return Decimal("0.00")
    total = Order.objects.filter(
        status=Order.Status.PAID,
        register_session__owner_id=employee.user_id,
        created_at__date__gte=period_start,
        created_at__date__lte=period_end,
    ).aggregate(total=Sum("total"))["total"]
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
    payroll_run.status = PayrollRun.Status.APPROVED
    payroll_run.approved_at = timezone.now()
    payroll_run.approved_by = employee_created_by(request)
    payroll_run.save(
        update_fields=[
            "status",
            "approved_at",
            "approved_by",
            "gross_total",
            "additions_total",
            "deductions_total",
            "net_total",
            "updated_at",
        ]
    )
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
    payroll_run.status = PayrollRun.Status.PAID
    payroll_run.payment_date = payment_date or timezone.localdate()
    payroll_run.paid_at = timezone.now()
    payroll_run.paid_by = employee_created_by(request)
    payroll_run.save(
        update_fields=[
            "status",
            "payment_date",
            "paid_at",
            "paid_by",
            "updated_at",
        ]
    )
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


@transaction.atomic
def void_payroll_run(payroll_run, *, request=None):
    payroll_run = PayrollRun.objects.select_for_update().get(pk=payroll_run.pk)
    if payroll_run.status == PayrollRun.Status.VOID:
        return payroll_run
    if payroll_run.status == PayrollRun.Status.PAID:
        raise serializers.ValidationError(
            {"detail": "Paid payroll runs cannot be voided."}
        )
    payroll_run.status = PayrollRun.Status.VOID
    payroll_run.voided_at = timezone.now()
    payroll_run.voided_by = employee_created_by(request)
    payroll_run.save(update_fields=["status", "voided_at", "voided_by", "updated_at"])
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
