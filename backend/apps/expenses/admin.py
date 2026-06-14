from django.contrib import admin

from .models import Expense, ExpenseCategory


@admin.register(ExpenseCategory)
class ExpenseCategoryAdmin(admin.ModelAdmin):
    list_display = ("name", "display_order", "is_active")
    list_filter = ("is_active",)
    search_fields = ("name",)
    ordering = ("display_order", "name")


@admin.register(Expense)
class ExpenseAdmin(admin.ModelAdmin):
    list_display = (
        "description",
        "category",
        "amount",
        "payment_method",
        "spent_at",
        "created_by",
    )
    list_filter = ("payment_method", "category", "spent_at")
    search_fields = ("description", "reference")
    autocomplete_fields = ("category",)
    date_hierarchy = "spent_at"
