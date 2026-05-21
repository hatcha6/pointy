from django.contrib import admin

from .models import ReportRun


@admin.register(ReportRun)
class ReportRunAdmin(admin.ModelAdmin):
    list_display = (
        "id",
        "report_type",
        "output_format",
        "status",
        "requested_by",
        "row_count",
        "created_at",
    )
    list_filter = ("report_type", "output_format", "status")
    search_fields = ("requested_by__username", "checksum")
    readonly_fields = (
        "created_at",
        "updated_at",
        "completed_at",
        "checksum",
        "payload",
    )
