from django.contrib import admin

from .models import Order, OrderLine, RegisterCashMovement, RegisterSession


@admin.register(RegisterSession)
class RegisterSessionAdmin(admin.ModelAdmin):
    list_display = (
        "session_number",
        "owner_key",
        "status",
        "opening_cash",
        "closing_cash",
        "opened_at",
        "closed_at",
    )
    list_filter = ("status",)
    search_fields = ("owner_key", "owner__username")


@admin.register(RegisterCashMovement)
class RegisterCashMovementAdmin(admin.ModelAdmin):
    list_display = (
        "register_session",
        "movement_type",
        "amount",
        "created_by",
        "created_at",
    )
    list_filter = ("movement_type", "register_session__status")
    search_fields = (
        "register_session__owner_key",
        "register_session__owner__username",
        "created_by__username",
        "reason",
    )


class OrderLineInline(admin.TabularInline):
    model = OrderLine
    extra = 0


@admin.register(Order)
class OrderAdmin(admin.ModelAdmin):
    list_display = (
        "receipt_number",
        "status",
        "register_session",
        "subtotal",
        "total",
        "created_at",
    )
    list_filter = ("status", "register_session__status")
    search_fields = ("receipt_number", "register_session__owner_key")
    inlines = [OrderLineInline]
