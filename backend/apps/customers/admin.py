from django.contrib import admin

from .models import Customer


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
    )
    list_filter = ("is_active", "gender", "marketing_consent")
    search_fields = ("customer_number", "full_name", "phone", "email")
