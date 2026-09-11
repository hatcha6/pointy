"""Turning a scale label's value into a quantity of *this* product.

The arithmetic lives in :mod:`apps.catalog.scale_barcodes` and is pure. What is
needed on top is the product's own unit: whether it is a measured thing at all,
and how its unit relates to the one the label is denominated in. A label that
says 1.500 kg is 1500 for a product stocked in grams and is nothing at all for
a product counted in boxes.
"""

from __future__ import annotations

from decimal import Decimal

from . import scale_barcodes
from .models import UnitOfMeasure
from .units import base_resolved


def conversion_factor(value_unit: str, product_unit: str) -> Decimal | None:
    """How many of ``product_unit`` are in one ``value_unit``.

    ``None`` when the two cannot be converted between — different dimensions, or
    a unit with no global conversion (packaging units, whose real factors are
    per product). Reported rather than guessed: silently treating 1.5 kg as 1.5
    boxes is exactly the class of wrongness this feature exists to remove.
    """

    value_code = (value_unit or "").strip().lower()
    product_code = (product_unit or "").strip().lower()
    if not value_code or not product_code:
        # One of them is unnamed, so there is no conversion to reason about.
        # Answering "1" here would quietly ring a weight as a count.
        return None
    if value_code == product_code:
        return Decimal(1)
    units = {
        unit.code: unit
        for unit in UnitOfMeasure.objects.filter(code__in=[value_code, product_code])
    }
    source = units.get(value_code)
    target = units.get(product_code)
    if source is None or target is None:
        return None
    if source.dimension != target.dimension:
        return None
    if not source.reference_factor or not target.reference_factor:
        return None
    return Decimal(source.reference_factor) / Decimal(target.reference_factor)


def resolve_scale_quantity(
    match: scale_barcodes.ScaleBarcodeMatch,
    variant,
    *,
    unit_price: Decimal | None = None,
) -> scale_barcodes.ScaleQuantity:
    """The quantity ``variant`` should ring for this label.

    ``unit_price`` defaults to the variant's own price; the price checker passes
    the discounted price instead, because a sticker has to be worth what the
    till will actually charge for it.
    """

    product = variant.product
    resolved = base_resolved(product)
    factor = (
        conversion_factor(match.rule.value_unit, resolved.code)
        if match.value_kind == scale_barcodes.ValueKind.WEIGHT
        else Decimal(1)
    )
    return scale_barcodes.resolve_quantity(
        match,
        unit_price=Decimal(unit_price if unit_price is not None else variant.unit_price),
        allows_fractional=resolved.allows_fractional,
        unit_factor=factor,
    )
