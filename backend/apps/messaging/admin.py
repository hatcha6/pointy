from django.contrib import admin

from .models import MessagingGateway, OutboundMessage


@admin.register(MessagingGateway)
class MessagingGatewayAdmin(admin.ModelAdmin):
    list_display = ("name", "provider", "channel", "is_default", "is_active", "last_error_at")
    list_filter = ("provider", "channel", "is_active")
    search_fields = ("name",)
    exclude = ("secrets_encrypted",)


@admin.register(OutboundMessage)
class OutboundMessageAdmin(admin.ModelAdmin):
    list_display = ("to_phone", "status", "consent_class", "gateway", "segments", "created_at")
    list_filter = ("status", "consent_class", "gateway")
    search_fields = ("to_phone", "to_phone_raw", "provider_message_id", "dedup_key")
    readonly_fields = tuple(f.name for f in OutboundMessage._meta.fields)
