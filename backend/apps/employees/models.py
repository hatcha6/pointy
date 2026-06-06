from decimal import Decimal

from django.conf import settings
from django.core.exceptions import ValidationError
from django.core.validators import MinValueValidator
from django.db import models
from django.db.models import Q, Sum
from django.utils.crypto import get_random_string
from django.utils import timezone

from apps.core.models import TimeStampedModel


class Employee(TimeStampedModel):
    class Status(models.TextChoices):
        ACTIVE = "active", "Active"
        ON_LEAVE = "on_leave", "On leave"
        INACTIVE = "inactive", "Inactive"
        TERMINATED = "terminated", "Terminated"

    class EmploymentType(models.TextChoices):
        FULL_TIME = "full_time", "Full time"
        PART_TIME = "part_time", "Part time"
        CONTRACTOR = "contractor", "Contractor"
        SEASONAL = "seasonal", "Seasonal"
        INTERN = "intern", "Intern"
        OTHER = "other", "Other"

    employee_number = models.CharField(max_length=32, unique=True, blank=True)
    full_name = models.CharField(max_length=255)
    phone = models.CharField(max_length=64, blank=True)
    email = models.EmailField(blank=True)
    job_title = models.CharField(max_length=120, blank=True)
    department = models.CharField(max_length=120, blank=True)
    employment_type = models.CharField(
        max_length=24,
        choices=EmploymentType.choices,
        default=EmploymentType.FULL_TIME,
    )
    status = models.CharField(
        max_length=24,
        choices=Status.choices,
        default=Status.ACTIVE,
        db_index=True,
    )
    hire_date = models.DateField(default=timezone.localdate)
    termination_date = models.DateField(blank=True, null=True)
    user = models.OneToOneField(
        settings.AUTH_USER_MODEL,
        on_delete=models.SET_NULL,
        related_name="employee_profile",
        blank=True,
        null=True,
    )
    emergency_contact_name = models.CharField(max_length=255, blank=True)
    emergency_contact_phone = models.CharField(max_length=64, blank=True)
    notes = models.TextField(blank=True)

    class Meta:
        ordering = ["full_name", "employee_number"]
        indexes = [
            models.Index(fields=["status", "full_name"]),
            models.Index(fields=["department", "job_title"]),
        ]

    def __str__(self):
        return self.display_name

    def save(self, *args, **kwargs):
        if not self.employee_number:
            self.employee_number = f"E{timezone.now():%Y%m%d%H%M%S}{get_random_string(4).upper()}"
        return super().save(*args, **kwargs)

    @property
    def display_name(self):
        return self.full_name or self.employee_number

    @property
    def has_system_access(self):
        return self.user_id is not None

    @property
    def active_compensation_plan(self):
        today = timezone.localdate()
        return (
            self.compensation_plans.filter(
                effective_from__lte=today,
            )
            .filter(Q(effective_to__isnull=True) | Q(effective_to__gte=today))
            .order_by("-effective_from", "-id")
            .first()
        )

    @property
    def payroll_total(self):
        total = self.payroll_lines.exclude(
            payroll_run__status=PayrollRun.Status.VOID,
        ).aggregate(total=Sum("net_amount"))["total"]
        return (total or Decimal("0.00")).quantize(Decimal("0.01"))

    def clean(self):
        if self.termination_date and self.termination_date < self.hire_date:
            raise ValidationError(
                {"termination_date": "Termination date cannot be before hire date."}
            )
        if self.status == self.Status.TERMINATED and self.termination_date is None:
            raise ValidationError(
                {"termination_date": "Termination date is required for terminated employees."}
            )


class CompensationPlan(TimeStampedModel):
    MONEY_PLACES = Decimal("0.01")

    class PayType(models.TextChoices):
        MONTHLY_SALARY = "monthly_salary", "Monthly salary"
        WEEKLY_SALARY = "weekly_salary", "Weekly salary"
        DAILY_RATE = "daily_rate", "Daily rate"
        HOURLY = "hourly", "Hourly"
        PER_SHIFT = "per_shift", "Per shift"
        COMMISSION = "commission", "Commission"
        CONTRACT = "contract", "Contract"
        OTHER = "other", "Other"

    employee = models.ForeignKey(
        Employee,
        on_delete=models.CASCADE,
        related_name="compensation_plans",
    )
    pay_type = models.CharField(max_length=32, choices=PayType.choices)
    amount = models.DecimalField(
        max_digits=12,
        decimal_places=2,
        validators=[MinValueValidator(Decimal("0.00"))],
    )
    currency = models.CharField(max_length=8, default="LYD")
    expected_units_per_period = models.DecimalField(
        max_digits=8,
        decimal_places=2,
        default=Decimal("1.00"),
        validators=[MinValueValidator(Decimal("0.00"))],
    )
    effective_from = models.DateField(default=timezone.localdate)
    effective_to = models.DateField(blank=True, null=True)
    notes = models.TextField(blank=True)
    is_active = models.BooleanField(default=True)

    class Meta:
        ordering = ["-effective_from", "-id"]
        indexes = [
            models.Index(fields=["employee", "is_active", "effective_from"]),
            models.Index(fields=["pay_type", "effective_from"]),
        ]
        constraints = [
            models.UniqueConstraint(
                fields=["employee", "effective_from", "pay_type"],
                name="unique_employee_pay_type_start",
            )
        ]

    def __str__(self):
        return f"{self.employee} - {self.pay_type} {self.amount}"

    def clean(self):
        if self.effective_to and self.effective_to < self.effective_from:
            raise ValidationError(
                {"effective_to": "Effective end cannot be before effective start."}
            )

    def amount_for_units(self, units):
        units = Decimal(units or "0.00")
        if self.pay_type in {
            self.PayType.MONTHLY_SALARY,
            self.PayType.WEEKLY_SALARY,
            self.PayType.CONTRACT,
        }:
            return self.amount.quantize(self.MONEY_PLACES)
        return (self.amount * units).quantize(self.MONEY_PLACES)


class PayrollRun(TimeStampedModel):
    MONEY_PLACES = Decimal("0.01")

    class Status(models.TextChoices):
        DRAFT = "draft", "Draft"
        APPROVED = "approved", "Approved"
        PAID = "paid", "Paid"
        VOID = "void", "Void"

    run_number = models.CharField(max_length=32, unique=True, blank=True)
    status = models.CharField(
        max_length=16,
        choices=Status.choices,
        default=Status.DRAFT,
        db_index=True,
    )
    period_start = models.DateField()
    period_end = models.DateField()
    payment_date = models.DateField(blank=True, null=True)
    notes = models.TextField(blank=True)
    gross_total = models.DecimalField(max_digits=12, decimal_places=2, default=0)
    additions_total = models.DecimalField(max_digits=12, decimal_places=2, default=0)
    deductions_total = models.DecimalField(max_digits=12, decimal_places=2, default=0)
    net_total = models.DecimalField(max_digits=12, decimal_places=2, default=0)
    approved_at = models.DateTimeField(blank=True, null=True)
    approved_by = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.SET_NULL,
        related_name="approved_payroll_runs",
        blank=True,
        null=True,
    )
    paid_at = models.DateTimeField(blank=True, null=True)
    paid_by = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.SET_NULL,
        related_name="paid_payroll_runs",
        blank=True,
        null=True,
    )
    voided_at = models.DateTimeField(blank=True, null=True)
    voided_by = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.SET_NULL,
        related_name="voided_payroll_runs",
        blank=True,
        null=True,
    )

    class Meta:
        ordering = ["-period_end", "-created_at"]
        permissions = [
            ("approve_payrollrun", "Can approve payroll run"),
            ("mark_payrollrun_paid", "Can mark payroll run paid"),
            ("void_payrollrun", "Can void payroll run"),
        ]
        indexes = [
            models.Index(fields=["status", "period_end"]),
            models.Index(fields=["period_start", "period_end"]),
        ]
        constraints = [
            models.CheckConstraint(
                condition=Q(period_end__gte=models.F("period_start")),
                name="payroll_run_period_end_after_start",
            ),
        ]

    def __str__(self):
        return self.run_number or f"Payroll {self.period_start} - {self.period_end}"

    def save(self, *args, **kwargs):
        if not self.run_number:
            self.run_number = f"PR{timezone.now():%Y%m%d%H%M%S}{get_random_string(4).upper()}"
        return super().save(*args, **kwargs)

    def clean(self):
        if self.period_end < self.period_start:
            raise ValidationError({"period_end": "Period end cannot be before start."})

    def recalculate(self, *, save_lines=False):
        gross_total = Decimal("0.00")
        additions_total = Decimal("0.00")
        deductions_total = Decimal("0.00")
        for line in self.lines.all():
            line.recalculate(save=save_lines)
            gross_total += line.gross_amount
            additions_total += line.additions_amount
            deductions_total += line.deductions_amount
        self.gross_total = gross_total.quantize(self.MONEY_PLACES)
        self.additions_total = additions_total.quantize(self.MONEY_PLACES)
        self.deductions_total = deductions_total.quantize(self.MONEY_PLACES)
        self.net_total = (
            self.gross_total + self.additions_total - self.deductions_total
        ).quantize(self.MONEY_PLACES)


class PayrollLine(TimeStampedModel):
    MONEY_PLACES = Decimal("0.01")

    payroll_run = models.ForeignKey(
        PayrollRun,
        on_delete=models.CASCADE,
        related_name="lines",
    )
    employee = models.ForeignKey(
        Employee,
        on_delete=models.PROTECT,
        related_name="payroll_lines",
    )
    compensation_plan = models.ForeignKey(
        CompensationPlan,
        on_delete=models.PROTECT,
        related_name="payroll_lines",
        blank=True,
        null=True,
    )
    description = models.CharField(max_length=255, blank=True)
    units = models.DecimalField(
        max_digits=8,
        decimal_places=2,
        default=Decimal("1.00"),
        validators=[MinValueValidator(Decimal("0.00"))],
    )
    rate = models.DecimalField(
        max_digits=12,
        decimal_places=2,
        default=Decimal("0.00"),
        validators=[MinValueValidator(Decimal("0.00"))],
    )
    gross_amount = models.DecimalField(max_digits=12, decimal_places=2, default=0)
    additions_amount = models.DecimalField(max_digits=12, decimal_places=2, default=0)
    deductions_amount = models.DecimalField(max_digits=12, decimal_places=2, default=0)
    net_amount = models.DecimalField(max_digits=12, decimal_places=2, default=0)
    notes = models.TextField(blank=True)

    class Meta:
        ordering = ["employee__full_name", "id"]
        constraints = [
            models.UniqueConstraint(
                fields=["payroll_run", "employee"],
                name="unique_employee_per_payroll_run",
            )
        ]

    def __str__(self):
        return f"{self.employee} - {self.net_amount}"

    def clean(self):
        if self.compensation_plan_id and self.compensation_plan.employee_id != self.employee_id:
            raise ValidationError(
                {"compensation_plan": "Compensation plan must belong to the employee."}
            )

    def recalculate(self, *, save=False):
        if self.compensation_plan_id:
            self.rate = self.compensation_plan.amount
            self.gross_amount = self.compensation_plan.amount_for_units(self.units)
        else:
            self.gross_amount = (self.rate * self.units).quantize(self.MONEY_PLACES)

        additions = Decimal("0.00")
        deductions = Decimal("0.00")
        if self.pk:
            for adjustment in self.adjustments.all():
                if adjustment.direction == PayrollAdjustment.Direction.ADDITION:
                    additions += adjustment.amount
                else:
                    deductions += adjustment.amount
        self.additions_amount = additions.quantize(self.MONEY_PLACES)
        self.deductions_amount = deductions.quantize(self.MONEY_PLACES)
        self.net_amount = (
            self.gross_amount + self.additions_amount - self.deductions_amount
        ).quantize(self.MONEY_PLACES)
        if self.net_amount < Decimal("0.00"):
            raise ValidationError({"net_amount": "Payroll line net amount cannot be negative."})
        if save:
            self.save(
                update_fields=[
                    "rate",
                    "gross_amount",
                    "additions_amount",
                    "deductions_amount",
                    "net_amount",
                    "updated_at",
                ]
            )


class PayrollAdjustment(TimeStampedModel):
    class Direction(models.TextChoices):
        ADDITION = "addition", "Addition"
        DEDUCTION = "deduction", "Deduction"

    class AdjustmentType(models.TextChoices):
        BONUS = "bonus", "Bonus"
        COMMISSION = "commission", "Commission"
        OVERTIME = "overtime", "Overtime"
        REIMBURSEMENT = "reimbursement", "Reimbursement"
        ADVANCE = "advance", "Advance"
        ABSENCE = "absence", "Absence"
        PENALTY = "penalty", "Penalty"
        OTHER = "other", "Other"

    payroll_line = models.ForeignKey(
        PayrollLine,
        on_delete=models.CASCADE,
        related_name="adjustments",
    )
    direction = models.CharField(max_length=16, choices=Direction.choices)
    adjustment_type = models.CharField(max_length=24, choices=AdjustmentType.choices)
    amount = models.DecimalField(
        max_digits=12,
        decimal_places=2,
        validators=[MinValueValidator(Decimal("0.00"))],
    )
    notes = models.TextField(blank=True)

    class Meta:
        ordering = ["created_at", "id"]

    def __str__(self):
        return f"{self.direction} {self.amount}"
