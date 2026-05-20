from django.contrib import admin

from .models import (
    PurchaseLine,
    PurchaseOrder,
    PurchaseOrderAdjustment,
    PurchaseOrderAdjustmentReplacementLine,
    PurchaseReceipt,
    PurchaseReceiptLine,
    Supplier,
    SupplierCredit,
    SupplierPayment,
)


@admin.register(Supplier)
class SupplierAdmin(admin.ModelAdmin):
    list_display = ("name", "contact_name", "phone", "email", "is_active")
    list_filter = ("is_active",)
    search_fields = ("name", "contact_name", "phone", "email", "address")


class PurchaseLineInline(admin.TabularInline):
    model = PurchaseLine
    extra = 0
    readonly_fields = (
        "allocated_landed_cost",
        "landed_unit_cost",
        "effective_unit_cost",
    )


class PurchaseReceiptLineInline(admin.TabularInline):
    model = PurchaseReceiptLine
    extra = 0
    readonly_fields = (
        "purchase_line",
        "product",
        "ordered_quantity",
        "outstanding_before",
        "accepted_quantity",
        "damaged_quantity",
        "cancelled_quantity",
        "expected_reduction_quantity",
        "over_received_quantity",
        "outstanding_after",
        "notes",
    )
    can_delete = False


class PurchaseOrderAdjustmentReplacementLineInline(admin.TabularInline):
    model = PurchaseOrderAdjustmentReplacementLine
    extra = 0
    readonly_fields = ("adjustment", "product", "quantity", "unit_cost")
    can_delete = False


@admin.register(PurchaseOrder)
class PurchaseOrderAdmin(admin.ModelAdmin):
    list_display = (
        "order_number",
        "supplier",
        "supplier_invoice_number",
        "supplier_invoice_date",
        "status",
        "subtotal",
        "landed_cost_total",
        "total",
        "due_date",
        "submitted_at",
        "received_at",
    )
    list_filter = ("status", "supplier")
    search_fields = ("order_number", "supplier__name", "supplier_invoice_number")
    inlines = [PurchaseLineInline]


@admin.register(PurchaseReceipt)
class PurchaseReceiptAdmin(admin.ModelAdmin):
    list_display = ("purchase_order", "received_at", "created_by")
    list_filter = ("received_at", "created_by")
    search_fields = ("purchase_order__order_number", "notes")
    inlines = [PurchaseReceiptLineInline]


@admin.register(PurchaseOrderAdjustment)
class PurchaseOrderAdjustmentAdmin(admin.ModelAdmin):
    list_display = (
        "purchase_order",
        "adjustment_type",
        "amount",
        "outbound_amount",
        "replacement_amount",
        "net_amount",
        "settlement_method",
        "created_by",
    )
    list_filter = ("adjustment_type", "settlement_method")
    search_fields = ("purchase_order__order_number", "reason")
    inlines = [PurchaseOrderAdjustmentReplacementLineInline]


@admin.register(SupplierPayment)
class SupplierPaymentAdmin(admin.ModelAdmin):
    list_display = (
        "supplier",
        "purchase_order",
        "method",
        "amount",
        "paid_at",
        "created_by",
    )
    list_filter = ("method", "supplier")
    search_fields = ("supplier__name", "purchase_order__order_number", "reference")


@admin.register(SupplierCredit)
class SupplierCreditAdmin(admin.ModelAdmin):
    list_display = (
        "supplier",
        "purchase_order",
        "adjustment",
        "amount",
        "remaining_amount",
        "status",
    )
    list_filter = ("status", "supplier")
    search_fields = ("supplier__name", "purchase_order__order_number", "reason")
