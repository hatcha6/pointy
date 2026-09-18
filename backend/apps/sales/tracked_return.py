"""What comes back through the door, and which article it actually is.

A return of a serialized line returns **that unit** — the handset with that
IMEI, not "one of those". Three things follow from saying it that way, and none
of them is possible while a return is only a quantity:

* the same article cannot be returned twice, which today is prevented only by
  arithmetic;
* it re-enters at what *it* cost, not at what the shelf averages;
* the buyer stops owning it, so its ``Asset`` ownership row closes and the shop
  can sell it on with the history intact.

The consignment fork lives here too. A customer returning a watch whose owner
has already collected ten thousand dinars is common enough in high-value used
trade that leaving it undefined means every shop invents an answer, so the
return screen asks once and both answers are real (§5.8).
"""

from __future__ import annotations

from decimal import Decimal

from django.utils import timezone

from apps.inventory import tracking
from apps.inventory.models import StockUnit

#: The two defensible answers when a paid-out consignment comes back.
BUY_IN = "buy_in"
REOPEN = "reopen"
CONSIGNMENT_ACTIONS = (BUY_IN, REOPEN)


def units_sold_by_line(line, *, limit=None):
    """The identified articles this order line actually issued.

    Read off the units themselves rather than off the allocations: the sale
    stamped the line onto every unit it took, so this is one indexed query and
    no join.
    """
    query = StockUnit.objects.select_related("variant", "variant__product", "batch").filter(
        sold_order_line=line, status=StockUnit.Status.SOLD
    ).order_by("id")
    if limit is not None:
        query = query[: int(limit)]
    return list(query)


def return_units_for_line(line, quantity, *, warehouse=None, consignment_action=BUY_IN,
                          request=None):
    """Bring this line's articles back, and hand the shop's answer to valuation.

    Returns the plan, which the movement carries so its ledger entry names what
    came back — or ``None`` for a line that identifies nothing, which leaves
    every existing return working exactly as it did.
    """
    if not tracking.is_tracked(line.variant):
        return None
    units = units_sold_by_line(line, limit=quantity)
    if not units:
        # A tracked line with nothing to bring back is a sale that predates
        # tracking: the product held anonymous quantity then, its stock reached
        # zero, and somebody turned identification on. The goods are genuinely
        # coming back, so refusing the refund would be wrong and letting the
        # quantity rise with no article behind it would break invariant 1 — a
        # bin counting stock no unit accounts for. So they come back as
        # *placeholders*: counted, listed on the missing-identifier worklist,
        # and refused by the till until somebody scans them. Exactly the shape
        # "capture later" already uses, for the same reason.
        return _return_as_placeholders(
            line, quantity, warehouse=warehouse
        )
    for unit in units:
        _settle_consignment(unit, action=consignment_action)
    plan = tracking.plan_return(units=units, warehouse=warehouse, variant=line.variant)
    tracking.apply_return(
        plan, at=timezone.now(), warehouse_id=getattr(plan, "warehouse_id", None)
    )
    _close_ownership(units, request=request)
    return plan


def _return_as_placeholders(line, quantity, *, warehouse=None):
    """Bring goods back as articles the shop still owes an identifier for."""
    count = int(Decimal(quantity))
    if count <= 0:
        return None
    at = timezone.now()
    plan = tracking.plan_receipt(
        variant=line.variant,
        warehouse=warehouse,
        quantity=Decimal(count),
        # At what it left at, so a return books no profit or loss on a sale that
        # was simply undone.
        rate=Decimal(line.unit_cost or 0) / (line.unit_factor or Decimal("1")),
        units=[],
        capture_later=True,
        placeholder_key=f"ret-{line.pk}-{int(at.timestamp())}",
        at=at,
    )
    tracking.apply_receipt(plan, at=at)
    return plan


def _settle_consignment(unit, *, action):
    """Decide whose watch this is now, before anything is valued.

    The order matters: the allocation's rate is read from the unit, so the
    answer has to be on the row before the plan is built.
    """
    if not unit.is_consignment:
        return
    from apps.inventory import consignment_service

    if unit.consignor_paid_at is None:
        # Nothing has gone out yet, so nothing has to come back: the payable
        # simply closes with the sale that created it and the watch returns to
        # consigned stock.
        consignment_service.reopen_consignment(unit)
        return
    if action == REOPEN:
        consignment_service.reopen_consignment(unit)
    else:
        consignment_service.buy_in_returned_consignment(unit)


def _close_ownership(units, *, request=None):
    """The buyer no longer owns it.

    The ownership row closes rather than the asset being deleted: the car had
    its gearbox done here in March, and that is still true after it comes back.
    """
    from django.utils import timezone as tz

    from apps.customers.models import AssetOwnership

    asset_ids = [unit.asset_id for unit in units if unit.asset_id]
    if not asset_ids:
        return
    now = tz.now()
    AssetOwnership.objects.filter(
        asset_id__in=asset_ids, released_at__isnull=True
    ).update(released_at=now, updated_at=now)


__all__ = [
    "BUY_IN",
    "CONSIGNMENT_ACTIONS",
    "REOPEN",
    "return_units_for_line",
    "units_sold_by_line",
]
