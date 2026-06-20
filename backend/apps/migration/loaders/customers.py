"""Customer loader."""

from __future__ import annotations

from apps.customers.models import Customer

from ..entity_plan import CUSTOMER
from .base import (
    CREATED,
    UPDATED,
    BaseLoader,
    LoaderError,
    LoadOutcome,
    clean_str,
    to_bool,
)


class CustomerLoader(BaseLoader):
    entity_type = CUSTOMER

    def load(self, record, resolver, *, dry_run):
        full_name = clean_str(record.full_name)
        if not full_name:
            raise LoaderError("Customer name is required.", code="missing_name")

        phone = clean_str(record.phone)
        email = clean_str(record.email)

        instance = resolver.existing(Customer, self.entity_type, record.source_key)
        # No unique natural key on the model, but phone/email are good de-dup
        # signals on a first import; only match when present.
        if instance is None and phone:
            instance = Customer.objects.filter(phone=phone).first()
        if instance is None and email:
            instance = Customer.objects.filter(email=email).first()
        action = UPDATED if instance is not None else CREATED
        if instance is None:
            instance = Customer()
        instance.full_name = full_name
        instance.phone = phone
        instance.email = email
        instance.notes = clean_str(record.notes)
        instance.is_active = to_bool(record.is_active)
        # Customer.save() runs full_clean() and auto-assigns customer_number;
        # a malformed email surfaces here as a per-record error.
        instance.save()
        resolver.remember(self.entity_type, record.source_key, instance)
        return LoadOutcome(action, instance.pk)
