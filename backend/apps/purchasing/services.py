from decimal import Decimal

from django.contrib.contenttypes.models import ContentType
from django.db import models, transaction
from django.utils import timezone
from rest_framework import serializers

from apps.analytics.models import AnalyticsEvent
from apps.analytics.services import record_domain_event
from apps.discounts.models import (
    AppliedDiscount,
    DiscountRedemption,
    normalize_coupon_code,
)
from apps.discounts.services import DiscountUsageLimitExceeded, persist_applied_discounts
from apps.inventory.models import StockMovement
from apps.inventory.services import (
    consume_expiring_stock_batches,
    create_expiring_stock_batch,
    create_stock_movement,
    lock_stock_item,
    save_stock_item_quantities,
    stock_snapshot,
)
from .models import (
    PurchaseLine,
    PurchaseOrder,
    PurchaseOrderAdjustment,
    PurchaseOrderAdjustmentLine,
    PurchaseOrderAdjustmentReplacementLine,
    PurchaseOrderAuditEvent,
    PurchaseOrderLandedCostEntry,
    PurchaseReceipt,
    PurchaseReceiptLine,
    Supplier,
    SupplierCredit,
    SupplierPayment,
)


def latest_purchase_line_for_variant(variant_id, *, before_line=None):
    lines = PurchaseLine.objects.filter(variant_id=variant_id).exclude(
        purchase_order__status=PurchaseOrder.Status.CANCELLED,
    )
    if before_line is not None:
        lines = lines.exclude(pk=before_line.pk)
        if before_line.created_at is not None:
            lines = lines.filter(created_at__lt=before_line.created_at)
    return lines.order_by("-created_at", "-id").first()


def latest_purchase_line_for_product(product_id, *, variant_id=None, before_line=None):
    if variant_id is not None:
        return latest_purchase_line_for_variant(variant_id, before_line=before_line)

    lines = PurchaseLine.objects.filter(variant__product_id=product_id).exclude(
        purchase_order__status=PurchaseOrder.Status.CANCELLED,
    )
    if before_line is not None:
        lines = lines.exclude(pk=before_line.pk)
        if before_line.created_at is not None:
            lines = lines.filter(created_at__lt=before_line.created_at)
    return lines.order_by("-created_at", "-id").first()


def latest_variant_unit_cost(variant_id):
    line = latest_purchase_line_for_variant(variant_id)
    # Normalise to per *base* unit so the sales cost lookup (which multiplies by
    # the line's own unit factor) stays correct even when the purchase was a pack.
    return None if line is None else line.base_unit_cost


def latest_product_unit_cost(product_id, *, variant_id=None):
    if variant_id is not None:
        return latest_variant_unit_cost(variant_id)

    line = latest_purchase_line_for_product(product_id)
    return None if line is None else line.unit_cost


def purchase_created_by(request):
    if request is not None and request.user.is_authenticated:
        return request.user
    return None


def record_purchase_order_audit_event(
    purchase_order,
    action,
    *,
    request=None,
    created_by=None,
    message="",
    details=None,
):
    if created_by is None:
        created_by = purchase_created_by(request)
    audit_event = PurchaseOrderAuditEvent.objects.create(
        purchase_order=purchase_order,
        order_number=purchase_order.order_number,
        action=action,
        message=message,
        details=details or {},
        created_by=created_by,
    )
    action_value = str(action)
    record_domain_event(
        name=f"purchasing.purchase_order.{action_value}",
        event_type=AnalyticsEvent.EventType.AUDIT,
        severity=(
            AnalyticsEvent.Severity.WARNING
            if action_value
            in {
                PurchaseOrderAuditEvent.Action.ADJUSTED,
                PurchaseOrderAuditEvent.Action.CANCELLED,
                PurchaseOrderAuditEvent.Action.DELETED,
            }
            else AnalyticsEvent.Severity.INFO
        ),
        user=created_by,
        entity_type="purchase_order",
        entity_id=purchase_order.pk,
        attributes={
            "purchase_order_audit_event_id": audit_event.pk,
            "order_number": purchase_order.order_number,
            "action": action_value,
            "status": purchase_order.status,
            "supplier_id": purchase_order.supplier_id,
            "message_present": bool(message),
            "details": details or {},
        },
        metrics={"total": float(purchase_order.total)},
    )
    return audit_event


def decrement_expected(stock_item, quantity):
    expected_reduction = min(quantity, stock_item.quantity_expected)
    stock_item.quantity_expected -= expected_reduction
    return expected_reduction


@transaction.atomic
def save_purchase_order_with_lines(
    *,
    purchase_order=None,
    lines_data=None,
    landed_cost_entries_data=None,
    request=None,
    **order_fields,
):
    is_create = purchase_order is None
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

    if landed_cost_entries_data is not None:
        replace_purchase_order_landed_cost_entries(
            purchase_order,
            landed_cost_entries_data,
        )

    clear_purchase_order_applied_discounts(purchase_order)
    discount_result = purchase_order.recalculate()
    validate_requested_purchase_discount_codes(purchase_order, discount_result)
    purchase_order.save(
        update_fields=["subtotal", "discount_total", "total", "updated_at"]
    )
    persist_purchase_order_applied_discounts(purchase_order, discount_result)
    record_purchase_order_audit_event(
        purchase_order,
        (
            PurchaseOrderAuditEvent.Action.CREATED
            if is_create
            else PurchaseOrderAuditEvent.Action.UPDATED
        ),
        request=request,
    )
    return purchase_order


def replace_purchase_order_landed_cost_entries(purchase_order, entries_data):
    purchase_order.landed_cost_entries.all().delete()
    PurchaseOrderLandedCostEntry.objects.bulk_create(
        [
            PurchaseOrderLandedCostEntry(
                purchase_order=purchase_order,
                name=entry["name"],
                amount=entry["amount"],
            )
            for entry in entries_data
        ]
    )
    if hasattr(purchase_order, "_prefetched_objects_cache"):
        purchase_order._prefetched_objects_cache.pop("landed_cost_entries", None)


def purchase_order_content_type():
    return ContentType.objects.get_for_model(PurchaseOrder, for_concrete_model=False)


def clear_purchase_order_applied_discounts(purchase_order):
    document_content_type = purchase_order_content_type()
    applied_discounts = AppliedDiscount.objects.filter(
        document_content_type=document_content_type,
        document_object_id=purchase_order.pk,
    )
    DiscountRedemption.objects.filter(applied_discount__in=applied_discounts).delete()
    applied_discounts.delete()


def validate_requested_purchase_discount_codes(purchase_order, discount_result):
    requested_codes = [
        normalize_coupon_code(code)
        for code in (purchase_order.discount_codes or [])
        if normalize_coupon_code(code)
    ]
    if not requested_codes:
        return

    applied_codes = {
        normalize_coupon_code(application.coupon_code)
        for application in discount_result.applications
        if application.coupon_code
    }
    missing_codes = [
        code for code in dict.fromkeys(requested_codes) if code not in applied_codes
    ]
    if missing_codes:
        raise serializers.ValidationError(
            {
                "discount_codes": (
                    "Discount code is invalid, disabled, expired, or unavailable: "
                    + ", ".join(missing_codes)
                )
            }
        )


def persist_purchase_order_applied_discounts(purchase_order, discount_result):
    lines_by_key = {
        str(line.pk): line
        for line in purchase_order.lines.select_related(
            "variant",
            "variant__product",
        ).order_by("created_at", "id")
    }
    try:
        return persist_applied_discounts(
            document=purchase_order,
            result=discount_result,
            line_objects_by_key=lines_by_key,
        )
    except DiscountUsageLimitExceeded as exc:
        raise serializers.ValidationError(
            discount_usage_limit_error_payload(exc, "discount_codes")
        )


def discount_usage_limit_error_payload(exc, field_name):
    if exc.coupon_codes:
        return {
            field_name: (
                "Discount code is invalid, disabled, expired, or unavailable: "
                + ", ".join(exc.coupon_codes)
            )
        }
    return {"detail": "A discount is no longer available."}


@transaction.atomic
def submit_purchase_order(purchase_order, *, request=None):
    locked_order = (
        PurchaseOrder.objects.select_for_update()
        .prefetch_related("lines__variant__product")
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
    missing_expiry = locked_order.lines.filter(
        variant__product__tracks_expiry=True,
        expiry_date__isnull=True,
    ).exists()
    if missing_expiry:
        raise serializers.ValidationError(
            {
                "lines": (
                    "Expiry date is required for products that track expiry."
                )
            }
        )

    created_by = purchase_created_by(request)
    for line in locked_order.lines.select_related(
        "variant",
        "variant__product",
    ).order_by("variant_id"):
        stock_item = lock_stock_item(variant=line.variant)
        before = stock_snapshot(stock_item)
        # Stock is kept in base units; a line bought in packs becomes base units.
        expected_base = line.to_base_quantity(line.quantity)
        stock_item.quantity_expected += expected_base
        save_stock_item_quantities(stock_item)
        create_stock_movement(
            stock_item=stock_item,
            variant=line.variant,
            movement_type=StockMovement.Type.EXPECTED,
            quantity=expected_base,
            note=f"شراء متوقع {locked_order.order_number}",
            created_by=created_by,
            before=before,
        )

    locked_order.status = PurchaseOrder.Status.SUBMITTED
    locked_order.submitted_at = timezone.now()
    locked_order.save(update_fields=["status", "submitted_at", "updated_at"])
    record_purchase_order_audit_event(
        locked_order,
        PurchaseOrderAuditEvent.Action.SUBMITTED,
        created_by=created_by,
    )
    return locked_order


def lock_purchase_lines_for_update(purchase_order, *, line_ids=None):
    queryset = (
        PurchaseLine.objects.select_for_update()
        .filter(purchase_order=purchase_order)
        .select_related("variant", "variant__product")
        .order_by("pk")
    )
    if line_ids is not None:
        queryset = queryset.filter(pk__in=line_ids)
    lines = list(queryset)
    if lines:
        line_ids = [line.pk for line in lines]
        list(
            PurchaseReceiptLine.objects.select_for_update()
            .filter(purchase_line_id__in=line_ids)
            .order_by("pk")
        )
        list(
            PurchaseOrderAdjustmentLine.objects.select_for_update()
            .filter(purchase_line_id__in=line_ids)
            .order_by("pk")
        )
    return lines


def default_receipt_lines(locked_order, lines=None):
    lines = lock_purchase_lines_for_update(locked_order) if lines is None else lines
    return [
        {
            "line": line,
            "accepted_quantity": line.outstanding_quantity,
            "damaged_quantity": 0,
            "cancelled_quantity": 0,
            "allowed_over_receipt_quantity": 0,
            "expiry_date": line.expiry_date,
            "notes": "",
        }
        for line in lines
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


def validate_receipt_line_quantities(
    line,
    accepted_quantity,
    damaged_quantity,
    cancelled_quantity,
    *,
    allowed_over_receipt_quantity=0,
):
    if accepted_quantity + damaged_quantity + cancelled_quantity <= 0:
        raise serializers.ValidationError(
            {"lines": "At least one received, damaged, or cancelled quantity is required."}
        )
    outstanding_before = line.outstanding_quantity
    received_quantity = accepted_quantity + damaged_quantity
    if received_quantity > outstanding_before + allowed_over_receipt_quantity:
        raise serializers.ValidationError(
            {"lines": "Received quantity exceeds the remaining outstanding quantity."}
        )
    if cancelled_quantity > 0:
        if accepted_quantity + damaged_quantity + cancelled_quantity > outstanding_before:
            raise serializers.ValidationError(
                {
                    "lines": (
                        "Cancelled quantity cannot be combined with quantities beyond "
                        "the outstanding order quantity."
                    )
                }
            )


def validate_receipt_line_expiry(line, accepted_quantity, expiry_date):
    if (
        accepted_quantity > 0
        and line.variant.product.tracks_expiry
        and expiry_date is None
    ):
        raise serializers.ValidationError(
            {
                "expiry_date": (
                    "Expiry date is required for received products that track expiry."
                )
            }
        )


def fresh_purchase_receipt_lines(locked_order, lines_data, *, locked_lines):
    requested_by_line = {}
    for line_data in lines_data:
        line = line_data["line"]
        if line.purchase_order_id != locked_order.pk:
            raise serializers.ValidationError(
                {"lines": "Receipt line does not belong to this purchase order."}
            )
        if line.pk in requested_by_line:
            raise serializers.ValidationError(
                {"lines": "Each purchase line can be received only once per receipt."}
            )
        requested_by_line[line.pk] = line_data

    lines_by_id = {line.pk: line for line in locked_lines}
    if set(requested_by_line) - set(lines_by_id):
        raise serializers.ValidationError(
            {"lines": "Receipt line does not belong to this purchase order."}
        )

    fresh_lines = []
    for line_id, line_data in requested_by_line.items():
        line = lines_by_id[line_id]
        accepted_quantity = line_data.get("accepted_quantity", 0)
        damaged_quantity = line_data.get("damaged_quantity", 0)
        cancelled_quantity = line_data.get("cancelled_quantity", 0)
        allowed_over_receipt_quantity = line_data.get("allowed_over_receipt_quantity")
        if allowed_over_receipt_quantity is None:
            allowed_over_receipt_quantity = 0
        validate_receipt_line_quantities(
            line,
            accepted_quantity,
            damaged_quantity,
            cancelled_quantity,
            allowed_over_receipt_quantity=allowed_over_receipt_quantity,
        )
        expiry_date = line_data.get("expiry_date", line.expiry_date)
        validate_receipt_line_expiry(line, accepted_quantity, expiry_date)
        fresh_lines.append(
            {
                "line": line,
                "accepted_quantity": accepted_quantity,
                "damaged_quantity": damaged_quantity,
                "cancelled_quantity": cancelled_quantity,
                "allowed_over_receipt_quantity": allowed_over_receipt_quantity,
                "expiry_date": expiry_date,
                "notes": line_data.get("notes", ""),
            }
        )
    return fresh_lines


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
    stock_item = lock_stock_item(variant=line.variant)

    # Receipt quantities are in the line's purchase unit (whole packs); stock is
    # kept in base units, so convert each at the boundary via the line's factor.
    accepted_expected = expected_quantities["accepted_expected"]
    accepted_overage = accepted_quantity - accepted_expected
    if accepted_expected > 0:
        accepted_expected_base = line.to_base_quantity(accepted_expected)
        before = stock_snapshot(stock_item)
        stock_item.quantity_on_hand += accepted_expected_base
        decrement_expected(stock_item, accepted_expected_base)
        save_stock_item_quantities(stock_item)
        create_stock_movement(
            stock_item=stock_item,
            variant=line.variant,
            movement_type=StockMovement.Type.RECEIVE_EXPECTED,
            quantity=accepted_expected_base,
            note=f"استلام مشتريات {locked_order.order_number}",
            created_by=created_by,
            before=before,
        )

    if accepted_overage > 0:
        accepted_overage_base = line.to_base_quantity(accepted_overage)
        before = stock_snapshot(stock_item)
        stock_item.quantity_on_hand += accepted_overage_base
        save_stock_item_quantities(stock_item)
        create_stock_movement(
            stock_item=stock_item,
            variant=line.variant,
            movement_type=StockMovement.Type.INCREASE,
            quantity=accepted_overage_base,
            note=f"زيادة توريد {locked_order.order_number}",
            created_by=created_by,
            before=before,
        )

    damaged_expected = expected_quantities["damaged_expected"]
    if damaged_expected > 0:
        before = stock_snapshot(stock_item)
        decrement_expected(stock_item, line.to_base_quantity(damaged_expected))
        save_stock_item_quantities(stock_item)
        create_stock_movement(
            stock_item=stock_item,
            variant=line.variant,
            movement_type=StockMovement.Type.RECEIVE_DAMAGED,
            quantity=line.to_base_quantity(damaged_expected),
            note=f"تالف عند الاستلام {locked_order.order_number}",
            created_by=created_by,
            before=before,
        )

    cancelled_expected = expected_quantities["cancelled_expected"]
    if cancelled_expected > 0:
        before = stock_snapshot(stock_item)
        decrement_expected(stock_item, line.to_base_quantity(cancelled_expected))
        save_stock_item_quantities(stock_item)
        create_stock_movement(
            stock_item=stock_item,
            variant=line.variant,
            movement_type=StockMovement.Type.CANCEL_EXPECTED,
            quantity=line.to_base_quantity(cancelled_expected),
            note=f"إلغاء توريد {locked_order.order_number}",
            created_by=created_by,
            before=before,
        )


@transaction.atomic
def receive_purchase_order(purchase_order, *, request=None, lines_data=None, notes=""):
    locked_order = (
        PurchaseOrder.objects.select_for_update()
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
    locked_lines = lock_purchase_lines_for_update(locked_order)
    if lines_data is None:
        lines_data = default_receipt_lines(locked_order, locked_lines)
    else:
        lines_data = fresh_purchase_receipt_lines(
            locked_order,
            lines_data,
            locked_lines=locked_lines,
        )
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
            allowed_over_receipt_quantity=line_data.get(
                "allowed_over_receipt_quantity",
                0,
            ),
        )
        expiry_date = line_data.get("expiry_date", line.expiry_date)
        validate_receipt_line_expiry(line, accepted_quantity, expiry_date)
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
        receipt_line = PurchaseReceiptLine.objects.create(
            receipt=receipt,
            purchase_line=line,
            variant=line.variant,
            ordered_quantity=line.quantity,
            outstanding_before=expected_quantities["outstanding_before"],
            accepted_quantity=accepted_quantity,
            damaged_quantity=damaged_quantity,
            cancelled_quantity=cancelled_quantity,
            expected_reduction_quantity=expected_quantities["expected_reduction"],
            over_received_quantity=expected_quantities["over_received"],
            outstanding_after=expected_quantities["outstanding_after"],
            expiry_date=expiry_date,
            notes=line_data.get("notes", ""),
        )
        create_expiring_stock_batch(
            receipt_line=receipt_line,
            expiry_date=expiry_date,
            # Batches are consumed in base units by FEFO, so store base units.
            quantity=line.to_base_quantity(accepted_quantity),
        )

    has_outstanding = any(
        line.outstanding_quantity > 0 for line in locked_lines
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
    record_purchase_order_audit_event(
        locked_order,
        PurchaseOrderAuditEvent.Action.RECEIVED,
        created_by=created_by,
        details={"receipt": receipt.pk, "status": locked_order.status},
    )
    return locked_order


def purchase_adjustment_line_amount(line, quantity):
    prior_amount = line.adjustment_lines.aggregate(total=models.Sum("line_amount"))[
        "total"
    ] or Decimal("0.00")
    if quantity >= line.adjustable_quantity:
        return (line.net_line_total - prior_amount).quantize(Decimal("0.01"))
    return (
        line.net_line_total * Decimal(quantity) / Decimal(line.quantity)
    ).quantize(Decimal("0.01"))


def purchase_adjustment_line_unit_cost(line, quantity):
    amount = purchase_adjustment_line_amount(line, quantity)
    return (amount / Decimal(quantity)).quantize(Decimal("0.01"))


def purchase_adjustment_amount(lines):
    amount = sum(
        (purchase_adjustment_line_amount(line, quantity) for line, quantity in lines),
        Decimal("0.00"),
    ).quantize(Decimal("0.01"))
    if amount <= 0:
        raise serializers.ValidationError({"detail": "Adjustment amount must be positive."})
    return amount


def purchase_replacement_amount(lines):
    return sum(
        (unit_cost * quantity for _, quantity, unit_cost in lines),
        Decimal("0.00"),
    ).quantize(Decimal("0.01"))


def validate_purchase_order_adjustment_allowed(purchase_order, *, lines=None):
    if purchase_order.status not in (
        PurchaseOrder.Status.PARTIALLY_RECEIVED,
        PurchaseOrder.Status.RECEIVED,
    ):
        raise serializers.ValidationError(
            {"detail": "Only received purchase orders can be adjusted."}
        )
    order_lines = purchase_order.lines.all() if lines is None else lines
    if not any(line.adjustable_quantity > 0 for line in order_lines):
        raise serializers.ValidationError(
            {"detail": "No remaining purchase lines can be adjusted."}
        )


def validate_purchase_stock_available(lines):
    # Compare against base-unit stock (a returned pack frees up base units), but
    # report the shortage in the unit the user actually entered (packs).
    requested_base_by_variant = {}
    requested_display_by_variant = {}
    variants_by_id = {}
    for line, quantity in lines:
        variants_by_id[line.variant_id] = line.variant
        requested_base_by_variant[line.variant_id] = requested_base_by_variant.get(
            line.variant_id, Decimal("0")
        ) + line.to_base_quantity(quantity)
        requested_display_by_variant[line.variant_id] = (
            requested_display_by_variant.get(line.variant_id, 0) + quantity
        )

    stock_items = {}
    shortages = []
    for variant_id in sorted(requested_base_by_variant):
        variant = variants_by_id[variant_id]
        base_needed = requested_base_by_variant[variant_id]
        stock_item = lock_stock_item(variant=variant)
        stock_items[variant_id] = stock_item
        if stock_item.quantity_on_hand < base_needed:
            shortages.append(
                {
                    "product": variant.product_id,
                    "product_id": variant.product_id,
                    "variant": variant.pk,
                    "variant_id": variant.pk,
                    "product_name": variant.product.name,
                    "variant_name": variant.full_name,
                    "requested": requested_display_by_variant[variant_id],
                    "available": float(stock_item.quantity_on_hand),
                }
            )

    if shortages:
        raise serializers.ValidationError(
            {
                "code": "purchase_stock_already_sold",
                "detail": (
                    "لا يمكن تعديل أمر الشراء لأن الكمية المستلمة بيعت أو لم تعد "
                    "متوفرة في المخزون."
                ),
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


def purchase_replacement_note(order_number):
    return f"استلام بديل مشتريات {order_number}"


def record_purchase_adjustment_stock_movements(
    *,
    purchase_order,
    adjustment_type,
    lines,
    stock_items,
    created_by,
):
    for line, quantity in lines:
        stock_item = stock_items[line.variant_id]
        before = stock_snapshot(stock_item)
        # Returned packs leave stock in base units.
        base_quantity = line.to_base_quantity(quantity)
        stock_item.quantity_on_hand -= base_quantity
        save_stock_item_quantities(stock_item)
        consume_expiring_stock_batches(variant=line.variant, quantity=base_quantity)
        create_stock_movement(
            variant=line.variant,
            stock_item=stock_item,
            movement_type=StockMovement.Type.DECREASE,
            quantity=base_quantity,
            note=purchase_adjustment_note(adjustment_type, purchase_order.order_number),
            created_by=created_by,
            before=before,
        )


def lock_replacement_stock_items(lines, stock_items=None):
    stock_items = {} if stock_items is None else dict(stock_items)
    variants_by_id = {variant.pk: variant for variant, _, _ in lines}
    for variant_id in sorted(variants_by_id):
        if variant_id in stock_items:
            continue
        variant = variants_by_id[variant_id]
        stock_item = lock_stock_item(variant=variant)
        stock_items[variant_id] = stock_item
    return stock_items


def record_purchase_replacement_stock_movements(
    *,
    purchase_order,
    lines,
    stock_items,
    created_by,
):
    for variant, quantity, _ in lines:
        stock_item = stock_items[variant.pk]
        before = stock_snapshot(stock_item)
        stock_item.quantity_on_hand += quantity
        save_stock_item_quantities(stock_item)
        create_stock_movement(
            variant=variant,
            stock_item=stock_item,
            movement_type=StockMovement.Type.INCREASE,
            quantity=quantity,
            note=purchase_replacement_note(purchase_order.order_number),
            created_by=created_by,
            before=before,
        )


def create_purchase_order_adjustment(
    *,
    purchase_order,
    adjustment_type,
    lines,
    reason,
    replacement_lines=None,
    request=None,
    settlement_method="",
):
    created_by = purchase_created_by(request)
    stock_items = validate_purchase_stock_available(lines)
    replacement_lines = replacement_lines or []
    stock_items = lock_replacement_stock_items(replacement_lines, stock_items)
    outbound_amount = purchase_adjustment_amount(lines)
    replacement_amount = purchase_replacement_amount(replacement_lines)
    net_amount = (replacement_amount - outbound_amount).quantize(Decimal("0.01"))
    adjustment = PurchaseOrderAdjustment.objects.create(
        purchase_order=purchase_order,
        adjustment_type=adjustment_type,
        amount=outbound_amount,
        outbound_amount=outbound_amount,
        replacement_amount=replacement_amount,
        net_amount=net_amount,
        settlement_method=settlement_method,
        reason=reason,
        created_by=created_by,
    )
    for line, quantity in lines:
        line_amount = purchase_adjustment_line_amount(line, quantity)
        PurchaseOrderAdjustmentLine.objects.create(
            adjustment=adjustment,
            purchase_line=line,
            variant=line.variant,
            quantity=quantity,
            unit_cost=purchase_adjustment_line_unit_cost(line, quantity),
            line_amount=line_amount,
        )
    for variant, quantity, unit_cost in replacement_lines:
        PurchaseOrderAdjustmentReplacementLine.objects.create(
            adjustment=adjustment,
            variant=variant,
            quantity=quantity,
            unit_cost=unit_cost,
        )
    record_purchase_adjustment_stock_movements(
        purchase_order=purchase_order,
        adjustment_type=adjustment_type,
        lines=lines,
        stock_items=stock_items,
        created_by=created_by,
    )
    record_purchase_replacement_stock_movements(
        purchase_order=purchase_order,
        lines=replacement_lines,
        stock_items=stock_items,
        created_by=created_by,
    )
    settle_purchase_order_adjustment(adjustment, created_by=created_by)
    record_purchase_order_audit_event(
        purchase_order,
        PurchaseOrderAuditEvent.Action.ADJUSTED,
        created_by=created_by,
        details={
            "adjustment": adjustment.pk,
            "adjustment_type": adjustment.adjustment_type,
            "outbound_amount": str(adjustment.outbound_amount),
            "replacement_amount": str(adjustment.replacement_amount),
            "net_amount": str(adjustment.net_amount),
        },
    )
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
            amount=adjustment.outbound_amount,
            remaining_amount=adjustment.outbound_amount,
            reason=adjustment.reason,
        )
        return

    SupplierPayment.objects.create(
        supplier=supplier,
        purchase_order=adjustment.purchase_order,
        amount=adjustment.outbound_amount,
        method=adjustment.settlement_method,
        notes=adjustment.reason,
        created_by=created_by,
    )


def fresh_purchase_adjustment_lines(locked_order, lines, *, locked_lines):
    requested_by_line = {}
    for line, quantity in lines:
        if line.purchase_order_id != locked_order.pk:
            raise serializers.ValidationError(
                {"lines": "Adjustment line does not belong to this purchase order."}
            )
        requested_by_line[line.pk] = requested_by_line.get(line.pk, 0) + quantity

    lines_by_id = {line.pk: line for line in locked_lines}
    if set(requested_by_line) - set(lines_by_id):
        raise serializers.ValidationError(
            {"lines": "Adjustment line does not belong to this purchase order."}
        )

    fresh_lines = []
    for line_id, quantity in requested_by_line.items():
        line = lines_by_id[line_id]
        adjustable_quantity = line.adjustable_quantity
        if quantity > adjustable_quantity:
            raise serializers.ValidationError(
                {
                    "lines": (
                        f"Cannot adjust more than {adjustable_quantity} "
                        "remaining items."
                    )
                }
            )
        fresh_lines.append((line, quantity))
    return fresh_lines


@transaction.atomic
def adjust_purchase_order_items(
    *,
    purchase_order,
    adjustment_type,
    lines,
    reason,
    replacement_lines=None,
    request=None,
    settlement_method="",
):
    locked_order = (
        PurchaseOrder.objects.select_for_update()
        .get(pk=purchase_order.pk)
    )
    locked_lines = lock_purchase_lines_for_update(locked_order)
    validate_purchase_order_adjustment_allowed(locked_order, lines=locked_lines)
    lines = fresh_purchase_adjustment_lines(
        locked_order,
        lines,
        locked_lines=locked_lines,
    )
    return create_purchase_order_adjustment(
        purchase_order=locked_order,
        adjustment_type=adjustment_type,
        lines=lines,
        replacement_lines=replacement_lines,
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
    # No commission on supplier pay-outs: a processing fee is the terminal
    # operator's cost, and here the shop is paying out, not collecting. Commission
    # is captured only on customer payments (where the shop runs the terminal).
    payment = SupplierPayment.objects.create(**payment_fields)
    if method == SupplierPayment.Method.SUPPLIER_CREDIT:
        consume_supplier_credit(supplier=supplier, amount=amount)
    return payment


@transaction.atomic
def cancel_purchase_order(purchase_order, *, request=None):
    locked_order = (
        PurchaseOrder.objects.select_for_update()
        .prefetch_related("lines__variant__product", "lines__receipt_lines")
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
        for line in locked_order.lines.select_related(
            "variant",
            "variant__product",
        ).order_by("variant_id"):
            outstanding_quantity = line.outstanding_quantity
            if outstanding_quantity <= 0:
                continue
            stock_item = lock_stock_item(variant=line.variant)
            before = stock_snapshot(stock_item)
            # quantity_expected is in base units; convert the outstanding packs.
            expected_reduction = decrement_expected(
                stock_item, line.to_base_quantity(outstanding_quantity)
            )
            if expected_reduction <= 0:
                continue
            save_stock_item_quantities(stock_item)
            create_stock_movement(
                stock_item=stock_item,
                variant=line.variant,
                movement_type=StockMovement.Type.CANCEL_EXPECTED,
                quantity=expected_reduction,
                note=f"إلغاء أمر شراء {locked_order.order_number}",
                created_by=created_by,
                before=before,
            )

    locked_order.status = PurchaseOrder.Status.CANCELLED
    locked_order.save(update_fields=["status", "updated_at"])
    record_purchase_order_audit_event(
        locked_order,
        PurchaseOrderAuditEvent.Action.CANCELLED,
        created_by=created_by,
    )
    return locked_order
