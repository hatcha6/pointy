from django.contrib import admin

from .models import StockBatch, StockItem, StockMovement


@admin.register(StockItem)
class StockItemAdmin(admin.ModelAdmin):
    list_display = (
        "variant",
        "parent_product",
        "quantity_on_hand",
        "quantity_committed",
        "quantity_expected",
        "reorder_level",
        "updated_at",
    )
    search_fields = (
        "variant__sku",
        "variant__barcode",
        "variant__name",
        "variant__product__name",
    )

    @admin.display(ordering="variant__product__name", description="Product")
    def parent_product(self, stock_item):
        return stock_item.variant.product


@admin.register(StockMovement)
class StockMovementAdmin(admin.ModelAdmin):
    list_display = (
        "variant",
        "parent_product",
        "movement_type",
        "quantity",
        "on_hand_after",
        "committed_after",
        "expected_after",
        "created_at",
    )
    list_filter = ("movement_type",)
    search_fields = (
        "variant__sku",
        "variant__barcode",
        "variant__name",
        "variant__product__name",
        "note",
    )

    @admin.display(ordering="variant__product__name", description="Product")
    def parent_product(self, movement):
        return movement.variant.product


@admin.register(StockBatch)
class StockBatchAdmin(admin.ModelAdmin):
    list_display = (
        "variant",
        "parent_product",
        "expiry_date",
        "remaining_quantity",
        "received_quantity",
        "source_receipt_line",
        "created_at",
    )
    list_filter = ("expiry_date",)
    search_fields = (
        "variant__sku",
        "variant__barcode",
        "variant__name",
        "variant__product__name",
    )
    raw_id_fields = ("variant", "source_receipt_line")

    @admin.display(ordering="variant__product__name", description="Product")
    def parent_product(self, batch):
        return batch.variant.product
