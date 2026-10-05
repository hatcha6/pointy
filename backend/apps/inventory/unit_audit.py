"""§6.9: the changes that move no stock are on the record too.

A unit's history is ``allocations ∪ events``. The allocations come from the
documents that moved it; this module writes the events for the edits a person
makes to an article without moving it — its asking price, its facts, its notes,
its second number and its warranty — by comparing what the row held before the
edit with what it holds after. One comparison, every path: the generic edit,
the attribute form, the warranty field and the shelf markdown all end here, so
none of them can forget to leave a trace.

A price or a fact a customer can be quoted also moves the catalog version: the
price checker answers an IMEI from a cache keyed on it, and a kiosk quoting
yesterday's price for a handset is exactly the wrong number at the wrong time.
"""

from __future__ import annotations

from django.db import transaction
from django.utils import timezone

from .models import StockUnitEvent

#: The fields an edit may move, read before and compared after.
_AUDITED = (
    "list_price",
    "attributes",
    "notes",
    "secondary_code",
    "warranty_override_expires_on",
)


def snapshot(unit) -> dict:
    """What an edit is about to change, copied so a later save cannot alias it."""
    return {
        field: (
            dict(getattr(unit, field) or {})
            if field == "attributes"
            else getattr(unit, field)
        )
        for field in _AUDITED
    }


def _money(value) -> str:
    return "" if value is None else f"{value:.2f}"


def _date(value) -> str:
    return "" if value is None else value.isoformat()


def audit_unit_edit(unit, before: dict, *, actor=None, note: str = "") -> list:
    """Write one event per audited field that actually moved."""
    from .stock_count_tracking import record_unit_event

    actor = actor if getattr(actor, "is_authenticated", False) else None
    after = snapshot(unit)
    events = []

    if before["list_price"] != after["list_price"]:
        events.append(
            record_unit_event(
                unit,
                kind=StockUnitEvent.Kind.REPRICED,
                actor=actor,
                from_value=_money(before["list_price"]),
                to_value=_money(after["list_price"]),
                note=note,
            )
        )
    if before["attributes"] != after["attributes"]:
        from .unit_attributes import definitions_for, describe_change

        definitions = definitions_for(unit.variant.product.asset_type_id)
        from_value, to_value, changed = describe_change(
            before["attributes"], after["attributes"], definitions
        )
        events.append(
            record_unit_event(
                unit,
                kind=StockUnitEvent.Kind.ATTRIBUTES_EDITED,
                actor=actor,
                from_value=from_value,
                to_value=to_value,
                note=note or changed,
            )
        )
    if before["secondary_code"] != after["secondary_code"]:
        events.append(
            record_unit_event(
                unit,
                kind=StockUnitEvent.Kind.IDENTIFIER_CORRECTED,
                actor=actor,
                from_value=before["secondary_code"] or "",
                to_value=after["secondary_code"] or "",
                note=note,
            )
        )
    if before["notes"] != after["notes"]:
        events.append(
            record_unit_event(
                unit,
                kind=StockUnitEvent.Kind.NOTE,
                actor=actor,
                from_value=before["notes"] or "",
                to_value=after["notes"] or "",
                note=note,
            )
        )
    if before["warranty_override_expires_on"] != after["warranty_override_expires_on"]:
        events.append(
            record_unit_event(
                unit,
                kind=StockUnitEvent.Kind.WARRANTY_CHANGED,
                actor=actor,
                from_value=_date(before["warranty_override_expires_on"]),
                to_value=_date(after["warranty_override_expires_on"]),
                note=note,
            )
        )
    if events:
        _bump_catalog_version()
    return events


def record_reprices(changes, *, actor=None) -> None:
    """``[(unit, old_price, new_price), ...]`` as one insert of events."""
    if not changes:
        return
    actor = actor if getattr(actor, "is_authenticated", False) else None
    now = timezone.now()
    StockUnitEvent.objects.bulk_create(
        [
            StockUnitEvent(
                unit=unit,
                kind=StockUnitEvent.Kind.REPRICED,
                actor=actor,
                at=now,
                from_value=_money(old),
                to_value=_money(new),
                note="تعديل جماعي",
            )
            for unit, old, new in changes
        ]
    )
    _bump_catalog_version()


def _bump_catalog_version() -> None:
    """After commit, like every other counter: a kiosk that polled inside the
    transaction would otherwise cache the old price under the new number."""
    from apps.catalog.cache import bump_catalog_version

    transaction.on_commit(bump_catalog_version)


__all__ = ["audit_unit_edit", "record_reprices", "snapshot"]
