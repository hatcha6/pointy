from django.contrib import admin

from .models import IntegrationAccount


@admin.register(IntegrationAccount)
class IntegrationAccountAdmin(admin.ModelAdmin):
    list_display = ("provider", "username", "is_active", "balance", "last_checked_at")
    list_filter = ("provider", "is_active")
    search_fields = ("provider", "username", "account_label")
    readonly_fields = ("secrets_encrypted",)
