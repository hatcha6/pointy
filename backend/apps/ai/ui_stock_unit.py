"""The ``StockUnitCard`` properties for one identified article (§8.4).

The assistant tools hand these back beside their prose-friendly rows so the
model can draw the card by copying one object rather than re-deriving a status
tone or a lot's sellability from raw fields — which is exactly the kind of
"creativity" a generated card must not have. They are validated by the same
catalog rules as anything else the model draws.

**No cost, by construction.** Nothing here reads ``incoming_rate``, refurb cost
or a consignment payout: a chat transcript is forwarded, and the kiosk's rule
(§13) holds for the same reason with less force.
"""

from __future__ import annotations

from decimal import Decimal

from django.utils import timezone

#: The catalog component these properties belong to.
COMPONENT = "StockUnitCard"


def _availability(unit) -> str:
    """Whether the article's lot may be sold: the till's own two refusals."""
    batch = unit.batch if unit.batch_id else None
    if batch is None:
        return "ok"
    if not batch.is_sellable:
        from apps.inventory.models import StockBatch

        return "expired" if batch.status == StockBatch.Status.EXPIRED else "recalled"
    if (
        batch.expiry_date is not None
        and batch.expiry_date < timezone.localdate()
        and unit.variant.product.prevent_selling_expired
    ):
        return "expired"
    return "ok"


def _attribute_rows(units) -> dict:
    """``{unit_id: [{label, value}]}``, one definitions query for all of them."""
    from apps.inventory.models import UnitAttributeDefinition

    keys = {key for unit in units for key in (unit.attributes or {})}
    if not keys:
        return {}
    labels = dict(
        UnitAttributeDefinition.objects.filter(key__in=keys).values_list(
            "key", "label"
        )
    )
    return {
        unit.pk: [
            {"label": labels[key], "value": str(value)}
            for key, value in (unit.attributes or {}).items()
            if key in labels and str(value)
        ]
        for unit in units
    }


def stock_unit_cards(units, *, variant="full") -> dict:
    """``{unit_id: props}`` for each unit, ready to drop into ``render_ui``."""
    units = list(units)
    attributes = _attribute_rows(units) if variant == "full" else {}
    now = timezone.now()
    cards = {}
    for unit in units:
        price = (
            unit.list_price if unit.list_price is not None else unit.variant.unit_price
        )
        batch = unit.batch if unit.batch_id else None
        props = {
            "unitId": unit.pk,
            "code": unit.code,
            "product": unit.variant.full_name,
            "status": unit.status,
            "price": float(Decimal(price)),
            "variant": variant,
        }
        if unit.in_stock_since:
            props["daysOnShelf"] = (now - unit.in_stock_since).days
        warehouse = getattr(unit.warehouse, "name", "") if unit.warehouse_id else ""
        if warehouse:
            props["warehouse"] = warehouse
        if batch is not None:
            if batch.display_code:
                props["lot"] = batch.display_code
            if batch.expiry_date:
                props["expiryDate"] = batch.expiry_date.isoformat()
        availability = _availability(unit)
        if availability != "ok":
            props["availability"] = availability
        if unit.is_consignment:
            props["consignment"] = True
        if attributes.get(unit.pk):
            props["attributes"] = attributes[unit.pk]
        cards[unit.pk] = props
    return cards


def stock_unit_card(unit, *, variant="full") -> dict:
    return stock_unit_cards([unit], variant=variant)[unit.pk]
