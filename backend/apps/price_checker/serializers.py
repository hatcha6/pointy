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
    image_url: str = "",
    lot_detail: dict | None = None,
) -> dict:
    """Display-ready JSON for a web kiosk (decimals as strings; RTL-safe).

    Every key this can publish is named in the ``KIOSK_*_KEYS`` sets below and
    asserted by name in a guard test (§13). ``lot_detail`` is the one
    staff-only block; the view passes it only to an authenticated reader who
    asked for it and may see lots.
    """
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
            "image_url": image_url,
            "availability": result.availability,
        }
    )
    if result.batch_id is not None or result.lot_code or result.lot_expiry:
        # What is printed on the pack, and nothing the shop knows about it:
        # not its supplier, not its cost, not why it was stopped.
        payload["lot"] = {
            "code": result.lot_code,
            "expiry_date": (
                result.lot_expiry.isoformat() if result.lot_expiry else None
            ),
        }
    if lot_detail is not None:
        payload["lot_detail"] = {
            key: lot_detail.get(key) for key in sorted(KIOSK_LOT_DETAIL_KEYS)
        }

    if not result.is_sellable:
        # A recalled or expired pack gets a safety notice, never a price. The
        # price is withheld from the payload rather than left for the client
        # to hide: a kiosk on last month's build reads ``final_price_display``
        # whatever ``availability`` says, and must find nothing there to quote.
        # ``in_stock`` goes false so that same old build at least says
        # «غير متوفّر» under the name.
        payload["in_stock"] = False
        return payload

    payload.update(
        {
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
    if result.stock_unit_id is not None:
        # §13: **cost never leaves the kiosk.** This block is written out by
        # hand, field by field, rather than serialized from the unit — the
        # kiosk is unauthenticated on the LAN, so there is no user for a
        # permission to mask, and a filtered view of the authenticated
        # serializer is one careless ``fields = "__all__"`` away from
        # publishing what the shop paid for every phone on its shelf to
        # anybody on the wifi. ``KIOSK_UNIT_KEYS`` below is asserted by name in
        # a guard test.
        payload["unit"] = {
            "code": result.unit_code,
            "attributes": [dict(row) for row in result.unit_attributes],
        }
    return payload


def lot_detail_for_staff(result: PriceResult) -> dict | None:
    """The lot's own state, for a staff reader: status, since when, and why.

    Read fresh rather than from the cached result — the staff view is the one
    asked "is this lot still stopped?", and a manager test-scanning a pack
    right after releasing it must see the release.
    """
    if result.batch_id is None:
        return None
    from apps.inventory.models import StockBatch

    batch = (
        StockBatch.objects.filter(pk=result.batch_id)
        .only(
            "id",
            "status",
            "is_locked",
            "quarantined_at",
            "quarantine_reason",
            "expiry_date",
        )
        .first()
    )
    if batch is None:
        return None
    return {
        "batch_id": batch.pk,
        "status": batch.status,
        "is_locked": batch.is_locked,
        "quarantined_at": (
            batch.quarantined_at.isoformat() if batch.quarantined_at else None
        ),
        "quarantine_reason": batch.quarantine_reason,
        "expiry_date": batch.expiry_date.isoformat() if batch.expiry_date else None,
    }


#: Every key the lookup may publish, by case. Named here so a guard test can
#: assert the response's key set rather than trusting that nobody widened a
#: serializer (§13). Not one of them is a cost, a supplier or a consignment
#: term — and a recalled pack's response carries no price key at all.
KIOSK_BASE_KEYS = frozenset(
    {"found", "barcode", "in_stock", "currency", "display_lines"}
)
KIOSK_FOUND_KEYS = KIOSK_BASE_KEYS | frozenset(
    {"product_name", "variant_name", "sku", "unit", "image_url", "availability"}
)
KIOSK_PRICE_KEYS = frozenset(
    {
        "original_price",
        "final_price",
        "discount_total",
        "discount_percent",
        "has_discount",
        "original_price_display",
        "final_price_display",
        "discounts",
    }
)
#: Every key the kiosk may ever publish about one identified article.
KIOSK_UNIT_KEYS = frozenset({"code", "attributes"})
KIOSK_UNIT_ATTRIBUTE_KEYS = frozenset({"key", "label", "value"})
#: About the lot a scan named: only what is printed on the pack itself.
KIOSK_LOT_KEYS = frozenset({"code", "expiry_date"})
#: Staff only — ``?staff=1`` from an authenticated reader holding
#: ``inventory.view_stockbatch``. Never sent to a kiosk.
KIOSK_LOT_DETAIL_KEYS = frozenset(
    {
        "batch_id",
        "status",
        "is_locked",
        "quarantined_at",
        "quarantine_reason",
        "expiry_date",
    }
)
