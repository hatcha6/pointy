"""Stock the shop already owns, put on the shelf at what it actually cost.

Not to be confused with :mod:`apps.inventory.opening` next door, which takes
stock that is *already counted* and gives each article an identity. This is the
step before that one: a shop typing in a product it has forty of, on the day it
starts using Pointy, and saying what those forty cost.

**Why this is not a purchase order.** A PO is a document about a transaction
with a supplier — ordered, received, billed, paid. Opening stock has none of
that: there is no supplier to owe, no invoice to match, and inventing one would
put money into payables that nobody owes. The ledger already has the right
word for it (``StockLedgerEntry.VoucherType.OPENING``), which the migration
importers have been writing for imported shops since they existed; this is the
same event, performed by hand.

**It is a real, valued stock event.** The shelf moves through ``StockMovement``
like any other change, and the valuation ledger is opened at the cost that was
typed. That is the entire point of the feature: without the second half, the
valuation engine falls back to the last purchase price, finds none, and books
the whole selling price as profit the first time the product sells — which is
the same silence :mod:`apps.migration.loaders.inventory` calls out.
"""

from __future__ import annotations

from decimal import Decimal

from django.utils import timezone
from rest_framework import serializers

from . import tracking
from .models import StockLedgerEntry, StockMovement
from .services import (
    build_stock_movement,
    lock_stock_item,
    resolve_warehouse_id,
    save_stock_item_quantities,
    stock_snapshot,
)
from .valuation_service import post_movement_valuations

ZERO = Decimal("0")

#: What the movement and the ledger entry say they are, in the language the
#: shop reads its own stock history in.
OPENING_NOTE = "رصيد افتتاحي"


def open_stock_balance(
    *,
    variant,
    quantity,
    unit_cost,
    warehouse=None,
    user=None,
    note="",
    at=None,
    units=None,
    batches=None,
):
    """Open ``variant`` at ``quantity`` on hand, valued at ``unit_cost``.

    ``quantity`` and ``unit_cost`` are both per BASE unit — per egg, never per
    tray — because that is the denomination the bin, the ledger and the price
    sheet are all written in. A caller holding a pack figure divides by the
    pack factor before it gets here, exactly as a purchase line does.

    Returns the saved :class:`StockMovement`, or ``None`` when there was
    nothing to open (a zero quantity, which is what almost every product
    created in the catalog sends).
    """
    quantity = Decimal(quantity or 0)
    if quantity <= ZERO:
        return None
    unit_cost = Decimal(unit_cost or 0)
    if unit_cost < ZERO:
        raise serializers.ValidationError(
            {"opening_unit_cost": "Opening cost cannot be negative."}
        )

    product = variant.product
    if product.is_service or product.is_prepared:
        # A service has no shelf and a made-to-order dish is assembled when it
        # is ordered; neither has an opening quantity to state. Refused rather
        # than ignored — silently dropping a number somebody typed is how a
        # shop ends up believing it has stock it never had.
        raise serializers.ValidationError(
            {
                "opening_quantity": (
                    "This product does not keep stock (service or made-to-order)."
                )
            }
        )

    at = at or timezone.now()
    warehouse_id = resolve_warehouse_id(warehouse)
    stock_item = lock_stock_item(variant=variant, warehouse=warehouse_id)
    before = stock_snapshot(stock_item)
    stock_item.quantity_on_hand += quantity
    save_stock_item_quantities(stock_item)

    # A tracked product opened by hand is the §6.1 shape: the goods are on the
    # shelf and nobody has scanned them yet, so they are counted, placed on the
    # missing-identifier worklist and refused by the till until somebody does.
    # ``rate`` is the cost that was typed rather than the bin's own — the bin
    # is empty, which is the whole reason this call exists.
    plan = tracking.plan_adjustment(
        variant=variant,
        warehouse=warehouse_id,
        delta=quantity,
        rate=unit_cost,
        units=units,
        batches=batches,
        at=at,
        placeholder_key=f"OPEN-{variant.pk}",
        what="الرصيد الافتتاحي",
    )
    plan = tracking.apply_adjustment(plan, at=at)

    movement = build_stock_movement(
        stock_item=stock_item,
        movement_type=StockMovement.Type.INCREASE,
        quantity=quantity,
        note=(note or OPENING_NOTE)[:240],
        created_by=user,
        before=before,
        variant=variant,
        unit_cost=unit_cost,
        tracked_plan=plan,
    )
    movement.save()
    # Valued as an OPENING voucher, not an adjustment: a manual adjustment is a
    # correction to a shelf the system already had an opinion about, and this
    # is the first opinion. Reports, the cost history and the cost metrics all
    # read the voucher type to tell the two apart.
    post_movement_valuations(
        [movement],
        voucher_type=StockLedgerEntry.VoucherType.OPENING,
        voucher_id=movement.pk,
        posting_at=at,
        warehouse=warehouse_id,
    )
    return movement


def opening_cost_entries(*, product=None, variant=None):
    """Every opening balance that established a cost for this product.

    The other half of the feature, and the reason it is not merely a stock
    write: the cost screens — "lowest / highest / last / average" and the cost
    history beside them — read purchase lines, so a shop that opened a product
    at 10 and never bought it through Pointy saw "no cost data" on the product
    page while the till happily showed a cost of 10. This is the second source
    those screens merge in.

    Imported shops get it for free: ``apps.migration`` has been writing OPENING
    entries since it existed, so a migrated catalog's costs light up too.

    Newest first, matching the purchase-line ordering it is merged with.
    """
    entries = StockLedgerEntry.objects.filter(
        voucher_type=StockLedgerEntry.VoucherType.OPENING,
        quantity_change__gt=0,
    ).select_related("variant", "variant__product")
    if variant is not None:
        entries = entries.filter(variant=variant)
    elif product is not None:
        entries = entries.filter(variant__product=product)
    else:
        return StockLedgerEntry.objects.none()
    return entries.order_by("-posting_at", "-id")


__all__ = ["OPENING_NOTE", "open_stock_balance", "opening_cost_entries"]
