"""Turning stock a shop already has into stock it can name.

§6.10. A shop with forty anonymous iPhones on hand cannot flip the switch and
lose them, and it cannot invent forty IMEIs either — the only honest way to
identify forty handsets is for somebody to pick each one up. This is the
guided run that lets them, and the reason
``catalog.tracking_modes.assert_mode_change_allowed`` can point at something
when it refuses a mode change.

**Nothing moves.** That is the whole design. The quantity is already on the
shelf and already in the bin at a rate the ledger decided; identifying it adds
articles that *account for* that quantity, at exactly that rate, so the bin is
unchanged by construction and invariants 1 and 4 hold on both sides of the run.
Allocations are written — a unit with no history is a unit whose first sale
looks like it left twice — but no movement and no ledger entry, because
claiming a stock event happened would be claiming something false.

Two rules keep it honest:

* **Refuse to finish while anything is unaccounted for.** A run that stops
  halfway leaves a shelf that is part named and part anonymous, and the till
  cannot tell which handset it is holding.
* **"Identify later" is allowed, and visible.** The same placeholder shape
  receiving already uses (§6.1): counted, on the missing-identifier worklist,
  and refused by the till until somebody scans it.
"""

from __future__ import annotations

from decimal import Decimal

from django.db import transaction
from django.utils import timezone
from rest_framework import serializers

from apps.catalog.models import Product

from . import tracking
from .models import (
    StockBatchBalance,
    StockItem,
    StockLedgerEntry,
    StockUnit,
)
from .services import lock_stock_item, resolve_warehouse_id

ZERO = Decimal("0")


def outstanding_for(variant, *, warehouse=None):
    """How much of this variant is on the shelf and not yet identified.

    The gap between the quantity the bin believes and the articles that
    account for it — which for a product that has just been switched on is all
    of it, and for one half-way through a run is what is left to scan.
    """
    warehouse_id = resolve_warehouse_id(warehouse)
    mode = tracking.mode_of(variant)
    if mode == Product.TrackingMode.QUANTITY:
        return ZERO
    item = StockItem.objects.filter(
        variant=variant, warehouse_id=warehouse_id
    ).first()
    on_hand = Decimal(item.quantity_on_hand) if item is not None else ZERO
    if tracking.tracks_units(mode):
        named = StockUnit.objects.filter(
            variant=variant,
            warehouse_id=warehouse_id,
            status__in=StockUnit.ON_HAND_STATUSES,
        ).count()
        return on_hand - Decimal(named)
    held = sum(
        (
            balance.remaining_quantity
            for balance in StockBatchBalance.objects.filter(
                variant=variant, warehouse_id=warehouse_id
            )
        ),
        ZERO,
    )
    return on_hand - Decimal(held)


def worklist(*, warehouse=None, category=None):
    """Every variant with stock that nothing has named yet.

    The screen this run opens on, and the one it has to empty. Ordered by how
    much is outstanding, because a shop with two hundred lines wants the
    twenty that matter first.
    """
    from apps.catalog.models import ProductVariant

    warehouse_id = resolve_warehouse_id(warehouse)
    variants = ProductVariant.objects.filter(
        product__tracking_mode__in=[
            Product.TrackingMode.BATCH,
            Product.TrackingMode.SERIAL,
            Product.TrackingMode.SERIAL_BATCH,
        ],
        stock_items__warehouse_id=warehouse_id,
        stock_items__quantity_on_hand__gt=0,
    ).select_related("product")
    if category is not None:
        from apps.catalog.services import category_ids_with_descendants

        variants = variants.filter(
            product__category_id__in=category_ids_with_descendants(category)
        )
    rows = []
    for variant in variants.distinct():
        gap = outstanding_for(variant, warehouse=warehouse_id)
        if gap <= ZERO:
            continue
        rows.append(
            {
                "variant": variant.pk,
                "variant_name": variant.full_name,
                "sku": variant.sku,
                "tracking_mode": variant.product.tracking_mode,
                "outstanding": gap,
            }
        )
    rows.sort(key=lambda row: row["outstanding"], reverse=True)
    return rows


@transaction.atomic
def identify_opening_stock(
    *,
    variant,
    warehouse=None,
    units=None,
    batches=None,
    at=None,
    capture_later=False,
    actor=None,
):
    """Name the goods that are already here. Nothing moves.

    ``units`` are capture rows (``code`` and the usual optional fields) and
    ``batches`` are lot rows, exactly as receiving sends them — the same sheet,
    so a shop learns one screen rather than two.
    """
    mode = tracking.mode_of(variant)
    if mode == Product.TrackingMode.QUANTITY:
        raise serializers.ValidationError(
            {"variant": "هذا الصنف غير مُتتبَّع — لا حاجة لتعريف افتتاحي."}
        )
    warehouse_id = resolve_warehouse_id(warehouse)
    at = at or timezone.now()
    rows = list(units or [])
    lot_rows = list(batches or [])

    stock_item = lock_stock_item(variant=variant, warehouse=warehouse_id)
    outstanding = outstanding_for(variant, warehouse=warehouse_id)
    if outstanding <= ZERO:
        raise serializers.ValidationError(
            {
                "detail": (
                    "كل الكمية الموجودة معرّفة بالفعل — لا يوجد ما يُعرَّف."
                ),
                "outstanding": str(outstanding),
            }
        )

    if tracking.tracks_units(mode):
        wanted = int(outstanding)
        if len(rows) > wanted:
            raise serializers.ValidationError(
                {
                    "detail": (
                        f"تم إدخال {len(rows)} معرّفًا لكمية غير معرّفة "
                        f"قدرها {wanted}."
                    ),
                    "captured": len(rows),
                    "outstanding": wanted,
                }
            )
        if len(rows) < wanted and not capture_later:
            raise serializers.ValidationError(
                {
                    "detail": (
                        f"تم إدخال {len(rows)} من {wanted} معرّفًا — أكمل "
                        "المعرّفات أو فعّل خيار الإدخال لاحقًا."
                    ),
                    "captured": len(rows),
                    "outstanding": wanted,
                }
            )
        quantity = Decimal(wanted)
    else:
        captured = sum(
            (Decimal(row.get("quantity") or 0) for row in lot_rows), ZERO
        )
        if lot_rows and captured != outstanding:
            raise serializers.ValidationError(
                {
                    "detail": (
                        f"مجموع كميات الدفعات ({captured}) لا يساوي الكمية "
                        f"غير المعرّفة ({outstanding})."
                    ),
                    "captured": str(captured),
                    "outstanding": str(outstanding),
                }
            )
        quantity = outstanding

    # The rate the ledger already decided. Anything else would revalue stock
    # that has not moved, which is the one thing this run must never do.
    rate = _opening_rate(variant, warehouse_id, stock_item, quantity)
    plan = tracking.plan_receipt(
        variant=variant,
        warehouse=warehouse_id,
        quantity=quantity,
        rate=rate,
        units=rows,
        batches=lot_rows or None,
        at=at,
        capture_later=capture_later,
        placeholder_key=f"OPEN-{variant.pk}",
    )
    tracking.apply_receipt(plan, at=at)
    # ``in_stock_since`` is the day the shop started tracking, not a made-up
    # arrival: aging must not claim these handsets landed this morning.
    tracking.write_allocations(
        plan,
        voucher_type=StockLedgerEntry.VoucherType.OPENING,
        voucher_id=variant.pk,
        posting_at=at,
        note="تعريف افتتاحي",
    )
    for unit in plan.new_units:
        from .stock_count_tracking import record_unit_event

        record_unit_event(
            unit,
            kind="identified" if unit.is_identified else "note",
            actor=actor,
            at=at,
            to_value=unit.code,
            note="تعريف افتتاحي",
            reference_type="opening_identification",
            reference_id=variant.pk,
        )
    return {
        "variant": variant.pk,
        "identified": len(plan.new_units) or len(plan.allocations),
        "outstanding": outstanding_for(variant, warehouse=warehouse_id),
        "rate": rate,
    }


def _opening_rate(variant, warehouse_id, stock_item, quantity):
    """What the shelf is already worth, per base unit.

    Read off the bin rather than recomputed: the bin is what every other
    report already believes, and a second derivation here would be a second
    answer to the same question.
    """
    from .models import StockValuationBin

    bin_row = StockValuationBin.objects.filter(
        variant=variant, warehouse_id=warehouse_id
    ).first()
    if bin_row is not None and bin_row.valuation_rate:
        return Decimal(bin_row.valuation_rate)
    if bin_row is not None and bin_row.quantity and bin_row.stock_value:
        return Decimal(bin_row.stock_value) / Decimal(bin_row.quantity)
    from .valuation_service import valuation_unit_costs

    return Decimal(
        valuation_unit_costs([variant.pk], warehouse=warehouse_id).get(
            variant.pk, ZERO
        )
    )


__all__ = ["identify_opening_stock", "outstanding_for", "worklist"]
