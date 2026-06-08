from django.contrib import admin

from .models import (
    CompensationPlan,
    Employee,
    EmployeeLoan,
    EmployeeLoanPayment,
    PayrollAdjustment,
    PayrollLine,
    PayrollRun,
)


class CompensationPlanInline(admin.TabularInline):
    model = CompensationPlan
    extra = 0


@admin.register(Employee)
class EmployeeAdmin(admin.ModelAdmin):
    list_display = (
        "employee_number",
        "full_name",
        "job_title",
        "department",
        "employment_type",
        "status",
        "hire_date",
        "user",
    )
    list_filter = ("status", "employment_type", "department")
    search_fields = ("employee_number", "full_name", "phone", "email", "job_title")
    inlines = [CompensationPlanInline]


@admin.register(CompensationPlan)
class CompensationPlanAdmin(admin.ModelAdmin):
    list_display = (
        "employee",
        "salary_type",
        "pay_type",
        "amount",
        "commission_percent",
        "currency",
        "effective_from",
        "is_active",
    )
    list_filter = ("salary_type", "pay_type", "is_active", "currency")
    search_fields = ("employee__full_name", "employee__employee_number", "notes")


class EmployeeLoanPaymentInline(admin.TabularInline):
    model = EmployeeLoanPayment
    extra = 0
    readonly_fields = ("paid_at",)


@admin.register(EmployeeLoan)
class EmployeeLoanAdmin(admin.ModelAdmin):
    list_display = (
        "employee",
        "status",
        "amount",
        "monthly_deduction",
        "outstanding_balance",
        "requested_by",
        "reviewed_by",
    )
    list_filter = ("status", "created_at", "reviewed_at")
    search_fields = (
        "employee__full_name",
        "employee__employee_number",
        "requested_by__username",
        "purpose",
        "review_notes",
    )
    readonly_fields = ("paid_at",)
    inlines = [EmployeeLoanPaymentInline]


class PayrollAdjustmentInline(admin.TabularInline):
    model = PayrollAdjustment
    extra = 0


class PayrollLineInline(admin.TabularInline):
    model = PayrollLine
    extra = 0
    readonly_fields = (
        "absence_deduction_amount",
        "gross_amount",
        "additions_amount",
        "deductions_amount",
        "net_amount",
    )


@admin.register(PayrollRun)
class PayrollRunAdmin(admin.ModelAdmin):
    list_display = (
        "run_number",
        "status",
        "period_start",
        "period_end",
        "payment_date",
        "gross_total",
        "additions_total",
        "deductions_total",
        "net_total",
    )
    list_filter = ("status", "period_start", "period_end")
    search_fields = ("run_number", "notes", "lines__employee__full_name")
    inlines = [PayrollLineInline]


@admin.register(PayrollLine)
class PayrollLineAdmin(admin.ModelAdmin):
    list_display = (
        "payroll_run",
        "employee",
        "units",
        "rate",
        "absence_days",
        "raise_amount",
        "net_amount",
    )
    list_filter = (
        "payroll_run__status",
        "compensation_plan__salary_type",
        "compensation_plan__pay_type",
    )
    search_fields = ("employee__full_name", "employee__employee_number", "description")
    inlines = [PayrollAdjustmentInline]
