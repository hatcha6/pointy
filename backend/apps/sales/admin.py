from django.contrib import admin

from .models import Order, OrderLine, RegisterSession


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
