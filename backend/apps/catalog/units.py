"""Unit-of-measure conversion and pricing engine.

Pure, dependency-light functions shared by sales checkout and purchasing. The
invariants (see ``UNITS_IMPLEMENTATION_PLAN.md``):

* stock is always kept in the product's base unit; a transacted quantity is
  converted to base via its factor before touching stock;
* price and cost are *per transacted unit*; quantity is stored in the transacted
  unit; ``base_quantity = quantity * factor``;
* the conversion factor is snapshotted on the transaction line for auditability.

Resolution raises :class:`UnitConversionError` (a plain exception) on bad input;
the calling DRF serializer translates it into a field error.
"""

from __future__ import annotations

from dataclasses import dataclass
from decimal import ROUND_HALF_UP, Decimal

from apps.catalog.models import Product, ProductUnit, UnitOfMeasure

QUANTITY_PLACES = Decimal("0.001")
MONEY_PLACES = Decimal("0.01")
ONE = Decimal("1")


class UnitConversionError(Exception):
    """Raised for an invalid/disallowed unit on a transaction line. Carries the
    serializer field name so the caller can attach the message to it."""

    def __init__(self, field: str, message: str):
        self.field = field
        self.message = message
        super().__init__(message)


@dataclass(frozen=True)
class ResolvedUnit:
    """A unit resolved against a specific product, ready to price and convert."""

    code: str
    factor: Decimal  # base units per 1 of this unit
    is_base: bool
    allows_fractional: bool
    product_unit: ProductUnit | None
    unit: UnitOfMeasure | None


def quantize_quantity(value) -> Decimal:
    return Decimal(value).quantize(QUANTITY_PLACES, rounding=ROUND_HALF_UP)


def quantize_money(value) -> Decimal:
    return Decimal(value).quantize(MONEY_PLACES, rounding=ROUND_HALF_UP)


def _base_code(product: Product) -> str:
    return product.unit or Product.Unit.PIECE


def _base_uom(product: Product) -> UnitOfMeasure | None:
    return UnitOfMeasure.objects.filter(code=_base_code(product)).first()


def _base_allows_fractional(product: Product, uom: UnitOfMeasure | None) -> bool:
    if uom is not None:
        return uom.allows_fractional
    # Fallback for a base code without a seeded UoM row: preserve the legacy rule
    # that only "piece" was whole-number.
    return _base_code(product) != Product.Unit.PIECE


def _product_unit_by_code(product: Product, code: str) -> ProductUnit | None:
    # Relies on ``product.units`` being prefetched (with ``unit``) by the caller.
    for product_unit in product.units.all():
        if product_unit.unit.code == code:
            return product_unit
    return None


def base_resolved(product: Product) -> ResolvedUnit:
    uom = _base_uom(product)
    return ResolvedUnit(
        code=_base_code(product),
        factor=ONE,
        is_base=True,
        allows_fractional=_base_allows_fractional(product, uom),
        product_unit=None,
        unit=uom,
    )


def resolve_unit(
    product: Product,
    code: str | None,
    *,
    field: str = "unit",
    for_purchase: bool = False,
) -> ResolvedUnit:
    """Resolve ``code`` against ``product``. Blank/base code → the base unit.

    Raises :class:`UnitConversionError` if the code is unknown for this product,
    or not available for the requested direction (sale vs purchase)."""

    if not code or code == _base_code(product):
        return base_resolved(product)

    product_unit = _product_unit_by_code(product, code)
    if product_unit is None or not product_unit.unit.is_active:
        raise UnitConversionError(field, f"Unknown unit '{code}' for this product.")
    if for_purchase and not product_unit.is_purchasable:
        raise UnitConversionError(field, "This unit is not available for purchasing.")
    if not for_purchase and not product_unit.is_sellable:
        raise UnitConversionError(field, "This unit is not available for sale.")
    return ResolvedUnit(
        code=code,
        factor=product_unit.factor_to_base,
        is_base=False,
        allows_fractional=product_unit.unit.allows_fractional,
        product_unit=product_unit,
        unit=product_unit.unit,
    )


def validate_quantity(quantity: Decimal, resolved: ResolvedUnit, *, field: str = "quantity") -> None:
    """Quantity-acceptability seam for a transaction line.

    Fractional quantities are allowed for **every** unit: a cashier or buyer may
    ring up 2.5 of any product — whole-number unit or not — and that is their
    choice. Every quantity column is decimal, so nothing downstream needs a whole
    number. This used to reject fractions when ``resolved.allows_fractional`` was
    false; that guard was intentionally dropped. The function is kept as the one
    seam both sales and purchasing funnel through, so per-unit (or per-shop)
    whole-number enforcement can be reintroduced in a single place if ever asked
    for. ``quantity``/``resolved`` are retained in the signature for that seam."""


def to_base_quantity(quantity, resolved: ResolvedUnit) -> Decimal:
    """Quantity in the transacted unit → quantity in the product's base unit."""

    return quantize_quantity(Decimal(quantity) * resolved.factor)


def unit_sale_price(variant, resolved: ResolvedUnit) -> Decimal:
    """Price for one of the resolved unit: the custom per-unit price if set, else
    the variant base price scaled by the conversion factor."""

    product_unit = resolved.product_unit
    if product_unit is not None and product_unit.price is not None:
        return quantize_money(product_unit.price)
    return quantize_money(Decimal(variant.unit_price) * resolved.factor)


def scale_cost_to_unit(base_unit_cost, resolved: ResolvedUnit) -> Decimal:
    """Per-base-unit cost → per-transacted-unit cost (cost of one box = 12× the
    per-piece cost)."""

    return quantize_money(Decimal(base_unit_cost) * resolved.factor)


def base_unit_cost_from_purchase(line_unit_cost, factor) -> Decimal:
    """A purchase line stores cost per *transacted* unit; normalise to per base
    unit so the sales cost-lookup stays base-denominated."""

    factor = Decimal(factor or ONE)
    if factor <= 0:
        return quantize_money(line_unit_cost)
    return quantize_money(Decimal(line_unit_cost) / factor)


def unit_label_for(code: str, context: dict | None = None) -> str:
    """Short display label (abbreviation, then name, then code) for a unit code.

    Builds the code→label map once and caches it in the DRF serializer ``context``
    so a document's many lines share a single query."""

    if not code:
        return ""
    cache = None if context is None else context.get("_unit_labels")
    if cache is None:
        cache = {
            unit.code: (unit.abbreviation or unit.name or unit.code)
            for unit in UnitOfMeasure.objects.all()
        }
        if context is not None:
            context["_unit_labels"] = cache
    return cache.get(code, code)
