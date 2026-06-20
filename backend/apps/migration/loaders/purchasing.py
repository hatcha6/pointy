"""Purchasing loaders: suppliers (master data) + purchase orders (stub)."""

from __future__ import annotations

from apps.purchasing.models import Supplier

from ..entity_plan import PURCHASE_ORDER, SUPPLIER
from .base import (
    CREATED,
    UPDATED,
    BaseLoader,
    LoaderError,
    LoadOutcome,
    NotImplementedLoader,
    clean_str,
    to_bool,
)


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


class PurchaseOrderLoader(NotImplementedLoader):
    """Stub. Implement with direct ORM writes against ``PurchaseOrder`` /
    ``PurchaseLine`` (never the live receiving flow), resolving supplier +
    variants through the resolver. ``order_number`` is auto-generated, so match
    via the identity map only."""

    entity_type = PURCHASE_ORDER
