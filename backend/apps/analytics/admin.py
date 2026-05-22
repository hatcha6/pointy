from django.contrib import admin

from .models import AnalyticsEvent


@admin.register(AnalyticsEvent)
class AnalyticsEventAdmin(admin.ModelAdmin):
    list_display = (
        "occurred_at",
        "name",
        "event_type",
        "severity",
        "source",
        "received_by",
        "risk_score",
    )
    list_filter = ("event_type", "severity", "source", "platform")
    search_fields = (
        "name",
        "session_id",
        "device_id",
        "installation_id",
        "trace_id",
        "entity_type",
        "entity_id",
        "received_by__username",
    )
    readonly_fields = ("created_at", "updated_at")
    autocomplete_fields = ("received_by",)
