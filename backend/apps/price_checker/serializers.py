from rest_framework import serializers

from .drivers import get_driver
from .formatting import format_money
from .models import PriceCheckerDevice, PriceCheckEvent
from .pricing import PriceResult


class PriceCheckerDeviceSerializer(serializers.ModelSerializer):
    is_serving = serializers.BooleanField(read_only=True)

    class Meta:
        model = PriceCheckerDevice
        fields = (
            "id",
            "identifier",
            "name",
            "driver",
            "make",
            "model",
            "transport",
            "address",
            "port",
            "mac_address",
            "display_rows",
            "display_cols",
            "arabic_support",
            "encoding",
            "location",
            "status",
            "discovery_method",
            "is_serving",
            "last_seen_at",
            "settings",
            "created_at",
            "updated_at",
        )
        read_only_fields = (
            "discovery_method",
            "is_serving",
            "last_seen_at",
            "created_at",
            "updated_at",
        )

    def validate_driver(self, value):
        if get_driver(value) is None:
            raise serializers.ValidationError("Unknown price-checker driver.")
        return value


class PriceCheckEventSerializer(serializers.ModelSerializer):
    class Meta:
        model = PriceCheckEvent
        fields = (
            "id",
            "device",
            "device_identifier",
            "barcode",
            "result",
            "variant",
            "product_name",
            "original_price",
            "final_price",
            "discount_total",
            "currency",
            "source_address",
            "latency_ms",
            "created_at",
        )
        read_only_fields = fields


def price_result_payload(
    result: PriceResult,
    *,
    allow_arabic: bool = True,
    display_lines: list[str] | None = None,
) -> dict:
    """Display-ready JSON for a web kiosk (decimals as strings; RTL-safe)."""
    payload = {
        "found": result.found,
        "barcode": result.barcode,
        "in_stock": result.in_stock,
        "currency": format_money(None, allow_arabic=allow_arabic).split(" ", 1)[-1],
        "display_lines": display_lines or [],
    }
    if not result.found:
        return payload

    payload.update(
        {
            "product_name": result.product_name,
            "variant_name": result.variant_name,
            "sku": result.sku,
            "unit": result.unit,
            "original_price": f"{result.original_price:.2f}",
            "final_price": f"{result.final_price:.2f}",
            "discount_total": f"{result.discount_total:.2f}",
            "discount_percent": int(result.discount_percent),
            "has_discount": result.has_discount,
            "original_price_display": format_money(
                result.original_price, allow_arabic=allow_arabic
            ),
            "final_price_display": format_money(
                result.final_price, allow_arabic=allow_arabic
            ),
            "discounts": [
                {
                    "name": discount.name,
                    "value_type": discount.value_type,
                    "value": f"{discount.value:.2f}",
                    "amount": f"{discount.amount:.2f}",
                }
                for discount in result.discounts
            ],
        }
    )
    return payload
