from django.contrib import admin

from .models import StockItem, StockMovement


@admin.register(StockItem)
class StockItemAdmin(admin.ModelAdmin):
    list_display = (
        "product",
        "quantity_on_hand",
        "quantity_committed",
        "quantity_expected",
        "reorder_level",
        "updated_at",
    )
    search_fields = ("product__sku", "product__barcode", "product__name")


@admin.register(StockMovement)
class StockMovementAdmin(admin.ModelAdmin):
    list_display = (
        "product",
        "movement_type",
        "quantity",
        "on_hand_after",
        "committed_after",
        "expected_after",
        "created_at",
    )
    list_filter = ("movement_type",)
    search_fields = ("product__sku", "product__barcode", "product__name", "note")
