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


#: Where an order keeps its lines in the order the cart sent them.
ORDER_LINES_ATTR = "_pointy_lines_in_cart_order"


def remember_line_order(order, lines) -> None:
    """Keep the cart's own order on the order, as its lines are written.

    The key each identified article was tagged with is its **position in the
    cart**, decided when the issue was planned — before any of these rows
    existed to point at. Stashing them here rather than re-reading is one query
    saved on the cashier's critical path.
    """
    if order is not None:
        setattr(order, ORDER_LINES_ATTR, list(lines))


def lines_in_cart_order(order) -> list:
    """The sale's lines, in the sequence the till sent them.

    Falls back to primary-key order, which is the same sequence — the rows are
    created in a loop over the cart — and is what the settle-later path (آجل)
    takes, where the lines existed before this sale was planned.
    """
    lines = getattr(order, ORDER_LINES_ATTR, None)
    if lines is None:
        lines = list(order.lines.order_by("pk"))
    return lines


def lines_by_variant(order, lines=None) -> dict:
    """First line per variant — the fallback, and only ever the fallback.

    It was once enough: the question was "which sale took this IMEI", and two
    lines of one variant belong to the same sale either way. It stopped being
    enough the moment each article carried its own price, because "what did it
    fetch" and "which line is it printed on" have two different answers on an
    invoice holding two handsets of the same model. The allocation's own
    ``source_key`` is what answers those; this remains for allocations nobody
    attributed — a lot issue, a path with no cart behind it — where naming the
    variant's first line is still better than naming none.
    """
    by_variant = {}
    for line in lines if lines is not None else order.lines.all():
        by_variant.setdefault(line.variant_id, line)
    return by_variant


def attribute_allocations(plan, claims) -> None:
    """Say which cart line each identified article is leaving on.

    A movement is planned per variant, so the plan for two handsets of one model
    holds two allocations and no idea that the cart asked for them separately,
    at two prices. This puts that back, by the only two rules there are:

    * an article a line **named** — scanned, or picked from the sheet — belongs
      to that line, whatever order the planner happened to lock them in;
    * an article **nobody named** fills the earliest line that still has room,
      which is the order the cashier rang them up in.

    Lot allocations are deliberately left unattributed: one FEFO allocation can
    span two lines of the same drug, and splitting it to say otherwise would
    invent a precision the pick does not have.
    """
    if plan is None or not plan.allocations or not claims:
        return
    from apps.inventory.identity import normalize_identifier

    by_id = {}
    by_code = {}
    for claim in claims:
        for unit_id in claim.get("unit_ids") or ():
            by_id.setdefault(int(unit_id), claim["key"])
        for code in claim.get("unit_codes") or ():
            by_code.setdefault(normalize_identifier(code), claim["key"])

    room = [[claim["key"], Decimal(claim.get("quantity") or 0)] for claim in claims]

    def _take(key, quantity):
        for row in room:
            if row[0] == key:
                row[1] -= quantity
                return

    def _earliest(quantity):
        for row in room:
            if row[1] >= quantity and row[1] > 0:
                row[1] -= quantity
                return row[0]
        return None

    for allocation in plan.allocations:
        unit = allocation.unit
        if unit is None:
            continue
        key = by_id.get(unit.pk)
        if key is None:
            key = by_code.get(unit.code_normalized)
        if key is not None:
            _take(key, Decimal(allocation.quantity))
        else:
            key = _earliest(Decimal(allocation.quantity))
        allocation.source_key = key


def stamp_consignment_payouts(plan, line_for) -> Decimal:
    """Fix every consigned article in this plan at the payout it has earned.

    ``line_for`` answers "which line sold this allocation", because under a
    commission agreement the payout is a percentage **of the price that article
    fetched** — and two watches of one model on one invoice, at 12,000 and
    9,000, owe their owners two different numbers. Reading one line for the
    whole variant would pay the second consignor out of the first one's price.

    Returns the total, which the plan carries into the valuation pass as the
    quantity-zero ``consignment_cost`` entry posted immediately before the issue
    (§5.8). Without that entry the payout leaves a ledger it never entered.
    """
    if plan is None or not plan.allocations:
        return ZERO
    total = ZERO
    for allocation in plan.allocations:
        unit = allocation.unit
        if unit is None or not unit.is_consignment:
            continue
        line = line_for(allocation)
        price = net_unit_price(line) if line is not None else ZERO
        payout = consignment_service.stamp_payout(unit, sold_price=price)
        allocation.rate = payout
        total += payout
    plan.consignment_cost = total
    return total


def line_resolver(order):
    """``(allocation, variant_id) -> OrderLine`` for the sale just written.

    Prefers what the allocation itself says — the cart line that named this
    article — and falls back to the variant's first line for anything the
    planner produced with no cart behind it.
    """
    # One read of the lines, two views of it: the cashier waits on this.
    lines = lines_in_cart_order(order)
    by_key = {str(index): line for index, line in enumerate(lines)}
    by_variant = lines_by_variant(order, lines)

    def resolve(allocation, variant_id=None):
        key = getattr(allocation, "source_key", None)
        if key is not None and key in by_key:
            return by_key[key]
        return by_variant.get(
            variant_id if variant_id is not None else _variant_of(allocation)
        )

    return resolve


def _variant_of(allocation):
    unit = getattr(allocation, "unit", None)
    return getattr(unit, "variant_id", None)


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
    line_for = line_resolver(order)
    sold_on = timezone.localtime(order.created_at or timezone.now()).date()

    updates = []
    consigned = []
    # The *movement's* variant, not the unit's: the movement carries the
    # instance the cart preloaded, with its product and relations already on it,
    # while the unit's own ``variant`` is a second instance freshly locked and
    # carrying nothing. Reading through the unit would be a query per article on
    # the cashier's critical path, which is what §11's budget exists to stop.
    for movement in tracked:
        variant = getattr(movement, "variant", None)
        product = getattr(variant, "product", None)
        warranty_days = int(getattr(product, "warranty_days", 0) or 0)
        for allocation in movement.tracked_plan.allocations:
            unit = allocation.unit
            if unit is None:
                continue
            # The line that asked for *this* article, not the variant's first:
            # on an invoice holding two handsets of one model, the second is
            # printed on the second line and fetched the second price.
            line = line_for(allocation, movement.variant_id)
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
    "attribute_allocations",
    "finish_sold_units",
    "line_resolver",
    "lines_in_cart_order",
    "remember_line_order",
    "lines_by_variant",
    "net_unit_price",
    "notify_consignors",
    "register_sold_assets",
    "stamp_consignment_payouts",
    "tracked_plans",
]
