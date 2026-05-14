from django.contrib import admin

from .models import StockItem


@admin.register(StockItem)
class StockItemAdmin(admin.ModelAdmin):
    list_display = ("product", "quantity_on_hand", "reorder_level", "updated_at")
    search_fields = ("product__sku", "product__name")
