"""Changing how closely a product is tracked, and when that is allowed.

Turning tracking on or off is not a preference, it is a **re-labelling of
history**. A product that has held forty anonymous units for a year cannot
become a serialized product by declaration, because the forty identifiers it
should have had were never written down; and a product whose units are on the
shelf right now cannot stop being serialized, because the identifiers on those
articles would stop meaning anything the moment the next sale did not consume
one.

The same shape — and the same reasoning — as the valuation-method guard in
``ShopSettingsSerializer``: guarded, not forbidden, with the escape hatch being
an explicit *opening identification* run rather than an unchecked flag.

One softening is deliberate. ``serial → serial_batch`` **grandfathers**: the
units already in stock keep ``batch = NULL`` and appear on the missing-identifier
worklist, while every new receipt requires a lot. Refusing until history is
perfect would mean a pharmacy that starts with serials can never adopt lots,
which is the wrong answer to a shop that is trying to get *more* correct.
"""

from __future__ import annotations

from rest_framework import serializers

from .models import Product

#: Transitions that never need to ask about stock on hand.
#:
#: ``serial_batch → serial`` is free because nothing is unsaid: the lots simply
#: stop being required, and every allocation keeps naming the lot it named.
#: ``serial → serial_batch`` is the grandfathering case above. A mode to itself
#: is trivially allowed, which is what lets an unrelated product edit save
#: without proving anything about its stock.
ALWAYS_ALLOWED = {
    (Product.TrackingMode.SERIAL, Product.TrackingMode.SERIAL_BATCH),
    (Product.TrackingMode.SERIAL_BATCH, Product.TrackingMode.SERIAL),
}


def on_hand_quantity(product) -> "object":
    """How much of this product is anywhere, in base units."""
    from decimal import Decimal

    from django.db.models import Sum

    from apps.inventory.models import StockItem

    total = StockItem.objects.filter(variant__product=product).aggregate(
        total=Sum("quantity_on_hand")
    )["total"]
    return total or Decimal("0")


def live_unit_count(product) -> int:
    from apps.inventory.models import StockUnit

    return StockUnit.objects.filter(
        variant__product=product, status__in=StockUnit.LIVE_STATUSES
    ).count()


def assert_mode_change_allowed(product, new_mode):
    """Refuse a tracking-mode change that would re-label history.

    Raises the ordinary per-field 400 so a product form marks the field the user
    changed, rather than printing one red line under the whole dialog.
    """
    if product is None or product.pk is None:
        return
    current = product.tracking_mode
    if new_mode == current or (current, new_mode) in ALWAYS_ALLOWED:
        return

    if new_mode == Product.TrackingMode.QUANTITY:
        # Going back to a number in a bin. Refused while anything identified is
        # still on the shelf, because those identifiers would stop being
        # consumed and the units would outlive the stock they represent.
        if live_unit_count(product):
            raise serializers.ValidationError(
                {
                    "tracking_mode": (
                        "لا يمكن إيقاف التتبّع بينما توجد وحدات معرّفة في "
                        "المخزون. بِع أو اشطب الوحدات أولًا."
                    )
                }
            )
        if on_hand_quantity(product) > 0 and current in (
            Product.TrackingMode.BATCH,
            Product.TrackingMode.SERIAL_BATCH,
        ):
            raise serializers.ValidationError(
                {
                    "tracking_mode": (
                        "لا يمكن إيقاف تتبّع الدفعات بينما توجد كمية في "
                        "المخزون."
                    )
                }
            )
        return

    # Turning tracking *on*, or deepening it. Every one of these needs the
    # existing stock to be identified, and the only honest way to identify forty
    # anonymous units is for somebody to pick them up — which is what opening
    # identification is for.
    if on_hand_quantity(product) > 0:
        raise serializers.ValidationError(
            {
                "tracking_mode": (
                    "لا يمكن تفعيل التتبّع بينما توجد كمية في المخزون. "
                    "استخدم جرد التعريف الافتتاحي، أو غيّر الوضع عندما يكون "
                    "الرصيد صفرًا."
                )
            }
        )


__all__ = [
    "ALWAYS_ALLOWED",
    "assert_mode_change_allowed",
    "live_unit_count",
    "on_hand_quantity",
]
