from django.contrib import admin

from .models import Product, ProductCategory, ProductVariant, VariantOption, VariantOptionValue


@admin.register(ProductCategory)
class ProductCategoryAdmin(admin.ModelAdmin):
    list_display = ("name", "parent", "is_active")
    list_filter = ("is_active", "parent")
    search_fields = ("name", "description")
    autocomplete_fields = ("parent",)


@admin.register(Product)
class ProductAdmin(admin.ModelAdmin):
    list_display = ("sku", "name", "unit_price", "quantity_on_hand", "is_active")
    list_filter = ("is_active", "categories")
    search_fields = ("variants__sku", "variants__barcode", "name")
    filter_horizontal = ("categories",)


@admin.register(ProductVariant)
class ProductVariantAdmin(admin.ModelAdmin):
    list_display = ("sku", "product", "display_name", "unit_price", "is_default", "is_active")
    list_filter = ("is_active", "is_default", "product")
    search_fields = ("sku", "barcode", "name", "product__name")
    filter_horizontal = ("option_values",)


@admin.register(VariantOption)
class VariantOptionAdmin(admin.ModelAdmin):
    list_display = ("name", "code", "display_order", "is_active")
    list_filter = ("is_active",)
    search_fields = ("name", "code")


@admin.register(VariantOptionValue)
class VariantOptionValueAdmin(admin.ModelAdmin):
    list_display = ("name", "option", "code", "display_order", "is_active")
    list_filter = ("is_active", "option")
    search_fields = ("name", "code", "option__name")
