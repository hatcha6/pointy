from datetime import timedelta
from decimal import Decimal

from django.db import transaction
from django.utils import timezone
from rest_framework import serializers

from apps.core.models import ShopSettings
from apps.core.roles import user_is_manager
from apps.discounts.models import DiscountRule, normalize_coupon_code
from apps.discounts.services import (
    DiscountContext,
    DiscountEngine,
    DiscountLineInput,
    DiscountUsageLimitExceeded,
    persist_applied_discounts,
)
from apps.inventory.models import StockMovement
from apps.inventory.services import (
    create_stock_movement,
    lock_stock_item,
    save_stock_item_quantities,
    stock_snapshot,
)
from .models import Order, OrderAdjustment, OrderAdjustmentLine, OrderLine


MONEY_PLACES = Decimal("0.01")


def money(value):
    return Decimal(value).quantize(MONEY_PLACES)


def cashier_window_expired(order):
    if order.created_at is None:
        return False
    settings = ShopSettings.load()
    deadline = order.created_at + timedelta(
        hours=settings.cashier_return_window_hours,
    )
    return timezone.now() > deadline


def can_adjust_order(order, user=None):
    if order.status != Order.Status.PAID:
        return False
    if not any(line.returnable_quantity > 0 for line in order.lines.all()):
        return False
    if user is not None and user_is_manager(user):
        return True
    return not cashier_window_expired(order)


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

    order = Order.objects.create(**order_fields)
    line_objects_by_key = {}
    for line_data in lines_data:
        product = line_data["product"]
        line_key = checkout_line_key(line_data)
        line = OrderLine.objects.create(
            order=order,
            product=product,
            quantity=line_data["quantity"],
            unit_price=product.unit_price,
            unit_cost=latest_sale_unit_cost(product),
            discount_total=discount_by_line_key.get(line_key, Decimal("0.00")),
        )
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


def checkout_line_key(line_data):
    return str(line_data.get("_discount_line_key", "0"))


def prepare_discount_lines(lines_data):
    prepared_lines = []
    for index, line_data in enumerate(lines_data):
        line_data["_discount_line_key"] = str(index)
        product = line_data["product"]
        prepared_lines.append(
            DiscountLineInput(
                key=str(index),
                product_id=product.pk,
                quantity=line_data["quantity"],
                unit_amount=product.unit_price,
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
    return DiscountEngine().calculate(
        sales_discount_context(
            lines_data=lines_data,
            customer=customer,
            coupon_codes=coupon_codes,
        )
    )


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


def latest_sale_unit_cost(product):
    from apps.purchasing.services import latest_product_unit_cost

    return latest_product_unit_cost(product.pk) or Decimal("0.00")


@transaction.atomic
def checkout_order(
    *,
    register_session,
    lines_data,
    payments_data,
    customer=None,
    coupon_codes=(),
    discount_result=None,
    request=None,
):
    from apps.payments.serializers import PaymentSerializer

    stock_adjustments = prepare_sale_stock_adjustments(lines_data)
    order = create_order_with_lines(
        register_session=register_session,
        customer=customer,
        lines_data=lines_data,
        coupon_codes=coupon_codes,
        discount_result=discount_result,
    )
    record_sale_stock_movements(order, stock_adjustments, request=request)

    for payment_data in payments_data:
        payment_serializer = PaymentSerializer(
            data={
                "order": order.pk,
                "method": payment_data["method"],
                "amount": payment_data["amount"],
            }
        )
        payment_serializer.is_valid(raise_exception=True)
        payment_serializer.save()
    order.refresh_from_db()
    return order


def prepare_sale_stock_adjustments(lines_data):
    settings = ShopSettings.load()
    quantities_by_product = {}
    products_by_id = {}
    for line_data in lines_data:
        product = line_data["product"]
        products_by_id[product.pk] = product
        quantities_by_product[product.pk] = (
            quantities_by_product.get(product.pk, 0) + line_data["quantity"]
        )

    stock_adjustments = []
    shortages = []
    for product_id in sorted(quantities_by_product):
        product = products_by_id[product_id]
        quantity = quantities_by_product[product_id]
        stock_item = lock_stock_item(product)
        if not settings.allow_overselling and stock_item.quantity_on_hand < quantity:
            shortages.append(
                {
                    "product": product.pk,
                    "product_name": product.name,
                    "requested": quantity,
                    "available": stock_item.quantity_on_hand,
                }
            )
        stock_adjustments.append((product, stock_item, quantity))

    if shortages:
        raise serializers.ValidationError(
            {
                "detail": "Insufficient stock for checkout.",
                "stock": shortages,
            }
        )
    return stock_adjustments


def record_sale_stock_movements(order, stock_adjustments, *, request=None):
    created_by = adjustment_created_by(request)

    for product, stock_item, quantity in stock_adjustments:
        before = stock_snapshot(stock_item)
        stock_item.quantity_on_hand -= quantity
        save_stock_item_quantities(stock_item)
        create_stock_movement(
            product=product,
            stock_item=stock_item,
            movement_type=StockMovement.Type.DECREASE,
            quantity=quantity,
            note=f"بيع {order.receipt_number}",
            created_by=created_by,
            before=before,
        )


def validate_order_adjustment_allowed(order, *, request=None):
    if order.status != Order.Status.PAID:
        raise serializers.ValidationError({"detail": "Only paid orders can be adjusted."})
    if order.register_session is None:
        raise serializers.ValidationError(
            {"detail": "Order is not linked to a register session."}
        )
    if (
        request is not None
        and not user_is_manager(request.user)
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
    refund_method = refund_method_for_order(order)
    amount = adjustment_amount(lines)
    commission_percent, commission_amount = payment_commission_values(
        refund_method,
        -amount,
    )

    adjustment = OrderAdjustment.objects.create(
        order=order,
        register_session=adjustment_register_session(order, register_session),
        adjustment_type=adjustment_type,
        amount=amount,
        refund_method=refund_method,
        reason=reason,
        created_by=created_by,
    )

    for line, quantity in lines:
        discount_total = line_refund_discount(line, quantity)
        OrderAdjustmentLine.objects.create(
            adjustment=adjustment,
            order_line=line,
            product=line.product,
            quantity=quantity,
            unit_price=line.unit_price,
            discount_total=discount_total,
        )
        record_return_stock_movement(
            order=order,
            product=line.product,
            quantity=quantity,
            created_by=created_by,
        )

    Payment.objects.create(
        order=order,
        method=refund_method,
        amount=-amount,
        commission_percent=commission_percent,
        commission_amount=commission_amount,
        external_reference=f"{adjustment.adjustment_type}:{adjustment.pk}",
    )
    return adjustment


@transaction.atomic
def void_order(*, order, reason, request=None, register_session=None):
    locked_order = (
        Order.objects.select_for_update()
        .select_related("register_session")
        .prefetch_related("lines__product")
        .get(pk=order.pk)
    )
    lines = [
        (line, line.returnable_quantity)
        for line in locked_order.lines.select_related("product")
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
    return adjustment


@transaction.atomic
def return_order_items(*, order, lines, reason, request=None, register_session=None):
    locked_order = (
        Order.objects.select_for_update()
        .select_related("register_session")
        .get(pk=order.pk)
    )
    adjustment = create_order_adjustment(
        order=locked_order,
        adjustment_type=OrderAdjustment.AdjustmentType.RETURN,
        lines=lines,
        reason=reason,
        request=request,
        register_session=register_session,
    )

    if all(line.returnable_quantity == 0 for line in locked_order.lines.all()):
        locked_order.status = Order.Status.VOID
        locked_order.save(update_fields=["status", "updated_at"])
    return adjustment


def record_return_stock_movement(*, order, product, quantity, created_by):
    stock_item = lock_stock_item(product)
    before = stock_snapshot(stock_item)
    stock_item.quantity_on_hand += quantity
    save_stock_item_quantities(stock_item)
    create_stock_movement(
        product=product,
        stock_item=stock_item,
        movement_type=StockMovement.Type.INCREASE,
        quantity=quantity,
        note=f"مرتجع {order.receipt_number}",
        created_by=created_by,
        before=before,
    )
