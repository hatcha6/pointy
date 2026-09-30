from django.contrib import admin

from .models import WalletSettings, WalletTopUp


@admin.register(WalletTopUp)
class WalletTopUpAdmin(admin.ModelAdmin):
    list_display = (
        "invoice_no",
        "amount",
        "status",
        "test_mode",
        "requested_by",
        "relay_created_at",
        "paid_at",
        "expense",
    )
    list_filter = ("status", "test_mode")
    search_fields = ("invoice_no", "relay_id", "provider_transaction_id")
    # The relay owns these rows; the admin only reads them.
    readonly_fields = [field.name for field in WalletTopUp._meta.fields]

    def has_add_permission(self, request):
        return False


@admin.register(WalletSettings)
class WalletSettingsAdmin(admin.ModelAdmin):
    list_display = ("record_topups_as_expenses", "expense_category", "updated_at")
