from django.contrib import admin

from .models import (
    PrinterProfile,
    PrintAgent,
    PrintAuditEvent,
    PrintJob,
    PrintJobEvent,
    PrintTemplate,
    PrintTemplateVersion,
)


class PrintTemplateVersionInline(admin.TabularInline):
    model = PrintTemplateVersion
    extra = 0
    readonly_fields = ("version_number", "status", "published_at", "created_at", "updated_at")


@admin.register(PrintTemplate)
class PrintTemplateAdmin(admin.ModelAdmin):
    list_display = ("slug", "name", "template_type", "is_active", "current_version")
    list_filter = ("template_type", "is_active")
    search_fields = ("slug", "name")
    inlines = [PrintTemplateVersionInline]


@admin.register(PrintTemplateVersion)
class PrintTemplateVersionAdmin(admin.ModelAdmin):
    list_display = ("template", "version_number", "status", "published_at", "created_by")
    list_filter = ("status", "template")
    search_fields = ("template__slug", "content")


@admin.register(PrinterProfile)
class PrinterProfileAdmin(admin.ModelAdmin):
    list_display = ("name", "printer_type", "is_default", "is_active")
    list_filter = ("printer_type", "is_default", "is_active")
    search_fields = ("name",)


@admin.register(PrintAgent)
class PrintAgentAdmin(admin.ModelAdmin):
    list_display = ("name", "identifier", "printer_profile", "is_active", "last_seen_at")
    list_filter = ("is_active", "printer_profile")
    search_fields = ("name", "identifier")


class PrintJobEventInline(admin.TabularInline):
    model = PrintJobEvent
    extra = 0
    readonly_fields = ("event_type", "user", "agent", "message", "metadata", "created_at")
    can_delete = False


@admin.register(PrintJob)
class PrintJobAdmin(admin.ModelAdmin):
    list_display = (
        "id",
        "job_type",
        "status",
        "order",
        "printer_profile",
        "attempts",
        "created_at",
    )
    list_filter = ("job_type", "status", "printer_profile")
    search_fields = ("idempotency_key", "order__receipt_number", "error_message")
    inlines = [PrintJobEventInline]


@admin.register(PrintJobEvent)
class PrintJobEventAdmin(admin.ModelAdmin):
    list_display = ("job", "event_type", "user", "agent", "created_at")
    list_filter = ("event_type",)
    search_fields = ("job__idempotency_key", "message")


@admin.register(PrintAuditEvent)
class PrintAuditEventAdmin(admin.ModelAdmin):
    list_display = (
        "document_number",
        "document_type",
        "action",
        "status",
        "user",
        "agent_identifier",
        "printer_name",
        "created_at",
    )
    list_filter = ("document_type", "action", "status")
    search_fields = (
        "document_number",
        "agent_identifier",
        "device_name",
        "printer_name",
        "message",
    )
    readonly_fields = ("created_at", "updated_at")
