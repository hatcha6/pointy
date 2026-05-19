from datetime import timedelta
from decimal import Decimal

from django.db import transaction
from django.utils import timezone
from rest_framework import serializers

from apps.core.models import ShopSettings
from apps.core.roles import user_is_manager
from apps.inventory.models import StockItem, StockMovement
from .models import Order, OrderAdjustment, OrderAdjustmentLine, OrderLine


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
def create_order_with_lines(*, lines_data, **order_fields):
    order = Order.objects.create(**order_fields)
    for line_data in lines_data:
        product = line_data["product"]
        OrderLine.objects.create(
            order=order,
            product=product,
            quantity=line_data["quantity"],
            unit_price=product.unit_price,
            unit_cost=latest_sale_unit_cost(product),
        )
    order.recalculate()
    order.save(update_fields=["subtotal", "total", "updated_at"])
    return order


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
    request=None,
):
    from apps.payments.serializers import PaymentSerializer

    stock_adjustments = prepare_sale_stock_adjustments(lines_data)
    order = create_order_with_lines(
        register_session=register_session,
        customer=customer,
        lines_data=lines_data,
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
        stock_item, _ = StockItem.objects.select_for_update().get_or_create(
            product=product,
        )
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
        StockMovement.objects.create(
            product=product,
            stock_item=stock_item,
            movement_type=StockMovement.Type.DECREASE,
            quantity=quantity,
            note=f"بيع {order.receipt_number}",
            created_by=created_by,
            on_hand_before=before["on_hand"],
            on_hand_after=stock_item.quantity_on_hand,
            committed_before=before["committed"],
            committed_after=stock_item.quantity_committed,
            expected_before=before["expected"],
            expected_after=stock_item.quantity_expected,
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
        (line.unit_price * quantity for line, quantity in lines),
        Decimal("0.00"),
    ).quantize(Decimal("0.01"))
    if amount <= 0:
        raise serializers.ValidationError({"detail": "Adjustment amount must be positive."})
    return amount


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
        OrderAdjustmentLine.objects.create(
            adjustment=adjustment,
            order_line=line,
            product=line.product,
            quantity=quantity,
            unit_price=line.unit_price,
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
    stock_item, _ = StockItem.objects.select_for_update().get_or_create(
        product=product,
    )
    before = stock_snapshot(stock_item)
    stock_item.quantity_on_hand += quantity
    save_stock_item_quantities(stock_item)
    StockMovement.objects.create(
        product=product,
        stock_item=stock_item,
        movement_type=StockMovement.Type.INCREASE,
        quantity=quantity,
        note=f"مرتجع {order.receipt_number}",
        created_by=created_by,
        on_hand_before=before["on_hand"],
        on_hand_after=stock_item.quantity_on_hand,
        committed_before=before["committed"],
        committed_after=stock_item.quantity_committed,
        expected_before=before["expected"],
        expected_after=stock_item.quantity_expected,
    )


def stock_snapshot(stock_item):
    return {
        "on_hand": stock_item.quantity_on_hand,
        "committed": stock_item.quantity_committed,
        "expected": stock_item.quantity_expected,
    }


def save_stock_item_quantities(stock_item):
    stock_item.save(
        update_fields=[
            "quantity_on_hand",
            "quantity_committed",
            "quantity_expected",
            "updated_at",
        ],
    )
