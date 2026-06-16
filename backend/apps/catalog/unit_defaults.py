"""Seed data for the global :class:`~apps.catalog.models.UnitOfMeasure` registry.

Kept in a module (mirroring ``variant_option_defaults``) so the seed migration and
the initial-setup data check in ``apps.core.roles`` can share the same constants.

``reference_factor`` is expressed in the dimension's reference unit (piece for
count, kg for weight, liter for volume, meter for length). It powers a *suggested*
per-product factor when a unit shares the base unit's dimension — e.g. adding "kg"
to a gram-based product suggests 1000. Packaging units (box, carton, pack, bag)
have no universal factor, so ``reference_factor`` is ``None`` and the manager sets
the conversion per product.
"""

from decimal import Decimal

# Each entry: code, name (Arabic), abbreviation, dimension, reference_factor,
# allows_fractional, display_order.
DEFAULT_UNITS = [
    # Count — reference unit is "piece".
    ("piece", "قطعة", "قطعة", "count", Decimal("1"), False, 10),
    ("pair", "زوج", "زوج", "count", Decimal("2"), False, 20),
    ("dozen", "دزينة", "دزينة", "count", Decimal("12"), False, 30),
    ("pack", "عبوة", "عبوة", "count", None, False, 40),
    ("box", "صندوق", "صندوق", "count", None, False, 50),
    ("carton", "كرتون", "كرتون", "count", None, False, 60),
    ("bag", "كيس", "كيس", "count", None, False, 70),
    # Weight — reference unit is "kg".
    ("kg", "كيلوغرام", "كجم", "weight", Decimal("1"), True, 110),
    ("g", "غرام", "جم", "weight", Decimal("0.001"), True, 120),
    ("ton", "طن", "طن", "weight", Decimal("1000"), True, 130),
    # Volume — reference unit is "liter".
    ("l", "لتر", "لتر", "volume", Decimal("1"), True, 210),
    ("ml", "مليلتر", "مل", "volume", Decimal("0.001"), True, 220),
    # Length — reference unit is "meter".
    ("m", "متر", "م", "length", Decimal("1"), True, 310),
    ("cm", "سنتيمتر", "سم", "length", Decimal("0.01"), True, 320),
]

DEFAULT_UNIT_CODES = [entry[0] for entry in DEFAULT_UNITS]
