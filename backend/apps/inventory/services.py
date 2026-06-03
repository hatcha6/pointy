from rest_framework import serializers

from .models import StockBatch, StockItem, StockMovement


def lock_stock_item(*, variant):
    if variant is None:
        raise serializers.ValidationError({"variant": "Variant is required."})
    stock_item, _ = StockItem.objects.select_for_update().get_or_create(
        variant=variant,
    )
    return stock_item


def stock_snapshot(stock_item):
    return {
        "on_hand": stock_item.quantity_on_hand,
        "committed": stock_item.quantity_committed,
        "expected": stock_item.quantity_expected,
    }


def save_stock_item_quantities(stock_item):
    stock_item.save(
        update_fields=[
            "quantity_on_hand",
            "quantity_committed",
            "quantity_expected",
            "updated_at",
        ],
    )


def create_stock_movement(
    *,
    stock_item,
    movement_type,
    quantity,
    note,
    created_by,
    before,
    variant=None,
):
    variant = variant or stock_item.variant
    if variant is None:
        raise serializers.ValidationError({"variant": "Variant is required."})
    if stock_item.variant_id != variant.pk:
        raise serializers.ValidationError(
            {"variant": "Variant must match the locked stock item."}
        )
    if quantity <= 0:
        return None
    return StockMovement.objects.create(
        variant=variant,
        stock_item=stock_item,
        movement_type=movement_type,
        quantity=quantity,
        note=note,
        created_by=created_by,
        on_hand_before=before["on_hand"],
        on_hand_after=stock_item.quantity_on_hand,
        committed_before=before["committed"],
        committed_after=stock_item.quantity_committed,
        expected_before=before["expected"],
        expected_after=stock_item.quantity_expected,
    )


def create_expiring_stock_batch(*, receipt_line, expiry_date, quantity):
    if expiry_date is None or quantity <= 0:
        return None
    variant = receipt_line.variant
    if not getattr(variant.product, "tracks_expiry", False):
        return None
    batch, _ = StockBatch.objects.get_or_create(
        source_receipt_line=receipt_line,
        defaults={
            "variant": variant,
            "expiry_date": expiry_date,
            "received_quantity": quantity,
            "remaining_quantity": quantity,
        },
    )
    return batch


def consume_expiring_stock_batches(*, variant, quantity):
    if quantity <= 0 or not getattr(variant.product, "tracks_expiry", False):
        return 0

    remaining = quantity
    consumed = 0
    batches = (
        StockBatch.objects.select_for_update()
        .filter(variant=variant, remaining_quantity__gt=0)
        .order_by("expiry_date", "created_at", "id")
    )
    for batch in batches:
        if remaining <= 0:
            break
        used = min(batch.remaining_quantity, remaining)
        batch.remaining_quantity -= used
        batch.save(update_fields=["remaining_quantity", "updated_at"])
        remaining -= used
        consumed += used
    return consumed
