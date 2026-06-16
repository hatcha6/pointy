from django.contrib import admin

from .models import PriceCheckerDevice, PriceCheckEvent


@admin.register(PriceCheckerDevice)
class PriceCheckerDeviceAdmin(admin.ModelAdmin):
    list_display = (
        "name",
        "identifier",
        "driver",
        "transport",
        "address",
        "status",
        "arabic_support",
        "discovery_method",
        "last_seen_at",
    )
    list_filter = ("transport", "status", "driver", "arabic_support", "discovery_method")
    search_fields = ("name", "identifier", "address", "mac_address", "location")
    readonly_fields = ("last_seen_at", "created_at", "updated_at")


@admin.register(PriceCheckEvent)
class PriceCheckEventAdmin(admin.ModelAdmin):
    list_display = (
        "barcode",
        "result",
        "product_name",
        "final_price",
        "device_identifier",
        "source_address",
        "created_at",
    )
    list_filter = ("result",)
    search_fields = ("barcode", "product_name", "device_identifier")
    readonly_fields = [field.name for field in PriceCheckEvent._meta.fields]

    def has_add_permission(self, request):
        return False
