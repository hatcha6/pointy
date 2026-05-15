from django.contrib import admin

from .models import Product


@admin.register(Product)
class ProductAdmin(admin.ModelAdmin):
    list_display = ("sku", "name", "unit_price", "is_active")
    list_filter = ("is_active",)
    search_fields = ("sku", "barcode", "name")
