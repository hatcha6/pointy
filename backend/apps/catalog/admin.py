from django.contrib import admin

from .models import Product, ProductCategory


@admin.register(ProductCategory)
class ProductCategoryAdmin(admin.ModelAdmin):
    list_display = ("name", "parent", "is_active")
    list_filter = ("is_active", "parent")
    search_fields = ("name", "description")
    autocomplete_fields = ("parent",)


@admin.register(Product)
class ProductAdmin(admin.ModelAdmin):
    list_display = ("sku", "name", "unit_price", "is_active")
    list_filter = ("is_active", "categories")
    search_fields = ("sku", "barcode", "name")
    filter_horizontal = ("categories",)
