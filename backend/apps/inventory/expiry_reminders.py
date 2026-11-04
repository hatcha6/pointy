"""Which owner-stated expiry reminders are due — the one answer alerts read.

A shop that bought its stock before dates were kept cannot name a lot's date, but
it knows roughly when the shelf goes off and wants to be told.
``ProductVariant.expiry_reminder_date`` is exactly that sentence and nothing more:
no lot carries it, no sale reads it, FEFO never sees it.

It speaks only for **stock nobody has dated**. On a counted product that is what
is on hand; on a lot-tracked one, the balances of lots without a date. A delivery
received with a real date raises its own alert and quiets nothing here, and when
the undated stock is gone the reminder stops by itself, so a date nobody cleared
cannot nag about an empty shelf.
"""

from __future__ import annotations

from decimal import Decimal

from django.db.models import Sum

from apps.catalog.models import Product, ProductVariant

from .models import StockBatchBalance, StockItem, Warehouse

ZERO = Decimal("0")


def due_reminders(*, window_end) -> list[tuple]:
    """``[(variant, undated quantity)]`` due by ``window_end``, soonest first."""
    variants = list(
        ProductVariant.objects.filter(
            expiry_reminder_date__isnull=False,
            expiry_reminder_date__lte=window_end,
            is_active=True,
            product__is_active=True,
            product__archived_at__isnull=True,
        )
        .select_related("product")
        .order_by("expiry_reminder_date", "id")
    )
    if not variants:
        return []
    ids = [variant.pk for variant in variants]
    counted = dict(
        StockItem.objects.filter(variant_id__in=ids)
        .exclude(warehouse__kind=Warehouse.Kind.TRANSIT)
        .values("variant_id")
        .annotate(total=Sum("quantity_on_hand"))
        .values_list("variant_id", "total")
    )
    undated = dict(
        StockBatchBalance.objects.filter(variant_id__in=ids, batch__expiry_date__isnull=True)
        .exclude(warehouse__kind=Warehouse.Kind.TRANSIT)
        .values("variant_id")
        .annotate(total=Sum("remaining_quantity"))
        .values_list("variant_id", "total")
    )
    due = []
    for variant in variants:
        mode = variant.product.tracking_mode
        if mode == Product.TrackingMode.QUANTITY:
            quantity = counted.get(variant.pk) or ZERO
        elif mode == Product.TrackingMode.BATCH:
            quantity = undated.get(variant.pk) or ZERO
        else:
            # Handsets are named one by one; a shelf-wide date says nothing.
            continue
        if quantity > ZERO:
            due.append((variant, quantity))
    return due
