from django.contrib import admin

from .models import AppliedDiscount, DiscountRedemption, DiscountRule


@admin.register(DiscountRule)
class DiscountRuleAdmin(admin.ModelAdmin):
    list_display = (
        "name",
        "channel",
        "application_type",
        "coupon_code",
        "scope",
        "value_type",
        "value",
        "priority",
        "exclusive",
        "is_active",
        "starts_at",
        "ends_at",
    )
    list_filter = (
        "channel",
        "application_type",
        "scope",
        "value_type",
        "exclusive",
        "is_active",
    )
    search_fields = ("name", "coupon_code", "description")
    filter_horizontal = (
        "products",
        "variants",
        "product_categories",
        "customers",
        "suppliers",
    )


@admin.register(AppliedDiscount)
class AppliedDiscountAdmin(admin.ModelAdmin):
    list_display = (
        "rule_name",
        "channel",
        "scope",
        "coupon_code",
        "discount_amount",
        "created_at",
    )
    list_filter = ("channel", "scope", "value_type")
    search_fields = ("rule_name", "coupon_code")
    readonly_fields = (
        "rule",
        "rule_name",
        "coupon_code",
        "channel",
        "scope",
        "value_type",
        "value",
        "priority",
        "exclusive",
        "source_subtotal",
        "discount_amount",
        "document_content_type",
        "document_object_id",
        "line_content_type",
        "line_object_id",
        "allocations",
        "metadata",
        "created_at",
        "updated_at",
    )


@admin.register(DiscountRedemption)
class DiscountRedemptionAdmin(admin.ModelAdmin):
    list_display = (
        "rule",
        "coupon_code",
        "channel",
        "customer",
        "supplier",
        "discount_amount",
        "created_at",
    )
    list_filter = ("channel", "rule")
    search_fields = ("coupon_code", "rule__name")
    readonly_fields = (
        "rule",
        "applied_discount",
        "coupon_code",
        "channel",
        "customer",
        "supplier",
        "discount_amount",
        "document_content_type",
        "document_object_id",
        "created_at",
        "updated_at",
    )
