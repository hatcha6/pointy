"""Purchasing loaders: suppliers + historical purchase orders.

Purchase orders are written directly (status ``received``) without the live
receiving flow, so no stock movements are created — the on-hand quantities were
already imported from the source. The original date is preserved by overwriting
``PurchaseOrder.created_at``.
"""

from __future__ import annotations

from decimal import Decimal

from django.utils import timezone

from apps.catalog.models import ProductVariant
from apps.purchasing.models import PurchaseLine, PurchaseOrder, Supplier

from ..entity_plan import PURCHASE_ORDER, SUPPLIER, VARIANT
from .base import (
    CREATED,
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

_MONEY = Decimal("0.01")
_FALLBACK_SUPPLIER_NAME = "مورّد غير محدد"


class SupplierLoader(BaseLoader):
    entity_type = SUPPLIER

    def load(self, record, resolver, *, dry_run):
        name = clean_str(record.name)
        if not name:
            raise LoaderError("Supplier name is required.", code="missing_name")

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
            variant = resolver.existing(ProductVariant, VARIANT, line.variant_source_key)
            if variant is None:
                issues.append(
                    Issue(
                        WARNING,
                        "unresolved_variant",
                        f"Purchase line references unknown product {line.variant_source_key!r}; skipped.",
                        source_key=str(record.source_key),
                    )
                )
                continue
            quantity = int(to_decimal(line.quantity))
            if quantity <= 0:
                continue
            line_specs.append((variant, quantity, to_decimal(line.unit_cost)))
        if not line_specs:
            raise LoaderError("Purchase order has no resolvable line items.", code="no_lines")

        supplier = (
            resolver.existing(Supplier, SUPPLIER, record.supplier_source_key)
            if record.supplier_source_key
            else None
        )
        if supplier is None:
            supplier, _created = Supplier.objects.get_or_create(name=_FALLBACK_SUPPLIER_NAME)

        order = resolver.existing(PurchaseOrder, self.entity_type, record.source_key)
        action = UPDATED if order is not None else CREATED
        if order is not None:
            order.lines.all().delete()
        else:
            order = PurchaseOrder()
        order.supplier = supplier
        order.status = PurchaseOrder.Status.RECEIVED
        order.supplier_invoice_number = clean_str(record.supplier_invoice_number)[:120]
        if record.occurred_at is not None:
            order.received_at = _aware(record.occurred_at)
            order.supplier_invoice_date = _aware(record.occurred_at).date()
        order.save()

        subtotal = Decimal("0")
        for variant, quantity, cost in line_specs:
            line_total = (cost * quantity).quantize(_MONEY)
            PurchaseLine.objects.create(
                purchase_order=order,
                variant=variant,
                quantity=quantity,
                unit_cost=cost,
                net_line_total=line_total,
                net_unit_cost=cost,
                effective_unit_cost=cost,
            )
            subtotal += line_total

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


def _aware(value):
    if timezone.is_naive(value):
        return timezone.make_aware(value)
    return value
