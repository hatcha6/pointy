"""Taking an identified article off the shelf because it is gone.

Its own module and not a status flip, because a write-off is a **movement**:
the bin drops by one, the ledger records the value that left, and the reason is
part of the record. A shop that could set the status alone would end up with a
unit nobody can find and a quantity that still counts it — which is exactly the
drift the fourteen invariants exist to catch.
"""

from __future__ import annotations

from decimal import Decimal

from django.db import transaction
from django.utils import timezone
from rest_framework import serializers

from . import tracking
from .models import StockLedgerEntry, StockMovement, StockUnit
from .services import (
    build_stock_movement,
    create_stock_movements,
    lock_stock_item,
    save_stock_item_quantities_bulk,
    stock_snapshot,
)

ONE = Decimal("1")


@transaction.atomic
def write_off_unit(unit, *, reason, request=None, status=StockUnit.Status.WRITTEN_OFF):
    unit = (
        # Only the unit row: ``variant`` is fine but the unit carries several
        # nullable relations, and Postgres refuses ``FOR UPDATE`` on the
        # nullable side of an outer join.
        StockUnit.objects.select_for_update(of=("self",))
        .select_related("variant", "variant__product")
        .get(pk=unit.pk)
    )
    if unit.status not in StockUnit.ON_HAND_STATUSES:
        raise serializers.ValidationError(
            {"detail": f"الوحدة {unit.code} ليست في المخزون ({unit.status})."}
        )
    if unit.is_consignment:
        # §6.8. Its own rate is zero, so this action would move no money and
        # record no claim — a shop that lost somebody else's camera would have
        # written off a liability by filling in a reason box. Losing our own
        # stock costs stock value; losing someone else's costs cash we have not
        # yet been asked for. Two different events, two different screens.
        raise serializers.ValidationError(
            {
                "detail": (
                    f"الوحدة {unit.code} أمانة — سجّل محضر حادث عهدة "
                    "بدل الشطب."
                ),
                "stock_unit": unit.pk,
                "use_endpoint": "stock-units/{id}/report-incident",
            }
        )
    at = timezone.now()
    plan = tracking.plan_issue(
        variant=unit.variant,
        warehouse=unit.warehouse_id,
        quantity=ONE,
        unit_ids=[unit.pk],
        allow_expired=True,
        allow_short=False,
    )
    stock_item = lock_stock_item(variant=unit.variant, warehouse=unit.warehouse_id)
    before = stock_snapshot(stock_item)
    stock_item.quantity_on_hand -= ONE
    tracking.apply_issue(plan, status=status, at=at)
    movement = build_stock_movement(
        variant=unit.variant,
        stock_item=stock_item,
        movement_type=StockMovement.Type.DECREASE,
        quantity=ONE,
        note=f"شطب {unit.code}: {reason}",
        created_by=getattr(request, "user", None)
        if getattr(getattr(request, "user", None), "is_authenticated", False)
        else None,
        before=before,
        tracked_plan=plan,
    )
    save_stock_item_quantities_bulk([stock_item])
    create_stock_movements(
        [movement],
        voucher_type=StockLedgerEntry.VoucherType.ADJUSTMENT,
        voucher_id=unit.pk,
        posting_at=at,
    )
    if reason and reason not in unit.notes:
        unit.notes = f"{unit.notes}\n{reason}".strip()
        unit.save(update_fields=["notes", "updated_at"])
    return unit


__all__ = ["write_off_unit"]
