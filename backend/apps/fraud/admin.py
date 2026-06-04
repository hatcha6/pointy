from django.contrib import admin

from .models import FraudFinding


@admin.register(FraudFinding)
class FraudFindingAdmin(admin.ModelAdmin):
    list_display = (
        "rule_code",
        "target_user",
        "risk_score",
        "severity",
        "status",
        "last_detected_at",
        "resolved_at",
    )
    list_filter = ("status", "severity", "rule_code")
    search_fields = (
        "fingerprint",
        "rule_code",
        "target_user__username",
        "target_user_label",
        "entity_type",
        "entity_id",
    )
    readonly_fields = (
        "created_at",
        "updated_at",
        "first_detected_at",
        "last_detected_at",
        "occurrence_count",
    )
    autocomplete_fields = ("target_user",)

