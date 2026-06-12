from django.contrib import admin

from .models import SalesChannel


@admin.register(SalesChannel)
class SalesChannelAdmin(admin.ModelAdmin):
    list_display = (
        "name",
        "slug",
        "channel_type",
        "is_active",
        "is_system",
        "api_key_prefix",
        "api_key_last_used_at",
    )
    list_filter = ("is_active", "channel_type", "is_system")
    search_fields = ("name", "slug", "api_key_prefix")
    readonly_fields = (
        "is_system",
        "api_key_prefix",
        "api_key_hash",
        "api_key_generated_at",
        "api_key_last_used_at",
        "created_at",
        "updated_at",
    )
