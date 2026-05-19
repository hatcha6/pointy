from decimal import Decimal

from django.db import models, transaction
from django.utils import timezone
from rest_framework import serializers

from apps.inventory.models import StockItem, StockMovement
from .models import (
    PurchaseLine,
    PurchaseOrder,
    PurchaseOrderAdjustment,
    PurchaseOrderAdjustmentLine,
    PurchaseReceipt,
    PurchaseReceiptLine,
    Supplier,
    SupplierCredit,
    SupplierPayment,
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


def create_stock_movement(
    *,
    stock_item,
    product,
    movement_type,
    quantity,
    note,
    created_by,
    before,
):
    if quantity <= 0:
        return None
    return StockMovement.objects.create(
        product=product,
        stock_item=stock_item,
        movement_type=movement_type,
        quantity=quantity,
        note=note,
        created_by=created_by,
        on_hand_before=before["on_hand"],
        on_hand_after=stock_item.quantity_on_hand,
        committed_before=before["committed"],
        committed_after=stock_item.quantity_committed,
        expected_before=before["expected"],
        expected_after=stock_item.quantity_expected,
    )


def decrement_expected(stock_item, quantity):
    expected_reduction = min(quantity, stock_item.quantity_expected)
    stock_item.quantity_expected -= expected_reduction
    return expected_reduction


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
def submit_purchase_order(purchase_order, *, request=None):
    locked_order = (
        PurchaseOrder.objects.select_for_update()
        .prefetch_related("lines__product")
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

    created_by = purchase_created_by(request)
    for line in locked_order.lines.select_related("product").order_by("product_id"):
        stock_item, _ = StockItem.objects.select_for_update().get_or_create(
            product=line.product,
        )
        before = stock_snapshot(stock_item)
        stock_item.quantity_expected += line.quantity
        save_stock_item_quantities(stock_item)
        create_stock_movement(
            stock_item=stock_item,
            product=line.product,
            movement_type=StockMovement.Type.EXPECTED,
            quantity=line.quantity,
            note=f"شراء متوقع {locked_order.order_number}",
            created_by=created_by,
            before=before,
        )

    locked_order.status = PurchaseOrder.Status.SUBMITTED
    locked_order.submitted_at = timezone.now()
    locked_order.save(update_fields=["status", "submitted_at", "updated_at"])
    return locked_order


def default_receipt_lines(locked_order):
    return [
        {
            "line": line,
            "accepted_quantity": line.outstanding_quantity,
            "damaged_quantity": 0,
            "cancelled_quantity": 0,
            "notes": "",
        }
        for line in locked_order.lines.select_related("product").order_by("product_id")
        if line.outstanding_quantity > 0
    ]


def receipt_line_expected_quantities(line, accepted_quantity, damaged_quantity, cancelled_quantity):
    outstanding_before = line.outstanding_quantity
    accepted_expected = min(accepted_quantity, outstanding_before)
    remaining_after_accepted = max(outstanding_before - accepted_expected, 0)
    damaged_expected = min(damaged_quantity, remaining_after_accepted)
    remaining_after_damaged = max(remaining_after_accepted - damaged_expected, 0)
    cancelled_expected = min(cancelled_quantity, remaining_after_damaged)
    expected_reduction = accepted_expected + damaged_expected + cancelled_expected
    outstanding_after = max(outstanding_before - expected_reduction, 0)
    over_received = max(accepted_quantity + damaged_quantity - outstanding_before, 0)
    return {
        "outstanding_before": outstanding_before,
        "accepted_expected": accepted_expected,
        "damaged_expected": damaged_expected,
        "cancelled_expected": cancelled_expected,
        "expected_reduction": expected_reduction,
        "outstanding_after": outstanding_after,
        "over_received": over_received,
    }


def validate_receipt_line_quantities(line, accepted_quantity, damaged_quantity, cancelled_quantity):
    if accepted_quantity + damaged_quantity + cancelled_quantity <= 0:
        raise serializers.ValidationError(
            {"lines": "At least one received, damaged, or cancelled quantity is required."}
        )
    if cancelled_quantity > 0:
        outstanding_before = line.outstanding_quantity
        if accepted_quantity + damaged_quantity + cancelled_quantity > outstanding_before:
            raise serializers.ValidationError(
                {
                    "lines": (
                        "Cancelled quantity cannot be combined with quantities beyond "
                        "the outstanding order quantity."
                    )
                }
            )


def apply_receipt_stock_changes(
    *,
    locked_order,
    line,
    accepted_quantity,
    damaged_quantity,
    cancelled_quantity,
    expected_quantities,
    created_by,
):
    stock_item, _ = StockItem.objects.select_for_update().get_or_create(
        product=line.product,
    )

    accepted_expected = expected_quantities["accepted_expected"]
    accepted_overage = accepted_quantity - accepted_expected
    if accepted_expected > 0:
        before = stock_snapshot(stock_item)
        stock_item.quantity_on_hand += accepted_expected
        decrement_expected(stock_item, accepted_expected)
        save_stock_item_quantities(stock_item)
        create_stock_movement(
            stock_item=stock_item,
            product=line.product,
            movement_type=StockMovement.Type.RECEIVE_EXPECTED,
            quantity=accepted_expected,
            note=f"استلام مشتريات {locked_order.order_number}",
            created_by=created_by,
            before=before,
        )

    if accepted_overage > 0:
        before = stock_snapshot(stock_item)
        stock_item.quantity_on_hand += accepted_overage
        save_stock_item_quantities(stock_item)
        create_stock_movement(
            stock_item=stock_item,
            product=line.product,
            movement_type=StockMovement.Type.INCREASE,
            quantity=accepted_overage,
            note=f"زيادة توريد {locked_order.order_number}",
            created_by=created_by,
            before=before,
        )

    damaged_expected = expected_quantities["damaged_expected"]
    if damaged_expected > 0:
        before = stock_snapshot(stock_item)
        decrement_expected(stock_item, damaged_expected)
        save_stock_item_quantities(stock_item)
        create_stock_movement(
            stock_item=stock_item,
            product=line.product,
            movement_type=StockMovement.Type.RECEIVE_DAMAGED,
            quantity=damaged_expected,
            note=f"تالف عند الاستلام {locked_order.order_number}",
            created_by=created_by,
            before=before,
        )

    cancelled_expected = expected_quantities["cancelled_expected"]
    if cancelled_expected > 0:
        before = stock_snapshot(stock_item)
        decrement_expected(stock_item, cancelled_expected)
        save_stock_item_quantities(stock_item)
        create_stock_movement(
            stock_item=stock_item,
            product=line.product,
            movement_type=StockMovement.Type.CANCEL_EXPECTED,
            quantity=cancelled_expected,
            note=f"إلغاء توريد {locked_order.order_number}",
            created_by=created_by,
            before=before,
        )


@transaction.atomic
def receive_purchase_order(purchase_order, *, request=None, lines_data=None, notes=""):
    locked_order = (
        PurchaseOrder.objects.select_for_update()
        .prefetch_related("lines__product", "lines__receipt_lines")
        .get(pk=purchase_order.pk)
    )
    if locked_order.status not in (
        PurchaseOrder.Status.SUBMITTED,
        PurchaseOrder.Status.PARTIALLY_RECEIVED,
    ):
        raise serializers.ValidationError(
            {"detail": "Only submitted purchase orders can be received."}
        )

    created_by = purchase_created_by(request)
    if lines_data is None:
        lines_data = default_receipt_lines(locked_order)
    if not lines_data:
        raise serializers.ValidationError(
            {"lines": "No outstanding purchase lines can be received."}
        )

    receipt = PurchaseReceipt.objects.create(
        purchase_order=locked_order,
        notes=notes,
        created_by=created_by,
    )

    for line_data in lines_data:
        line = line_data["line"]
        accepted_quantity = line_data.get("accepted_quantity", 0)
        damaged_quantity = line_data.get("damaged_quantity", 0)
        cancelled_quantity = line_data.get("cancelled_quantity", 0)
        validate_receipt_line_quantities(
            line,
            accepted_quantity,
            damaged_quantity,
            cancelled_quantity,
        )
        expected_quantities = receipt_line_expected_quantities(
            line,
            accepted_quantity,
            damaged_quantity,
            cancelled_quantity,
        )
        apply_receipt_stock_changes(
            locked_order=locked_order,
            line=line,
            accepted_quantity=accepted_quantity,
            damaged_quantity=damaged_quantity,
            cancelled_quantity=cancelled_quantity,
            expected_quantities=expected_quantities,
            created_by=created_by,
        )
        PurchaseReceiptLine.objects.create(
            receipt=receipt,
            purchase_line=line,
            product=line.product,
            ordered_quantity=line.quantity,
            outstanding_before=expected_quantities["outstanding_before"],
            accepted_quantity=accepted_quantity,
            damaged_quantity=damaged_quantity,
            cancelled_quantity=cancelled_quantity,
            expected_reduction_quantity=expected_quantities["expected_reduction"],
            over_received_quantity=expected_quantities["over_received"],
            outstanding_after=expected_quantities["outstanding_after"],
            notes=line_data.get("notes", ""),
        )

    locked_order.refresh_from_db()
    has_outstanding = any(
        line.outstanding_quantity > 0
        for line in locked_order.lines.prefetch_related("receipt_lines")
    )
    locked_order.status = (
        PurchaseOrder.Status.PARTIALLY_RECEIVED
        if has_outstanding
        else PurchaseOrder.Status.RECEIVED
    )
    if locked_order.status == PurchaseOrder.Status.RECEIVED:
        locked_order.received_at = timezone.now()
        locked_order.save(update_fields=["status", "received_at", "updated_at"])
    else:
        locked_order.save(update_fields=["status", "updated_at"])
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
    if purchase_order.status not in (
        PurchaseOrder.Status.PARTIALLY_RECEIVED,
        PurchaseOrder.Status.RECEIVED,
    ):
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
    settlement_method="",
):
    created_by = purchase_created_by(request)
    stock_items = validate_purchase_stock_available(lines)
    amount = purchase_adjustment_amount(lines)
    adjustment = PurchaseOrderAdjustment.objects.create(
        purchase_order=purchase_order,
        adjustment_type=adjustment_type,
        amount=amount,
        settlement_method=settlement_method,
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
    settle_purchase_order_adjustment(adjustment, created_by=created_by)
    return adjustment


def settle_purchase_order_adjustment(adjustment, *, created_by=None):
    supplier = adjustment.purchase_order.supplier
    if supplier is None or not adjustment.settlement_method:
        return

    if adjustment.settlement_method == PurchaseOrderAdjustment.SettlementMethod.SUPPLIER_CREDIT:
        SupplierCredit.objects.create(
            supplier=supplier,
            purchase_order=adjustment.purchase_order,
            adjustment=adjustment,
            amount=adjustment.amount,
            remaining_amount=adjustment.amount,
            reason=adjustment.reason,
        )
        return

    SupplierPayment.objects.create(
        supplier=supplier,
        purchase_order=adjustment.purchase_order,
        amount=adjustment.amount,
        method=adjustment.settlement_method,
        notes=adjustment.reason,
        created_by=created_by,
    )


@transaction.atomic
def adjust_purchase_order_items(
    *,
    purchase_order,
    adjustment_type,
    lines,
    reason,
    request=None,
    settlement_method="",
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
        settlement_method=settlement_method,
    )


def supplier_available_credit(supplier):
    total = supplier.credits.filter(status=SupplierCredit.Status.OPEN).aggregate(
        total=models.Sum("remaining_amount")
    )["total"]
    return (total or Decimal("0.00")).quantize(Decimal("0.01"))


def validate_supplier_payment_order(supplier, purchase_order):
    if purchase_order is None:
        return
    if purchase_order.supplier_id != supplier.pk:
        raise serializers.ValidationError(
            {"purchase_order": "Purchase order does not belong to this supplier."}
        )
    if purchase_order.status == PurchaseOrder.Status.CANCELLED:
        raise serializers.ValidationError(
            {"purchase_order": "Cannot pay a cancelled purchase order."}
        )


def consume_supplier_credit(*, supplier, amount):
    remaining = amount
    credits = supplier.credits.select_for_update().filter(
        status=SupplierCredit.Status.OPEN,
        remaining_amount__gt=0,
    ).order_by("created_at", "id")
    for credit in credits:
        if remaining <= 0:
            break
        applied = min(credit.remaining_amount, remaining)
        credit.remaining_amount = (credit.remaining_amount - applied).quantize(
            Decimal("0.01")
        )
        if credit.remaining_amount == Decimal("0.00"):
            credit.status = SupplierCredit.Status.USED
        credit.save(update_fields=["remaining_amount", "status", "updated_at"])
        remaining = (remaining - applied).quantize(Decimal("0.01"))


@transaction.atomic
def create_supplier_payment(*, created_by=None, **payment_fields):
    supplier = Supplier.objects.select_for_update().get(pk=payment_fields["supplier"].pk)
    payment_fields["supplier"] = supplier

    purchase_order = payment_fields.get("purchase_order")
    if purchase_order is not None:
        purchase_order = PurchaseOrder.objects.select_for_update().get(
            pk=purchase_order.pk
        )
        payment_fields["purchase_order"] = purchase_order
    validate_supplier_payment_order(supplier, purchase_order)

    amount = payment_fields["amount"].quantize(Decimal("0.01"))
    method = payment_fields["method"]
    if amount <= 0:
        raise serializers.ValidationError({"amount": "Payment amount must be positive."})

    if method == SupplierPayment.Method.SUPPLIER_CREDIT:
        if purchase_order is None:
            raise serializers.ValidationError(
                {"purchase_order": "Supplier credit payments require a purchase order."}
            )
        available_credit = supplier_available_credit(supplier)
        if amount > available_credit:
            raise serializers.ValidationError(
                {"amount": "Payment exceeds available supplier credit."}
            )
    elif purchase_order is None and amount > supplier.payable_balance:
        raise serializers.ValidationError(
            {"amount": "Payment exceeds the supplier payable balance."}
        )

    if purchase_order is not None and amount > purchase_order.balance_due:
        raise serializers.ValidationError(
            {"amount": "Payment exceeds the purchase order balance."}
        )

    payment_fields["amount"] = amount
    payment_fields["created_by"] = created_by
    payment = SupplierPayment.objects.create(**payment_fields)
    if method == SupplierPayment.Method.SUPPLIER_CREDIT:
        consume_supplier_credit(supplier=supplier, amount=amount)
    return payment


@transaction.atomic
def cancel_purchase_order(purchase_order, *, request=None):
    locked_order = (
        PurchaseOrder.objects.select_for_update()
        .prefetch_related("lines__product", "lines__receipt_lines")
        .get(pk=purchase_order.pk)
    )
    if locked_order.status not in (
        PurchaseOrder.Status.DRAFT,
        PurchaseOrder.Status.SUBMITTED,
    ):
        raise serializers.ValidationError(
            {"detail": "Only draft or submitted purchase orders can be cancelled."}
        )

    created_by = purchase_created_by(request)
    if locked_order.status == PurchaseOrder.Status.SUBMITTED:
        for line in locked_order.lines.select_related("product").order_by("product_id"):
            outstanding_quantity = line.outstanding_quantity
            if outstanding_quantity <= 0:
                continue
            stock_item, _ = StockItem.objects.select_for_update().get_or_create(
                product=line.product,
            )
            before = stock_snapshot(stock_item)
            expected_reduction = decrement_expected(stock_item, outstanding_quantity)
            if expected_reduction <= 0:
                continue
            save_stock_item_quantities(stock_item)
            create_stock_movement(
                stock_item=stock_item,
                product=line.product,
                movement_type=StockMovement.Type.CANCEL_EXPECTED,
                quantity=expected_reduction,
                note=f"إلغاء أمر شراء {locked_order.order_number}",
                created_by=created_by,
                before=before,
            )

    locked_order.status = PurchaseOrder.Status.CANCELLED
    locked_order.save(update_fields=["status", "updated_at"])
    return locked_order
