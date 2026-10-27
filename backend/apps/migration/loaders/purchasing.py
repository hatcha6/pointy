"""Purchasing loaders: suppliers + historical purchase orders.

Purchase orders are written directly (status ``received``) without the live
receiving flow, so no stock movements are created — the on-hand quantities were
already imported from the source. The original date is preserved by overwriting
``PurchaseOrder.created_at``.
"""

from __future__ import annotations

from decimal import Decimal

from django.utils import timezone

from apps.documents.guards import system_write
from apps.purchasing.models import (
    PurchaseLine,
    PurchaseOrder,
    PurchaseOrderAdjustment,
    PurchaseOrderAdjustmentLine,
    Supplier,
    SupplierCredit,
    SupplierPayment,
)

from ..entity_plan import PURCHASE_ORDER, PURCHASE_RETURN, SUPPLIER, SUPPLIER_PAYMENT, VARIANT
from .base import (
    CREATED,
    SKIPPED,
    UPDATED,
    WARNING,
    BaseLoader,
    Issue,
    LoaderError,
    LoadOutcome,
    clean_str,
    to_bool,
    to_decimal,
)

_SUPPLIER_PAYMENT_METHODS = {choice for choice, _label in SupplierPayment.Method.choices}

_MONEY = Decimal("0.01")
_FALLBACK_SUPPLIER_NAME = "مورّد غير محدد"


def fallback_supplier():
    """The stand-in supplier for an order whose own is unknown."""
    supplier, _created = Supplier.objects.get_or_create(name=_FALLBACK_SUPPLIER_NAME)
    return supplier


class SupplierLoader(BaseLoader):
    entity_type = SUPPLIER

    def load(self, record, resolver, *, dry_run):
        name = clean_str(record.name)
        if not name:
            raise LoaderError("اسم المورّد مطلوب.", code="missing_name")

        phone = clean_str(record.phone)
        instance = resolver.existing(Supplier, self.entity_type, record.source_key)
        if instance is None and phone:
            instance = Supplier.objects.filter(name=name, phone=phone).first()
        if instance is None:
            instance = Supplier.objects.filter(name=name).first()
        action = UPDATED if instance is not None else CREATED
        if instance is None:
            instance = Supplier()
        instance.name = name
        instance.contact_name = clean_str(record.contact_name)
        instance.phone = phone
        instance.email = clean_str(record.email)
        instance.address = clean_str(record.address)
        instance.notes = clean_str(record.notes)
        instance.is_active = to_bool(record.is_active)
        instance.save()
        resolver.remember(self.entity_type, record.source_key, instance)
        return LoadOutcome(action, instance.pk)


class PurchaseOrderLoader(BaseLoader):
    entity_type = PURCHASE_ORDER

    def load(self, record, resolver, *, dry_run):
        issues: list[Issue] = []
        line_specs = []
        for line in record.lines:
            variant_pk = resolver.resolve(VARIANT, line.variant_source_key)
            if variant_pk is None:
                issues.append(
                    Issue(
                        WARNING,
                        "unresolved_variant",
                        f"سطر شراء يشير إلى صنف غير معروف {line.variant_source_key!r} — تم تجاهل السطر.",
                        source_key=str(record.source_key),
                    )
                )
                continue
            quantity = to_decimal(line.quantity)
            if quantity <= 0:
                continue
            line_specs.append((variant_pk, quantity, to_decimal(line.unit_cost)))
        if not line_specs:
            raise LoaderError("لا يوجد في فاتورة الشراء أي سطر يمكن ربطه بصنف.", code="no_lines")

        supplier_pk = resolver.resolve(SUPPLIER, record.supplier_source_key)
        if supplier_pk is None:
            supplier_pk = fallback_supplier().pk

        order = resolver.existing(PurchaseOrder, self.entity_type, record.source_key)
        action = UPDATED if order is not None else CREATED
        if order is not None:
            # Returns first: ``PurchaseOrderAdjustmentLine.purchase_line`` is
            # PROTECT. They are rebuilt from the source right after the orders
            # are (ENTITY_PLAN puts PURCHASE_RETURN immediately after).
            _withdraw_returns(order)
            order.lines.all().delete()
        else:
            order = PurchaseOrder()
        # An import reconstructs documents that were already delivered, and a
        # re-import replays the same source rows over them. That is a machine
        # rewriting history, not a person editing a submitted order, so it runs
        # past the document freeze deliberately — the same rule the period lock
        # already follows (apps.core.period_lock: guards govern people, not
        # code). See apps.documents.test_registered_types for the census of
        # everywhere this is allowed.
        with system_write():
            return self._write(
                order,
                action=action,
                record=record,
                resolver=resolver,
                supplier_pk=supplier_pk,
                line_specs=line_specs,
                issues=issues,
            )

    def _write(
        self,
        order,
        *,
        action,
        record,
        resolver,
        supplier_pk,
        line_specs,
        issues,
    ):
        order.supplier_id = supplier_pk
        if not order.order_number:
            # Numbered after the run, in file order (``planning``).
            order.order_number = getattr(record, "planned_number", "")
        order.status = PurchaseOrder.Status.RECEIVED
        order.supplier_invoice_number = clean_str(record.supplier_invoice_number)[:120]
        if record.occurred_at is not None:
            order.received_at = _aware(record.occurred_at)
            order.supplier_invoice_date = _aware(record.occurred_at).date()
        order.save()

        subtotal = Decimal("0")
        lines = []
        for variant_pk, quantity, cost in line_specs:
            line_total = (cost * quantity).quantize(_MONEY)
            lines.append(
                PurchaseLine(
                    purchase_order=order,
                    variant_id=variant_pk,
                    quantity=quantity,
                    unit_cost=cost,
                    net_line_total=line_total,
                    net_unit_cost=cost,
                    effective_unit_cost=cost,
                )
            )
            subtotal += line_total
        PurchaseLine.objects.bulk_create(lines)

        discount = to_decimal(record.discount_total)
        order.subtotal = subtotal.quantize(_MONEY)
        order.discount_total = min(discount, order.subtotal)
        order.total = (order.subtotal - order.discount_total).quantize(_MONEY)
        order.save(
            update_fields=[
                "supplier",
                "status",
                "supplier_invoice_number",
                "supplier_invoice_date",
                "received_at",
                "subtotal",
                "discount_total",
                "total",
                "updated_at",
            ]
        )

        if record.occurred_at is not None:
            PurchaseOrder.objects.filter(pk=order.pk).update(created_at=_aware(record.occurred_at))

        resolver.remember(self.entity_type, record.source_key, order)
        return LoadOutcome(action, order.pk, issues)


class SupplierPaymentLoader(BaseLoader):
    entity_type = SUPPLIER_PAYMENT

    def load(self, record, resolver, *, dry_run):
        amount = to_decimal(record.amount)
        if amount <= 0:
            raise LoaderError(
                "مبلغ دفعة المورّد يجب أن يكون أكبر من صفر.",
                code="invalid_amount",
            )
        supplier_pk = resolver.resolve(SUPPLIER, record.supplier_source_key)
        if supplier_pk is None:
            raise LoaderError(
                f"دفعة تشير إلى مورّد غير معروف {record.supplier_source_key!r}.",
                code="unresolved_supplier",
            )

        method = record.method if record.method in _SUPPLIER_PAYMENT_METHODS else "cash"
        instance = resolver.existing(SupplierPayment, self.entity_type, record.source_key)
        action = UPDATED if instance is not None else CREATED
        if instance is None:
            instance = SupplierPayment()
        instance.supplier_id = supplier_pk
        instance.amount = amount
        instance.method = method
        instance.reference = clean_str(record.reference)[:128]
        instance.notes = clean_str(record.notes)
        if record.occurred_at is not None:
            instance.paid_at = _aware(record.occurred_at)
        instance.save()
        resolver.remember(self.entity_type, record.source_key, instance)
        return LoadOutcome(action, instance.pk)


def _withdraw_returns(order, *, only=None):
    """Delete ``order``'s returns (or just ``only``) and the credit each issued.

    A credit the shop has already spent against a payment is history that
    happened in Pointy, not in the source — refused rather than unwound.
    """
    adjustments = PurchaseOrderAdjustment.objects.filter(purchase_order=order)
    if only is not None:
        adjustments = adjustments.filter(pk=only.pk)
    credits = SupplierCredit.objects.filter(adjustment__in=adjustments)
    if any(credit.remaining_amount != credit.amount for credit in credits):
        raise LoaderError(
            "رصيد مرتجع هذه الفاتورة استُخدم في دفعة للمورّد — لم يُعَد استيراده.",
            code="return_credit_spent",
        )
    credits.delete()
    adjustments.delete()


class PurchaseReturnLoader(BaseLoader):
    """Goods sent back to a supplier, as a return on the purchase they came off.

    Written the way a live return settled as credit is
    (``purchasing.services.create_purchase_order_adjustment``): an adjustment
    with its lines and a ``SupplierCredit`` for the amount — but deliberately
    **no stock movement**, because on-hand was imported as the source's own
    final count, which already has these goods off the shelf.
    """

    entity_type = PURCHASE_RETURN

    def load(self, record, resolver, *, dry_run):
        if not record.purchase_order_source_key:
            return LoadOutcome(
                SKIPPED,
                None,
                [
                    Issue(
                        WARNING,
                        "purchase_return_without_order",
                        "مرتجع للمورّد لا يطابق أي فاتورة شراء مستوردة من نفس المورّد — لم يُسجَّل شيء.",
                        source_key=str(record.source_key),
                        detail={
                            "amount": str(
                                sum(
                                    (
                                        to_decimal(line.unit_cost) * to_decimal(line.quantity)
                                        for line in record.lines
                                    ),
                                    Decimal("0"),
                                ).quantize(_MONEY)
                            )
                        },
                    )
                ],
            )
        order_pk = resolver.resolve(PURCHASE_ORDER, record.purchase_order_source_key)
        order = PurchaseOrder.objects.filter(pk=order_pk).first() if order_pk else None
        if order is None:
            raise LoaderError(
                f"مرتجع يشير إلى فاتورة شراء غير معروفة {record.purchase_order_source_key!r}.",
                code="unresolved_purchase_order",
            )

        issues: list[Issue] = []
        by_variant: dict[int, PurchaseLine] = {}
        for line in order.lines.all():
            by_variant.setdefault(line.variant_id, line)
        specs = []
        for line in record.lines:
            variant_pk = resolver.resolve(VARIANT, line.variant_source_key)
            purchase_line = by_variant.get(variant_pk) if variant_pk else None
            if purchase_line is None:
                issues.append(
                    Issue(
                        WARNING,
                        "return_line_unmatched",
                        f"الصنف المرتجع {line.variant_source_key!r} غير موجود في فاتورة "
                        "الشراء — تم تجاهل السطر.",
                        source_key=str(record.source_key),
                    )
                )
                continue
            quantity = min(to_decimal(line.quantity), to_decimal(purchase_line.quantity))
            if quantity <= 0:
                continue
            cost = to_decimal(line.unit_cost) or to_decimal(purchase_line.net_unit_cost)
            specs.append((purchase_line, quantity, cost))
        if not specs:
            raise LoaderError("لا يوجد في المرتجع أي سطر يطابق فاتورة الشراء.", code="no_lines")

        existing = resolver.existing(PurchaseOrderAdjustment, self.entity_type, record.source_key)
        action = UPDATED if existing is not None else CREATED
        amount = sum(
            ((cost * quantity).quantize(_MONEY) for _line, quantity, cost in specs),
            Decimal("0.00"),
        )
        reason = clean_str(record.reason) or "مرتجع للمورّد من النظام السابق"
        with system_write():
            if existing is not None:
                _withdraw_returns(existing.purchase_order, only=existing)
            adjustment = PurchaseOrderAdjustment.objects.create(
                purchase_order=order,
                adjustment_type=PurchaseOrderAdjustment.AdjustmentType.RETURN,
                amount=amount,
                outbound_amount=amount,
                net_amount=-amount,
                settlement_method=PurchaseOrderAdjustment.SettlementMethod.SUPPLIER_CREDIT,
                reason=reason,
            )
            for purchase_line, quantity, cost in specs:
                PurchaseOrderAdjustmentLine.objects.create(
                    adjustment=adjustment,
                    purchase_line=purchase_line,
                    variant_id=purchase_line.variant_id,
                    quantity=quantity,
                    unit_cost=cost,
                    line_amount=(cost * quantity).quantize(_MONEY),
                )
            if amount > 0 and order.supplier_id:
                SupplierCredit.objects.create(
                    supplier_id=order.supplier_id,
                    purchase_order=order,
                    adjustment=adjustment,
                    amount=amount,
                    remaining_amount=amount,
                    reason=reason,
                )
            if record.occurred_at is not None:
                at = _aware(record.occurred_at)
                PurchaseOrderAdjustment.objects.filter(pk=adjustment.pk).update(created_at=at)
                SupplierCredit.objects.filter(adjustment=adjustment).update(created_at=at)
        resolver.remember(self.entity_type, record.source_key, adjustment)
        return LoadOutcome(action, adjustment.pk, issues)


def _aware(value):
    if timezone.is_naive(value):
        return timezone.make_aware(value)
    return value
