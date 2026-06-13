from django.contrib import admin

from .models import Job, JobMaterial, JobStageEvent, WorkflowStage, WorkflowTemplate


class WorkflowStageInline(admin.TabularInline):
    model = WorkflowStage
    extra = 0


@admin.register(WorkflowTemplate)
class WorkflowTemplateAdmin(admin.ModelAdmin):
    list_display = ("name", "job_type", "is_active", "is_system")
    list_filter = ("job_type", "is_active", "is_system")
    inlines = [WorkflowStageInline]


class JobMaterialInline(admin.TabularInline):
    model = JobMaterial
    extra = 0
    readonly_fields = ("unit_cost", "unit_price", "consumed_at", "reversed_at")


class JobStageEventInline(admin.TabularInline):
    model = JobStageEvent
    extra = 0
    readonly_fields = ("from_stage", "to_stage", "changed_by", "note", "created_at")


@admin.register(Job)
class JobAdmin(admin.ModelAdmin):
    list_display = (
        "job_number",
        "job_type",
        "status",
        "current_stage",
        "customer",
        "assigned_to",
        "priority",
        "due_at",
    )
    list_filter = ("job_type", "status", "priority")
    search_fields = ("job_number", "customer__full_name")
    readonly_fields = ("job_number", "public_token", "created_at", "updated_at")
    inlines = [JobMaterialInline, JobStageEventInline]
