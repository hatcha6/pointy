from decimal import Decimal

from django.db import transaction
from django.utils import timezone
from rest_framework import serializers

from apps.analytics.models import AnalyticsEvent
from apps.analytics.services import record_domain_event

from .models import Employee, PayrollAdjustment, PayrollLine, PayrollRun


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
