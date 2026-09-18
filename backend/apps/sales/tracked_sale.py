"""What a sale does to the identified articles it issues.

Four things, all of which have to happen inside the checkout transaction and
none of which the ledger can work out for itself:

1. **A consigned article's cost is fixed at its payout.** A consignment sale is
   a purchase and a sale in one transaction; this is the purchase half.
2. **The invoice is named on the unit**, so "which sale took this IMEI" is a
   column rather than a walk through allocations.
3. **Warranty starts.** Days from the sale, stamped, because a derived date
   would silently change the day somebody edited the product.
4. **The buyer owns it.** A sold unit becomes the customer's ``Asset``, which is
   the bridge that lets the handset we sold arrive for repair already knowing
   its own history.

The SMS a consignor gets is queued from here too, after the ledger has been
written — a message about a sale that then rolled back would be worse than no
message at all.
"""

from __future__ import annotations

from datetime import timedelta
from decimal import Decimal

from django.db import transaction
from django.utils import timezone

from apps.core.models import ShopSettings
from apps.inventory import consignment as consignment_service
from apps.inventory.models import StockUnit

ZERO = Decimal("0.00")


def _money(value) -> Decimal:
    return Decimal(value or 0).quantize(Decimal("0.01"))


def net_unit_price(line) -> Decimal:
    """What one article on this line actually fetched.

    Net of the line's discount, because a commission payout computed off the
    pre-discount price would pay the consignor out of money the shop never
    collected — and because "sold for" on a unit's own history should be the
    figure the customer paid.
    """
    quantity = Decimal(line.quantity or 0)
    if quantity <= 0:
        return _money(line.unit_price)
    return _money(Decimal(line.line_total) / quantity)


def lines_by_variant(order) -> dict:
    """First line per variant. When the same variant appears twice on one
    invoice every question this mapping answers has the same answer either way:
    both lines belong to the same sale."""
    lines = {}
    for line in order.lines.all():
        lines.setdefault(line.variant_id, line)
    return lines


def stamp_consignment_payouts(plan, line) -> Decimal:
    """Fix every consigned article in this plan at the payout it has earned.

    Returns the total, which the plan carries into the valuation pass as the
    quantity-zero ``consignment_cost`` entry posted immediately before the issue
    (§5.8). Without that entry the payout leaves a ledger it never entered.
    """
    if plan is None or not plan.allocations:
        return ZERO
    price = net_unit_price(line) if line is not None else ZERO
    total = ZERO
    for allocation in plan.allocations:
        unit = allocation.unit
        if unit is None or not unit.is_consignment:
            continue
        payout = consignment_service.stamp_payout(unit, sold_price=price)
        allocation.rate = payout
        total += payout
    plan.consignment_cost = total
    return total


def finish_sold_units(order, movements, *, settings=None, request=None):
    """Stamp the invoice, the price, the warranty and the ownership.

    One bulk update for the units and one pass for the assets, because this runs
    on the cashier's critical path and a twelve-line cart must not pay a query
    per article.
    """
    tracked = [
        movement
        for movement in movements
        if getattr(movement, "tracked_plan", None) is not None
    ]
    if not tracked:
        return
    settings = settings or ShopSettings.load()
    lines = lines_by_variant(order)
    sold_on = timezone.localtime(order.created_at or timezone.now()).date()

    updates = []
    consigned = []
    # The *movement's* variant, not the unit's: the movement carries the
    # instance the cart preloaded, with its product and relations already on it,
    # while the unit's own ``variant`` is a second instance freshly locked and
    # carrying nothing. Reading through the unit would be a query per article on
    # the cashier's critical path, which is what §11's budget exists to stop.
    for movement in tracked:
        line = lines.get(movement.variant_id)
        variant = getattr(movement, "variant", None)
        product = getattr(variant, "product", None)
        warranty_days = int(getattr(product, "warranty_days", 0) or 0)
        for allocation in movement.tracked_plan.allocations:
            unit = allocation.unit
            if unit is None:
                continue
            unit.sold_order_line = line
            if line is not None:
                unit.sold_price = net_unit_price(line)
            if warranty_days:
                unit.warranty_expires_on = sold_on + timedelta(days=warranty_days)
            updates.append((unit, variant))
            if unit.is_consignment:
                consigned.append(unit)
    units = [unit for unit, _ in updates]
    if units:
        StockUnit.objects.bulk_update(
            units,
            [
                "sold_order_line",
                "sold_price",
                # Written in memory by ``stamp_consignment_payouts`` before the
                # ledger was valued; this is where it lands on disk.
                "incoming_rate",
                "warranty_expires_on",
                "updated_at",
            ],
        )
    register_sold_assets(updates, order, settings=settings, request=request)
    if consigned:
        notify_consignors(consigned, order, settings=settings)


def register_sold_assets(pairs, order, *, settings=None, request=None):
    """Hand every sold article to the buyer, as their asset.

    ``serialized_require_customer_for_asset`` reads literally: registering a
    sold article as somebody's property **requires a named customer**. A walk-in
    cash sale therefore creates nothing and still records the sale — no
    placeholder owner is invented for a person nobody wrote down.
    """
    settings = settings or ShopSettings.load()
    if not settings.serialized_require_customer_for_asset:
        return []
    if order.customer_id is None:
        return []

    from apps.customers.services import transfer_asset

    created = []
    for unit, variant in pairs:
        asset_type = getattr(getattr(variant, "product", None), "asset_type", None)
        if asset_type is None:
            continue
        if unit.asset_id:
            # It has been round this loop before — traded in, refurbished and
            # sold on. The item keeps its history and changes hands.
            transfer_asset(
                asset=unit.asset,
                customer=order.customer,
                note=f"بيع {order.receipt_number}",
                request=request,
            )
            continue
        asset = _create_asset(unit, variant, order, asset_type)
        unit.asset = asset
        created.append(unit)
    if created:
        StockUnit.objects.bulk_update(created, ["asset", "updated_at"])
    return created


def _create_asset(unit, variant, order, asset_type):
    from apps.customers.models import Asset
    from apps.inventory.identity import IdentifierKind

    fields = {
        "customer": order.customer,
        "asset_type": asset_type,
        # The variant's own name is the model; nothing here invents a brand from
        # a category, because a category is not a brand and a guess on a
        # warranty record is worse than a blank.
        "model_name": variant.full_name,
    }
    # The identifier lands in the column its kind names, so a workshop looking a
    # car up by chassis number and a phone shop looking one up by IMEI both find
    # what they sold.
    column = {
        IdentifierKind.IMEI: "imei",
        IdentifierKind.VIN: "vin",
        IdentifierKind.SERIAL: "serial_number",
    }.get(unit.identifier_kind, "custom_identifier")
    fields[column] = unit.code
    asset = Asset.objects.create(**fields)
    return asset


def notify_consignors(units, order, *, settings=None):
    """Queue the "your goods sold" message, once the sale is certainly real."""
    settings = settings or ShopSettings.load()
    if not settings.consignment_auto_sms_on_sale:
        return
    pending = list(units)

    def _send():
        for unit in pending:
            consignment_service.notify_consignor_of_sale(
                unit, order, settings=settings
            )

    transaction.on_commit(_send)


def tracked_plans(movements):
    return [
        movement.tracked_plan
        for movement in movements
        if getattr(movement, "tracked_plan", None) is not None
    ]


__all__ = [
    "finish_sold_units",
    "lines_by_variant",
    "net_unit_price",
    "notify_consignors",
    "register_sold_assets",
    "stamp_consignment_payouts",
    "tracked_plans",
]
