"""Map the pack language printed on an invoice to a real
:class:`~apps.catalog.models.ProductUnit`.

"كرتونة 12" is two facts: the unit word ("كرتونة" → the ``carton`` unit) and the
conversion for *this* product (12 pieces to the carton). Getting them onto the
purchase line is what keeps the cost per pack from being read as a cost per
piece — the phantom-loss bug class the UoM cost normalisation work closed. A
label we cannot resolve is never guessed at: the line falls back to the
product's base unit and carries a warning, which is a visible, correctable
mistake rather than a silent 12× cost error.
"""

import re
from decimal import Decimal

from apps.catalog.search_terms import normalize_term

# Words Libyan suppliers actually print, mapped to the seeded unit codes in
# apps.catalog.unit_defaults. The DB registry is editable, so this is a
# supplement to (never a replacement for) matching a unit's own code/name/
# abbreviation — see _unit_index.
_SYNONYMS = {
    "carton": ("كرتون", "كرتونة", "كارتون", "carton", "ctn", "ktn"),
    "box": ("صندوق", "علبة", "بوكس", "box"),
    "pack": ("عبوة", "باكيت", "شد", "شدة", "ربطة", "pack", "pkt"),
    "bag": ("كيس", "شوال", "جوال", "bag", "sack"),
    "dozen": ("دزينة", "درزن", "dozen", "dz"),
    "pair": ("زوج", "pair"),
    "piece": ("قطعة", "حبة", "وحدة", "piece", "pieces", "pcs", "pc", "ea", "each", "unit"),
    "kg": ("كيلو", "كيلوغرام", "كيلوجرام", "كجم", "kg", "kilo", "kgs"),
    "g": ("غرام", "جرام", "جم", "g", "gm", "gr"),
    "ton": ("طن", "ton", "tonne"),
    "l": ("لتر", "liter", "litre", "lt", "l"),
    "ml": ("مليلتر", "مل", "ml"),
    "m": ("متر", "meter", "metre", "m"),
    "cm": ("سنتيمتر", "سم", "cm"),
}
_SYNONYM_INDEX = {
    normalize_term(word): code for code, words in _SYNONYMS.items() for word in words
}

_TRAILING_NUMBER = re.compile(r"(\d+(?:\.\d+)?)")

# Warnings a line can carry back from unit mapping.
UNIT_UNKNOWN = "unit_unknown"
UNIT_FACTOR_UNKNOWN = "unit_factor_unknown"
UNIT_FACTOR_MISMATCH = "unit_factor_mismatch"
UNIT_NOT_PURCHASABLE = "unit_not_purchasable"


def split_label(unit_label):
    """``"كرتونة 12"`` → ``("كرتونة", Decimal("12"))``. The pack size is printed
    inside the label as often as it is given as its own column."""
    text = (unit_label or "").strip()
    if not text:
        return "", None
    match = _TRAILING_NUMBER.search(text)
    size = None
    if match is not None:
        try:
            size = Decimal(match.group(1))
        except Exception:  # pragma: no cover - regex already guarantees a number
            size = None
        text = (text[: match.start()] + " " + text[match.end():]).strip()
    return text, (size if size and size > 0 else None)


def _unit_index():
    """Every active unit keyed by each way it can be written: its code, its
    (Arabic) name and its abbreviation."""
    from apps.catalog.models import UnitOfMeasure

    index = {}
    for unit in UnitOfMeasure.objects.active():
        for key in (unit.code, unit.name, unit.abbreviation):
            normalized = normalize_term(key)
            if normalized:
                index.setdefault(normalized, unit)
    return index


def resolve_unit_of_measure(unit_label, *, index=None):
    """The :class:`UnitOfMeasure` a printed label names, or ``None``."""
    word, _ = split_label(unit_label)
    key = normalize_term(word)
    if not key:
        return None
    index = _unit_index() if index is None else index
    unit = index.get(key)
    if unit is not None:
        return unit
    code = _SYNONYM_INDEX.get(key)
    if code is None:
        # "كرتونة كبيرة" — try the individual words before giving up.
        for token in key.split():
            code = _SYNONYM_INDEX.get(token)
            if code:
                break
    if code is None:
        return None
    return index.get(normalize_term(code))


def _suggested_factor(unit, base_unit):
    """The conversion implied by the global registry, when both units measure
    the same physical dimension (g → kg is 0.001). Packaging units have no
    universal factor, so this returns ``None`` for them — that conversion is
    per-product and has to come off the invoice."""
    if unit is None or base_unit is None:
        return None
    if unit.dimension != base_unit.dimension:
        return None
    if not unit.reference_factor or not base_unit.reference_factor:
        return None
    if base_unit.reference_factor <= 0:
        return None
    return Decimal(unit.reference_factor) / Decimal(base_unit.reference_factor)


def map_line_unit(product, unit_label, pack_size, *, index=None):
    """Resolve a line's printed pack to a unit usable on a purchase line.

    Returns ``{"code", "factor", "status", "product_unit_id", "propose",
    "warnings"}`` where ``status`` is:

    ``base``
        the line is in the product's own stock unit — ``code`` is ``""``, which
        is what the purchase-line serializer wants for "no pack unit".
    ``existing``
        the product already has this :class:`ProductUnit`; use it.
    ``propose``
        the product does not have it yet and we know the factor — ``propose``
        carries what to create.

    ``product`` may be ``None`` for a line that will create a new product; the
    proposal is then built against a plain ``piece`` base.
    """
    warnings = []
    index = _unit_index() if index is None else index
    word, embedded_size = split_label(unit_label)

    from .schemas import to_decimal

    factor = to_decimal(pack_size) or embedded_size
    if factor is not None and factor <= 0:
        factor = None

    base_code = getattr(product, "unit", None) or "piece"
    base_unit = index.get(normalize_term(base_code))

    blank = {
        "code": "",
        "factor": Decimal("1"),
        "status": "base",
        "product_unit_id": None,
        "propose": None,
        "warnings": warnings,
    }
    if not word:
        return blank

    unit = resolve_unit_of_measure(unit_label, index=index)
    if unit is None:
        warnings.append(UNIT_UNKNOWN)
        return blank
    if unit.code == base_code:
        # The invoice priced the product in its own stock unit; a pack size
        # printed alongside it ("قطعة") is noise, not a conversion.
        return blank

    existing = None
    if product is not None and product.pk:
        existing = next(
            (link for link in product.units.all() if link.unit_id == unit.pk),
            None,
        )
    if existing is not None:
        if not existing.is_purchasable:
            warnings.append(UNIT_NOT_PURCHASABLE)
            return blank
        if factor is not None and Decimal(existing.factor_to_base) != factor:
            # The invoice says 12 to the carton, the catalog says 24. Both are
            # plausible; the catalog wins (it is what stock is counted in) and
            # the disagreement is surfaced instead of silently re-scaling cost.
            warnings.append(UNIT_FACTOR_MISMATCH)
        return {
            "code": unit.code,
            "factor": Decimal(existing.factor_to_base),
            "status": "existing",
            "product_unit_id": existing.pk,
            "propose": None,
            "warnings": warnings,
        }

    if factor is None:
        factor = _suggested_factor(unit, base_unit)
    if factor is None or factor <= 0:
        # A pack whose size nobody stated: buying "1 carton" of an unknown size
        # would book one piece of stock. Fall back to base and say so.
        warnings.append(UNIT_FACTOR_UNKNOWN)
        return blank

    return {
        "code": unit.code,
        "factor": Decimal(factor),
        "status": "propose",
        "product_unit_id": None,
        "propose": {
            "unit": unit.code,
            "unit_name": unit.name,
            "factor_to_base": format(Decimal(factor).normalize(), "f"),
            "is_purchasable": True,
        },
        "warnings": warnings,
    }
