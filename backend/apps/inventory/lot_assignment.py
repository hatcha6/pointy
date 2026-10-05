"""Giving grandfathered units the lot they were never given (§4.2).

``serial → serial_batch`` grandfathers: the handsets — or packs — already on
the shelf keep ``batch = NULL`` and every new receipt has to name a lot. They
can still be sold (``tracking._born_before_lots``), but nothing a recall reads
can find them, and until now nothing could give them one. This is that tool.

**Nothing moves, and nothing is revalued.** A ``serial_batch`` bin is valued by
its *units* (invariants 4 and 9), so naming the lot a unit sits in changes no
quantity and no money: there is no ledger entry, and no allocation — an
allocation is a row of the ledger's join and must balance against one. What
*does* change is the lot's own balance in the unit's warehouse, because
invariant 11 holds every ``serial_batch`` balance to the count of live units
that name it. So the balance takes the unit in exactly the way a receipt under
this lot would have — ``lock_balance`` + ``receive_into_balance`` at the unit's
own rate — and the unit records the fact as a ``lot_assigned`` event, whose
time is what tells invariant 14 that the unit's earlier, lot-less movements
were written before it had one.

Only units on the shelf (in stock or reserved) are named here. One in a van is
named when it lands; one on order is named at receipt like any other.
"""

from __future__ import annotations

from collections import defaultdict
from decimal import Decimal

from django.db import transaction
from django.db.models import Count
from django.utils import timezone
from rest_framework import serializers

from apps.catalog.models import Product

from . import tracking
from .models import StockBatch, StockUnit, StockUnitEvent

ZERO = Decimal("0")


def missing_lot_units(*, variant=None, product=None, warehouse=None):
    """Units on the shelf of a ``serial_batch`` product that name no lot.

    The worklist's rows. Narrower than ``integrity.units_missing_lots`` on
    purpose: that one asks what is *wrong* (any live unit), this one what can be
    *fixed here* — a unit in transit or on order is not on a shelf anyone can
    read a lot number off.
    """
    query = StockUnit.objects.filter(
        variant__product__tracking_mode=Product.TrackingMode.SERIAL_BATCH,
        status__in=StockUnit.ON_HAND_STATUSES,
        batch__isnull=True,
    )
    if variant is not None:
        query = query.filter(variant_id=getattr(variant, "pk", variant))
    if product is not None:
        query = query.filter(variant__product_id=getattr(product, "pk", product))
    if warehouse is not None:
        query = query.filter(warehouse_id=getattr(warehouse, "pk", warehouse))
    return query


def missing_lot_groups(*, product=None, warehouse=None):
    """One row per variant still owing lots, largest first. One query."""
    rows = (
        missing_lot_units(product=product, warehouse=warehouse)
        .values(
            "variant_id",
            "variant__name",
            "variant__sku",
            "variant__product_id",
            "variant__product__name",
            "variant__product__expiry_required",
        )
        .annotate(count=Count("id"))
        .order_by("-count", "variant__product__name", "variant_id")
    )
    return [
        {
            "variant": row["variant_id"],
            "variant_name": row["variant__name"],
            "sku": row["variant__sku"],
            "product": row["variant__product_id"],
            "product_name": row["variant__product__name"],
            # So the lot chooser asks for the date receiving would have asked
            # for, rather than learning it from a refusal.
            "expiry_required": row["variant__product__expiry_required"],
            "count": row["count"],
        }
        for row in rows
    ]


def _refuse(message, **extra):
    raise serializers.ValidationError({"detail": message, **extra})


@transaction.atomic
def assign_lot(
    *,
    variant,
    unit_ids,
    batch=None,
    lot=None,
    actor=None,
):
    """Put ``unit_ids`` into one lot of ``variant``: an existing one or a new one.

    ``batch`` is a lot already known to this variant; ``lot`` is
    ``{"code", "expiry_date", "manufactured_on"}`` for one typed off the box —
    found if the variant already has a lot by that code (a second sighting of
    Lot A *is* Lot A), created otherwise, and refused with the receipt's own
    expiry conflict if the dates disagree.

    Returns ``(batch, created, units)``.
    """
    unit_ids = [int(unit_id) for unit_id in unit_ids or [] if unit_id]
    if not unit_ids:
        _refuse("اختر وحدة واحدة على الأقل.")
    if len(set(unit_ids)) != len(unit_ids):
        _refuse("وحدة مكرّرة في الطلب.")
    if variant.product.tracking_mode != Product.TrackingMode.SERIAL_BATCH:
        _refuse("هذا الصنف لا يتتبّع الوحدات داخل دفعات.")

    units = tracking.lock_units(unit_ids)
    missing = [unit_id for unit_id in unit_ids if unit_id not in units]
    if missing:
        _refuse("بعض الوحدات غير موجودة.", units=missing)
    for unit in units.values():
        if unit.variant_id != variant.pk:
            _refuse(f"الوحدة {unit.code} ليست من هذا الصنف.", unit=unit.pk)
        if unit.batch_id is not None:
            _refuse(f"الوحدة {unit.code} لها دفعة بالفعل.", unit=unit.pk)
        if unit.status not in StockUnit.ON_HAND_STATUSES:
            _refuse(
                f"الوحدة {unit.code} ليست على الرف — تُسند دفعتها عند وصولها.",
                unit=unit.pk,
            )

    created = False
    if batch is not None:
        batch = (
            StockBatch.objects.select_for_update()
            .filter(pk=getattr(batch, "pk", batch))
            .first()
        )
        if batch is None or batch.variant_id != variant.pk:
            _refuse("الدفعة المختارة ليست من هذا الصنف.")
    else:
        lot = lot or {}
        batch, created = tracking.resolve_batch(
            variant=variant,
            code=lot.get("code", ""),
            expiry_date=lot.get("expiry_date"),
            manufactured_on=lot.get("manufactured_on"),
        )
        if batch.expiry_date is None and variant.product.expiry_required:
            # The same rule receiving holds a new lot of this product to. The
            # transaction takes a lot it just created back with it.
            raise serializers.ValidationError(
                {"expiry_date": "تاريخ الصلاحية مطلوب لدفعات هذا الصنف."}
            )

    by_warehouse = defaultdict(list)
    for unit in units.values():
        by_warehouse[unit.warehouse_id].append(unit)
    for warehouse_id in sorted(by_warehouse):
        members = by_warehouse[warehouse_id]
        balance = tracking.lock_balance(
            batch=batch, warehouse=warehouse_id, variant=variant
        )
        # The rate a receipt under this lot would have given the balance: each
        # unit at its own landed cost. The bin does not read it — a
        # ``serial_batch`` bin is valued by units — but the lot's own "where it
        # is" panel does, and a unit arriving at zero would halve it.
        tracking.receive_into_balance(
            balance=balance,
            quantity=len(members),
            rate=sum((Decimal(unit.incoming_rate) for unit in members), ZERO)
            / len(members),
            at=min(
                (unit.in_stock_since for unit in members if unit.in_stock_since),
                default=None,
            ),
        )

    ordered = [units[unit_id] for unit_id in sorted(units)]
    StockUnit.objects.filter(pk__in=[unit.pk for unit in ordered]).update(
        batch=batch, updated_at=timezone.now()
    )
    StockUnitEvent.objects.bulk_create(
        [
            StockUnitEvent(
                unit=unit,
                kind=StockUnitEvent.Kind.LOT_ASSIGNED,
                actor=actor if getattr(actor, "is_authenticated", False) else None,
                to_value=batch.code[:240],
                reference_type="stock_batch",
                reference_id=batch.pk,
            )
            for unit in ordered
        ]
    )
    for unit in ordered:
        unit.batch = batch
    return batch, created, ordered


__all__ = ["assign_lot", "missing_lot_groups", "missing_lot_units"]
