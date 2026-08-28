from django.contrib import admin

from .models import MoneyAccount, MoneyCount, MoneyTransfer


@admin.register(MoneyAccount)
class MoneyAccountAdmin(admin.ModelAdmin):
    list_display = ("name", "kind", "is_default", "is_active", "opening_balance")
    list_filter = ("kind", "is_active", "is_default")
    search_fields = ("name", "bank_name", "account_number")


@admin.register(MoneyTransfer)
class MoneyTransferAdmin(admin.ModelAdmin):
    list_display = ("moved_at", "from_account", "to_account", "amount")
    list_filter = ("moved_at",)


@admin.register(MoneyCount)
class MoneyCountAdmin(admin.ModelAdmin):
    list_display = ("counted_at", "account", "counted_amount", "expected_amount", "variance")
    list_filter = ("account",)
