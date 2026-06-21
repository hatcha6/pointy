from django.contrib import admin

from .models import Customer, PaymentCard


@admin.register(Customer)
class CustomerAdmin(admin.ModelAdmin):
    list_display = (
        "customer_number",
        "full_name",
        "phone",
        "gender",
        "birthday",
        "marketing_consent",
        "is_active",
        "is_auto_created",
    )
    list_filter = ("is_active", "gender", "marketing_consent", "is_auto_created")
    search_fields = ("customer_number", "full_name", "phone", "email")


@admin.register(PaymentCard)
class PaymentCardAdmin(admin.ModelAdmin):
    list_display = (
        "masked_pan",
        "card_scheme",
        "label",
        "customer",
        "is_active",
        "last_seen_at",
    )
    list_filter = ("is_active", "card_scheme")
    search_fields = ("masked_pan", "label", "card_scheme", "customer__full_name")
    raw_id_fields = ("customer",)
    readonly_fields = ("fingerprint", "first_seen_at", "last_seen_at", "last_receipt_data")
