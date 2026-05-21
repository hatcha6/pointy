from django.contrib import admin

from .models import (
    Product,
    ProductCategory,
    ProductVariant,
    VariantOption,
    VariantOptionValue,
)


class ProductVariantInline(admin.TabularInline):
    model = ProductVariant
    extra = 0
    fields = (
        "name",
        "sku",
        "barcode",
        "unit_price",
        "is_default",
        "is_active",
    )
    show_change_link = True


class VariantOptionValueInline(admin.TabularInline):
    model = VariantOptionValue
    extra = 0
    fields = ("name", "code", "display_order", "is_active")


@admin.register(ProductCategory)
class ProductCategoryAdmin(admin.ModelAdmin):
    list_display = ("name", "parent", "is_active")
    list_filter = ("is_active", "parent")
    search_fields = ("name", "description")
    autocomplete_fields = ("parent",)


@admin.register(Product)
class ProductAdmin(admin.ModelAdmin):
    list_display = (
        "name",
        "default_variant_sku",
        "variant_count",
        "quantity_on_hand",
        "is_active",
    )
    list_filter = ("is_active", "categories")
    search_fields = ("variants__sku", "variants__barcode", "name")
    filter_horizontal = ("categories",)
    inlines = (ProductVariantInline,)

    @admin.display(description="Default variant SKU", ordering="variants__sku")
    def default_variant_sku(self, product):
        variant = product.default_variant
        return "" if variant is None else variant.sku

    @admin.display(description="Variants")
    def variant_count(self, product):
        return product.variants.count()


@admin.register(ProductVariant)
class ProductVariantAdmin(admin.ModelAdmin):
    list_display = (
        "sku",
        "product",
        "display_name",
        "unit_price",
        "is_default",
        "is_active",
    )
    list_filter = ("is_active", "is_default", "product")
    search_fields = ("sku", "barcode", "name", "product__name")
    autocomplete_fields = ("product",)
    filter_horizontal = ("option_values",)


@admin.register(VariantOption)
class VariantOptionAdmin(admin.ModelAdmin):
    list_display = ("name", "code", "display_order", "is_active")
    list_filter = ("is_active",)
    search_fields = ("name", "code")
    inlines = (VariantOptionValueInline,)


@admin.register(VariantOptionValue)
class VariantOptionValueAdmin(admin.ModelAdmin):
    list_display = ("name", "option", "code", "display_order", "is_active")
    list_filter = ("is_active", "option")
    search_fields = ("name", "code", "option__name")
