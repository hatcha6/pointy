import logging
from datetime import timedelta
from decimal import Decimal, ROUND_DOWN

from django.db import transaction
from django.db.models import Sum
from django.utils import timezone
from rest_framework import serializers

logger = logging.getLogger(__name__)

from apps.analytics.models import AnalyticsEvent
from apps.analytics.services import record_domain_event
from apps.channels.services import require_active_sales_channel
from apps.core.models import ShopSettings
from apps.core.roles import user_is_manager
from apps.holidays.services import special_day_keys_for
from apps.discounts.models import DiscountRule, normalize_coupon_code
from apps.discounts.services import (
    DiscountContext,
    DiscountEngine,
    DiscountLineInput,
    DiscountUsageLimitExceeded,
    persist_applied_discounts,
)
from apps.catalog.units import quantize_quantity
from apps.inventory.models import StockMovement
from apps.inventory.services import (
    consume_expiring_stock_batches,
    create_stock_movement,
    lock_stock_item,
    save_stock_item_quantities,
    stock_snapshot,
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
    **order_fields,
):
    customer = order_fields.get("customer")
    if discount_result is None:
        discount_result = calculate_sales_discounts(
            lines_data=lines_data,
            customer=customer,
            coupon_codes=coupon_codes,
        )
    discount_by_line_key = discount_allocations_by_line_key(discount_result)

    # Snapshot the special day(s) active right now (shop-local) onto the sale so
    # forecasting has a stable per-sale signal. Defensive by contract: a holidays
    # failure degrades to an empty list and never rolls back a paid sale.
    if "special_day_keys" not in order_fields:
        order_fields["special_day_keys"] = special_day_keys_for()

    order = Order.objects.create(**order_fields)
    line_objects_by_key = {}
    for line_data in lines_data:
        variant = line_data["variant"]
        line_key = checkout_line_key(line_data)
        # The transacted unit + its base-conversion factor are snapshots so price,
        # cost, and stock all stay self-consistent if the product's units change
        # later. unit_cost is per base unit, scaled to the transacted unit so
        # line_cost = unit_cost * quantity stays correct.
        unit_factor = line_data.get("unit_factor", Decimal("1"))
        line = OrderLine.objects.create(
            order=order,
            variant=variant,
            quantity=line_data["quantity"],
            unit=line_data.get("unit", ""),
            unit_factor=unit_factor,
            # Effective price folds in the selected unit's price + modifier deltas;
            # falls back to the bare variant price for lines without either.
            unit_price=line_data.get("effective_unit_price", variant.unit_price),
            unit_cost=money(latest_sale_unit_cost(variant) * unit_factor),
            discount_total=discount_by_line_key.get(line_key, Decimal("0.00")),
            notes=line_data.get("notes", ""),
        )
        _persist_order_line_modifiers(line, line_data.get("modifiers", []))
        line_objects_by_key[line_key] = line
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
                category_ids=tuple(product.categories.values_list("id", flat=True)),
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
    for application in discount_result.applications:
        for allocation in application.allocations:
            allocations[allocation.line_key] = money(
                allocations.get(allocation.line_key, Decimal("0.00")) + allocation.amount
            )
    return allocations


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


def checkout_loss_lines(lines_data, discount_result=None):
    discount_by_line_key = (
        discount_allocations_by_line_key(discount_result)
        if discount_result is not None
        else {}
    )
    # Batch the cost lookup across every cart line (was one query per line, on the
    # preview that fires on every keystroke).
    cost_by_variant = latest_sale_unit_costs(
        [line_data["variant"] for line_data in lines_data]
    )
    loss_lines = []
    for line_data in lines_data:
        variant = line_data["variant"]
        quantity = Decimal(line_data["quantity"])
        # Cost is per base unit; scale it to the transacted unit so it lines up
        # with the per-unit price (a box costs 12x a piece).
        unit_factor = Decimal(line_data.get("unit_factor", 1))
        base_cost = cost_by_variant.get(variant.pk) or Decimal("0.00")
        unit_cost = money(base_cost * unit_factor)
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


def validate_checkout_loss_sales_allowed(*, settings, lines_data, discount_result):
    if not settings.prevent_selling_at_loss:
        return
    loss_lines = checkout_loss_lines(lines_data, discount_result)
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


@transaction.atomic
def checkout_order(
    *,
    register_session,
    lines_data,
    payments_data,
    customer=None,
    coupon_codes=(),
    discount_result=None,
    sale_type=Order.SaleType.STANDARD,
    valid_until=None,
    reserve_stock=False,
    request=None,
):
    from apps.payments.serializers import PaymentSerializer

    settings = ShopSettings.load()
    is_quotation = sale_type == Order.SaleType.QUOTATION
    validate_sale_variants_sellable(lines_data)
    validate_checkout_loss_sales_allowed(
        settings=settings,
        lines_data=lines_data,
        discount_result=discount_result,
    )
    # Quotations (عرض سعر) never move stock; standard and credit (آجل) sales
    # deduct on-hand at issue. A quotation may instead hold stock via a
    # reservation (reserve_stock_for_quote, below).
    stock_adjustments = (
        []
        if is_quotation
        else prepare_sale_stock_adjustments(lines_data, settings=settings)
    )
    # The channel comes from the request's credentials only; direct service
    # calls without a request (scripts, tests) leave it unset.
    sales_channel = require_active_sales_channel(request) if request is not None else None
    order = create_order_with_lines(
        register_session=register_session,
        sales_channel=sales_channel,
        customer=customer,
        sale_type=sale_type,
        valid_until=valid_until,
        reserves_stock=bool(reserve_stock) and is_quotation,
        lines_data=lines_data,
        coupon_codes=coupon_codes,
        discount_result=discount_result,
    )
    if is_quotation:
        # A quote is a price offer, not a sale: no stock movement, no payment.
        # Optionally hold the quoted quantities until valid_until.
        if reserve_stock:
            reserve_stock_for_quote(order, settings=settings)
    else:
        # Standard and credit sales deduct stock at issue. A credit invoice may
        # carry a partial (or zero) down-payment; PaymentSerializer only flips
        # the order to PAID once cumulative payments reach the total, so a
        # partial leaves it OPEN with a balance owed.
        record_sale_stock_movements(order, stock_adjustments, request=request)
        for payment_data in payments_data:
            serializer_data = {
                "order": order.pk,
                "method": payment_data["method"],
                "amount": payment_data["amount"],
            }
            receipt_url = payment_data.get("card_receipt_url", "")
            if receipt_url:
                serializer_data["card_receipt_url"] = receipt_url
            payment_serializer = PaymentSerializer(
                data=serializer_data,
                context={
                    "request": request,
                    "stock_already_recorded": True,
                },
            )
            payment_serializer.is_valid(raise_exception=True)
            payment_serializer.save()
    order.refresh_from_db()
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


def prepare_sale_stock_adjustments(lines_data, *, settings=None):
    settings = settings or ShopSettings.load()
    quantities_by_variant = {}
    variants_by_id = {}
    for line_data in lines_data:
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

    stock_adjustments = []
    shortages = []
    for variant_id in sorted(quantities_by_variant):
        variant = variants_by_id[variant_id]
        quantity = quantities_by_variant[variant_id]
        stock_item = lock_stock_item(variant=variant)
        # Sellable = on-hand minus stock held by quotation reservations
        # (quantity_committed). A reservation blocks others from dipping into the
        # held units even though those units are still physically on hand.
        available = stock_item.quantity_on_hand - stock_item.quantity_committed
        if not settings.allow_overselling and available < quantity:
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


def record_sale_stock_movements(order, stock_adjustments, *, request=None):
    created_by = adjustment_created_by(request)

    for variant, stock_item, quantity in stock_adjustments:
        before = stock_snapshot(stock_item)
        stock_item.quantity_on_hand -= quantity
        save_stock_item_quantities(stock_item)
        consume_expiring_stock_batches(variant=variant, quantity=quantity)
        create_stock_movement(
            variant=variant,
            stock_item=stock_item,
            movement_type=StockMovement.Type.DECREASE,
            quantity=quantity,
            note=f"بيع {order.receipt_number}",
            created_by=created_by,
            before=before,
        )


def reserve_stock_for_quote(order, *, settings=None):
    """Place an ACTIVE hold on each stockable line of a quotation: bump the
    variant's ``quantity_committed`` and create a ``StockReservation``. Validates
    availability (on-hand minus existing commitments) unless overselling is on.
    Service/prepared products carry no stock and are skipped."""
    settings = settings or ShopSettings.load()
    lines = lock_order_lines_for_update(order)
    adjustments = prepare_sale_stock_adjustments(
        [
            {
                "variant": line.variant,
                "quantity": line.quantity,
                "unit_factor": line.unit_factor,
            }
            for line in lines
        ],
        settings=settings,
    )
    for variant, stock_item, quantity in adjustments:
        stock_item.quantity_committed += quantity
        save_stock_item_quantities(stock_item)
        StockReservation.objects.create(
            order=order,
            variant=variant,
            stock_item=stock_item,
            base_quantity=quantity,
            expires_at=order.valid_until,
        )


def _settle_reservation(reservation, status):
    """Free a reservation's hold (decrement quantity_committed) and stamp its
    terminal status. ACTIVE-only; a no-op for already-settled rows."""
    if reservation.status != StockReservation.Status.ACTIVE:
        return
    stock_item = lock_stock_item(variant=reservation.variant)
    stock_item.quantity_committed = max(
        stock_item.quantity_committed - reservation.base_quantity,
        Decimal("0.000"),
    )
    save_stock_item_quantities(stock_item)
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
    request=None,
    allow_cross_owner=False,
    card_receipt_amount_validated=False,
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
    if method == Payment.Method.CARD and card_receipt_url:
        from apps.payments.moamalat import (
            MoamalatReceiptError,
            parse_moamalat_receipt_url,
            payment_amount_matches_receipt,
        )

        try:
            receipt = parse_moamalat_receipt_url(card_receipt_url)
        except MoamalatReceiptError as exc:
            raise serializers.ValidationError(
                {"card_receipt_url": str(exc)}
            ) from exc
        if not payment_amount_matches_receipt(amount, receipt):
            raise serializers.ValidationError(
                {
                    "card_receipt_url": (
                        "Card receipt amount does not match the payment amount."
                    )
                }
            )
        card_receipt_amount_validated = True

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
            card_receipt_amount_validated=card_receipt_amount_validated,
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


def _quote_lines_to_checkout_data(lines):
    """Rebuild ``lines_data`` from a quotation's persisted lines so the
    conversion re-runs the normal checkout path (re-snapshotting cost at current
    values and re-evaluating discounts). Modifier options that were since deleted
    are dropped from the re-priced breakdown."""
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
    lines_data = _quote_lines_to_checkout_data(lines)

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

    locked.converted_to = new_order
    locked.status = Order.Status.VOID
    locked.save(update_fields=["converted_to", "status", "updated_at"])
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


def create_receipt_print_job(order_id):
    """Persist the receipt print job atomically with the sale.

    The print job is an outbox row that print agents poll for and print, so it
    does not depend on Redis or Celery for delivery. Creating it inside the
    sale's transaction (rather than in a post-commit hook) means a broker
    outage or a crash in the post-commit window can never silently drop a paid
    order's receipt.

    Job creation runs in its own savepoint and any failure is swallowed and
    logged: a printing misconfiguration (for example a broken default
    template) must never roll back a completed, paid sale. When that happens
    the sale still commits and staff can reprint the receipt from the order.
    """
    from apps.printing.services import enqueue_receipt_print_job

    try:
        with transaction.atomic():
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

    locked_order.status = Order.Status.PAID
    locked_order.save(update_fields=["status", "updated_at"])
    create_receipt_print_job(locked_order.pk)
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
    return payment.method


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
        return max(remaining_discount, Decimal("0.00"))

    proportional_discount = money(
        line.discount_total * Decimal(quantity) / Decimal(line.quantity)
    )
    return min(proportional_discount, max(remaining_discount, Decimal("0.00")))


def line_refund_amount(line, quantity):
    gross_amount = money(line.unit_price * Decimal(quantity))
    return money(gross_amount - line_refund_discount(line, quantity))


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
            net_by_method[row["method"]] = net

    if not net_by_method:
        return [(refund_method_for_order(order), amount)]

    methods = sorted(net_by_method)
    total_net = sum(net_by_method.values(), Decimal("0.00"))
    floored = {}
    remainder = {}
    for method in methods:
        share = (amount * net_by_method[method]) / total_net
        floor_share = share.quantize(MONEY_PLACES, rounding=ROUND_DOWN)
        floored[method] = floor_share
        remainder[method] = share - floor_share

    allocated = sum(floored.values(), Decimal("0.00"))
    leftover_cents = int(((amount - allocated) / MONEY_PLACES).to_integral_value())
    # Largest-remainder rounding: hand the leftover cents to the tenders with the
    # biggest fractional part first, tie-broken deterministically by method name,
    # so the per-tender amounts always sum back to exactly ``amount``.
    ranked = sorted(methods, key=lambda method: (remainder[method], method), reverse=True)
    for index in range(leftover_cents):
        floored[ranked[index % len(ranked)]] += MONEY_PLACES

    return [(method, floored[method]) for method in methods if floored[method] > 0]


def create_order_adjustment(
    *,
    order,
    adjustment_type,
    lines,
    reason,
    request=None,
    register_session=None,
):
    from apps.payments.models import Payment
    from apps.payments.serializers import payment_commission_values

    created_by = adjustment_created_by(request)
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
        record_return_stock_movement(
            order=order,
            variant=line.variant,
            # Returned quantity is in the line's transacted unit; stock is base.
            quantity=quantize_quantity(Decimal(quantity) * line.unit_factor),
            created_by=created_by,
        )

    # One negative payment per original tender so each method's ledger and the
    # cash drawer are reduced by exactly their share of the refund.
    for method, alloc in allocations:
        commission_percent, commission_amount = payment_commission_values(method, -alloc)
        Payment.objects.create(
            order=order,
            method=method,
            amount=-alloc,
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
        list(
            OrderAdjustmentLine.objects.select_for_update()
            .filter(order_line_id__in=[line.pk for line in lines])
            .order_by("pk")
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

    adjustment = create_order_adjustment(
        order=locked_order,
        adjustment_type=OrderAdjustment.AdjustmentType.VOID,
        lines=lines,
        reason=reason,
        request=request,
        register_session=register_session,
    )
    locked_order.status = Order.Status.VOID
    locked_order.save(update_fields=["status", "updated_at"])
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
    *, order, lines, reason, request=None, register_session=None, allow_window_override=False
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
    )

    if all(line.returnable_quantity == 0 for line in locked_lines):
        locked_order.status = Order.Status.VOID
        locked_order.save(update_fields=["status", "updated_at"])
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
    replacement_total = money(discount_result.total)
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


def record_return_stock_movement(*, order, variant, quantity, created_by):
    stock_item = lock_stock_item(variant=variant)
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
    )
