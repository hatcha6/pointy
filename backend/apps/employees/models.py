from decimal import Decimal

from django.conf import settings
from django.core.exceptions import ValidationError
from django.core.validators import MaxValueValidator, MinValueValidator
from django.db import models
from django.db.models import Q, Sum
from django.utils.crypto import get_random_string
from django.utils import timezone

from apps.core.models import TimeStampedModel
from apps.documents.guards import DocumentQuerySetMixin
from apps.documents.models import DocumentMixin

# Overtime is paid at the hourly wage times this multiplier unless an employee's
# compensation plan overrides it (e.g. 1.50 for time-and-a-half).
DEFAULT_OVERTIME_MULTIPLIER = Decimal("1.50")
DEFAULT_STANDARD_DAILY_HOURS = Decimal("8.00")

# Distinguishes "primed with no payroll lines" from "never primed" -- a real
# payroll total of zero must not be mistaken for a cache miss.
_UNPRIMED = object()


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
    # The employee's own account as a customer of the shop — what a cashier
    # picks at the till when a member of staff takes goods home. Whatever that
    # account owes on آجل invoices is deducted from the next payroll run (see
    # ``apps.employees.staff_purchases``). Created with the employee, so every
    # member of staff can buy on payroll without anyone setting it up.
    customer = models.OneToOneField(
        "customers.Customer",
        on_delete=models.SET_NULL,
        related_name="staff_employee",
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

    # Both properties below are serialized on every row of ``employee-list`` and
    # each cost their own query per row. ``EmployeeViewSet.get_queryset`` fills
    # the caches they read first -- ``_active_plans`` from a filtered prefetch,
    # ``_payroll_total_amount`` from a subquery on the page query -- so a whole
    # page costs nothing extra. Only the *fetching* is batched: the selection
    # rule lives once in ``CompensationPlan.active_as_of`` and the rounding
    # stays here, so a primed employee and a cold one cannot disagree.

    @property
    def active_compensation_plan(self):
        primed = getattr(self, "_active_plans", None)
        if primed is not None:
            return primed[0] if primed else None
        return CompensationPlan.active_as_of(
            timezone.localdate(),
            self.compensation_plans.all(),
        ).first()

    @property
    def payroll_total(self):
        total = getattr(self, "_payroll_total_amount", _UNPRIMED)
        if total is _UNPRIMED:
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

    class SalaryType(models.TextChoices):
        MONTHLY_FIXED = "monthly_fixed", "Monthly fixed"
        WEEKLY_FIXED = "weekly_fixed", "Weekly fixed"
        DAILY_RATE = "daily_rate", "Daily rate"
        HOURLY_RATE = "hourly_rate", "Hourly rate"
        PER_SHIFT = "per_shift", "Per shift"
        SALES_COMMISSION_ONLY = "sales_commission_only", "Sales commission only"
        MONTHLY_FIXED_PLUS_SALES_COMMISSION = (
            "monthly_fixed_plus_sales_commission",
            "Monthly fixed plus sales commission",
        )
        # Operations commission pays a percentage of the value of the jobs
        # (repairs) the employee completed in the period, not their sales.
        OPERATIONS_COMMISSION_ONLY = (
            "operations_commission_only",
            "Operations commission only",
        )
        MONTHLY_FIXED_PLUS_OPERATIONS_COMMISSION = (
            "monthly_fixed_plus_operations_commission",
            "Monthly fixed plus operations commission",
        )
        CONTRACT_FIXED = "contract_fixed", "Contract fixed"
        CUSTOM_FIXED = "custom_fixed", "Custom fixed"

    class OperationsCommissionBase(models.TextChoices):
        # What the operations-commission percentage is applied to.
        APPROVED_PRICE = "approved_price", "Approved repair price"
        LABOR = "labor", "Labor only"
        ORDER_TOTAL = "order_total", "Invoiced order total"

    employee = models.ForeignKey(
        Employee,
        on_delete=models.CASCADE,
        related_name="compensation_plans",
    )
    pay_type = models.CharField(max_length=32, choices=PayType.choices)
    salary_type = models.CharField(
        max_length=48,
        choices=SalaryType.choices,
        blank=True,
        default="",
        db_index=True,
    )
    amount = models.DecimalField(
        max_digits=12,
        decimal_places=2,
        validators=[MinValueValidator(Decimal("0.00"))],
    )
    commission_percent = models.DecimalField(
        max_digits=5,
        decimal_places=2,
        default=Decimal("0.00"),
        validators=[
            MinValueValidator(Decimal("0.00")),
            MaxValueValidator(Decimal("100.00")),
        ],
    )
    # Only used by operations-commission plans: the value the percentage applies
    # to (the full approved price, labor only, or the invoiced order total).
    operations_commission_base = models.CharField(
        max_length=24,
        choices=OperationsCommissionBase.choices,
        default=OperationsCommissionBase.APPROVED_PRICE,
    )
    currency = models.CharField(max_length=8, default="LYD")
    expected_units_per_period = models.DecimalField(
        max_digits=8,
        decimal_places=2,
        default=Decimal("1.00"),
        validators=[MinValueValidator(Decimal("0.00"))],
    )
    overtime_multiplier = models.DecimalField(
        max_digits=4,
        decimal_places=2,
        default=DEFAULT_OVERTIME_MULTIPLIER,
        validators=[
            MinValueValidator(Decimal("0.00")),
            MaxValueValidator(Decimal("10.00")),
        ],
        help_text="Overtime pay rate as a multiple of the hourly wage (e.g. 1.50).",
    )
    standard_daily_hours = models.DecimalField(
        max_digits=4,
        decimal_places=2,
        default=DEFAULT_STANDARD_DAILY_HOURS,
        validators=[
            MinValueValidator(Decimal("0.00")),
            MaxValueValidator(Decimal("24.00")),
        ],
        help_text="Hours in a standard working day, used to derive the hourly wage.",
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
            models.Index(fields=["salary_type", "effective_from"]),
        ]
        constraints = []

    def __str__(self):
        return f"{self.employee} - {self.pay_type} {self.amount}"

    @classmethod
    def active_as_of(cls, today, queryset=None):
        """The "which plan is in force" rule, in one place.

        ``Employee.active_compensation_plan`` applies it to one employee's
        relation; ``EmployeeViewSet.get_queryset`` applies it to a whole page as
        a prefetch, so the per-row and the batched answer cannot drift apart.
        The ordering matters to both callers: it is what makes ``.first()`` and
        the prefetch's first-row-per-employee pick the same plan.
        """
        rows = cls.objects.all() if queryset is None else queryset
        return (
            rows.filter(is_active=True, effective_from__lte=today)
            .filter(Q(effective_to__isnull=True) | Q(effective_to__gte=today))
            .order_by("-effective_from", "-id")
        )

    @property
    def resolved_salary_type(self):
        if self.salary_type:
            return self.salary_type
        if self.pay_type == self.PayType.MONTHLY_SALARY:
            if Decimal(self.commission_percent or "0.00") > Decimal("0.00"):
                return self.SalaryType.MONTHLY_FIXED_PLUS_SALES_COMMISSION
            return self.SalaryType.MONTHLY_FIXED
        if (
            self.pay_type == self.PayType.COMMISSION
            and Decimal(self.amount or "0.00") == Decimal("0.00")
            and Decimal(self.commission_percent or "0.00") > Decimal("0.00")
        ):
            return self.SalaryType.SALES_COMMISSION_ONLY
        return ""

    @property
    def has_fixed_monthly_amount(self):
        return self.resolved_salary_type in {
            self.SalaryType.MONTHLY_FIXED,
            self.SalaryType.MONTHLY_FIXED_PLUS_SALES_COMMISSION,
            self.SalaryType.MONTHLY_FIXED_PLUS_OPERATIONS_COMMISSION,
            self.SalaryType.CONTRACT_FIXED,
            self.SalaryType.CUSTOM_FIXED,
        }

    @property
    def uses_expected_units(self):
        return self.resolved_salary_type in {
            self.SalaryType.WEEKLY_FIXED,
            self.SalaryType.DAILY_RATE,
            self.SalaryType.HOURLY_RATE,
            self.SalaryType.PER_SHIFT,
        }

    @property
    def uses_sales_commission(self):
        return self.resolved_salary_type in {
            self.SalaryType.SALES_COMMISSION_ONLY,
            self.SalaryType.MONTHLY_FIXED_PLUS_SALES_COMMISSION,
        }

    @property
    def uses_operations_commission(self):
        return self.resolved_salary_type in {
            self.SalaryType.OPERATIONS_COMMISSION_ONLY,
            self.SalaryType.MONTHLY_FIXED_PLUS_OPERATIONS_COMMISSION,
        }

    @property
    def is_automatic_monthly_salary(self):
        return self.resolved_salary_type in {
            *self.SalaryType.values,
        }

    def clean(self):
        if self.effective_to and self.effective_to < self.effective_from:
            raise ValidationError(
                {"effective_to": "Effective end cannot be before effective start."}
            )
        salary_type = self.resolved_salary_type
        if not salary_type:
            return
        amount = Decimal(self.amount or "0.00")
        commission_percent = Decimal(self.commission_percent or "0.00")
        errors = {}
        if salary_type in {
            self.SalaryType.SALES_COMMISSION_ONLY,
            self.SalaryType.OPERATIONS_COMMISSION_ONLY,
        }:
            if amount != Decimal("0.00"):
                errors["amount"] = "Commission-only salary must use a zero fixed amount."
            if commission_percent <= Decimal("0.00"):
                errors["commission_percent"] = (
                    "Commission-only salary requires a commission percentage greater than zero."
                )
        elif salary_type in {
            self.SalaryType.MONTHLY_FIXED_PLUS_SALES_COMMISSION,
            self.SalaryType.MONTHLY_FIXED_PLUS_OPERATIONS_COMMISSION,
        }:
            if amount <= Decimal("0.00"):
                errors["amount"] = (
                    "Monthly fixed plus commission salary requires an amount greater than zero."
                )
            if commission_percent <= Decimal("0.00"):
                errors["commission_percent"] = (
                    "Monthly fixed plus commission salary requires a commission percentage."
                )
        else:
            if amount <= Decimal("0.00"):
                errors["amount"] = "Compensation plan requires an amount greater than zero."
            if commission_percent != Decimal("0.00"):
                errors["commission_percent"] = (
                    "This compensation type cannot include a commission percentage."
                )
        if self.uses_expected_units and self.expected_units_per_period <= Decimal("0.00"):
            errors["expected_units_per_period"] = (
                "This compensation type requires expected units greater than zero."
            )
        if errors:
            raise ValidationError(errors)

    def amount_for_units(self, units):
        units = Decimal(units or "0.00")
        if self.resolved_salary_type in {
            self.SalaryType.SALES_COMMISSION_ONLY,
            self.SalaryType.OPERATIONS_COMMISSION_ONLY,
        }:
            return Decimal("0.00").quantize(self.MONEY_PLACES)
        if self.has_fixed_monthly_amount:
            return self.amount.quantize(self.MONEY_PLACES)
        if self.uses_expected_units:
            return (self.amount * units).quantize(self.MONEY_PLACES)
        if self.pay_type in {
            self.PayType.MONTHLY_SALARY,
            self.PayType.WEEKLY_SALARY,
            self.PayType.CONTRACT,
        }:
            return self.amount.quantize(self.MONEY_PLACES)
        return (self.amount * units).quantize(self.MONEY_PLACES)


class PayrollRunQuerySet(DocumentQuerySetMixin, models.QuerySet):
    pass


class PayrollRun(DocumentMixin, TimeStampedModel):
    MONEY_PLACES = Decimal("0.01")

    objects = PayrollRunQuerySet.as_manager()

    class Status(models.TextChoices):
        """Where the run has got to — approval and payment, not the document.

        Three meanings used to share this field. ``doc_status`` carries the
        document's own state now (a run is *submitted* when it is paid, because
        that is when money leaves), and this is derived from that plus the
        approval stamp beside it, by
        ``apps.employees.documents.recompute_progress`` and nowhere else. Every
        query that filters on ``paid`` keeps working, the money position
        included.
        """

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
    # The money date (apps.core.money_dates): the profit report and the money
    # position both filter paid runs by it.
    payment_date = models.DateField(blank=True, null=True, db_index=True)
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
    # The payroll dialect of ``cancelled_at``/``cancelled_by``, kept because
    # the API exposes them. Mirrored from the lifecycle's own columns rather
    # than written beside them, so the two cannot disagree.
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

    def _lines_for_recalculation(self):
        """Read the run's lines with the relations ``recalculate`` will touch.

        ``PayrollLine.recalculate`` reads ``compensation_plan`` (for the rate,
        the overtime multiplier and the standard daily hours) and walks
        ``adjustments``, so a bare ``self.lines.all()`` costs two extra queries
        per line -- on a 12-line run that is 24 queries every time a payroll run
        is approved, drafted or re-costed from attendance.

        Reuse the caller's prefetch cache when it is already warm (the payroll
        viewset prefetches both relations), otherwise fetch them in one pass.
        """
        if "lines" in getattr(self, "_prefetched_objects_cache", {}):
            return self.lines.all()
        return self.lines.select_related("compensation_plan").prefetch_related("adjustments")

    def recalculate(self, *, save_lines=False):
        gross_total = Decimal("0.00")
        additions_total = Decimal("0.00")
        deductions_total = Decimal("0.00")
        for line in self._lines_for_recalculation():
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
    absence_days = models.DecimalField(
        max_digits=6,
        decimal_places=2,
        default=Decimal("0.00"),
        validators=[MinValueValidator(Decimal("0.00"))],
    )
    absence_deduction_amount = models.DecimalField(
        max_digits=12,
        decimal_places=2,
        default=Decimal("0.00"),
        validators=[MinValueValidator(Decimal("0.00"))],
    )
    overtime_hours = models.DecimalField(
        max_digits=7,
        decimal_places=2,
        default=Decimal("0.00"),
        validators=[MinValueValidator(Decimal("0.00"))],
    )
    overtime_multiplier = models.DecimalField(
        max_digits=4,
        decimal_places=2,
        default=DEFAULT_OVERTIME_MULTIPLIER,
        validators=[MinValueValidator(Decimal("0.00"))],
    )
    overtime_amount = models.DecimalField(
        max_digits=12,
        decimal_places=2,
        default=Decimal("0.00"),
        validators=[MinValueValidator(Decimal("0.00"))],
    )
    raise_amount = models.DecimalField(
        max_digits=12,
        decimal_places=2,
        default=Decimal("0.00"),
        validators=[MinValueValidator(Decimal("0.00"))],
    )
    manual_addition_amount = models.DecimalField(
        max_digits=12,
        decimal_places=2,
        default=Decimal("0.00"),
        validators=[MinValueValidator(Decimal("0.00"))],
    )
    manual_deduction_amount = models.DecimalField(
        max_digits=12,
        decimal_places=2,
        default=Decimal("0.00"),
        validators=[MinValueValidator(Decimal("0.00"))],
    )
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
        period_days = self.period_days
        if period_days and self.absence_days > Decimal(period_days):
            raise ValidationError(
                {"absence_days": "Absence days cannot exceed the payroll period."}
            )

    @property
    def period_days(self):
        if not self.payroll_run_id:
            return None
        return (self.payroll_run.period_end - self.payroll_run.period_start).days + 1

    @property
    def absence_day_rate(self):
        period_days = self.period_days
        if not period_days or period_days <= 0:
            return Decimal("0.00").quantize(self.MONEY_PLACES)
        return (self.gross_amount / Decimal(period_days)).quantize(self.MONEY_PLACES)

    @property
    def standard_daily_hours(self):
        if self.compensation_plan_id:
            hours = Decimal(self.compensation_plan.standard_daily_hours or "0.00")
            if hours > Decimal("0.00"):
                return hours
        return DEFAULT_STANDARD_DAILY_HOURS

    @property
    def resolved_overtime_multiplier(self):
        if self.compensation_plan_id:
            return Decimal(
                self.compensation_plan.overtime_multiplier
                or DEFAULT_OVERTIME_MULTIPLIER
            )
        return Decimal(self.overtime_multiplier or DEFAULT_OVERTIME_MULTIPLIER)

    @property
    def overtime_hourly_rate(self):
        """The base (pre-multiplier) hourly wage used to value overtime."""
        plan = self.compensation_plan if self.compensation_plan_id else None
        if plan is not None and (
            plan.pay_type == CompensationPlan.PayType.HOURLY
            or plan.resolved_salary_type == CompensationPlan.SalaryType.HOURLY_RATE
        ):
            return Decimal(plan.amount or "0.00").quantize(self.MONEY_PLACES)
        daily_hours = self.standard_daily_hours
        if daily_hours <= Decimal("0.00"):
            return Decimal("0.00").quantize(self.MONEY_PLACES)
        return (self.absence_day_rate / daily_hours).quantize(self.MONEY_PLACES)

    def recalculate(self, *, save=False):
        if self.compensation_plan_id:
            self.rate = self.compensation_plan.amount
            self.gross_amount = self.compensation_plan.amount_for_units(self.units)
        else:
            self.gross_amount = (self.rate * self.units).quantize(self.MONEY_PLACES)

        self.absence_deduction_amount = (
            self.absence_day_rate * Decimal(self.absence_days or "0.00")
        ).quantize(self.MONEY_PLACES)
        # Overtime pays the hourly wage times the per-employee multiplier. The
        # multiplier is snapshotted onto the line so the figure is auditable.
        self.overtime_multiplier = self.resolved_overtime_multiplier
        self.overtime_amount = (
            Decimal(self.overtime_hours or "0.00")
            * self.overtime_hourly_rate
            * self.overtime_multiplier
        ).quantize(self.MONEY_PLACES)
        additions = (
            Decimal(self.raise_amount or "0.00")
            + Decimal(self.manual_addition_amount or "0.00")
            + Decimal(self.overtime_amount or "0.00")
        )
        deductions = Decimal(self.absence_deduction_amount or "0.00") + Decimal(
            self.manual_deduction_amount or "0.00"
        )
        staff_purchases = []
        if self.pk:
            for adjustment in self.adjustments.all():
                if adjustment.is_staff_purchase_deduction:
                    staff_purchases.append(adjustment)
                elif adjustment.direction == PayrollAdjustment.Direction.ADDITION:
                    additions += adjustment.amount
                else:
                    deductions += adjustment.amount
        # Staff purchases come out of whatever pay is left, so they are the first
        # thing to give way: an absence stamped from attendance, or a penalty
        # typed after the draft, shrinks them rather than making the line
        # negative. What they no longer cover stays owed on the invoice, and the
        # next run takes it.
        resized = _fit_staff_purchases(
            staff_purchases, room=self.gross_amount + additions - deductions
        )
        deductions += sum(
            (adjustment.amount for adjustment in staff_purchases), Decimal("0.00")
        )
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
                    "absence_deduction_amount",
                    "overtime_multiplier",
                    "overtime_amount",
                    "additions_amount",
                    "deductions_amount",
                    "net_amount",
                    "updated_at",
                ]
            )
            for adjustment in resized:
                if adjustment.amount > Decimal("0.00"):
                    adjustment.save(update_fields=["amount", "updated_at"])
                else:
                    adjustment.delete()


def _fit_staff_purchases(adjustments, *, room):
    """Shrink staff-purchase deductions until they fit in ``room``.

    The newest invoice gives way first: the deductions were allocated oldest
    invoice first, and the oldest debt is the one worth settling. Mutates the
    adjustments in place and returns the ones it changed, for the caller to
    persist. A deduction cut to nothing is left at zero rather than removed
    here, so the caller decides whether that is a delete.
    """
    excess = sum(
        (adjustment.amount for adjustment in adjustments), Decimal("0.00")
    ) - max(Decimal(room), Decimal("0.00"))
    resized = []
    for adjustment in sorted(adjustments, key=lambda row: row.pk or 0, reverse=True):
        if excess <= Decimal("0.00"):
            break
        cut = min(adjustment.amount, excess)
        adjustment.amount = (adjustment.amount - cut).quantize(PayrollLine.MONEY_PLACES)
        excess -= cut
        resized.append(adjustment)
    return resized


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
        LOAN = "loan", "Loan"
        ABSENCE = "absence", "Absence"
        PENALTY = "penalty", "Penalty"
        # What the employee bought on آجل with their own staff account. Written
        # by ``apps.employees.staff_purchases`` only — one row per invoice, so
        # the run says which invoices it is taking — and never by hand.
        STAFF_PURCHASE = "staff_purchase", "Staff purchase"
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
    loan = models.ForeignKey(
        "EmployeeLoan",
        on_delete=models.PROTECT,
        related_name="payroll_adjustments",
        blank=True,
        null=True,
    )
    # A staff-purchase deduction names the invoice it settles, the way a loan
    # instalment names its loan.
    order = models.ForeignKey(
        "sales.Order",
        on_delete=models.PROTECT,
        related_name="payroll_adjustments",
        blank=True,
        null=True,
    )
    # The payment that settled ``order`` when the run was paid. Empty until
    # then, and given back (cancelled) if the run is voided.
    settlement_payment = models.OneToOneField(
        "payments.Payment",
        on_delete=models.PROTECT,
        related_name="payroll_adjustment",
        blank=True,
        null=True,
    )
    notes = models.TextField(blank=True)

    class Meta:
        ordering = ["created_at", "id"]

    def __str__(self):
        return f"{self.direction} {self.amount}"

    @property
    def is_staff_purchase_deduction(self):
        return (
            self.adjustment_type == self.AdjustmentType.STAFF_PURCHASE
            and self.direction == self.Direction.DEDUCTION
        )


class EmployeeLoan(TimeStampedModel):
    MONEY_PLACES = Decimal("0.01")

    class Status(models.TextChoices):
        REQUESTED = "requested", "Requested"
        APPROVED = "approved", "Approved"
        REJECTED = "rejected", "Rejected"
        CANCELLED = "cancelled", "Cancelled"
        PAID = "paid", "Paid"

    employee = models.ForeignKey(
        Employee,
        on_delete=models.PROTECT,
        related_name="loans",
    )
    requested_by = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.SET_NULL,
        related_name="requested_employee_loans",
        blank=True,
        null=True,
    )
    reviewed_by = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.SET_NULL,
        related_name="reviewed_employee_loans",
        blank=True,
        null=True,
    )
    status = models.CharField(
        max_length=16,
        choices=Status.choices,
        default=Status.REQUESTED,
        db_index=True,
    )
    amount = models.DecimalField(
        max_digits=12,
        decimal_places=2,
        validators=[MinValueValidator(Decimal("0.01"))],
    )
    monthly_deduction = models.DecimalField(
        max_digits=12,
        decimal_places=2,
        validators=[MinValueValidator(Decimal("0.01"))],
    )
    outstanding_balance = models.DecimalField(
        max_digits=12,
        decimal_places=2,
        default=Decimal("0.00"),
        validators=[MinValueValidator(Decimal("0.00"))],
    )
    purpose = models.TextField(blank=True)
    review_notes = models.TextField(blank=True)
    reviewed_at = models.DateTimeField(blank=True, null=True)
    paid_at = models.DateTimeField(blank=True, null=True)

    class Meta:
        ordering = ["-created_at", "-id"]
        permissions = [
            ("approve_employeeloan", "Can approve employee loan"),
            ("reject_employeeloan", "Can reject employee loan"),
        ]
        indexes = [
            models.Index(fields=["employee", "status", "created_at"]),
            models.Index(fields=["status", "created_at"]),
        ]

    def __str__(self):
        return f"{self.employee} loan {self.amount}"

    @property
    def deducted_amount(self):
        return (self.amount - self.outstanding_balance).quantize(self.MONEY_PLACES)

    @property
    def is_open(self):
        return self.status == self.Status.APPROVED and self.outstanding_balance > 0

    def clean(self):
        if self.monthly_deduction > self.amount:
            raise ValidationError(
                {"monthly_deduction": "Monthly deduction cannot exceed loan amount."}
            )
        if self.outstanding_balance > self.amount:
            raise ValidationError(
                {"outstanding_balance": "Outstanding balance cannot exceed loan amount."}
            )
        if self.status == self.Status.PAID and self.outstanding_balance != Decimal("0.00"):
            raise ValidationError(
                {"outstanding_balance": "Paid loans must have no outstanding balance."}
            )


class EmployeeLoanPayment(TimeStampedModel):
    loan = models.ForeignKey(
        EmployeeLoan,
        on_delete=models.PROTECT,
        related_name="payments",
    )
    payroll_line = models.ForeignKey(
        PayrollLine,
        on_delete=models.PROTECT,
        related_name="loan_payments",
    )
    amount = models.DecimalField(
        max_digits=12,
        decimal_places=2,
        validators=[MinValueValidator(Decimal("0.01"))],
    )
    paid_at = models.DateTimeField(default=timezone.now)

    class Meta:
        ordering = ["-paid_at", "-id"]
        constraints = [
            models.UniqueConstraint(
                fields=["loan", "payroll_line"],
                name="unique_employee_loan_payment_per_payroll_line",
            )
        ]
        indexes = [
            models.Index(fields=["loan", "paid_at"]),
            models.Index(fields=["payroll_line"]),
        ]

    def __str__(self):
        return f"{self.loan} payment {self.amount}"
