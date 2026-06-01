from django.contrib import admin

from .models import BusinessNotification, BusinessNotificationUserState


@admin.register(BusinessNotification)
class BusinessNotificationAdmin(admin.ModelAdmin):
    list_display = (
        "code",
        "category",
        "severity",
        "status",
        "entity_type",
        "entity_id",
        "last_seen_at",
        "resolved_at",
    )
    list_filter = ("status", "severity", "category", "code")
    search_fields = ("code", "fingerprint", "entity_type", "entity_id")


@admin.register(BusinessNotificationUserState)
class BusinessNotificationUserStateAdmin(admin.ModelAdmin):
    list_display = ("notification", "user", "acknowledged_at", "snoozed_until")
    list_filter = ("acknowledged_at", "snoozed_until")
    search_fields = ("notification__code", "user__username")
