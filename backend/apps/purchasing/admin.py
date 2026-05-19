from django.contrib import admin

from .models import PurchaseLine, PurchaseOrder, Supplier


@admin.register(Supplier)
class SupplierAdmin(admin.ModelAdmin):
    list_display = ("name", "contact_name", "phone", "email", "is_active")
    list_filter = ("is_active",)
    search_fields = ("name", "contact_name", "phone", "email", "address")


class PurchaseLineInline(admin.TabularInline):
    model = PurchaseLine
    extra = 0


@admin.register(PurchaseOrder)
class PurchaseOrderAdmin(admin.ModelAdmin):
    list_display = (
        "order_number",
        "supplier",
        "status",
        "subtotal",
        "total",
        "submitted_at",
        "received_at",
    )
    list_filter = ("status", "supplier")
    search_fields = ("order_number", "supplier__name", "supplier_reference")
    inlines = [PurchaseLineInline]
