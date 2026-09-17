"""The wire shape of a scan that resolved to identified stock.

Hand-written rather than a ``ModelSerializer`` because what the till needs back
from a scan is not a model — it is an *instruction*: this variant, this unit,
this lot, at this price, expiring then. A serializer per model would make the
client assemble that from four payloads on the busiest path in the shop.

The cost mask of ``inventory.view_stockunit_cost`` applies here too and for the
same reason: a scan at the counter must not tell a cashier what the shop paid
the walk-in seller who brought the handset in.
"""

from __future__ import annotations

from apps.catalog.tracked_resolution import KIND_NONE


def serialize_tracked_resolution(resolution, *, request=None) -> dict:
    payload = {
        "kind": resolution.kind,
        "found": resolution.found,
        "warnings": list(resolution.warnings),
        "variant": _variant(resolution.variant),
        "stock_unit": _unit(resolution.stock_unit, request=request),
        "stock_batch": _batch(resolution.stock_batch),
        "expiry_date": (
            resolution.expiry_date.isoformat() if resolution.expiry_date else ""
        ),
    }
    if resolution.scan is not None:
        payload["gs1"] = resolution.scan.as_dict()
    return payload


def _variant(variant):
    if variant is None:
        return None
    product = variant.product
    return {
        "id": variant.pk,
        "sku": variant.sku,
        "barcode": variant.barcode,
        "gtin": variant.gtin,
        "name": variant.display_name,
        "full_name": variant.full_name,
        "unit_price": str(variant.unit_price),
        "product": {
            "id": product.pk,
            "name": product.name,
            "tracking_mode": product.tracking_mode,
            "is_service": product.is_service,
            "is_prepared": product.is_prepared,
            "unit": product.unit,
        },
    }


def _unit(unit, *, request=None):
    if unit is None:
        return None
    payload = {
        "id": unit.pk,
        "code": unit.code,
        "identifier_kind": unit.identifier_kind,
        "secondary_code": unit.secondary_code,
        "status": unit.status,
        "warehouse": unit.warehouse_id,
        "is_identified": unit.is_identified,
        "is_consignment": unit.is_consignment,
        # The unit's own asking price when it has one. Resolved here rather than
        # at the till so the two can never disagree about which price won.
        "list_price": str(unit.list_price) if unit.list_price is not None else "",
        "in_stock_since": (
            unit.in_stock_since.isoformat() if unit.in_stock_since else ""
        ),
        "batch": unit.batch_id,
        "attributes": unit.attributes,
    }
    user = getattr(request, "user", None)
    if user is not None and user.has_perm("inventory.view_stockunit_cost"):
        payload["incoming_rate"] = str(unit.incoming_rate)
        payload["refurb_cost"] = str(unit.refurb_cost)
        payload["total_cost"] = str(unit.stock_value)
    return payload


def _batch(batch):
    if batch is None:
        return None
    return {
        "id": batch.pk,
        "code": batch.code,
        "display_code": batch.display_code,
        "expiry_date": batch.expiry_date.isoformat() if batch.expiry_date else "",
        "status": batch.status,
        "is_locked": batch.is_locked,
        "is_sellable": batch.is_sellable,
    }


__all__ = ["KIND_NONE", "serialize_tracked_resolution"]
