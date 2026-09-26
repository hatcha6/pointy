from django.contrib import admin

from .models import Payment


@admin.register(Payment)
class PaymentAdmin(admin.ModelAdmin):
    list_display = (
        "order",
        "method",
        "amount",
        "commission_percent",
        "commission_amount",
        "external_reference",
        "created_at",
    )
    list_filter = ("method",)
    search_fields = ("order__receipt_number", "external_reference")
    # Written by the cancellation alone; as a form field it would also render a
    # select over every payment the shop has ever taken.
    readonly_fields = ("reverses",)
