from decimal import Decimal

from django.db import transaction
from django.utils import timezone
from rest_framework import serializers

from apps.inventory.models import StockItem, StockMovement
from .models import (
    PurchaseLine,
    PurchaseOrder,
    PurchaseOrderAdjustment,
    PurchaseOrderAdjustmentLine,
)


def latest_purchase_line_for_product(product_id, *, before_line=None):
    lines = PurchaseLine.objects.filter(product_id=product_id).exclude(
        purchase_order__status=PurchaseOrder.Status.CANCELLED,
    )
    if before_line is not None:
        lines = lines.exclude(pk=before_line.pk)
        if before_line.created_at is not None:
            lines = lines.filter(created_at__lt=before_line.created_at)
    return lines.order_by("-created_at", "-id").first()


def latest_product_unit_cost(product_id):
    line = latest_purchase_line_for_product(product_id)
    return None if line is None else line.unit_cost


def purchase_created_by(request):
    if request is not None and request.user.is_authenticated:
        return request.user
    return None


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


@transaction.atomic
def save_purchase_order_with_lines(*, purchase_order=None, lines_data=None, **order_fields):
    if purchase_order is None:
        purchase_order = PurchaseOrder.objects.create(**order_fields)
    else:
        if purchase_order.status != PurchaseOrder.Status.DRAFT:
            raise serializers.ValidationError(
                {"detail": "Only draft purchase orders can be changed."}
            )
        for field, value in order_fields.items():
            setattr(purchase_order, field, value)
        purchase_order.save()
        if lines_data is not None:
            purchase_order.lines.all().delete()

    if lines_data is not None:
        for line_data in lines_data:
            PurchaseLine.objects.create(purchase_order=purchase_order, **line_data)

    purchase_order.recalculate()
    purchase_order.save(update_fields=["subtotal", "total", "updated_at"])
    return purchase_order


@transaction.atomic
def submit_purchase_order(purchase_order):
    locked_order = (
        PurchaseOrder.objects.select_for_update()
        .prefetch_related("lines")
        .get(pk=purchase_order.pk)
    )
    if locked_order.status != PurchaseOrder.Status.DRAFT:
        raise serializers.ValidationError(
            {"detail": "Only draft purchase orders can be submitted."}
        )
    if not locked_order.lines.exists():
        raise serializers.ValidationError(
            {"detail": "Purchase order must include at least one line."}
        )

    locked_order.status = PurchaseOrder.Status.SUBMITTED
    locked_order.submitted_at = timezone.now()
    locked_order.save(update_fields=["status", "submitted_at", "updated_at"])
    return locked_order


@transaction.atomic
def receive_purchase_order(purchase_order, *, request=None):
    locked_order = (
        PurchaseOrder.objects.select_for_update()
        .prefetch_related("lines__product")
        .get(pk=purchase_order.pk)
    )
    if locked_order.status != PurchaseOrder.Status.SUBMITTED:
        raise serializers.ValidationError(
            {"detail": "Only submitted purchase orders can be received."}
        )

    created_by = purchase_created_by(request)
    for line in locked_order.lines.select_related("product").order_by("product_id"):
        stock_item, _ = StockItem.objects.select_for_update().get_or_create(
            product=line.product,
        )
        before = stock_snapshot(stock_item)
        stock_item.quantity_on_hand += line.quantity
        save_stock_item_quantities(stock_item)
        StockMovement.objects.create(
            product=line.product,
            stock_item=stock_item,
            movement_type=StockMovement.Type.INCREASE,
            quantity=line.quantity,
            note=f"شراء {locked_order.order_number}",
            created_by=created_by,
            on_hand_before=before["on_hand"],
            on_hand_after=stock_item.quantity_on_hand,
            committed_before=before["committed"],
            committed_after=stock_item.quantity_committed,
            expected_before=before["expected"],
            expected_after=stock_item.quantity_expected,
        )

    locked_order.status = PurchaseOrder.Status.RECEIVED
    locked_order.received_at = timezone.now()
    locked_order.save(update_fields=["status", "received_at", "updated_at"])
    return locked_order


def purchase_adjustment_amount(lines):
    amount = sum(
        (line.unit_cost * quantity for line, quantity in lines),
        Decimal("0.00"),
    ).quantize(Decimal("0.01"))
    if amount <= 0:
        raise serializers.ValidationError({"detail": "Adjustment amount must be positive."})
    return amount


def validate_purchase_order_adjustment_allowed(purchase_order):
    if purchase_order.status != PurchaseOrder.Status.RECEIVED:
        raise serializers.ValidationError(
            {"detail": "Only received purchase orders can be adjusted."}
        )
    if not any(line.adjustable_quantity > 0 for line in purchase_order.lines.all()):
        raise serializers.ValidationError(
            {"detail": "No remaining purchase lines can be adjusted."}
        )


def validate_purchase_stock_available(lines):
    requested_by_product = {}
    products_by_id = {}
    for line, quantity in lines:
        products_by_id[line.product_id] = line.product
        requested_by_product[line.product_id] = (
            requested_by_product.get(line.product_id, 0) + quantity
        )

    stock_items = {}
    shortages = []
    for product_id in sorted(requested_by_product):
        product = products_by_id[product_id]
        quantity = requested_by_product[product_id]
        stock_item, _ = StockItem.objects.select_for_update().get_or_create(
            product=product,
        )
        stock_items[product_id] = stock_item
        if stock_item.quantity_on_hand < quantity:
            shortages.append(
                {
                    "product": product.pk,
                    "product_name": product.name,
                    "requested": quantity,
                    "available": stock_item.quantity_on_hand,
                }
            )

    if shortages:
        raise serializers.ValidationError(
            {
                "detail": "Insufficient stock for purchase adjustment.",
                "stock": shortages,
            }
        )
    return stock_items


def purchase_adjustment_note(adjustment_type, order_number):
    label = {
        PurchaseOrderAdjustment.AdjustmentType.RETURN: "إرجاع مشتريات",
        PurchaseOrderAdjustment.AdjustmentType.REFUND: "استرداد مشتريات",
        PurchaseOrderAdjustment.AdjustmentType.EXCHANGE: "استبدال مشتريات",
    }.get(adjustment_type, "تعديل مشتريات")
    return f"{label} {order_number}"


def record_purchase_adjustment_stock_movements(
    *,
    purchase_order,
    adjustment_type,
    lines,
    stock_items,
    created_by,
):
    for line, quantity in lines:
        stock_item = stock_items[line.product_id]
        before = stock_snapshot(stock_item)
        stock_item.quantity_on_hand -= quantity
        save_stock_item_quantities(stock_item)
        StockMovement.objects.create(
            product=line.product,
            stock_item=stock_item,
            movement_type=StockMovement.Type.DECREASE,
            quantity=quantity,
            note=purchase_adjustment_note(adjustment_type, purchase_order.order_number),
            created_by=created_by,
            on_hand_before=before["on_hand"],
            on_hand_after=stock_item.quantity_on_hand,
            committed_before=before["committed"],
            committed_after=stock_item.quantity_committed,
            expected_before=before["expected"],
            expected_after=stock_item.quantity_expected,
        )


def create_purchase_order_adjustment(
    *,
    purchase_order,
    adjustment_type,
    lines,
    reason,
    request=None,
):
    created_by = purchase_created_by(request)
    stock_items = validate_purchase_stock_available(lines)
    amount = purchase_adjustment_amount(lines)
    adjustment = PurchaseOrderAdjustment.objects.create(
        purchase_order=purchase_order,
        adjustment_type=adjustment_type,
        amount=amount,
        reason=reason,
        created_by=created_by,
    )
    for line, quantity in lines:
        PurchaseOrderAdjustmentLine.objects.create(
            adjustment=adjustment,
            purchase_line=line,
            product=line.product,
            quantity=quantity,
            unit_cost=line.unit_cost,
        )
    record_purchase_adjustment_stock_movements(
        purchase_order=purchase_order,
        adjustment_type=adjustment_type,
        lines=lines,
        stock_items=stock_items,
        created_by=created_by,
    )
    return adjustment


@transaction.atomic
def adjust_purchase_order_items(
    *,
    purchase_order,
    adjustment_type,
    lines,
    reason,
    request=None,
):
    locked_order = (
        PurchaseOrder.objects.select_for_update()
        .prefetch_related("lines__product")
        .get(pk=purchase_order.pk)
    )
    validate_purchase_order_adjustment_allowed(locked_order)
    return create_purchase_order_adjustment(
        purchase_order=locked_order,
        adjustment_type=adjustment_type,
        lines=lines,
        reason=reason,
        request=request,
    )


@transaction.atomic
def cancel_purchase_order(purchase_order):
    locked_order = PurchaseOrder.objects.select_for_update().get(pk=purchase_order.pk)
    if locked_order.status not in (
        PurchaseOrder.Status.DRAFT,
        PurchaseOrder.Status.SUBMITTED,
    ):
        raise serializers.ValidationError(
            {"detail": "Only draft or submitted purchase orders can be cancelled."}
        )

    locked_order.status = PurchaseOrder.Status.CANCELLED
    locked_order.save(update_fields=["status", "updated_at"])
    return locked_order
