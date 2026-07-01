from django.contrib import admin

from .models import Conversation, ConversationMessage, StaffCommandNumber


@admin.register(StaffCommandNumber)
class StaffCommandNumberAdmin(admin.ModelAdmin):
    list_display = ("phone", "label", "is_active")
    list_filter = ("is_active",)
    search_fields = ("phone", "label")


class ConversationMessageInline(admin.TabularInline):
    model = ConversationMessage
    extra = 0
    readonly_fields = ("direction", "body", "outbound", "inbound", "author", "created_at")
    can_delete = False


@admin.register(Conversation)
class ConversationAdmin(admin.ModelAdmin):
    list_display = ("phone", "customer", "status", "unread_count", "last_message_at")
    list_filter = ("status",)
    search_fields = ("phone", "phone_raw", "customer__full_name")
    inlines = [ConversationMessageInline]


@admin.register(ConversationMessage)
class ConversationMessageAdmin(admin.ModelAdmin):
    list_display = ("conversation", "direction", "body", "created_at")
    list_filter = ("direction",)
    search_fields = ("body",)
