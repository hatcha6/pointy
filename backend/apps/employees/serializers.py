from decimal import Decimal

from django.contrib.auth import get_user_model
from django.db import transaction
from rest_framework import serializers

from .models import (
    CompensationPlan,
    Employee,
    EmployeeLoan,
    PayrollAdjustment,
    PayrollLine,
    PayrollRun,
)
from .services import request_employee_loan, save_payroll_run_with_lines


def money_string(value):
    return str((value or Decimal("0.00")).quantize(Decimal("0.01")))


class EmployeeSummarySerializer(serializers.ModelSerializer):
    user_username = serializers.CharField(source="user.username", read_only=True)
    has_system_access = serializers.BooleanField(read_only=True)

    class Meta:
        model = Employee
        fields = [
            "id",
            "employee_number",
            "full_name",
            "job_title",
            "department",
            "status",
            "user",
            "user_username",
            "has_system_access",
        ]
        read_only_fields = ["id", "user_username", "has_system_access"]


class CompensationPlanSerializer(serializers.ModelSerializer):
    employee_name = serializers.CharField(source="employee.full_name", read_only=True)
    pay_type = serializers.ChoiceField(
        choices=CompensationPlan.PayType.choices,
        required=False,
    )
    salary_type = serializers.ChoiceField(
        choices=CompensationPlan.SalaryType.choices,
        allow_blank=True,
        required=False,
    )
    amount = serializers.DecimalField(
        max_digits=12,
        decimal_places=2,
        min_value=Decimal("0.00"),
        required=False,
    )
    commission_percent = serializers.DecimalField(
        max_digits=5,
        decimal_places=2,
        min_value=Decimal("0.00"),
        max_value=Decimal("100.00"),
        required=False,
    )

    class Meta:
        model = CompensationPlan
        fields = [
            "id",
            "employee",
            "employee_name",
            "pay_type",
            "salary_type",
            "amount",
            "commission_percent",
            "currency",
            "expected_units_per_period",
            "effective_from",
            "notes",
            "is_active",
            "created_at",
            "updated_at",
        ]
        read_only_fields = [
            "id",
            "employee_name",
            "effective_from",
            "created_at",
            "updated_at",
        ]

    def validate(self, attrs):
        employee = attrs.get("employee", getattr(self.instance, "employee", None))
        effective_from = attrs.get(
            "effective_from",
            getattr(self.instance, "effective_from", None),
        )
        effective_to = attrs.get("effective_to", getattr(self.instance, "effective_to", None))
        if effective_to and effective_from and effective_to < effective_from:
            raise serializers.ValidationError(
                {"effective_to": "Effective end cannot be before effective start."}
            )
        if employee is not None and employee.status == Employee.Status.TERMINATED:
            raise serializers.ValidationError(
                {"employee": "Cannot create compensation for a terminated employee."}
            )
        self._validate_salary_type(attrs)
        return attrs

    def _validate_salary_type(self, attrs):
        salary_type = attrs.get(
            "salary_type",
            getattr(self.instance, "salary_type", ""),
        )
        amount = attrs.get("amount", getattr(self.instance, "amount", Decimal("0.00")))
        commission_percent = attrs.get(
            "commission_percent",
            getattr(self.instance, "commission_percent", Decimal("0.00")),
        )
        amount = Decimal(amount or "0.00")
        commission_percent = Decimal(commission_percent or "0.00")

        if not salary_type:
            salary_type = self._infer_salary_type(attrs, amount, commission_percent)
            if salary_type:
                attrs["salary_type"] = salary_type

        if not salary_type:
            errors = {}
            if self.instance is None and "pay_type" not in attrs:
                errors["pay_type"] = "This field is required for manual compensation plans."
            if self.instance is None and "amount" not in attrs:
                errors["amount"] = "This field is required for manual compensation plans."
            if errors:
                raise serializers.ValidationError(errors)
            return

        attrs["pay_type"] = self._pay_type_for_salary_type(salary_type)
        errors = {}
        if salary_type == CompensationPlan.SalaryType.SALES_COMMISSION_ONLY:
            if "amount" not in attrs and self.instance is None:
                attrs["amount"] = Decimal("0.00")
                amount = Decimal("0.00")
            if amount != Decimal("0.00"):
                errors["amount"] = "Commission-only salary must use a zero fixed amount."
            if commission_percent <= Decimal("0.00"):
                errors["commission_percent"] = (
                    "Commission-only salary requires a commission percentage greater than zero."
                )
        elif salary_type == CompensationPlan.SalaryType.MONTHLY_FIXED_PLUS_SALES_COMMISSION:
            if amount <= Decimal("0.00"):
                errors["amount"] = (
                    "Monthly fixed plus commission salary requires an amount greater than zero."
                )
            if commission_percent <= Decimal("0.00"):
                errors["commission_percent"] = (
                    "Monthly fixed plus commission salary requires a commission percentage."
                )
        else:
            if "commission_percent" not in attrs and self.instance is None:
                attrs["commission_percent"] = Decimal("0.00")
                commission_percent = Decimal("0.00")
            if amount <= Decimal("0.00"):
                errors["amount"] = "Compensation plan requires an amount greater than zero."
            if commission_percent != Decimal("0.00"):
                errors["commission_percent"] = (
                    "This compensation type cannot include a commission percentage."
                )

        expected_units = attrs.get(
            "expected_units_per_period",
            getattr(self.instance, "expected_units_per_period", Decimal("1.00")),
        )
        expected_units = Decimal(expected_units or "0.00")
        if (
            salary_type
            in {
                CompensationPlan.SalaryType.WEEKLY_FIXED,
                CompensationPlan.SalaryType.DAILY_RATE,
                CompensationPlan.SalaryType.HOURLY_RATE,
                CompensationPlan.SalaryType.PER_SHIFT,
            }
            and expected_units <= Decimal("0.00")
        ):
            errors["expected_units_per_period"] = (
                "This compensation type requires expected units greater than zero."
            )

        if errors:
            raise serializers.ValidationError(errors)

    def _infer_salary_type(self, attrs, amount, commission_percent):
        pay_type = attrs.get("pay_type", getattr(self.instance, "pay_type", ""))
        if pay_type == CompensationPlan.PayType.MONTHLY_SALARY:
            if commission_percent > Decimal("0.00"):
                return CompensationPlan.SalaryType.MONTHLY_FIXED_PLUS_SALES_COMMISSION
            return CompensationPlan.SalaryType.MONTHLY_FIXED
        if (
            pay_type == CompensationPlan.PayType.COMMISSION
            and amount == Decimal("0.00")
            and commission_percent > Decimal("0.00")
        ):
            return CompensationPlan.SalaryType.SALES_COMMISSION_ONLY
        return ""

    def _pay_type_for_salary_type(self, salary_type):
        return {
            CompensationPlan.SalaryType.MONTHLY_FIXED: CompensationPlan.PayType.MONTHLY_SALARY,
            CompensationPlan.SalaryType.WEEKLY_FIXED: CompensationPlan.PayType.WEEKLY_SALARY,
            CompensationPlan.SalaryType.DAILY_RATE: CompensationPlan.PayType.DAILY_RATE,
            CompensationPlan.SalaryType.HOURLY_RATE: CompensationPlan.PayType.HOURLY,
            CompensationPlan.SalaryType.PER_SHIFT: CompensationPlan.PayType.PER_SHIFT,
            CompensationPlan.SalaryType.SALES_COMMISSION_ONLY: CompensationPlan.PayType.COMMISSION,
            CompensationPlan.SalaryType.MONTHLY_FIXED_PLUS_SALES_COMMISSION: (
                CompensationPlan.PayType.MONTHLY_SALARY
            ),
            CompensationPlan.SalaryType.CONTRACT_FIXED: CompensationPlan.PayType.CONTRACT,
            CompensationPlan.SalaryType.CUSTOM_FIXED: CompensationPlan.PayType.OTHER,
        }.get(salary_type, CompensationPlan.PayType.MONTHLY_SALARY)

    @transaction.atomic
    def create(self, validated_data):
        plan = super().create(validated_data)
        self._deactivate_other_active_plans(plan)
        return plan

    @transaction.atomic
    def update(self, instance, validated_data):
        plan = super().update(instance, validated_data)
        self._deactivate_other_active_plans(plan)
        return plan

    def _deactivate_other_active_plans(self, plan):
        if not plan.is_active:
            return
        CompensationPlan.objects.filter(
            employee=plan.employee,
            is_active=True,
        ).exclude(pk=plan.pk).update(is_active=False)


class EmployeeSerializer(serializers.ModelSerializer):
    user_username = serializers.CharField(source="user.username", read_only=True)
    has_system_access = serializers.BooleanField(read_only=True)
    active_compensation_plan = serializers.SerializerMethodField()
    payroll_total = serializers.DecimalField(
        max_digits=12,
        decimal_places=2,
        read_only=True,
    )

    class Meta:
        model = Employee
        fields = [
            "id",
            "employee_number",
            "full_name",
            "phone",
            "email",
            "job_title",
            "department",
            "employment_type",
            "status",
            "hire_date",
            "termination_date",
            "user",
            "user_username",
            "has_system_access",
            "emergency_contact_name",
            "emergency_contact_phone",
            "notes",
            "active_compensation_plan",
            "payroll_total",
            "created_at",
            "updated_at",
        ]
        read_only_fields = [
            "id",
            "user_username",
            "has_system_access",
            "active_compensation_plan",
            "payroll_total",
            "created_at",
            "updated_at",
        ]
        extra_kwargs = {
            "user": {"queryset": get_user_model().objects.all(), "required": False},
        }

    def get_active_compensation_plan(self, employee):
        plan = employee.active_compensation_plan
        if plan is None:
            return None
        return CompensationPlanSerializer(plan).data

    def validate_employee_number(self, value):
        return value.strip().upper()

    def validate_full_name(self, value):
        value = value.strip()
        if not value:
            raise serializers.ValidationError("Employee name is required.")
        return value

    def validate(self, attrs):
        hire_date = attrs.get("hire_date", getattr(self.instance, "hire_date", None))
        termination_date = attrs.get(
            "termination_date",
            getattr(self.instance, "termination_date", None),
        )
        status = attrs.get("status", getattr(self.instance, "status", None))
        if hire_date and termination_date and termination_date < hire_date:
            raise serializers.ValidationError(
                {"termination_date": "Termination date cannot be before hire date."}
            )
        if status == Employee.Status.TERMINATED and termination_date is None:
            raise serializers.ValidationError(
                {"termination_date": "Termination date is required."}
            )
        user = attrs.get("user", getattr(self.instance, "user", None))
        if user is not None:
            existing = Employee.objects.filter(user=user)
            if self.instance is not None:
                existing = existing.exclude(pk=self.instance.pk)
            if existing.exists():
                raise serializers.ValidationError(
                    {"user": "This user is already linked to another employee."}
                )
        return attrs


class PayrollAdjustmentSerializer(serializers.ModelSerializer):
    class Meta:
        model = PayrollAdjustment
        fields = [
            "id",
            "direction",
            "adjustment_type",
            "amount",
            "loan",
            "notes",
            "created_at",
            "updated_at",
        ]
        read_only_fields = ["id", "loan", "created_at", "updated_at"]


class EmployeeLoanSerializer(serializers.ModelSerializer):
    employee_name = serializers.CharField(source="employee.full_name", read_only=True)
    employee_number = serializers.CharField(
        source="employee.employee_number",
        read_only=True,
    )
    requested_by_username = serializers.CharField(
        source="requested_by.username",
        read_only=True,
    )
    reviewed_by_username = serializers.CharField(
        source="reviewed_by.username",
        read_only=True,
    )
    deducted_amount = serializers.DecimalField(
        max_digits=12,
        decimal_places=2,
        read_only=True,
    )

    class Meta:
        model = EmployeeLoan
        fields = [
            "id",
            "employee",
            "employee_name",
            "employee_number",
            "requested_by",
            "requested_by_username",
            "reviewed_by",
            "reviewed_by_username",
            "status",
            "amount",
            "monthly_deduction",
            "outstanding_balance",
            "deducted_amount",
            "purpose",
            "review_notes",
            "reviewed_at",
            "paid_at",
            "created_at",
            "updated_at",
        ]
        read_only_fields = [
            "id",
            "employee_name",
            "employee_number",
            "requested_by",
            "requested_by_username",
            "reviewed_by",
            "reviewed_by_username",
            "status",
            "outstanding_balance",
            "deducted_amount",
            "review_notes",
            "reviewed_at",
            "paid_at",
            "created_at",
            "updated_at",
        ]

    def validate(self, attrs):
        amount = Decimal(attrs.get("amount", getattr(self.instance, "amount", "0.00")))
        monthly_deduction = Decimal(
            attrs.get(
                "monthly_deduction",
                getattr(self.instance, "monthly_deduction", "0.00"),
            )
        )
        if monthly_deduction > amount:
            raise serializers.ValidationError(
                {"monthly_deduction": "Monthly deduction cannot exceed loan amount."}
            )
        return attrs

    def create(self, validated_data):
        if "outstanding_balance" not in validated_data:
            validated_data["outstanding_balance"] = Decimal("0.00")
        return super().create(validated_data)


class EmployeeLoanRequestSerializer(serializers.Serializer):
    amount = serializers.DecimalField(
        max_digits=12,
        decimal_places=2,
        min_value=Decimal("0.01"),
    )
    monthly_deduction = serializers.DecimalField(
        max_digits=12,
        decimal_places=2,
        min_value=Decimal("0.01"),
    )
    purpose = serializers.CharField(
        required=False,
        allow_blank=True,
        trim_whitespace=True,
    )

    def validate(self, attrs):
        if attrs["monthly_deduction"] > attrs["amount"]:
            raise serializers.ValidationError(
                {"monthly_deduction": "Monthly deduction cannot exceed loan amount."}
            )
        return attrs

    def save(self, **kwargs):
        request = self.context["request"]
        return request_employee_loan(
            user=request.user,
            amount=self.validated_data["amount"],
            monthly_deduction=self.validated_data["monthly_deduction"],
            purpose=self.validated_data.get("purpose", ""),
        )


class EmployeeLoanReviewSerializer(serializers.Serializer):
    review_notes = serializers.CharField(
        required=False,
        allow_blank=True,
        trim_whitespace=True,
    )


class PayrollLineSerializer(serializers.ModelSerializer):
    employee_name = serializers.CharField(source="employee.full_name", read_only=True)
    employee_number = serializers.CharField(
        source="employee.employee_number",
        read_only=True,
    )
    pay_type = serializers.CharField(source="compensation_plan.pay_type", read_only=True)
    salary_type = serializers.CharField(
        source="compensation_plan.resolved_salary_type",
        read_only=True,
    )
    absence_day_rate = serializers.SerializerMethodField()
    adjustments = PayrollAdjustmentSerializer(many=True, required=False)

    class Meta:
        model = PayrollLine
        fields = [
            "id",
            "employee",
            "employee_name",
            "employee_number",
            "compensation_plan",
            "pay_type",
            "salary_type",
            "description",
            "units",
            "rate",
            "gross_amount",
            "absence_days",
            "absence_day_rate",
            "absence_deduction_amount",
            "raise_amount",
            "manual_addition_amount",
            "manual_deduction_amount",
            "additions_amount",
            "deductions_amount",
            "net_amount",
            "adjustments",
            "notes",
            "created_at",
            "updated_at",
        ]
        read_only_fields = [
            "id",
            "employee_name",
            "employee_number",
            "pay_type",
            "salary_type",
            "gross_amount",
            "absence_day_rate",
            "absence_deduction_amount",
            "additions_amount",
            "deductions_amount",
            "net_amount",
            "created_at",
            "updated_at",
        ]

    def validate(self, attrs):
        employee = attrs.get("employee", getattr(self.instance, "employee", None))
        plan = attrs.get("compensation_plan", getattr(self.instance, "compensation_plan", None))
        if plan is not None and employee is not None and plan.employee_id != employee.pk:
            raise serializers.ValidationError(
                {"compensation_plan": "Compensation plan must belong to the employee."}
            )
        return attrs

    def get_absence_day_rate(self, payroll_line):
        return money_string(payroll_line.absence_day_rate)


class PayrollLineAdjustmentUpdateSerializer(serializers.ModelSerializer):
    class Meta:
        model = PayrollLine
        fields = [
            "absence_days",
            "raise_amount",
            "manual_addition_amount",
            "manual_deduction_amount",
            "notes",
        ]

    def validate_absence_days(self, value):
        period_days = self.instance.period_days if self.instance is not None else None
        if period_days and value > Decimal(period_days):
            raise serializers.ValidationError(
                "Absence days cannot exceed the payroll period."
            )
        return value

    def update(self, instance, validated_data):
        for field, value in validated_data.items():
            setattr(instance, field, value)
        instance.full_clean()
        instance.recalculate(save=False)
        instance.save(
            update_fields=[
                "rate",
                "gross_amount",
                "absence_days",
                "absence_deduction_amount",
                "raise_amount",
                "manual_addition_amount",
                "manual_deduction_amount",
                "additions_amount",
                "deductions_amount",
                "net_amount",
                "notes",
                "updated_at",
            ]
        )
        return instance


class PayrollRunSerializer(serializers.ModelSerializer):
    lines = PayrollLineSerializer(many=True, required=False)
    line_count = serializers.SerializerMethodField()
    approved_by_username = serializers.CharField(
        source="approved_by.username",
        read_only=True,
    )
    paid_by_username = serializers.CharField(source="paid_by.username", read_only=True)

    class Meta:
        model = PayrollRun
        fields = [
            "id",
            "run_number",
            "status",
            "period_start",
            "period_end",
            "payment_date",
            "notes",
            "gross_total",
            "additions_total",
            "deductions_total",
            "net_total",
            "line_count",
            "lines",
            "approved_at",
            "approved_by",
            "approved_by_username",
            "paid_at",
            "paid_by",
            "paid_by_username",
            "voided_at",
            "created_at",
            "updated_at",
        ]
        read_only_fields = [
            "id",
            "status",
            "gross_total",
            "additions_total",
            "deductions_total",
            "net_total",
            "line_count",
            "approved_at",
            "approved_by",
            "approved_by_username",
            "paid_at",
            "paid_by",
            "paid_by_username",
            "voided_at",
            "created_at",
            "updated_at",
        ]

    def get_line_count(self, payroll_run):
        line_count = getattr(payroll_run, "line_count", None)
        if line_count is not None:
            return line_count
        return payroll_run.lines.count()

    def validate(self, attrs):
        period_start = attrs.get(
            "period_start",
            getattr(self.instance, "period_start", None),
        )
        period_end = attrs.get("period_end", getattr(self.instance, "period_end", None))
        if period_start and period_end and period_end < period_start:
            raise serializers.ValidationError(
                {"period_end": "Period end cannot be before start."}
            )
        return attrs

    def create(self, validated_data):
        lines_data = validated_data.pop("lines", None)
        return save_payroll_run_with_lines(
            lines_data=lines_data,
            request=self.context.get("request"),
            **validated_data,
        )

    def update(self, instance, validated_data):
        lines_data = validated_data.pop("lines", None)
        return save_payroll_run_with_lines(
            payroll_run=instance,
            lines_data=lines_data,
            request=self.context.get("request"),
            **validated_data,
        )
