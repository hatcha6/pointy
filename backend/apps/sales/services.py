import logging
from datetime import timedelta
from decimal import Decimal, ROUND_DOWN

from django.db import transaction
from django.db.models import Prefetch, Q, Sum, prefetch_related_objects
from django.utils import timezone
from rest_framework import serializers

logger = logging.getLogger(__name__)

from apps.analytics.models import AnalyticsEvent
from apps.analytics.services import record_domain_event
from apps.channels.services import require_active_sales_channel
from apps.core.models import ShopSettings
from apps.core.roles import user_is_manager
from apps.documents import services as document_services
from apps.documents.statuses import DocumentStatus
from apps.holidays.services import special_day_keys_for
from apps.discounts.models import DiscountRule, normalize_coupon_code
from apps.discounts.services import (
    DiscountContext,
    DiscountEngine,
    DiscountLineInput,
    DiscountUsageLimitExceeded,
    allocate_discount_amount,
    persist_applied_discounts,
)
from apps.catalog.services import preload_line_variants
from apps.integrations.fulfillment import persist_fulfillment
from apps.catalog.units import quantize_quantity
from apps.inventory import tracking
from apps.inventory.models import StockLedgerEntry, StockMovement, StockUnit
from apps.inventory.oversell import may_oversell
from apps.sales.registers import selling_warehouse_id
from apps.inventory.services import (
    build_stock_movement,
    consume_expiring_stock_batches,
    create_stock_movement,
    create_stock_movements,
    lock_stock_item,
    lock_stock_items,
    save_stock_item_quantities,
    save_stock_item_quantities_bulk,
    stock_snapshot,
)
from . import documents as sales_documents
from .tracked_return import BUY_IN, return_units_for_line
from .tracked_sale import (
    attribute_allocations,
    finish_sold_units,
    line_resolver,
    remember_line_order,
    stamp_consignment_payouts,
)
from .models import (
    Order,
    OrderAdjustment,
    OrderAdjustmentLine,
    OrderExchange,
    OrderLine,
    OrderLineModifier,
    StockReservation,
)


MONEY_PLACES = Decimal("0.01")
# OrderLine.quantity's own precision. Mirrored here so expected_order_totals
# sees the quantity the line will actually store, not the caller's raw input.
QUANTITY_PLACES = Decimal("0.001")


def money(value):
    return Decimal(value).quantize(MONEY_PLACES)


def cashier_window_expired(order, settings=None):
    if order.created_at is None:
        return False
    if settings is None:
        settings = ShopSettings.load()
    deadline = order.created_at + timedelta(
        hours=settings.cashier_return_window_hours,
    )
    return timezone.now() > deadline


def can_adjust_order(order, user=None, *, is_manager=None, settings=None):
    if order.status != Order.Status.PAID:
        return False
    if not any(line.returnable_quantity > 0 for line in order.lines.all()):
        return False
    if is_manager is None:
        is_manager = user is not None and user_is_manager(user)
    if is_manager:
        return True
    return not cashier_window_expired(order, settings=settings)


def adjustment_created_by(request):
    if request is not None and request.user.is_authenticated:
        return request.user
    return None


@transaction.atomic
def create_order_with_lines(
    *,
    lines_data,
    coupon_codes=(),
    discount_result=None,
    warehouse=None,
    **order_fields,
):
    customer = order_fields.get("customer")
    if discount_result is None:
        discount_result = calculate_sales_discounts(
            lines_data=lines_data,
            customer=customer,
            coupon_codes=coupon_codes,
        )
    # The cashier's one-off discount, held down to what this cart can carry —
    # and written back into ``order_fields``, so the column stores the discount
    # actually given rather than the figure that was typed at a fuller cart.
    order_fields["extra_discount_amount"] = clamped_manual_discount(
        lines_data, discount_result, order_fields.get("extra_discount_amount")
    )
    discount_by_line_key = order_line_discounts(
        lines_data, discount_result, order_fields["extra_discount_amount"]
    )

    # Snapshot the special day(s) active right now (shop-local) onto the sale so
    # forecasting has a stable per-sale signal. Defensive by contract: a holidays
    # failure degrades to an empty list and never rolls back a paid sale.
    if "special_day_keys" not in order_fields:
        order_fields["special_day_keys"] = special_day_keys_for()

    order = Order.objects.create(**order_fields)
    # One batched cost lookup for the whole cart instead of one purchase/
    # production query per line (latest_sale_unit_cost was the checkout's
    # per-line cost N+1).
    # Provisional: the real cost is settled when the stock is actually issued
    # (see _stamp_ledger_cost_on_lines). A cart that never takes payment keeps
    # this figure, which is the right answer for a quotation.
    cost_by_variant = sale_cost_basis(
        [line_data["variant"] for line_data in lines_data], warehouse=warehouse
    )
    line_objects_by_key = {}
    # In cart order, because that is the key each identified article was tagged
    # with when the issue was planned — before any of these rows existed.
    lines_in_order = []
    for line_data in lines_data:
        variant = line_data["variant"]
        line_key = checkout_line_key(line_data)
        # The transacted unit + its base-conversion factor are snapshots so price,
        # cost, and stock all stay self-consistent if the product's units change
        # later. unit_cost is per base unit, scaled to the transacted unit so
        # line_cost = unit_cost * quantity stays correct.
        unit_factor = line_data.get("unit_factor", Decimal("1"))
        base_unit_cost = cost_by_variant.get(variant.pk) or Decimal("0.00")
        line = OrderLine.objects.create(
            order=order,
            variant=variant,
            quantity=line_data["quantity"],
            unit=line_data.get("unit", ""),
            unit_factor=unit_factor,
            # Effective price folds in the selected unit's price + modifier deltas;
            # falls back to the bare variant price for lines without either.
            unit_price=line_data.get("effective_unit_price", variant.unit_price),
            # Only set when a cashier actually repriced this line, so the
            # column reads as "changed, from this" rather than as a duplicate
            # of unit_price on every ordinary sale.
            original_unit_price=line_data.get("original_unit_price"),
            unit_cost=money(base_unit_cost * unit_factor),
            discount_total=discount_by_line_key.get(line_key, Decimal("0.00")),
            notes=line_data.get("notes", ""),
        )
        _persist_order_line_modifiers(line, line_data.get("modifiers", []))
        # A top-up's cost is what the provider quoted, not what the warehouse
        # thinks a service product cost (nothing). Written here rather than in
        # the create() above so the ordinary path reads unchanged.
        integration = line_data.get("integration")
        if integration:
            line.unit_cost = money(integration["cost"])
            line.save(update_fields=["unit_cost", "updated_at"])
            persist_fulfillment(line, integration)
        line_objects_by_key[line_key] = line
        lines_in_order.append(line)
    remember_line_order(order, lines_in_order)
    order.recalculate()
    order.save(update_fields=["subtotal", "discount_total", "total", "updated_at"])
    try:
        persist_applied_discounts(
            document=order,
            result=discount_result,
            line_objects_by_key=line_objects_by_key,
        )
    except DiscountUsageLimitExceeded as exc:
        raise serializers.ValidationError(
            discount_usage_limit_error_payload(exc, "coupon_codes")
        )
    return order


def _persist_order_line_modifiers(line, selections):
    """Snapshot the chosen modifier options onto the order line so reprints and
    audits survive later catalog edits."""
    for selection in selections:
        option = selection["option"]
        OrderLineModifier.objects.create(
            order_line=line,
            modifier_option=option,
            group_name=option.group.name,
            option_name=option.name,
            unit_price_delta=option.price_delta,
            quantity=selection["quantity"],
        )


def checkout_line_key(line_data):
    return str(line_data.get("_discount_line_key", "0"))


def prepare_discount_lines(lines_data):
    prepared_lines = []
    for index, line_data in enumerate(lines_data):
        line_data["_discount_line_key"] = str(index)
        variant = line_data["variant"]
        product = variant.product
        prepared_lines.append(
            DiscountLineInput(
                key=str(index),
                product_id=product.pk,
                variant_id=variant.pk,
                quantity=line_data["quantity"],
                unit_amount=line_data.get("effective_unit_price", variant.unit_price),
                # .all() (not .values_list) so the preloaded product__categories
                # prefetch is reused instead of firing a query per cart line.
                category_ids=tuple(
                    category.id for category in product.categories.all()
                ),
            )
        )
    return tuple(prepared_lines)


def sales_discount_context(*, lines_data, customer=None, coupon_codes=()):
    return DiscountContext(
        channel=DiscountRule.Channel.SALES,
        customer_id=customer.pk if customer is not None else None,
        coupon_codes=tuple(coupon_codes or ()),
        lines=prepare_discount_lines(lines_data),
    )


def calculate_sales_discounts(*, lines_data, customer=None, coupon_codes=()):
    context = sales_discount_context(
        lines_data=lines_data,
        customer=customer,
        coupon_codes=coupon_codes,
    )
    return DiscountEngine().calculate(context)


def preview_sales_discounts(*, lines_data, customer=None, coupon_codes=()):
    """Preview-only, Redis-guarded discount calculation (see apps.discounts.cache).

    The POS calls this on every cart edit, so it short-circuits when no rules are
    active and memoises the result per cart for a few seconds. Checkout keeps
    using calculate_sales_discounts — always live, with usage limits re-validated
    under a row lock at persist time — so nothing money-critical trusts the cache.
    """
    from apps.discounts.cache import preview_with_cache

    context = sales_discount_context(
        lines_data=lines_data,
        customer=customer,
        coupon_codes=coupon_codes,
    )
    return preview_with_cache(context, lambda: DiscountEngine().calculate(context))


def discount_allocations_by_line_key(discount_result):
    allocations = {}
    # Tolerates ``None`` so the guards below can ask one question — "what comes
    # off this line?" — whether or not the engine has run. A cart can carry a
    # manual discount and no engine result at all.
    if discount_result is None:
        return allocations
    for application in discount_result.applications:
        for allocation in application.allocations:
            allocations[allocation.line_key] = money(
                allocations.get(allocation.line_key, Decimal("0.00")) + allocation.amount
            )
    return allocations


def order_line_subtotals(lines_data):
    """The subtotal each line's ``OrderLine`` will store, keyed by line key.

    Price and quantity are quantized to the line's own field precision first:
    ``Order.recalculate`` reads the persisted line back, so anything finer than
    the column holds is already gone by the time it sums. Shared by
    ``expected_order_totals`` and ``order_line_discounts`` so the amount a line
    can carry and the amount the document charges can never drift apart.
    """
    subtotals = {}
    for line_data in lines_data:
        unit_price = money(
            line_data.get("effective_unit_price", line_data["variant"].unit_price)
        )
        quantity = Decimal(line_data["quantity"]).quantize(QUANTITY_PLACES)
        key = checkout_line_key(line_data)
        subtotals[key] = money(
            subtotals.get(key, Decimal("0.00")) + money(unit_price * quantity)
        )
    return subtotals


def order_line_discounts(lines_data, discount_result, extra_discount_amount=None):
    """Per-line discounts **in the order's own rounding regime**, by line key.

    Covers both kinds: what the engine's rules and coupons allocated, plus the
    cashier's own one-off discount for this invoice
    (``Order.extra_discount_amount``), spread over the lines here. The two are
    summed per line on purpose. A discount is a discount by the time it reaches
    ``OrderLine.discount_total``, and everything downstream — the Z-Report,
    every rollup, profit, the return desk — reads that one column and is
    therefore right about a haggled sale without knowing the feature exists.

    The discount engine allocates in its regime — 2dp HALF_UP — and caps each
    line at *its* subtotal (``DiscountLineInput.subtotal``). An order line
    stores the sales regime, 2dp HALF_EVEN (``OrderLine.line_subtotal``). On a
    line whose gross lands exactly on a half-cent the two disagree by a cent:
    0.750 kg at 5.50 is 4.125, which the engine calls 4.13 and the line calls
    4.12. So an allocation that consumed the whole engine line — a free item, a
    fixed-amount coupon bigger than the cart, a 100% rule, the free unit of a
    buy-X-get-Y — is a cent more than the line can carry.

    Cap each line at the subtotal it will actually store. This is the same move
    ``expected_order_totals`` makes for the document and for the same documented
    reason: the engine decides discount *amounts*, it does not get to decide
    what a line — or the order — is worth. ``checkout_loss_lines`` already
    capped this way when deciding whether a line sells below cost.

    Two things were wrong before the cap, one on each side of the ledger. The
    line settled at ``line_total = -0.01``, which is not a display bug: the
    returns desk credits ``line_total`` for a whole-line return and
    ``adjustment_amount`` refuses a non-positive refund, so those goods could
    not be handed back at all. And the uncapped cent reached the document too,
    so a cart holding the free item plus 6.00 of other goods charged 5.99.
    """
    subtotals, engine_discounts = _engine_line_discounts(
        lines_data, discount_result
    )
    extra = money(extra_discount_amount or Decimal("0.00"))
    if extra <= Decimal("0.00"):
        return engine_discounts
    return _with_manual_discount(subtotals, engine_discounts, extra)


def _engine_line_discounts(lines_data, discount_result):
    """``(subtotals, engine_discounts)`` by line key, each capped as documented
    above. One place, because the two callers below must agree about what a
    line is worth and what is already off it — and because the allocation map
    is built ONCE here. Reading it per line made this quadratic on a path the
    POS fires on every cart edit.
    """
    subtotals = order_line_subtotals(lines_data)
    allocated = discount_allocations_by_line_key(discount_result)
    return subtotals, {
        key: min(allocated.get(key, Decimal("0.00")), subtotal)
        for key, subtotal in subtotals.items()
    }


def manual_discount_room(lines_data, discount_result):
    """The largest manual discount these lines can still carry.

    What the goods are worth less whatever the engine's rules and coupons have
    already taken off them. A discount cannot exceed it — a sale that charges
    less than nothing is not a sale — so this is the bound every caller clamps
    to before the amount reaches a line, a total, or the stored document.
    """
    subtotals, engine_discounts = _engine_line_discounts(
        lines_data, discount_result
    )
    return max(
        money(
            sum(subtotals.values(), Decimal("0.00"))
            - sum(engine_discounts.values(), Decimal("0.00"))
        ),
        Decimal("0.00"),
    )


def clamped_manual_discount(lines_data, discount_result, amount):
    """``amount``, held down to what this cart can actually carry.

    The clamp is not a formality. The figure the cashier typed is checked
    against the shop's ceiling when it arrives, but the cart can shrink between
    the preview and the tender — remove the one expensive line and a 50 dinar
    discount is suddenly larger than the sale. Clamping here is what keeps the
    stored ``Order.extra_discount_amount`` equal to the discount actually
    given, which is what the receipt prints and what an owner reads back.
    """
    return min(
        max(money(amount or Decimal("0.00")), Decimal("0.00")),
        manual_discount_room(lines_data, discount_result),
    )


def _with_manual_discount(subtotals, engine_discounts, extra):
    """Spread the cashier's one-off discount over the lines, in proportion to
    what each still costs after the engine's rules.

    The same largest-remainder allocator the engine itself uses, so not one cent
    is created or lost, and the same weighting ``PurchaseOrder`` uses on the
    buying side: each line's weight is the room it has left, and ``extra`` is
    clamped to the sum of those weights, so no share can ever exceed the line
    it lands on and no line can be discounted below zero.
    """
    room = {
        key: max(subtotal - engine_discounts[key], Decimal("0.00"))
        for key, subtotal in subtotals.items()
    }
    extra = min(extra, money(sum(room.values(), Decimal("0.00"))))
    if extra <= Decimal("0.00"):
        return engine_discounts
    combined = dict(engine_discounts)
    for allocation in allocate_discount_amount(extra, room):
        combined[allocation.line_key] = min(
            money(combined[allocation.line_key] + allocation.amount),
            subtotals[allocation.line_key],
        )
    return combined


def expected_order_totals(lines_data, discount_result, extra_discount_amount=None):
    """``(subtotal, discount_total, total)`` the order for ``lines_data`` will store.

    Deliberately NOT ``discount_result.subtotal/.total``. The two live in
    different rounding regimes, both correct in their own domain:

    * the discount engine rounds a line with ``discounts.services.money`` —
      2dp **HALF_UP** — because a discount amount is rounded in the shop's
      favour by design;
    * an order line rounds with ``OrderLine.line_subtotal`` and
      ``Order.recalculate`` — 2dp **HALF_EVEN**, the sales regime.

    For a line whose ``unit_price × quantity`` lands exactly on a half-cent the
    two disagree by one cent: 0.75 kg at 5.50 is 4.125, which the engine calls
    4.13 and the order calls 4.12. That is harmless while each number stays in
    its own domain, and a live failure the moment the engine's figure is used as
    *the amount to tender* — the order then refuses the payment it was told to
    ask for ("Payment total cannot exceed the order total") and the sale cannot
    be rung up at all.

    So: anything that decides what the customer pays, or shows them what they
    are about to pay, computes it here, in the order's own regime. The engine
    keeps deciding discount *amounts*; it does not get to decide the total.

    That applies to the engine's per-line ``allocation.amount`` as much as to
    its ``.total``, which is why the discounts summed here come from
    ``order_line_discounts`` — each capped at what its own line is worth in this
    regime — rather than from the raw allocations. Summing the same figures the
    lines will store is also what keeps this function, ``Order.recalculate`` and
    the POS preview on one answer.
    """
    subtotal = money(
        sum(order_line_subtotals(lines_data).values(), Decimal("0.00"))
    )
    # The per-line discounts each line can actually carry (order_line_discounts),
    # not the engine's raw allocations: an allocation a cent larger than its own
    # line took that cent off the order too, so a cart of 6.00 of goods plus a
    # free half-cent item charged 5.99. Summing the capped figures also makes
    # this the same number Order.recalculate reaches from the stored lines, so
    # the preview, the tender check and the saved order cannot disagree.
    discount_total = sum(
        order_line_discounts(
            lines_data, discount_result, extra_discount_amount
        ).values(),
        Decimal("0.00"),
    )
    discount_total = min(money(discount_total), subtotal)
    return subtotal, discount_total, money(subtotal - discount_total)


def validate_manual_discount_allowed(amount, *, settings=None):
    """Refuse a till discount above the shop's per-invoice ceiling.

    Server-side because the ceiling is the whole point of the feature. The sell
    screen already stops the cashier typing past it, which is where a limit
    should be felt — but a limit that only exists in the client is a limit that
    holds until somebody posts to the API, and this one is guarding the
    difference between a shop's day's takings and its day's takings minus
    whatever a cashier decided.

    Null ceiling = no ceiling; the amount is still bounded by the cart itself
    (``clamped_manual_discount``). Zero = the shop does not discount at the
    till, and the only amount that passes is nothing.
    """
    amount = money(amount or Decimal("0.00"))
    if amount <= Decimal("0.00"):
        return
    if settings is None:
        settings = ShopSettings.load()
    ceiling = settings.max_invoice_discount_amount
    if ceiling is None:
        return
    ceiling = money(ceiling)
    if amount <= ceiling:
        return
    if ceiling <= Decimal("0.00"):
        raise serializers.ValidationError(
            {
                "extra_discount_amount": (
                    "الخصم اليدوي غير مسموح به في هذا المحل."
                )
            }
        )
    raise serializers.ValidationError(
        {
            "extra_discount_amount": (
                f"أقصى خصم مسموح به للفاتورة الواحدة هو {ceiling:.2f}."
            )
        }
    )


def unapplied_coupon_codes(discount_result, coupon_codes):
    requested_codes = {
        normalize_coupon_code(code)
        for code in coupon_codes or ()
        if normalize_coupon_code(code)
    }
    applied_codes = {
        normalize_coupon_code(application.coupon_code)
        for application in discount_result.applications
        if application.source == DiscountRule.ApplicationType.COUPON_CODE
    }
    return sorted(requested_codes - applied_codes)


def discount_usage_limit_error_payload(exc, field_name):
    if exc.coupon_codes:
        return {
            field_name: (
                "Coupon code is invalid, disabled, expired, or unavailable: "
                + ", ".join(exc.coupon_codes)
            )
        }
    return {"detail": "A discount is no longer available."}


def latest_sale_unit_cost(variant):
    from apps.purchasing.services import latest_variant_unit_cost

    cost = latest_variant_unit_cost(variant.pk)
    if cost is None:
        # Produced goods (bakery output, assembled items) are never purchased;
        # their cost comes from the production batch that made them.
        from apps.operations.services import latest_production_unit_cost

        cost = latest_production_unit_cost(variant.pk)
    return cost or Decimal("0.00")


def latest_sale_unit_costs(variants):
    """Batched ``latest_sale_unit_cost`` keyed by variant pk (per BASE unit):
    purchase cost first, production cost as the fallback for produced goods —
    one query per source instead of N per cart line. A purchase at cost 0 wins
    over the production fallback, exactly like the single-variant path."""
    from apps.operations.services import latest_production_unit_costs
    from apps.purchasing.services import latest_variant_unit_costs

    variant_ids = [variant.pk for variant in variants]
    costs = latest_variant_unit_costs(variant_ids)
    missing = [variant_id for variant_id in variant_ids if variant_id not in costs]
    if missing:
        costs.update(latest_production_unit_costs(missing))
    return costs


def sale_cost_basis(variants, *, warehouse=None):
    """Cost per base unit for a cart, read from the valuation ledger.

    Replaces the old last-purchase-cost lookup as the everyday answer. That
    lookup survives inside the valuation service as the fallback for stock that
    has never been valued, so a brand new product still prices sensibly.
    """
    from apps.inventory.valuation_service import valuation_unit_costs

    return valuation_unit_costs(
        [variant.pk for variant in variants], warehouse=warehouse
    )


#: Where the cart's resolved units are parked for the rest of the request. The
#: loss guard and the consignment floor both walk the same lines a moment apart,
#: and the cashier is waiting on both.
_UNITS_ATTR = "_pointy_named_units"


def units_named_by_lines(lines_data):
    """Every identified article the cart named, by id and by normalised code.

    One query for the whole cart, and none at all for a cart that named none —
    which is every cart in a shop that does not track units. Returned as a pair
    of maps because the picker sends ids and a scanner sends a code, and both
    reach the same article.

    Memoised on the cart's first line for the life of the request: the loss
    guard, the consignment floor and the checkout itself ask the same question
    within a few microseconds of each other, and asking it three times is three
    round trips on the busiest write path in the shop.
    """
    from apps.inventory.identity import normalize_identifier

    anchor = lines_data[0] if lines_data else None
    if isinstance(anchor, dict) and _UNITS_ATTR in anchor:
        return anchor[_UNITS_ATTR]

    ids = set()
    codes = set()
    for line_data in lines_data:
        ids.update(line_data.get("stock_units") or [])
        codes.update(
            normalize_identifier(code)
            for code in (line_data.get("stock_unit_codes") or [])
        )
    codes.discard("")
    if not ids and not codes:
        if isinstance(anchor, dict):
            anchor[_UNITS_ATTR] = ({}, {})
        return {}, {}
    query = Q()
    if ids:
        query |= Q(pk__in=ids)
    if codes:
        query |= Q(code_normalized__in=codes, status__in=StockUnit.LIVE_STATUSES)
    units = (
        StockUnit.objects.filter(query)
        .select_related("variant", "variant__product", "agreement", "consignor")
    )
    by_id = {}
    by_code = {}
    for unit in units:
        by_id[unit.pk] = unit
        by_code[unit.code_normalized] = unit
    if isinstance(anchor, dict):
        anchor[_UNITS_ATTR] = (by_id, by_code)
    return by_id, by_code


def line_units(line_data, by_id, by_code):
    """The articles one cart line names, in the order it named them."""
    from apps.inventory.identity import normalize_identifier

    units = []
    for unit_id in line_data.get("stock_units") or []:
        unit = by_id.get(unit_id)
        if unit is not None:
            units.append(unit)
    for code in line_data.get("stock_unit_codes") or []:
        unit = by_code.get(normalize_identifier(code))
        if unit is not None and unit not in units:
            units.append(unit)
    return units


def validate_consignment_floor(
    lines_data,
    discount_result=None,
    *,
    extra_discount_amount=None,
    settings=None,
):
    """Refuse a fixed-payout consignment sold below what it will cost.

    ``prevent_selling_at_loss`` compares an asking price against
    ``StockUnit.stock_value``, and a consigned article's is **zero until the
    instant of sale** — so on precisely the goods where losing money is easiest,
    the guard that exists to stop it is switched off. A fixed-payout bag with a
    1,200 payout sold at 900 collects 900 and owes 1,200.

    This is therefore not the loss guard and is not gated on the loss guard's
    setting: under a fixed payout the floor is ``max(reserve, payout)`` and it
    is **not overridable**, because selling below it loses the shop its own
    money rather than merely its commission. It is enforced here — server-side,
    at checkout — because the till is not the only caller. Commission mode needs
    no arithmetic floor: the payout scales with the price, so its reserve
    protects the consignor and stays advisory.
    """
    from apps.inventory import consignment as consignment_service

    by_id, by_code = units_named_by_lines(lines_data)
    if not by_id and not by_code:
        return
    # Everything coming off the line, the cashier's own discount included: a
    # floor that only counted the engine's rules would be walked straight
    # through by typing the same number into the discount box instead.
    discount_by_line_key = order_line_discounts(
        lines_data, discount_result, extra_discount_amount
    )
    refusals = []
    for line_data in lines_data:
        units = [unit for unit in line_units(line_data, by_id, by_code)
                 if unit.is_consignment]
        if not units:
            continue
        quantity = Decimal(line_data["quantity"])
        unit_price = money(
            line_data.get("effective_unit_price", line_data["variant"].unit_price)
        )
        line_subtotal = money(unit_price * quantity)
        discount_total = min(
            money(discount_by_line_key.get(checkout_line_key(line_data), Decimal("0.00"))),
            line_subtotal,
        )
        # What one article on this line actually fetches, after whatever the
        # discount engine took off it. A percentage discount on a fixed-payout
        # line eats the shop's commission first and its own money second, and
        # this is what stops it.
        net = money((line_subtotal - discount_total) / quantity) if quantity else Decimal("0.00")
        for unit in units:
            floor = consignment_service.payout_floor(unit)
            if floor > 0 and net < floor:
                refusals.append(
                    {
                        "variant": line_data["variant"].pk,
                        "variant_id": line_data["variant"].pk,
                        "variant_name": line_data["variant"].full_name,
                        "stock_unit": unit.pk,
                        "code": unit.code,
                        "price": f"{net:.2f}",
                        "floor": f"{floor:.2f}",
                    }
                )
    if refusals:
        raise serializers.ValidationError(
            {
                "code": "consignment_below_payout",
                "detail": (
                    "لا يمكن بيع أمانة بسعر أقل من المبلغ المستحق لصاحبها."
                ),
                "consignment": refusals,
            }
        )


def checkout_loss_lines(
    lines_data,
    discount_result=None,
    *,
    extra_discount_amount=None,
    warehouse=None,
):
    # As above: a manual discount is what most often pushes a line under its
    # cost, so it is the last thing this guard may be blind to.
    discount_by_line_key = order_line_discounts(
        lines_data, discount_result, extra_discount_amount
    )
    # Batch the cost lookup across every cart line (was one query per line, on the
    # preview that fires on every keystroke).
    cost_by_variant = sale_cost_basis(
        [line_data["variant"] for line_data in lines_data], warehouse=warehouse
    )
    # An identified article costs what *it* cost, never what the bin averages:
    # a used-goods trader's two handsets of the same model were bought at two
    # prices, and the guard that compares an asking price against a blend is a
    # guard that lets the expensive one go out at the cheap one's floor.
    by_id, by_code = units_named_by_lines(lines_data)
    loss_lines = []
    for line_data in lines_data:
        variant = line_data["variant"]
        quantity = Decimal(line_data["quantity"])
        # Cost is per base unit; scale it to the transacted unit so it lines up
        # with the per-unit price (a box costs 12x a piece).
        unit_factor = Decimal(line_data.get("unit_factor", 1))
        base_cost = cost_by_variant.get(variant.pk) or Decimal("0.00")
        unit_cost = money(base_cost * unit_factor)
        named = line_units(line_data, by_id, by_code) if (by_id or by_code) else []
        if named:
            unit_cost = money(
                max((unit.stock_value for unit in named), default=Decimal("0.00"))
                * unit_factor
            )
        if quantity <= 0 or unit_cost <= 0:
            continue

        unit_price = money(line_data.get("effective_unit_price", variant.unit_price))
        line_subtotal = money(unit_price * quantity)
        line_key = checkout_line_key(line_data)
        discount_total = min(
            money(discount_by_line_key.get(line_key, Decimal("0.00"))),
            line_subtotal,
        )
        line_total = money(line_subtotal - discount_total)
        line_cost = money(unit_cost * quantity)
        if line_total < line_cost:
            loss_lines.append(
                sale_loss_line_payload(
                    line_key=line_key,
                    variant=variant,
                    quantity=quantity,
                    unit_price=unit_price,
                    unit_cost=unit_cost,
                    discount_total=discount_total,
                    line_total=line_total,
                    line_cost=line_cost,
                )
            )
    return loss_lines


def order_loss_lines(order):
    loss_lines = []
    lines = order.lines.select_related("variant", "variant__product")
    for line in lines:
        if line.quantity <= 0 or line.unit_cost <= 0:
            continue
        if line.line_total < line.line_cost:
            loss_lines.append(
                sale_loss_line_payload(
                    line_key=str(line.pk),
                    variant=line.variant,
                    quantity=line.quantity,
                    unit_price=line.unit_price,
                    unit_cost=line.unit_cost,
                    discount_total=line.discount_total,
                    line_total=line.line_total,
                    line_cost=line.line_cost,
                )
            )
    return loss_lines


def sale_loss_line_payload(
    *,
    line_key,
    variant,
    quantity,
    unit_price,
    unit_cost,
    discount_total,
    line_total,
    line_cost,
):
    loss_amount = money(line_cost - line_total)
    return {
        "line_key": line_key,
        "product": variant.product_id,
        "product_id": variant.product_id,
        "variant": variant.pk,
        "variant_id": variant.pk,
        "product_name": variant.product.name,
        "variant_name": variant.full_name,
        "quantity": float(quantity),
        "unit_price": f"{unit_price:.2f}",
        "unit_cost": f"{unit_cost:.2f}",
        "discount_total": f"{discount_total:.2f}",
        "line_total": f"{line_total:.2f}",
        "line_cost": f"{line_cost:.2f}",
        "loss_amount": f"{loss_amount:.2f}",
    }


def validate_checkout_loss_sales_allowed(
    *, settings, lines_data, discount_result, extra_discount_amount=None, warehouse=None
):
    if not settings.prevent_selling_at_loss:
        return
    loss_lines = checkout_loss_lines(
        lines_data,
        discount_result,
        extra_discount_amount=extra_discount_amount,
        warehouse=warehouse,
    )
    if loss_lines:
        raise serializers.ValidationError(sale_loss_blocked_payload(loss_lines))


def validate_order_loss_sales_allowed(*, settings, order):
    if not settings.prevent_selling_at_loss:
        return
    loss_lines = order_loss_lines(order)
    if loss_lines:
        raise serializers.ValidationError(sale_loss_blocked_payload(loss_lines))


def sale_loss_blocked_payload(loss_lines):
    return {
        "code": "sale_at_loss_blocked",
        "detail": "Selling at a loss is disabled for this shop.",
        "loss": loss_lines,
    }


def resolve_credit_due_date(
    *, sale_type, customer, supplied=None, was_supplied=False, settings=None
):
    """The due date to stamp on a sale, or ``None``.

    Three rules, in order:

    **Only credit invoices get one.** A cash sale is settled at the counter and
    a quotation has an expiry rather than a debt, so neither grows a due date
    even if a client sends one. ERPNext draws the same line, returning early
    from its payment-schedule pass for POS invoices — and it is what keeps the
    busiest write path in the shop untouched by this feature: no lookup, no
    settings read, no extra query on a cash checkout.

    **An explicit answer wins.** A cashier who picked a date, or who cleared the
    field to leave the tab open, has said something more specific than the
    customer's standing terms. ``was_supplied`` is what separates "they sent
    null" from "they sent nothing" — collapsing the two would make it impossible
    to record an open-ended debt for a customer who has terms.

    **Otherwise the terms decide.** Which, for a shop that has never configured
    any, is the invoice date itself — the same "due now" that a null has always
    meant.
    """
    if sale_type != Order.SaleType.CREDIT:
        return None
    if was_supplied:
        return supplied
    from apps.core.timeutils import business_local_date
    from apps.customers.payment_terms import resolve_due_date

    return resolve_due_date(customer, business_local_date(), settings=settings)


def validate_customer_credit_limit(
    *, customer, new_debt, settings=None, exclude_order_id=None
):
    """Refuse an آجل sale that would put the customer over their ceiling.

    ``new_debt`` is what the sale actually adds to the receivable — the total
    less whatever is tendered at the till — so a fully-paid sale is never
    refused and a part-paid one is judged on the part that stays owed.

    A credit sale with no customer is unbounded by definition — the shop chose
    to allow anonymous debt by turning ``require_customer_for_credit`` off — so
    there is nobody to hold a limit and nothing to check.
    """
    if customer is None:
        return
    if settings is None:
        from apps.core.models import ShopSettings

        settings = ShopSettings.load()
    if not settings.enforce_customer_credit_limits:
        return
    from apps.customers.receivables import assess_credit

    assessment = assess_credit(
        customer, new_debt, settings=settings, exclude_order_id=exclude_order_id
    )
    if assessment.allowed:
        return
    raise serializers.ValidationError(credit_limit_blocked_payload(assessment))


def credit_limit_blocked_payload(assessment):
    available = assessment.available
    return {
        "code": "credit_limit_exceeded",
        "detail": "This sale would put the customer over their credit limit.",
        "credit": {
            "limit": f"{assessment.limit:.2f}",
            "outstanding": f"{assessment.outstanding:.2f}",
            "available": f"{available:.2f}" if available is not None else None,
            "new_debt": f"{assessment.new_debt:.2f}",
            "projected": f"{assessment.projected:.2f}",
        },
    }


def validate_sale_variants_sellable(lines_data):
    """Reject a checkout that references an archived or deactivated product.

    The API serializer only resolves active variants, but the checkout service
    is also reachable directly (scripts, internal callers, future endpoints).
    Guarding here keeps a discontinued or archived product from ever being sold
    through any path, not just the one the POS happens to use today.
    """
    blocked = []
    for line_data in lines_data:
        variant = line_data["variant"]
        product = variant.product
        if not variant.is_active or not product.is_active or product.archived_at is not None:
            blocked.append(
                {
                    "product_id": product.pk,
                    "variant_id": variant.pk,
                    "product_name": product.name,
                    "variant_name": variant.full_name,
                }
            )
    if blocked:
        raise serializers.ValidationError(
            {
                "detail": "Cannot sell an archived or inactive product.",
                "variants": blocked,
            }
        )


def validate_integration_lines_carry_their_top_up(lines_data):
    """Reject a sale of a recharge service product that tops nobody up.

    ``apps.integrations`` owns one service product per provider, because every
    order line has to point at a real variant. Its standing price is zero —
    the real one is computed per line from the provider's live quote — so a
    line that arrived WITHOUT its top-up payload would hand a customer a free
    recharge that reached no provider, recorded no fulfillment, and left
    nobody anything to notice.

    The product is hidden from the catalog, the search, the variant endpoint
    and the price checker, which is what stops a cashier meeting one. This is
    the rule underneath all of that, for the paths hiding cannot reach: a held
    invoice from before the release, a till that has not updated, a direct
    service call.

    Deliberately NOT in ``CheckoutLineSerializer``: the discount preview
    re-uses that serializer and drops the payload on purpose (it prices, it
    does not sell), so a guard there would soft-fail every preview of a cart
    with a top-up in it. This runs where a line becomes a sold line.
    """
    blocked = [
        {
            "product_id": line_data["variant"].product.pk,
            "variant_id": line_data["variant"].pk,
            "product_name": line_data["variant"].product.name,
        }
        for line_data in lines_data
        if line_data["variant"].product.is_system
        and not line_data.get("integration")
    ]
    if blocked:
        raise serializers.ValidationError(
            {
                "detail": (
                    "This product is sold only through its own flow and "
                    "cannot be rung up on its own."
                ),
                "variants": blocked,
            }
        )
    validate_voucher_lines(lines_data)


def validate_quotation_sells_no_provider_work(lines_data):
    """A quotation cannot carry a top-up or a provider card.

    The till performs a sale's provider work the moment the sale is recorded,
    and a quotation is recorded too — so a card on a quote would be bought,
    and a card's PIN printed, for a customer who has only asked the price.
    """
    if any(line_data.get("integration") for line_data in lines_data):
        raise serializers.ValidationError(
            {
                "detail": (
                    "A quotation cannot include a top-up or a provider card; "
                    "sell it instead."
                ),
                "code": "quotation_provider_line",
            }
        )


def validate_voucher_lines(lines_data):
    """A provider card is sold one to a line, and only while the provider has it.

    One to a line because one line is one purchase from the provider, with one
    PIN on the receipt beneath it and one at-most-once guard around it. Only
    while listed because a card the provider no longer has would be paid for
    here and fail behind the customer's back; the till hides it within
    minutes, and this catches the sale rung up in those minutes.
    """
    problems = []
    for line_data in lines_data:
        resolved = line_data.get("integration") or {}
        voucher = resolved.get("voucher")
        if voucher is None:
            continue
        variant = line_data["variant"]
        if Decimal(line_data.get("quantity") or 0) != 1:
            problems.append(
                {
                    "variant_id": variant.pk,
                    "product_name": variant.product.name,
                    "code": "voucher_quantity",
                }
            )
        elif not (voucher.is_available and voucher.brand.is_listed):
            problems.append(
                {
                    "variant_id": variant.pk,
                    "product_name": variant.product.name,
                    "code": "voucher_unavailable",
                }
            )
    if problems:
        raise serializers.ValidationError(
            {
                "detail": (
                    "A provider card is sold one to a line, and only while "
                    "the provider has it in stock."
                ),
                "code": problems[0]["code"],
                "variants": problems,
            }
        )


@transaction.atomic
def checkout_order(
    *,
    register_session,
    lines_data,
    payments_data,
    customer=None,
    coupon_codes=(),
    discount_result=None,
    extra_discount_amount=None,
    sale_type=Order.SaleType.STANDARD,
    valid_until=None,
    due_date=None,
    due_date_supplied=False,
    reserve_stock=False,
    request=None,
):
    from apps.payments.serializers import PaymentSerializer

    settings = ShopSettings.load()
    # Where this till stands. A shop with one location — which is every shop
    # until it opens a second — resolves to the same warehouse it has always
    # sold from, with nothing configured and nothing to configure.
    warehouse_id = selling_warehouse_id(request)
    is_quotation = sale_type == Order.SaleType.QUOTATION
    # Checkout is the busiest write path in the shop, run thousands of times
    # a day: bulk-load the lines' variants so the per-line product /
    # categories / option_values reads below cost a constant few queries.
    preload_line_variants(lines_data)
    # Give every line its own key before anything reads a per-line figure back
    # by one. ``checkout_line_key`` answers "0" for a line nobody has keyed, so
    # on a direct service call that brought no ``discount_result`` an entire
    # multi-line cart collapsed onto a single key — and the guards below, which
    # look a line's discount up by key, handed EVERY line the whole invoice
    # discount. A cart of two comfortably profitable items was then refused as
    # a sale at a loss the moment a cashier took a dinar off it.
    #
    # Idempotent (it keys by position), and the serializer path has usually run
    # it already via ``calculate_sales_discounts``; this makes the invariant
    # hold for every caller rather than for the ones that happen to.
    prepare_discount_lines(lines_data)
    validate_sale_variants_sellable(lines_data)
    validate_integration_lines_carry_their_top_up(lines_data)
    if is_quotation:
        validate_quotation_sells_no_provider_work(lines_data)
    validate_checkout_loss_sales_allowed(
        settings=settings,
        lines_data=lines_data,
        discount_result=discount_result,
        extra_discount_amount=extra_discount_amount,
        warehouse=warehouse_id,
    )
    validate_consignment_floor(
        lines_data,
        discount_result,
        extra_discount_amount=extra_discount_amount,
        settings=settings,
    )
    # Quotations (عرض سعر) never move stock; standard and credit (آجل) sales
    # deduct on-hand at issue. A quotation may instead hold stock via a
    # reservation (reserve_stock_for_quote, below).
    stock_adjustments = (
        []
        if is_quotation
        else prepare_sale_stock_adjustments(
            lines_data, settings=settings, warehouse=warehouse_id
        )
    )
    # The channel comes from the request's credentials only; direct service
    # calls without a request (scripts, tests) leave it unset.
    sales_channel = require_active_sales_channel(request) if request is not None else None
    order = create_order_with_lines(
        register_session=register_session,
        sales_channel=sales_channel,
        customer=customer,
        sale_type=sale_type,
        valid_until=valid_until if is_quotation else None,
        due_date=resolve_credit_due_date(
            sale_type=sale_type,
            customer=customer,
            supplied=due_date,
            was_supplied=due_date_supplied,
            settings=settings,
        ),
        reserves_stock=bool(reserve_stock) and is_quotation,
        extra_discount_amount=extra_discount_amount,
        lines_data=lines_data,
        coupon_codes=coupon_codes,
        discount_result=discount_result,
        warehouse=warehouse_id,
    )
    # The credit ceiling is judged on what the sale leaves owed — the total less
    # whatever is tendered now — so it waits until the order has a total. Raising
    # inside this atomic block unwinds the order rows with it.
    if sale_type == Order.SaleType.CREDIT:
        paid_total = sum(
            (Decimal(str(payment_data["amount"])) for payment_data in payments_data),
            Decimal("0.00"),
        )
        validate_customer_credit_limit(
            customer=customer,
            new_debt=order.total - paid_total,
            settings=settings,
            exclude_order_id=order.pk,
        )
    if is_quotation:
        # A quote is a price offer, not a sale: no stock movement, no payment.
        # Optionally hold the quoted quantities until valid_until.
        if reserve_stock:
            reserve_stock_for_quote(
                order,
                settings=settings,
                warehouse=warehouse_id,
                lines_data=lines_data,
            )
    else:
        # Standard and credit sales deduct stock at issue. A credit invoice may
        # carry a partial (or zero) down-payment; PaymentSerializer only flips
        # the order to PAID once cumulative payments reach the total, so a
        # partial leaves it OPEN with a balance owed.
        record_sale_stock_movements(
            order, stock_adjustments, request=request, settings=settings
        )
        for payment_data in payments_data:
            serializer_data = {
                "order": order.pk,
                "method": payment_data["method"],
                "amount": payment_data["amount"],
            }
            receipt_url = payment_data.get("card_receipt_url", "")
            if receipt_url:
                serializer_data["card_receipt_url"] = receipt_url
            money_account = payment_data.get("money_account")
            if money_account is not None:
                serializer_data["money_account"] = money_account.pk
            payment_serializer = PaymentSerializer(
                data=serializer_data,
                context={
                    "request": request,
                    "stock_already_recorded": True,
                },
            )
            payment_serializer.is_valid(raise_exception=True)
            payment_serializer.save()
        # A sale that costs nothing (a fully-discounted cart, a giveaway line, an
        # exchange whose replacement is free) takes no tender, so no payment row
        # ever fires PaymentSerializer's flip-to-PAID and the order would sit at
        # OPEN forever. An OPEN standard order is not a recognized sale:
        # ``committed_sales`` skips it, so it reaches neither the register
        # summary, the Z-Report nor any revenue report — while the goods have
        # left and the line still shows on the session's sales list. Settle it
        # here; stock moved above, so this only flips the status.
        order.refresh_from_db()
        if order.status == Order.Status.OPEN and order.balance_due <= Decimal("0.00"):
            mark_order_paid(order, request=request, stock_already_recorded=True)
    order.refresh_from_db()
    # The document is issued here, last, once its lines, stock, reservations
    # and payments are all in place — so it can never be reached half-built.
    # A standard sale that a payment already settled submitted itself through
    # ``mark_order_paid``; a quotation or a part-paid credit invoice arrives
    # here still a draft. Everything above ran inside this transaction, so from
    # outside the order has never existed as anything but issued.
    if order.doc_status == DocumentStatus.DRAFT:
        order = document_services.submit(order, request=request)
    record_domain_event(
        name="sales.checkout.completed",
        event_type=AnalyticsEvent.EventType.AUDIT,
        user=getattr(request, "user", None),
        entity_type="sale_order",
        entity_id=order.pk,
        attributes={
            "receipt_number": order.receipt_number,
            "register_session_id": order.register_session_id,
            "sales_channel": sales_channel.slug if sales_channel is not None else None,
            "customer_present": customer is not None,
            "sale_type": order.sale_type,
            "coupon_count": len(coupon_codes),
            "line_count": len(lines_data),
            "payment_methods": sorted(
                {str(payment_data["method"]) for payment_data in payments_data}
            ),
            "stock_already_recorded": not is_quotation,
        },
        metrics={
            "total": float(order.total),
            "discount_total": float(order.discount_total),
            "payment_count": len(payments_data),
            "item_count": float(
                sum(Decimal(line_data["quantity"]) for line_data in lines_data)
            ),
        },
    )
    # Restaurant flow: an order containing made-to-order dishes lands on the
    # kitchen board immediately, with its recipe ingredients pending. Quotations
    # are not real orders, so they never spawn kitchen jobs.
    if not is_quotation:
        from apps.operations.services import create_kitchen_job_for_order

        create_kitchen_job_for_order(order=order, request=request)
    return order


def prepare_sale_stock_adjustments(lines_data, *, settings=None, warehouse=None):
    settings = settings or ShopSettings.load()
    quantities_by_variant = {}
    variants_by_id = {}
    # Which identified articles the till named, per variant. Empty for every
    # untracked cart, and read only when the variant's mode says so.
    selections_by_variant = {}
    # And which *line* asked for what, in the order the cart sent them. The
    # issue is planned per variant, so without this a sale of two handsets of
    # one model has one plan, two articles and no way back to the two prices
    # they were rung up at (§5.7).
    claims_by_variant = {}
    for line_index, line_data in enumerate(lines_data):
        variant = line_data["variant"]
        if variant.product.is_service or variant.product.is_prepared:
            # Labor/fees have no stock, and made-to-order dishes consume their
            # recipe ingredients through the kitchen job instead.
            continue
        variants_by_id[variant.pk] = variant
        # Stock is kept in the product's base unit, so convert the transacted
        # quantity (e.g. 2 boxes) to base units (24 pieces) before aggregating.
        base_quantity = quantize_quantity(
            line_data["quantity"] * line_data.get("unit_factor", Decimal("1"))
        )
        quantities_by_variant[variant.pk] = (
            quantities_by_variant.get(variant.pk, Decimal("0")) + base_quantity
        )
        selection = selections_by_variant.setdefault(
            variant.pk, {"unit_ids": [], "unit_codes": [], "batch_ids": []}
        )
        selection["unit_ids"].extend(line_data.get("stock_units") or [])
        selection["unit_codes"].extend(line_data.get("stock_unit_codes") or [])
        selection["batch_ids"].extend(line_data.get("stock_batches") or [])
        claims_by_variant.setdefault(variant.pk, []).append(
            {
                "key": str(line_index),
                "quantity": base_quantity,
                "unit_ids": list(line_data.get("stock_units") or []),
                "unit_codes": list(line_data.get("stock_unit_codes") or []),
            }
        )

    stock_adjustments = []
    shortages = []
    # One locking statement for the whole cart instead of one per line — the
    # cashier waits on this. ``lock_stock_items`` keeps the ascending-variant-id
    # lock order the loop below used to establish.
    locked_items = lock_stock_items(variants_by_id.values(), warehouse=warehouse)
    # Resolved once for the cart, not once per line: a cart sells out of one
    # location and the answer cannot change mid-cart, so asking per line would
    # put a query on the cashier's critical path for nothing.
    overselling_allowed = may_oversell(
        warehouse or next(iter(locked_items.values()), None),
        # The cart's own tracked lines are refused individually below, at
        # the point where each one's plan is made, so the document-level
        # answer here is about the place rather than the goods.
        variant=None,
        settings=settings,
    )
    for variant_id in sorted(quantities_by_variant):
        variant = variants_by_id[variant_id]
        quantity = quantities_by_variant[variant_id]
        stock_item = locked_items[variant_id]
        # Identified stock is never oversellable, whatever the shop or the
        # warehouse says: there is no such thing as a phantom handset, and a
        # setting that could conjure one is a setting that produces a serial
        # number for an article nobody has. §3.5 — ERPNext removed their own
        # special case here in v15 for the same reason.
        tracked = tracking.is_tracked(variant)
        # Plan the issue *before* the shortage check, so a cart that names an
        # unavailable unit is refused by the identity rather than by arithmetic.
        if tracked:
            plan = tracking.plan_issue(
                variant=variant,
                warehouse=stock_item.warehouse_id,
                quantity=quantity,
                # Never short: identified stock has no oversell path at all,
                # so a cart that cannot be allocated is refused here rather
                # than allowed through to invent a serial number later.
                allow_short=False,
                **selections_by_variant.get(variant_id, {}),
            )
            attribute_allocations(plan, claims_by_variant.get(variant_id))
            tracking.attach_plan(variant, plan)
        # Sellable = on-hand minus stock held by quotation reservations
        # (quantity_committed). A reservation blocks others from dipping into the
        # held units even though those units are still physically on hand.
        available = stock_item.quantity_on_hand - stock_item.quantity_committed
        if (tracked or not overselling_allowed) and available < quantity:
            shortages.append(
                {
                    "product": variant.product_id,
                    "product_id": variant.product_id,
                    "variant": variant.pk,
                    "variant_id": variant.pk,
                    "product_name": variant.product.name,
                    "variant_name": variant.full_name,
                    "requested": float(quantity),
                    "available": float(available),
                }
            )
        stock_adjustments.append((variant, stock_item, quantity))

    if shortages:
        raise serializers.ValidationError(
            {
                "detail": "Insufficient stock for checkout.",
                "stock": shortages,
            }
        )
    return stock_adjustments


def prepare_sale_stock_adjustments_for_order(order):
    lines = lock_order_lines_for_update(order)
    if not lines:
        raise serializers.ValidationError(
            {"lines": "Order must include at least one line before payment."}
        )
    return prepare_sale_stock_adjustments(
        [
            {
                "variant": line.variant,
                "quantity": line.quantity,
                "unit_factor": line.unit_factor,
            }
            for line in lines
        ]
    )


def record_sale_stock_movements(order, stock_adjustments, *, request=None, settings=None):
    # Deduct every line's stock and write its ledger row in two statements
    # rather than two per line: this runs inside the cashier's checkout, and a
    # 12-line cart used to pay 24 round trips here. The per-line arithmetic is
    # unchanged — each movement is still built from the snapshot taken before
    # that line's deduction, so the before/after history reads identically.
    created_by = adjustment_created_by(request)
    adjusted_items = []
    movements = []

    sold_at = timezone.now()
    line_for = line_resolver(order)
    for variant, stock_item, quantity in stock_adjustments:
        before = stock_snapshot(stock_item)
        stock_item.quantity_on_hand -= quantity
        adjusted_items.append(stock_item)
        # No separate expiry drawdown here any more. A sale plans its own
        # issue — ``prepare_sale_stock_adjustments`` did it, locks and all —
        # and since §18.4 folded ``tracks_expiry`` into ``tracking_mode`` the
        # expiry products are lot-tracked, so calling the cohort drawdown as
        # well would take the same goods off the shelf twice.
        # The plan was made (and its rows locked) back in
        # ``prepare_sale_stock_adjustments``; this is where it is spent.
        plan = tracking.plan_on(variant)
        if plan is not None:
            # Before anything is issued: a consigned article's cost becomes the
            # payout its terms have just earned. The plan carries the total into
            # the valuation pass, which posts it as the purchase half of this
            # sale (§5.8).
            stamp_consignment_payouts(
                plan, lambda allocation, _v=variant.pk: line_for(allocation, _v)
            )
            tracking.apply_issue(
                plan,
                status=StockUnit.Status.SOLD,
                sold_at=sold_at,
                customer=order.customer,
            )
            tracking.clear_plan(variant)
        movements.append(
            build_stock_movement(
                variant=variant,
                stock_item=stock_item,
                movement_type=StockMovement.Type.DECREASE,
                quantity=quantity,
                note=f"بيع {order.receipt_number}",
                created_by=created_by,
                before=before,
                tracked_plan=plan,
            )
        )

    save_stock_item_quantities_bulk(adjusted_items)
    created = create_stock_movements(
        movements,
        voucher_type=StockLedgerEntry.VoucherType.SALE,
        voucher_id=order.pk,
    )
    _stamp_ledger_cost_on_lines(order, created, line_for=line_for)
    finish_sold_units(order, created, settings=settings, request=request)


def _stamp_ledger_cost_on_lines(order, movements, *, line_for=None):
    """Write what the sale actually cost onto its own lines.

    Until the stock is issued nobody knows the cost: with FIFO a sale can
    straddle two purchase prices, and even under moving average the rate can
    move between adding the line and taking the payment. So the line carries a
    provisional cost while the cart is open, and this replaces it with the
    figure the valuation engine settled on when the stock actually left.

    Every report reads ``OrderLine.unit_cost``, so correcting it here is what
    makes gross profit true without touching a single report.

    **An identified line costs what its own article cost.** The movement's rate
    is blended across the variant, which is the right number for the ledger
    entry and the wrong one for a line: a 1,200 handset and an 800 one sold
    together would both report 1,000, and a consigned watch beside an owned one
    would report neither the payout nor the cost. So where an allocation names
    the line it left on, that allocation's own rate wins.
    """
    rates = {
        movement.variant_id: movement.valuation_rate_applied
        for movement in movements
        if getattr(movement, "valuation_rate_applied", None) is not None
    }
    per_line = _identified_line_costs(movements, line_for=line_for)
    if not rates and not per_line:
        return

    lines = list(order.lines.filter(variant_id__in=rates)) if rates else []
    lines += [
        line
        for line in order.lines.filter(pk__in=per_line)
        if line.variant_id not in rates
    ]
    updated = []
    for line in lines:
        # The ledger works in base units; the line is priced in whatever unit
        # was sold, so scale by the factor the line snapshotted.
        base_rate = per_line.get(line.pk)
        if base_rate is None:
            base_rate = rates.get(line.variant_id)
        if base_rate is None:
            continue
        unit_cost = money(base_rate * (line.unit_factor or Decimal("1")))
        if unit_cost != line.unit_cost:
            line.unit_cost = unit_cost
            updated.append(line)
    if updated:
        OrderLine.objects.bulk_update(updated, ["unit_cost", "updated_at"])


def _identified_line_costs(movements, *, line_for=None):
    """``{line pk: base-unit rate}`` for the lines whose articles named them."""
    if line_for is None:
        return {}
    totals = {}
    for movement in movements:
        plan = getattr(movement, "tracked_plan", None)
        if plan is None:
            continue
        for allocation in plan.allocations:
            if allocation.unit is None:
                continue
            line = line_for(allocation, movement.variant_id)
            if line is None:
                continue
            row = totals.setdefault(line.pk, [Decimal("0"), Decimal("0")])
            row[0] += Decimal(allocation.quantity)
            row[1] += Decimal(allocation.value)
    return {
        pk: (value / quantity)
        for pk, (quantity, value) in totals.items()
        if quantity > 0
    }



def reserve_stock_for_quote(order, *, settings=None, warehouse=None, lines_data=None):
    """Place an ACTIVE hold on each stockable line of a quotation: bump the
    variant's ``quantity_committed`` and create a ``StockReservation``. Validates
    availability (on-hand minus existing commitments) unless overselling is on.
    Service/prepared products carry no stock and are skipped.

    ``lines_data`` is the cart as the till sent it, and it is passed in rather
    than rebuilt because ``OrderLine`` has nowhere to keep a chosen article: a
    quote written against a specific handset would otherwise be re-planned from
    the persisted lines, which name only a variant and a quantity, and the hold
    would land on whichever unit happened to be oldest instead.
    """
    settings = settings or ShopSettings.load()
    lines = lock_order_lines_for_update(order)
    # What the till named, per variant, so a quote for two of the same model
    # holds both of the articles it was written against.
    chosen = {}
    for row in lines_data or []:
        variant = row.get("variant")
        if variant is None:
            continue
        entry = chosen.setdefault(
            variant.pk, {"stock_units": [], "stock_unit_codes": [], "stock_batches": []}
        )
        for key in entry:
            entry[key].extend(row.get(key) or [])
    adjustments = prepare_sale_stock_adjustments(
        [
            {
                "variant": line.variant,
                "quantity": line.quantity,
                "unit_factor": line.unit_factor,
                **chosen.get(line.variant_id, {}),
            }
            for line in lines
        ],
        settings=settings,
        warehouse=warehouse,
    )
    for variant, stock_item, quantity in adjustments:
        stock_item.quantity_committed += quantity
        save_stock_item_quantities(stock_item)
        # ``prepare_sale_stock_adjustments`` already planned and locked the
        # articles this line would take; a quotation holds them rather than
        # issuing them. One reservation per unit, so the hold names what the
        # customer was actually shown and the sum still equals the commitment.
        plan = tracking.plan_on(variant)
        units = [
            allocation.unit
            for allocation in (plan.allocations if plan is not None else [])
            if allocation.unit is not None
        ]
        if units:
            for unit in units:
                tracking.transition_unit(unit, StockUnit.Status.RESERVED)
                StockReservation.objects.create(
                    order=order,
                    variant=variant,
                    stock_item=stock_item,
                    warehouse_id=stock_item.warehouse_id,
                    stock_unit=unit,
                    base_quantity=Decimal("1"),
                    expires_at=order.valid_until,
                )
            tracking.clear_plan(variant)
            continue
        tracking.clear_plan(variant)
        StockReservation.objects.create(
            order=order,
            variant=variant,
            stock_item=stock_item,
            # The row the hold was actually placed on, so releasing it later
            # cannot come off a different shelf.
            warehouse_id=stock_item.warehouse_id,
            base_quantity=quantity,
            expires_at=order.valid_until,
        )


def _settle_reservation(reservation, status):
    """Free a reservation's hold (decrement quantity_committed) and stamp its
    terminal status. ACTIVE-only; a no-op for already-settled rows."""
    if reservation.status != StockReservation.Status.ACTIVE:
        return
    # Released from the place it was held in, not from the shop's default.
    stock_item = lock_stock_item(
        variant=reservation.variant, warehouse=reservation.warehouse_id
    )
    stock_item.quantity_committed = max(
        stock_item.quantity_committed - reservation.base_quantity,
        Decimal("0.000"),
    )
    save_stock_item_quantities(stock_item)
    # The article goes back on the shelf whichever way the hold ended: released
    # because the quote lapsed, or consumed because it became a sale — and in
    # that second case the sale that follows has to be able to pick it up.
    if reservation.stock_unit_id:
        unit = StockUnit.objects.select_for_update().get(pk=reservation.stock_unit_id)
        if unit.status == StockUnit.Status.RESERVED:
            tracking.transition_unit(unit, StockUnit.Status.IN_STOCK)
    reservation.status = status
    reservation.save(update_fields=["status", "updated_at"])


def release_quote_reservations(order):
    """Free all active holds on a quotation (expired/cancelled): on-hand is
    untouched, the held units become sellable again."""
    # Lock the active rows: the expiry cron and a concurrent convert can both
    # try to settle the same holds. Without the row lock each could decrement
    # quantity_committed off its own stale in-memory copy (double-decrement);
    # FOR UPDATE makes the loser re-read status and skip already-settled rows.
    for reservation in order.stock_reservations.select_for_update().filter(
        status=StockReservation.Status.ACTIVE
    ):
        _settle_reservation(reservation, StockReservation.Status.RELEASED)


def consume_quote_reservations(order):
    """Mark a quotation's holds CONSUMED when it converts to a real sale. This
    only frees the commitment; the converted order's own stock movements move the
    on-hand units, so there is no double-decrement."""
    # FOR UPDATE so a concurrent expiry-cron release can't settle the same hold
    # in parallel (see release_quote_reservations).
    for reservation in order.stock_reservations.select_for_update().filter(
        status=StockReservation.Status.ACTIVE
    ):
        _settle_reservation(reservation, StockReservation.Status.CONSUMED)


def release_expired_quote_reservations(*, today=None):
    """Release the holds of every quotation whose validity has lapsed.

    A quotation is lapsed once its ``valid_until`` falls before ``today`` (the
    local date by default), so a quote valid through today keeps its hold until
    tomorrow. The quotation stays visible; only the hold is freed, returning the
    held units to availability. Returns the number of quotations released.

    Each quotation is settled in its own transaction so one failure can't strand
    the rest, and ``release_quote_reservations`` locks its rows FOR UPDATE, so
    this is safe to run on a schedule beside a concurrent convert. Idempotent.
    """
    today = today or timezone.localdate()
    expired = (
        Order.objects.quotations()
        .filter(
            reserves_stock=True,
            valid_until__isnull=False,
            valid_until__lt=today,
            stock_reservations__status=StockReservation.Status.ACTIVE,
        )
        .distinct()
    )
    released = 0
    for quotation in expired:
        with transaction.atomic():
            release_quote_reservations(quotation)
        released += 1
    return released


@transaction.atomic
def record_customer_payment(
    order,
    *,
    method,
    amount,
    register_session,
    card_receipt_url="",
    money_account=None,
    request=None,
    allow_cross_owner=False,
    card_receipt_amount_validated=False,
    card_receipt_expected_amount=None,
):
    """Record a payment against an existing invoice's balance.

    Reuses ``PaymentSerializer`` so commission, card linking, the
    receipt-match check and the flip-to-PAID transition all behave exactly as at
    checkout. Rejects quotations (no balance), voids, and over-payment.
    """
    from apps.payments.serializers import PaymentSerializer

    locked = Order.objects.select_for_update().get(pk=order.pk)
    if locked.sale_type == Order.SaleType.QUOTATION:
        raise serializers.ValidationError(
            {"order": "A quotation carries no balance; convert it to an invoice first."}
        )
    if locked.status == Order.Status.VOID:
        raise serializers.ValidationError({"order": "Order is void."})
    amount = money(Decimal(amount))
    if amount <= 0:
        raise serializers.ValidationError({"amount": "Amount must be positive."})
    if amount > locked.balance_due:
        raise serializers.ValidationError(
            {"amount": "Payment cannot exceed the balance due."}
        )

    serializer_data = {"order": locked.pk, "method": method, "amount": amount}
    if card_receipt_url:
        serializer_data["card_receipt_url"] = card_receipt_url
    if money_account is not None:
        serializer_data["money_account"] = getattr(money_account, "pk", money_account)
    payment_serializer = PaymentSerializer(
        data=serializer_data,
        context={
            "request": request,
            "register_session": register_session,
            # The goods left when the invoice was issued; later payments must
            # never re-touch stock when they settle the balance.
            "stock_already_recorded": True,
            # Account-level collection settles any of the customer's open debt,
            # including invoices another cashier issued.
            "allow_cross_owner": allow_cross_owner,
            # An account card collection validates its receipt once against the
            # total; the per-invoice splits skip the per-row amount match.
            "card_receipt_amount_validated": card_receipt_amount_validated,
            # When the receipt can only be proved later (its provider keeps
            # the details on its own server), the split rows must carry the
            # total the slip is expected to show. Without it each row would
            # be checked against its own portion and every one would be
            # flagged a mismatch.
            "card_receipt_expected_amount": card_receipt_expected_amount,
        },
    )
    payment_serializer.is_valid(raise_exception=True)
    payment = payment_serializer.save()
    record_domain_event(
        name="sales.payment.recorded",
        event_type=AnalyticsEvent.EventType.AUDIT,
        user=getattr(request, "user", None),
        entity_type="sale_order",
        entity_id=locked.pk,
        attributes={
            "receipt_number": locked.receipt_number,
            "method": method,
            "register_session_id": getattr(register_session, "pk", None),
        },
        metrics={"amount": float(amount)},
    )
    return payment


@transaction.atomic
def record_customer_account_payment(
    customer,
    *,
    method,
    amount,
    register_session,
    card_receipt_url="",
    money_account=None,
    request=None,
):
    """Apply a payment to a customer's outstanding debt invoices, oldest first.

    Cash, transfer, or card. A card swipe is one receipt for the whole
    collection: it's validated once against the TOTAL here, then split across
    invoices (each split skips the per-row receipt amount-match via
    ``card_receipt_amount_validated`` but still parses + trust-checks + links the
    same card). Rejects over-payment beyond the total outstanding. Returns the
    per-invoice allocation (for the proof-of-payment).
    """
    from apps.payments.models import Payment

    if method not in (
        Payment.Method.CASH,
        Payment.Method.TRANSFER,
        Payment.Method.CARD,
    ):
        raise serializers.ValidationError({"method": "Unsupported payment method."})
    amount = money(Decimal(amount))
    if amount <= 0:
        raise serializers.ValidationError({"amount": "Amount must be positive."})

    invoices = list(
        Order.objects.open_credit()
        .filter(customer=customer)
        .select_for_update()
        .order_by("created_at", "id")
    )
    outstanding = sum((invoice.balance_due for invoice in invoices), Decimal("0.00"))
    if amount > outstanding:
        raise serializers.ValidationError(
            {"amount": "Payment exceeds the customer's outstanding balance."}
        )

    # A card collection is one terminal swipe for the whole amount: validate the
    # receipt ONCE against the total here. The per-invoice splits below then skip
    # the (necessarily failing) per-row amount match but still parse, trust-check
    # and link the same card.
    card_receipt_amount_validated = False
    card_receipt_expected_amount = None
    if method == Payment.Method.CARD and card_receipt_url:
        from apps.payments.card_receipts import (
            CardReceiptError,
            amount_matches,
            parse_receipt_url,
        )

        try:
            receipt = parse_receipt_url(card_receipt_url)
        except CardReceiptError as exc:
            raise serializers.ValidationError(
                {"card_receipt_url": str(exc)}
            ) from exc
        if receipt.is_verified:
            if not amount_matches(amount, receipt):
                raise serializers.ValidationError(
                    {
                        "card_receipt_url": (
                            "Card receipt amount does not match the payment amount."
                        )
                    }
                )
            card_receipt_amount_validated = True
        else:
            # Nothing to check yet: this provider keeps the receipt on its own
            # server. Every split row carries the collection TOTAL so that the
            # verification task compares the slip against the sum it should
            # show, not against one invoice's share of it.
            card_receipt_expected_amount = amount

    remaining = amount
    allocations = []
    for invoice in invoices:
        if remaining <= 0:
            break
        portion = min(remaining, invoice.balance_due)
        if portion <= 0:
            continue
        payment = record_customer_payment(
            invoice,
            method=method,
            amount=portion,
            register_session=register_session,
            request=request,
            card_receipt_url=card_receipt_url,
            # One collection, one bank: every split row lands in the account
            # the swipe (or the cashier) named, not just the first invoice's.
            money_account=money_account,
            card_receipt_amount_validated=card_receipt_amount_validated,
            card_receipt_expected_amount=card_receipt_expected_amount,
            # Cross-cashier: settle whoever's debt this customer owes.
            allow_cross_owner=True,
        )
        allocations.append(
            {"order": invoice, "payment": payment, "amount": portion}
        )
        remaining -= portion
    return allocations


@transaction.atomic
def assign_credit_invoice_customer(order, *, customer, request=None):
    """Assign or change the customer who owes a debt (آجل) invoice.

    Allowed only while NOT A SINGLE payment row exists (down-payment at issue,
    later collection, or a refund): once money moved, the invoice is part of a
    customer's payment history and reassignment would silently rewrite who paid
    whom. Sale terms (lines, totals, applied discounts) are snapshots agreed at
    issue and are intentionally left untouched — this fixes WHO owes, never how
    much.
    """
    locked = Order.objects.select_for_update().get(pk=order.pk)
    if locked.sale_type != Order.SaleType.CREDIT:
        raise serializers.ValidationError(
            {"order": "Only a credit (debt) invoice can be assigned a customer."}
        )
    if locked.status == Order.Status.VOID:
        raise serializers.ValidationError({"order": "Order is void."})
    if locked.payments.exists():
        raise serializers.ValidationError(
            {
                "order": (
                    "A payment has already been recorded against this invoice; "
                    "its customer can no longer be changed."
                )
            }
        )
    previous_customer_id = locked.customer_id
    if previous_customer_id == customer.pk:
        return locked
    locked.customer = customer
    locked.save(update_fields=["customer", "updated_at"])
    record_domain_event(
        name="sales.customer.assigned",
        event_type=AnalyticsEvent.EventType.AUDIT,
        user=getattr(request, "user", None),
        entity_type="sale_order",
        entity_id=locked.pk,
        attributes={
            "receipt_number": locked.receipt_number,
            "previous_customer_id": previous_customer_id,
            "customer_id": customer.pk,
        },
    )
    return locked


@transaction.atomic
def reschedule_credit_invoice_due_date(order, *, due_date, request=None):
    """Move (or clear) the due date on an outstanding credit invoice.

    A due date is the one term on an آجل invoice that a shop genuinely
    renegotiates — the customer asks for another week, or the cashier fat-fingers
    the year on the date picker. Without this the only remedies were voiding a
    real sale or living with a wrong reminder forever.

    It is deliberately narrow. It moves *when* the debt is settled and never how
    much: lines, totals and discounts are the terms agreed at issue and are not
    touched. A settled invoice is left alone — rescheduling a debt nobody owes
    is meaningless, and permitting it would let a closed invoice reappear in the
    aging report.

    ``due_date=None`` clears the date, returning the invoice to an open tab. It
    is a real instruction, not a missing argument, which is why the caller has
    to pass it explicitly.
    """
    locked = Order.objects.select_for_update().get(pk=order.pk)
    if locked.sale_type != Order.SaleType.CREDIT:
        raise serializers.ValidationError(
            {"order": "Only a credit (debt) invoice has a due date."}
        )
    if locked.status != Order.Status.OPEN:
        raise serializers.ValidationError(
            {"order": "Only an outstanding invoice can be rescheduled."}
        )
    previous = locked.due_date
    if previous == due_date:
        return locked
    locked.due_date = due_date
    locked.save(update_fields=["due_date", "updated_at"])
    record_domain_event(
        name="sales.credit.rescheduled",
        event_type=AnalyticsEvent.EventType.AUDIT,
        user=getattr(request, "user", None),
        entity_type="sale_order",
        entity_id=locked.pk,
        attributes={
            "receipt_number": locked.receipt_number,
            "previous_due_date": previous.isoformat() if previous else None,
            "due_date": due_date.isoformat() if due_date else None,
        },
    )
    return locked


def _quote_lines_to_checkout_data(lines, *, order=None):
    """Rebuild ``lines_data`` from a quotation's persisted lines so the
    conversion re-runs the normal checkout path (re-snapshotting cost at current
    values and re-evaluating discounts). Modifier options that were since deleted
    are dropped from the re-priced breakdown.

    A quotation that held identified articles carries them into the sale. The
    customer was shown *that* handset — its IMEI, its battery health, its price
    — so converting must not hand the picker a free choice and sell whichever
    one happens to be oldest.
    """
    held = {}
    if order is not None:
        for reservation in order.stock_reservations.filter(
            status=StockReservation.Status.ACTIVE, stock_unit__isnull=False
        ):
            held.setdefault(reservation.variant_id, []).append(
                reservation.stock_unit_id
            )
    lines_data = []
    for line in lines:
        modifiers = [
            {"option": modifier.modifier_option, "quantity": modifier.quantity}
            for modifier in line.modifiers.all()
            if modifier.modifier_option_id is not None
        ]
        lines_data.append(
            {
                "variant": line.variant,
                "quantity": line.quantity,
                "unit": line.unit,
                "unit_factor": line.unit_factor,
                # The stored unit_price already folds in the modifier deltas.
                "effective_unit_price": line.unit_price,
                "modifiers": modifiers,
                "notes": line.notes,
                # Taken, not copied: a quote with the same variant on two lines
                # must not send the same unit twice.
                "stock_units": [
                    held[line.variant_id].pop(0)
                    for _ in range(int(line.quantity * line.unit_factor))
                    if held.get(line.variant_id)
                ],
            }
        )
    return lines_data


@transaction.atomic
def convert_quotation_to_sale(
    quotation,
    *,
    sale_type,
    register_session,
    payments_data=(),
    request=None,
):
    """Convert a quotation in place into a real sale (standard or credit).

    Builds a NEW order from the quote's lines through the normal checkout path
    (fresh cost snapshot, re-evaluated discounts, stock movement, payments), then
    consumes any reservation and links + voids the quote for audit. A standard
    conversion must be paid in full; a credit conversion may be partial.
    """
    if sale_type not in (Order.SaleType.STANDARD, Order.SaleType.CREDIT):
        raise serializers.ValidationError(
            {"sale_type": "Convert target must be a standard or credit sale."}
        )
    locked = Order.objects.select_for_update().get(pk=quotation.pk)
    if locked.sale_type != Order.SaleType.QUOTATION:
        raise serializers.ValidationError({"order": "Order is not a quotation."})
    if locked.status != Order.Status.OPEN or locked.converted_to_id is not None:
        raise serializers.ValidationError(
            {"order": "Quotation has already been converted or closed."}
        )
    lines = lock_order_lines_for_update(locked)
    if not lines:
        raise serializers.ValidationError({"lines": "Quotation has no lines."})
    # Read the holds before they are settled, so the sale can name the very
    # articles the quotation was written against.
    lines_data = _quote_lines_to_checkout_data(lines, order=locked)

    # Free the held stock first so the converted sale moves on-hand exactly once.
    consume_quote_reservations(locked)
    new_order = checkout_order(
        register_session=register_session,
        lines_data=lines_data,
        payments_data=list(payments_data),
        customer=locked.customer,
        sale_type=sale_type,
        request=request,
    )
    if sale_type == Order.SaleType.STANDARD and new_order.balance_due > 0:
        # Validated against the freshly computed total (discounts may have moved
        # since the quote); the atomic block rolls the whole conversion back.
        raise serializers.ValidationError(
            {"payments": "A standard sale must be paid in full."}
        )

    # Supersession, not amendment: the sale is its own document with its own
    # number. ``converted_to`` is the older name for the same forward pointer
    # and is kept in step until the column goes.
    locked.converted_to = new_order
    locked.save(update_fields=["converted_to", "updated_at"])
    locked = document_services.supersede(
        locked,
        new_order,
        reason="تم تحويل عرض السعر إلى فاتورة",
        request=request,
    )
    record_domain_event(
        name="sales.quotation.converted",
        event_type=AnalyticsEvent.EventType.AUDIT,
        user=getattr(request, "user", None),
        entity_type="sale_order",
        entity_id=new_order.pk,
        attributes={
            "quotation_receipt_number": locked.receipt_number,
            "receipt_number": new_order.receipt_number,
            "sale_type": new_order.sale_type,
        },
        metrics={"total": float(new_order.total)},
    )
    return new_order


# What the till told us it will do with the receipt, sent on the checkout body.
RECEIPT_DELIVERY_LOCAL = "local"
RECEIPT_DELIVERY_AGENT = "agent"
RECEIPT_DELIVERY_CHOICES = (RECEIPT_DELIVERY_LOCAL, RECEIPT_DELIVERY_AGENT)


def requested_receipt_delivery(request):
    """How the caller says this sale's receipt will reach the customer.

    ``local`` means the till prints it itself and no queue row should be made.
    ``agent`` (or nothing at all, from a client too old to say) leaves the
    decision to whether an agent is actually reading the queue.
    """
    data = getattr(request, "data", None)
    if not isinstance(data, dict):
        return None
    value = data.get("receipt_delivery")
    if isinstance(value, str) and value in RECEIPT_DELIVERY_CHOICES:
        return value
    return None


def create_receipt_print_job(order_id, *, request=None):
    """Persist the receipt print job atomically with the sale — when anything
    is going to read it.

    The print job is an outbox row that print agents poll for and print, so it
    does not depend on Redis or Celery for delivery. Creating it inside the
    sale's transaction (rather than in a post-commit hook) means a broker
    outage or a crash in the post-commit window can never silently drop a paid
    order's receipt.

    Two things can mean nothing will ever read it, and both skip creation:

    The till said it prints the receipt itself. A driver/PDF printer is driven
    straight from the client, which never touches the queue — so a row made for
    that sale is one no consumer exists for. This is the exact per-sale answer
    and it also keeps a mixed shop honest: with one agent-backed till and one
    printing locally, the agent must not claim and re-print the other till's
    receipt.

    Or no agent has been seen recently, which is the fallback for callers with
    no client to ask (a payment settled later, an operations job). In the field
    a shop printing straight from the till banked 24,264 unread receipt jobs —
    one per sale, each carrying a full receipt payload — while every receipt
    printed perfectly by the other route.

    Skipping loses nothing that was not already lost: the receipt is reprintable
    from the order either way, which is what this outbox has always fallen back
    on when printing fails.

    Job creation runs in its own savepoint and any failure is swallowed and
    logged: a printing misconfiguration (for example a broken default
    template) must never roll back a completed, paid sale.
    """
    from apps.printing.services import enqueue_receipt_print_job, print_agent_is_live

    try:
        if requested_receipt_delivery(request) == RECEIPT_DELIVERY_LOCAL:
            return
        with transaction.atomic():
            if not print_agent_is_live():
                return
            enqueue_receipt_print_job(order_id)
    except Exception:
        logger.exception(
            "Failed to enqueue receipt print job for order %s; the sale is "
            "unaffected and the receipt can be reprinted from the order.",
            order_id,
        )


def mark_order_paid(order, *, request=None, stock_already_recorded=False):
    locked_order = Order.objects.select_for_update().get(pk=order.pk)
    if locked_order.status == Order.Status.PAID:
        return locked_order
    if locked_order.status != Order.Status.OPEN:
        raise serializers.ValidationError(
            {"order": "Only open orders can be marked paid."}
        )

    settings = ShopSettings.load()
    validate_order_loss_sales_allowed(settings=settings, order=locked_order)

    if not stock_already_recorded:
        stock_adjustments = prepare_sale_stock_adjustments_for_order(locked_order)
        record_sale_stock_movements(
            locked_order,
            stock_adjustments,
            request=request,
        )

    # Paying is a money event, not a lifecycle one — but for an order that has
    # not been submitted yet (one created through the API rather than at a
    # till), this is the moment its stock leaves and it becomes real.
    if locked_order.doc_status == DocumentStatus.DRAFT:
        locked_order = document_services.submit(locked_order, request=request)
    else:
        sales_documents.recompute_progress(locked_order)
    create_receipt_print_job(locked_order.pk, request=request)
    record_domain_event(
        name="sales.order.paid",
        event_type=AnalyticsEvent.EventType.AUDIT,
        user=getattr(request, "user", None),
        entity_type="sale_order",
        entity_id=locked_order.pk,
        attributes={
            "receipt_number": locked_order.receipt_number,
            "register_session_id": locked_order.register_session_id,
            "stock_already_recorded": stock_already_recorded,
        },
        metrics={"total": float(locked_order.total)},
    )
    return locked_order


def validate_order_adjustment_allowed(order, *, request=None, allow_window_override=False):
    if order.status != Order.Status.PAID:
        raise serializers.ValidationError({"detail": "Only paid orders can be adjusted."})
    if order.register_session is None:
        raise serializers.ValidationError(
            {"detail": "Order is not linked to a register session."}
        )
    # Non-managers normally cannot touch an order once the short cashier window
    # has elapsed. ``allow_window_override`` lifts that for a trusted operator
    # (a cashier holding ``sales.process_return_lookup``) processing a returns
    # desk lookup — they may adjust any invoice by number regardless of age.
    if (
        request is not None
        and not user_is_manager(request.user)
        and not allow_window_override
        and cashier_window_expired(order)
    ):
        raise serializers.ValidationError(
            {"detail": "This order requires manager approval to adjust."}
        )


def refund_method_for_order(order):
    payment = order.payments.order_by("created_at").first()
    if payment is None:
        from apps.payments.models import Payment

        return Payment.Method.CASH
    return refund_tender(payment.method)


def refund_tender(method):
    """The tender a refund goes back through, for money taken by ``method``.

    Every tender but one refunds through itself: a card sale back to the card,
    cash from the drawer. A salary deduction cannot — there is no wage to hand
    back at the counter — so what the employee's wages settled is given back in
    cash, and the drawer that pays it out is the one that counts it.
    """
    from apps.payments.models import Payment

    if method == Payment.Method.SALARY_DEDUCTION:
        return Payment.Method.CASH
    return method


def adjustment_register_session(order, context_session):
    return context_session or order.register_session


def adjustment_amount(lines):
    amount = sum(
        (line_refund_amount(line, quantity) for line, quantity in lines),
        Decimal("0.00"),
    ).quantize(MONEY_PLACES)
    if amount <= 0:
        raise serializers.ValidationError({"detail": "Adjustment amount must be positive."})
    return amount


def line_refund_discount(line, quantity):
    if line.discount_total <= 0:
        return Decimal("0.00")

    remaining_discount = money(line.discount_total - line.returned_discount_total)
    if quantity >= line.returnable_quantity:
        discount = max(remaining_discount, Decimal("0.00"))
    else:
        proportional_discount = money(
            line.discount_total * Decimal(quantity) / Decimal(line.quantity)
        )
        discount = min(proportional_discount, max(remaining_discount, Decimal("0.00")))
    # A refund line can never credit less than nothing. Each part of a split
    # return rounds its own gross on its own, so a proportional share of a
    # fully-discounted line can land a cent ABOVE the gross it is about to be
    # subtracted from: 0.500 kg off a 1.500 kg line at 3.33 is a 1.66 gross
    # against a 1.67 share. Clamping here rather than in line_refund_amount
    # keeps the amount paid out and the discount stored on OrderAdjustmentLine
    # the same number, so the refund document still adds up.
    return min(discount, money(line.unit_price * Decimal(quantity)))


def line_refund_amount(line, quantity):
    gross_amount = money(line.unit_price * Decimal(quantity))
    return money(gross_amount - line_refund_discount(line, quantity))


def proportional_cent_split(amount, weights, *, order):
    """Split ``amount`` across ``weights`` in proportion, exactly to the cent.

    Largest-remainder rounding: every share is floored, then the leftover cents
    go to the biggest fractional parts first, so the parts always sum back to
    ``amount`` rather than to ``amount`` minus a rounding crumb. ``order`` is
    the deterministic tie-break — two shops on the same data must split a half
    cent the same way, and dict order is not a promise. Ties go to the LAST
    key in ``order``, which is exactly what this code has always done: it
    ranked on ``(remainder, method)`` descending, and ``order`` is those same
    methods ascending. Ranking on the POSITION rather than on the key itself
    is what lets the same splitter take account ids too, where ``None`` cannot
    be compared against an integer.

    One implementation, used at both levels of a refund (across the methods
    that paid, then across the accounts inside a method), so a refund cannot be
    split by two subtly different roundings.
    """
    total = sum(weights.values(), Decimal("0.00"))
    if total <= 0:
        return {}
    floored = {}
    remainder = {}
    for index, key in enumerate(order):
        share = (amount * weights[key]) / total
        floor_share = share.quantize(MONEY_PLACES, rounding=ROUND_DOWN)
        floored[key] = floor_share
        remainder[key] = (share - floor_share, index)

    allocated = sum(floored.values(), Decimal("0.00"))
    leftover_cents = int(((amount - allocated) / MONEY_PLACES).to_integral_value())
    ranked = sorted(order, key=lambda key: remainder[key], reverse=True)
    for index in range(leftover_cents):
        floored[ranked[index % len(ranked)]] += MONEY_PLACES
    return floored


def refund_tender_allocations(order, amount):
    """Split a refund across the order's original tenders, proportional to how
    much each tender actually paid (net of any earlier refunds).

    A split cash+card sale therefore refunds the cash share from cash and the
    card share from card, so the drawer is only ever reduced by the cash part.
    Returns a list of ``(method, amount)`` whose amounts sum *exactly* to
    ``amount``. Falls back to the order's primary tender when there is no
    positive payment to attribute the refund to.
    """
    from apps.payments.models import Payment

    amount = money(amount)
    net_by_method = {}
    rows = Payment.objects.filter(order=order).values("method").annotate(
        total=Sum("amount")
    )
    for row in rows:
        net = money(row["total"] or Decimal("0.00"))
        if net > 0:
            method = refund_tender(row["method"])
            net_by_method[method] = net_by_method.get(method, Decimal("0.00")) + net

    if not net_by_method:
        return [(refund_method_for_order(order), amount)]

    methods = sorted(net_by_method)
    floored = proportional_cent_split(amount, net_by_method, order=methods)
    return [(method, floored[method]) for method in methods if floored[method] > 0]


def refund_tender_account_allocations(order, allocations):
    """Say which bank account each method's refund share comes back out of.

    A card sale taken on the Jumhouria terminal and refunded must reduce the
    Jumhouria account, not whichever account happens to be the default — that
    is the whole point of tagging a payment with its account, and a refund that
    ignored it would put the shop's two banks permanently out by the value of
    every return.

    Deliberately a SECOND pass over ``allocations`` rather than one split keyed
    on (method, account): the per-method amounts are then bit-identical to what
    this code paid out before accounts existed, so no test, report or oracle
    expectation moves by the cent that a different grouping would round away.

    Yields ``(method, money_account_id, amount)``.
    """
    from apps.payments.models import Payment

    net_by_key = {}
    rows = (
        Payment.objects.filter(order=order)
        .values("method", "money_account")
        .annotate(total=Sum("amount"))
    )
    for row in rows:
        net = money(row["total"] or Decimal("0.00"))
        if net > 0:
            net_by_key.setdefault(row["method"], {})[row["money_account"]] = net

    for method, method_amount in allocations:
        accounts = net_by_key.get(method) or {}
        if len(accounts) <= 1:
            # The ordinary case, and the only one before this feature: one
            # account (or none named at all) took every payment of this method.
            account_id = next(iter(accounts), None)
            yield method, account_id, method_amount
            continue
        # Untagged first, then by id, so the tie-break never depends on NULL
        # sorting against an integer.
        ordering = sorted(
            accounts, key=lambda value: (value is not None, value or 0)
        )
        split = proportional_cent_split(method_amount, accounts, order=ordering)
        for account_id in ordering:
            if split[account_id] > 0:
                yield method, account_id, split[account_id]


def create_order_adjustment(
    *,
    order,
    adjustment_type,
    lines,
    reason,
    request=None,
    register_session=None,
    created_by=None,
    consignment_action=BUY_IN,
):
    from apps.payments.models import Payment
    from apps.payments.serializers import payment_commission_values

    # The lifecycle hands the actor down directly; every other caller still
    # reads it off the request.
    created_by = created_by or adjustment_created_by(request)
    amount = adjustment_amount(lines)
    allocations = refund_tender_allocations(order, amount)
    cash_amount = sum(
        (alloc for method, alloc in allocations if method == Payment.Method.CASH),
        Decimal("0.00"),
    )
    # The displayed refund method is the tender that absorbed the largest share;
    # for a single-tender sale that is simply the one method that was used.
    primary_method = max(allocations, key=lambda item: item[1])[0]

    adjustment = OrderAdjustment.objects.create(
        order=order,
        register_session=adjustment_register_session(order, register_session),
        adjustment_type=adjustment_type,
        amount=amount,
        refund_method=primary_method,
        cash_amount=cash_amount,
        reason=reason,
        created_by=created_by,
    )

    for line, quantity in lines:
        discount_total = line_refund_discount(line, quantity)
        OrderAdjustmentLine.objects.create(
            adjustment=adjustment,
            order_line=line,
            variant=line.variant,
            quantity=quantity,
            unit_price=line.unit_price,
            discount_total=discount_total,
        )
        # A serialized line returns *that* article — the handset with that IMEI,
        # not "one of those" — which is also what stops the same one being
        # returned twice (§6.4).
        tracked_plan = return_units_for_line(
            line,
            quantize_quantity(Decimal(quantity) * line.unit_factor),
            consignment_action=consignment_action,
            request=request,
        )
        record_return_stock_movement(
            order=order,
            variant=line.variant,
            # Returned quantity is in the line's transacted unit; stock is base.
            quantity=quantize_quantity(Decimal(quantity) * line.unit_factor),
            created_by=created_by,
            tracked_plan=tracked_plan,
        )

    # One negative payment per original tender so each method's ledger and the
    # cash drawer are reduced by exactly their share of the refund — and, when
    # a method was taken across two bank accounts, one per account so each
    # bank is reduced by its own share.
    for method, account_id, alloc in refund_tender_account_allocations(
        order, allocations
    ):
        commission_percent, commission_amount = payment_commission_values(method, -alloc)
        Payment.objects.create(
            order=order,
            method=method,
            amount=-alloc,
            money_account_id=account_id,
            commission_percent=commission_percent,
            commission_amount=commission_amount,
            external_reference=f"{adjustment.adjustment_type}:{adjustment.pk}",
        )
    return adjustment


def lock_order_lines_for_update(order, *, line_ids=None):
    queryset = (
        OrderLine.objects.select_for_update()
        .filter(order=order)
        .select_related("variant", "variant__product")
        .order_by("pk")
    )
    if line_ids is not None:
        queryset = queryset.filter(pk__in=line_ids)
    lines = list(queryset)
    if lines:
        # The same locking read either way — but landed in each line's prefetch
        # cache instead of thrown away. Every caller then asks its lines for
        # ``returnable_quantity``, which sums ``adjustment_lines``: unprefetched
        # that is an aggregate per line (twice per line, in the comprehensions
        # that filter and then keep it), on top of a row set already read and
        # locked here. Fresh as of the lock is exactly the guarantee these
        # callers want, since nothing may write these rows until they commit.
        prefetch_related_objects(
            lines,
            Prefetch(
                "adjustment_lines",
                queryset=OrderAdjustmentLine.objects.select_for_update().order_by(
                    "pk"
                ),
            ),
        )
    return lines


def fresh_order_adjustment_lines(locked_order, lines, *, locked_lines=None):
    requested_by_line = {}
    for line, quantity in lines:
        requested_by_line[line.pk] = requested_by_line.get(line.pk, 0) + quantity

    if not requested_by_line:
        return []

    if locked_lines is None:
        locked_lines = lock_order_lines_for_update(
            locked_order,
            line_ids=requested_by_line,
        )
    lines_by_id = {line.pk: line for line in locked_lines}
    if set(requested_by_line) - set(lines_by_id):
        raise serializers.ValidationError(
            {"lines": "Return line does not belong to this order."}
        )

    fresh_lines = []
    for line_id, quantity in requested_by_line.items():
        line = lines_by_id[line_id]
        returnable_quantity = line.returnable_quantity
        if quantity > returnable_quantity:
            raise serializers.ValidationError(
                {
                    "lines": (
                        f"Cannot return more than {returnable_quantity} "
                        "remaining items."
                    )
                }
            )
        fresh_lines.append((line, quantity))
    return fresh_lines


@transaction.atomic
def void_order(
    *, order, reason, request=None, register_session=None, allow_window_override=False
):
    locked_order = Order.objects.select_for_update().get(pk=order.pk)
    validate_order_adjustment_allowed(
        locked_order, request=request, allow_window_override=allow_window_override
    )
    locked_lines = lock_order_lines_for_update(locked_order)
    lines = [
        (line, line.returnable_quantity)
        for line in locked_lines
        if line.returnable_quantity > 0
    ]
    if not lines:
        raise serializers.ValidationError({"detail": "No remaining items can be voided."})

    # The reversal itself is ``apps.sales.documents.reverse``; the primitive
    # owns everything around it — the period lock this path never had, the
    # trail, and the status that follows from the lifecycle rather than being
    # assigned beside it.
    locked_order = document_services.cancel(
        locked_order,
        reason=reason,
        request=request,
        actor=adjustment_created_by(request),
        context={
            "register_session": adjustment_register_session(
                locked_order, register_session
            ),
            "lines": lines,
        },
    )
    adjustment = (
        locked_order.adjustments.filter(
            adjustment_type=OrderAdjustment.AdjustmentType.VOID
        )
        .order_by("-created_at", "-id")
        .first()
    )
    expired = cashier_window_expired(locked_order)
    record_domain_event(
        name="sales.order.voided",
        event_type=AnalyticsEvent.EventType.AUDIT,
        severity=(
            AnalyticsEvent.Severity.WARNING
            if expired
            else AnalyticsEvent.Severity.INFO
        ),
        user=getattr(request, "user", None),
        entity_type="sale_order",
        entity_id=locked_order.pk,
        attributes={
            "receipt_number": locked_order.receipt_number,
            "register_session_id": locked_order.register_session_id,
            "reason_present": bool(reason),
            "manager_override": bool(
                request is not None and user_is_manager(request.user)
            ),
            "cashier_window_expired": expired,
            "requires_suspicion_review": expired,
            "line_count": len(lines),
        },
        metrics={
            "amount": float(adjustment.amount),
            "item_count": float(sum(quantity for _, quantity in lines)),
        },
    )
    return adjustment


@transaction.atomic
def return_order_items(
    *,
    order,
    lines,
    reason,
    request=None,
    register_session=None,
    allow_window_override=False,
    consignment_action=BUY_IN,
):
    locked_order = Order.objects.select_for_update().get(pk=order.pk)
    validate_order_adjustment_allowed(
        locked_order, request=request, allow_window_override=allow_window_override
    )
    locked_lines = lock_order_lines_for_update(locked_order)
    lines = fresh_order_adjustment_lines(
        locked_order,
        lines,
        locked_lines=locked_lines,
    )
    adjustment = create_order_adjustment(
        order=locked_order,
        adjustment_type=OrderAdjustment.AdjustmentType.RETURN,
        lines=lines,
        reason=reason,
        request=request,
        register_session=register_session,
        consignment_action=consignment_action,
    )

    # A sale whose every line has come back is spent. That has always been the
    # rule; it is now derived rather than assigned, so it cannot be applied in
    # one place and forgotten in another.
    sales_documents.recompute_progress(locked_order)
    expired = cashier_window_expired(locked_order)
    record_domain_event(
        name="sales.order.returned",
        event_type=AnalyticsEvent.EventType.AUDIT,
        severity=(
            AnalyticsEvent.Severity.WARNING
            if expired
            else AnalyticsEvent.Severity.INFO
        ),
        user=getattr(request, "user", None),
        entity_type="sale_order",
        entity_id=locked_order.pk,
        attributes={
            "receipt_number": locked_order.receipt_number,
            "register_session_id": locked_order.register_session_id,
            "adjustment_id": adjustment.pk,
            "refund_method": adjustment.refund_method,
            "reason_present": bool(reason),
            "manager_override": bool(
                request is not None and user_is_manager(request.user)
            ),
            "cashier_window_expired": expired,
            "requires_suspicion_review": expired,
            "order_became_void": locked_order.status == Order.Status.VOID,
            "line_count": len(lines),
        },
        metrics={
            "amount": float(adjustment.amount),
            "item_count": float(sum(quantity for _, quantity in lines)),
        },
    )
    return adjustment


@transaction.atomic
def exchange_order_items(
    *,
    order,
    outbound_lines,
    replacement_lines,
    settlement_method,
    reason,
    request=None,
    register_session=None,
    allow_window_override=False,
):
    """Exchange returned item(s) for replacement item(s) as one atomic operation.

    Composes the two existing, individually-correct legs:

    * **Outbound** — ``return_order_items`` restocks the returned goods, reverses
      the original tender(s), and is counted by reporting as a RETURN. Adjustment
      eligibility (paid status, register session, cashier window) is validated
      here.
    * **Replacement** — ``checkout_order`` rings up the replacement item(s) as a
      real new sale at current price, paid by ``settlement_method``, so revenue,
      COGS, profit and stock all flow through the normal checkout path.

    The customer settles only the net (``replacement_amount - outbound_amount``);
    the gross legs reconcile the cash drawer to that same net via the existing
    ``OrderAdjustment.cash_amount`` + ``Payment`` rows. An ``OrderExchange`` row
    links the pair and a ``sales.order.exchanged`` audit event is recorded.
    """
    adjustment = return_order_items(
        order=order,
        lines=outbound_lines,
        reason=reason,
        request=request,
        register_session=register_session,
        allow_window_override=allow_window_override,
    )

    session = register_session or order.register_session
    discount_result = calculate_sales_discounts(
        lines_data=replacement_lines,
        customer=order.customer,
    )
    _, _, replacement_total = expected_order_totals(replacement_lines, discount_result)
    payments_data = (
        [{"method": settlement_method, "amount": replacement_total}]
        if replacement_total > 0
        else []
    )
    replacement_order = checkout_order(
        register_session=session,
        lines_data=replacement_lines,
        payments_data=payments_data,
        customer=order.customer,
        discount_result=discount_result,
        request=request,
    )

    outbound_amount = money(adjustment.amount)
    net_amount = money(replacement_total - outbound_amount)
    exchange = OrderExchange.objects.create(
        original_order=order,
        return_adjustment=adjustment,
        replacement_order=replacement_order,
        register_session=session,
        outbound_amount=outbound_amount,
        replacement_amount=replacement_total,
        net_amount=net_amount,
        settlement_method=settlement_method,
        reason=reason,
        created_by=adjustment_created_by(request),
    )
    expired = cashier_window_expired(order)
    record_domain_event(
        name="sales.order.exchanged",
        event_type=AnalyticsEvent.EventType.AUDIT,
        severity=(
            AnalyticsEvent.Severity.WARNING
            if expired
            else AnalyticsEvent.Severity.INFO
        ),
        user=getattr(request, "user", None),
        entity_type="sale_order",
        entity_id=order.pk,
        attributes={
            "receipt_number": order.receipt_number,
            "register_session_id": order.register_session_id,
            "exchange_id": exchange.pk,
            "adjustment_id": adjustment.pk,
            "replacement_order_id": replacement_order.pk,
            "replacement_receipt_number": replacement_order.receipt_number,
            "settlement_method": settlement_method,
            "reason_present": bool(reason),
            "manager_override": bool(
                request is not None and user_is_manager(request.user)
            ),
            "window_override": bool(allow_window_override),
            "cashier_window_expired": expired,
            "requires_suspicion_review": expired,
            "outbound_line_count": len(outbound_lines),
            "replacement_line_count": len(replacement_lines),
        },
        metrics={
            "outbound_amount": float(outbound_amount),
            "replacement_amount": float(replacement_total),
            "net_amount": float(net_amount),
        },
    )
    return exchange


def record_return_stock_movement(
    *, order, variant, quantity, created_by, warehouse=None, tracked_plan=None
):
    # Goods come back to the shelves the till that took them back serves.
    # Defaults to the shop's one place, which is where they left from for every
    # shop that has never opened a second.
    stock_item = lock_stock_item(variant=variant, warehouse=warehouse)
    before = stock_snapshot(stock_item)
    stock_item.quantity_on_hand += quantity
    save_stock_item_quantities(stock_item)
    create_stock_movement(
        variant=variant,
        stock_item=stock_item,
        movement_type=StockMovement.Type.INCREASE,
        quantity=quantity,
        note=f"مرتجع {order.receipt_number}",
        created_by=created_by,
        before=before,
        # Returned goods re-enter at what they cost when they left, not at
        # today's rate. Valuing a return at the current rate would book a
        # profit or loss on a sale that was simply undone.
        unit_cost=returned_line_base_unit_cost(order, variant),
        # ...unless the articles themselves say what they cost, in which case
        # they do and the line's average does not get a vote.
        tracked_plan=tracked_plan,
        voucher_type=StockLedgerEntry.VoucherType.SALE_RETURN,
        voucher_id=order.pk,
    )


def returned_line_base_unit_cost(order, variant):
    """Cost per base unit that this variant left the shop at on this order.

    ``None`` when the order has no such line (it should), which lets the
    valuation fall back to the bin's own rate rather than guessing at zero.
    """
    line = (
        order.lines.filter(variant=variant)
        .order_by("id")
        .values("unit_cost", "unit_factor")
        .first()
    )
    if line is None:
        return None
    factor = line["unit_factor"] or Decimal("1")
    if factor <= 0:
        return line["unit_cost"]
    return Decimal(line["unit_cost"]) / factor
