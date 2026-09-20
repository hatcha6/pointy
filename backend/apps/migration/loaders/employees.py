"""Employee loaders: the staff, what they are paid, and past payroll.

An employee row with no pay rate is a contact card — payroll cannot run for
them, which is most of the reason to import them at all — so the compensation
plan is written alongside the person rather than as a separate entity. Sources
keep one current rate per employee, not a history of them, and inventing
effective-dated history out of a single number would be making things up.

Past payroll runs are written **paid and submitted**, which is what they are:
salary that was handed over months ago. They carry their own period so the
profit report and the money position place them on the right month rather than
on the day of the import.
"""

from __future__ import annotations

from decimal import Decimal

from django.utils import timezone

from apps.documents.guards import system_write
from apps.documents.statuses import DocumentStatus
from apps.employees.models import CompensationPlan, Employee, PayrollLine, PayrollRun

from ..entity_plan import EMPLOYEE, PAYROLL_RUN
from .base import (
    CREATED,
    UPDATED,
    WARNING,
    BaseLoader,
    Issue,
    LoaderError,
    LoadOutcome,
    clean_str,
    to_decimal,
)

_MONEY = Decimal("0.01")
_PAY_TYPES = {choice for choice, _label in CompensationPlan.PayType.choices}
_SALARY_TYPES = {choice for choice, _label in CompensationPlan.SalaryType.choices}
_EMPLOYMENT_TYPES = {choice for choice, _label in Employee.EmploymentType.choices}
_STATUSES = {choice for choice, _label in Employee.Status.choices}


class EmployeeLoader(BaseLoader):
    entity_type = EMPLOYEE

    def load(self, record, resolver, *, dry_run):
        full_name = clean_str(record.full_name)
        if not full_name:
            raise LoaderError("Employee name is required.", code="missing_name")

        phone = clean_str(record.phone)
        instance = resolver.existing(Employee, self.entity_type, record.source_key)
        if instance is None and phone:
            instance = Employee.objects.filter(phone=phone).first()
        if instance is None:
            instance = Employee.objects.filter(full_name=full_name).first()
        action = UPDATED if instance is not None else CREATED
        if instance is None:
            instance = Employee()

        instance.full_name = full_name[:255]
        instance.phone = phone[:64]
        instance.email = clean_str(record.email)
        instance.job_title = clean_str(record.job_title)[:120]
        instance.department = clean_str(record.department)[:120]
        if record.employment_type in _EMPLOYMENT_TYPES:
            instance.employment_type = record.employment_type
        if record.status in _STATUSES:
            instance.status = record.status
        if record.hire_date is not None:
            instance.hire_date = record.hire_date
        instance.notes = clean_str(record.notes)
        # ``employee_number`` is auto-assigned; never matched on, never set.
        instance.save()
        resolver.remember(self.entity_type, record.source_key, instance)

        issues = self._compensation(instance, record)
        return LoadOutcome(action, instance.pk, issues)

    @staticmethod
    def _compensation(employee, record):
        if record.pay_amount is None:
            return []
        amount = to_decimal(record.pay_amount)
        if amount <= 0:
            return []
        pay_type = (
            record.pay_type
            if record.pay_type in _PAY_TYPES
            else CompensationPlan.PayType.MONTHLY_SALARY
        )
        salary_type = (
            record.salary_type
            if record.salary_type in _SALARY_TYPES
            else CompensationPlan.SalaryType.MONTHLY_FIXED
        )
        defaults = {
            "pay_type": pay_type,
            "salary_type": salary_type,
            "amount": amount,
        }
        if record.standard_daily_hours:
            hours = to_decimal(record.standard_daily_hours)
            if Decimal("0") < hours <= Decimal("24"):
                defaults["standard_daily_hours"] = hours
        if record.hire_date is not None:
            defaults["effective_from"] = record.hire_date
        # One current plan per employee: keyed on the employee alone, so a
        # re-import corrects the rate instead of stacking a second plan whose
        # effective date would silently win.
        CompensationPlan.objects.update_or_create(employee=employee, defaults=defaults)
        return []


class PayrollRunLoader(BaseLoader):
    entity_type = PAYROLL_RUN

    def load(self, record, resolver, *, dry_run):
        issues: list[Issue] = []
        specs = []
        for line in record.lines:
            employee_pk = resolver.resolve(EMPLOYEE, line.employee_source_key)
            if employee_pk is None:
                issues.append(
                    Issue(
                        WARNING,
                        "unresolved_employee",
                        f"Payroll line references unknown employee "
                        f"{line.employee_source_key!r}; skipped.",
                        source_key=str(record.source_key),
                    )
                )
                continue
            specs.append((employee_pk, line))
        if not specs:
            raise LoaderError("Payroll run has no resolvable lines.", code="no_lines")
        if record.period_start is None or record.period_end is None:
            raise LoaderError("Payroll run has no period.", code="missing_period")

        run = resolver.existing(PayrollRun, self.entity_type, record.source_key)
        action = UPDATED if run is not None else CREATED
        if run is not None:
            run.lines.all().delete()
        else:
            run = PayrollRun()

        # Written past the document freeze on purpose: a submitted payroll run
        # is normally immutable, and this is a machine replaying one that was
        # paid months ago rather than a person editing it. Same rule the sale
        # and purchase loaders follow.
        with system_write():
            outcome = self._write(
                run, action=action, record=record, specs=specs, issues=issues
            )
        resolver.remember(self.entity_type, record.source_key, run)
        return outcome

    def _write(self, run, *, action, record, specs, issues):
        plans = {
            plan.employee_id: plan
            for plan in CompensationPlan.objects.filter(
                employee_id__in=[employee_pk for employee_pk, _line in specs]
            )
        }
        run.period_start = record.period_start
        run.period_end = record.period_end
        run.payment_date = record.payment_date or record.period_end
        run.notes = clean_str(record.notes)
        # Paid, months ago. ``status`` is derived from these two by
        # ``employees.documents.recompute_progress``, never assigned directly.
        run.doc_status = DocumentStatus.SUBMITTED
        run.approved_at = run.approved_at or timezone.now()
        run.status = PayrollRun.Status.PAID
        run.save()

        lines = []
        gross = additions = deductions = net = Decimal("0.00")
        for employee_pk, line in specs:
            line_gross = to_decimal(line.gross_amount).quantize(_MONEY)
            line_add = to_decimal(line.additions).quantize(_MONEY)
            line_ded = to_decimal(line.deductions).quantize(_MONEY)
            line_net = to_decimal(line.net_amount).quantize(_MONEY)
            if line_net == 0:
                line_net = (line_gross + line_add - line_ded).quantize(_MONEY)
            plan = plans.get(employee_pk)
            lines.append(
                PayrollLine(
                    payroll_run=run,
                    employee_id=employee_pk,
                    compensation_plan=plan,
                    description=clean_str(line.description)[:255],
                    units=Decimal("1.00"),
                    rate=line_gross,
                    gross_amount=line_gross,
                    manual_addition_amount=line_add,
                    manual_deduction_amount=line_ded,
                    additions_amount=line_add,
                    deductions_amount=line_ded,
                    net_amount=line_net,
                )
            )
            gross += line_gross
            additions += line_add
            deductions += line_ded
            net += line_net
        PayrollLine.objects.bulk_create(lines)

        run.gross_total = gross
        run.additions_total = additions
        run.deductions_total = deductions
        run.net_total = net
        run.save(
            update_fields=[
                "gross_total",
                "additions_total",
                "deductions_total",
                "net_total",
                "updated_at",
            ]
        )
        return LoadOutcome(action, run.pk, issues)
