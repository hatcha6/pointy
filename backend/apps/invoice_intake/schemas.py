"""The ``InvoiceExtraction`` contract, and the normaliser that makes a model's
JSON safe to compute on.

Two halves:

``INVOICE_EXTRACTION_SCHEMA``
    the strict JSON schema handed to the relay as ``response_format``
    (``json_schema``). It asks for ``unit_label``/``pack_size`` *verbatim* — the
    printed "كرتونة 12" — because the pack language is what later maps a line to
    a :class:`~apps.catalog.models.ProductUnit`, and guessing it after the fact
    is the base-unit scale bug class the UoM work already paid for once.

``normalise_extraction``
    coerces whatever came back into one canonical dict. A model that follows the
    schema still sends ``"1٬250٫500"``, ``"12 pcs"``, ``"٣"``, ``"25/07/2026"``
    and ``null`` in the same document, and every consumer downstream (arithmetic
    checks, reconciliation, the plan, the PO serializer) would otherwise re-guess
    those individually. Money and quantities come out as **strings** — decimal
    text, never floats — so the JSON stored on the intake round-trips through
    ``Decimal`` without a binary-float surprise.
"""

import re
import unicodedata
from datetime import date, datetime
from decimal import Decimal, InvalidOperation

# The model may only return these keys; anything else is dropped by the
# normaliser rather than trusted.
_LINE_KEYS = (
    "index",
    "raw_name",
    "quantity",
    "unit_label",
    "pack_size",
    "unit_cost",
    "line_total",
    "barcode",
    "notes",
    "confidence",
)

# Hard cap on the lines one intake carries, shared with the AI matcher so a
# 400-line wholesale invoice cannot fan the reconciler out unboundedly.
MAX_INVOICE_LINES = 100


def _max_lines():
    # Imported lazily: apps.ai imports this package's services for its intake
    # tool, so a module-level import would close the cycle.
    try:
        from apps.ai.tools import _MAX_INVOICE_LINES

        return int(_MAX_INVOICE_LINES)
    except Exception:  # pragma: no cover - defensive, the constant is ours too
        return MAX_INVOICE_LINES


INVOICE_EXTRACTION_SCHEMA = {
    "name": "InvoiceExtraction",
    "strict": True,
    "schema": {
        "type": "object",
        "additionalProperties": False,
        "required": ["supplier", "lines", "warnings"],
        "properties": {
            "supplier": {
                "type": "object",
                "additionalProperties": False,
                "required": ["name"],
                "properties": {
                    "name": {"type": ["string", "null"]},
                    "phone": {"type": ["string", "null"]},
                    "tax_id": {"type": ["string", "null"]},
                    "address": {"type": ["string", "null"]},
                },
            },
            "invoice_number": {"type": ["string", "null"]},
            "date": {
                "type": ["string", "null"],
                "description": "Invoice date, ISO 8601 (YYYY-MM-DD) when readable.",
            },
            "currency": {
                "type": ["string", "null"],
                "description": "ISO currency code the invoice is priced in, e.g. LYD, USD.",
            },
            "lines": {
                "type": "array",
                "items": {
                    "type": "object",
                    "additionalProperties": False,
                    "required": ["index", "raw_name", "quantity", "unit_cost", "confidence"],
                    "properties": {
                        "index": {"type": "integer"},
                        "raw_name": {
                            "type": "string",
                            "description": "The item name exactly as printed, no translation.",
                        },
                        "quantity": {"type": ["number", "string", "null"]},
                        "unit_label": {
                            "type": ["string", "null"],
                            "description": "The pack word as printed (كرتونة، شد، علبة، kg).",
                        },
                        "pack_size": {
                            "type": ["number", "string", "null"],
                            "description": "Units per pack when printed (the 12 of 'كرتونة 12').",
                        },
                        "unit_cost": {"type": ["number", "string", "null"]},
                        "line_total": {"type": ["number", "string", "null"]},
                        "barcode": {"type": ["string", "null"]},
                        "notes": {"type": ["string", "null"]},
                        "confidence": {
                            "type": "number",
                            "description": "0..1 — how sure you are of THIS line's numbers.",
                        },
                    },
                },
            },
            "subtotal": {"type": ["number", "string", "null"]},
            "discount": {"type": ["number", "string", "null"]},
            "tax": {"type": ["number", "string", "null"]},
            "total": {"type": ["number", "string", "null"]},
            "page_count": {"type": ["integer", "null"]},
            "warnings": {"type": "array", "items": {"type": "string"}},
        },
    },
}


# ── Coercion ─────────────────────────────────────────────────────────────────

# Arabic-Indic and extended (Persian) digits → ASCII, plus the Arabic decimal
# and thousands separators. Libyan invoices print both digit sets, often in the
# same document.
_DIGITS = str.maketrans(
    {
        **{chr(0x0660 + i): str(i) for i in range(10)},
        **{chr(0x06F0 + i): str(i) for i in range(10)},
        "٫": ".",  # ARABIC DECIMAL SEPARATOR
        "٬": "",  # ARABIC THOUSANDS SEPARATOR
        "،": "",  # ARABIC COMMA
    }
)
_NUMBER_RE = re.compile(r"-?\d+(?:\.\d+)?")


def _text(value, *, limit=255):
    if value is None:
        return ""
    text = unicodedata.normalize("NFKC", str(value)).strip()
    text = re.sub(r"\s+", " ", text)
    return text[:limit]


def _optional_text(value, *, limit=255):
    text = _text(value, limit=limit)
    return text or None


def to_decimal(value):
    """A ``Decimal`` from whatever the model emitted, or ``None``.

    Tolerates Arabic-Indic digits, thousands separators, a trailing unit or
    currency word ("12 كرتونة", "75.000 د.ل"), and a bare ``"-"`` for an empty
    cell. Returns ``None`` rather than raising: a number the model could not
    read is a *review* signal, never a crash.
    """
    if value is None or isinstance(value, bool):
        return None
    if isinstance(value, Decimal):
        return value
    if isinstance(value, (int, float)):
        try:
            return Decimal(str(value))
        except InvalidOperation:
            return None
    text = unicodedata.normalize("NFKC", str(value)).strip().translate(_DIGITS)
    if not text:
        return None
    # Drop grouping commas/spaces between digits, then take the first number.
    text = re.sub(r"(?<=\d)[,\s](?=\d{3}\b)", "", text)
    text = text.replace(",", ".")
    match = _NUMBER_RE.search(text)
    if match is None:
        return None
    try:
        return Decimal(match.group(0))
    except InvalidOperation:
        return None


def _decimal_text(value):
    """Canonical decimal *string* (or ``None``) — what gets stored in JSON."""
    amount = to_decimal(value)
    return None if amount is None else format(amount.normalize(), "f")


_DATE_FORMATS = (
    "%Y-%m-%d",
    "%d/%m/%Y",
    "%d-%m-%Y",
    "%Y/%m/%d",
    "%d.%m.%Y",
    "%d/%m/%y",
)


def _date_text(value):
    """An ISO date string, or ``None``. Day-first is the default reading: Libyan
    supplier invoices print 05/07/2026 for the 5th of July."""
    if isinstance(value, datetime):
        return value.date().isoformat()
    if isinstance(value, date):
        return value.isoformat()
    text = _text(value, limit=32).translate(_DIGITS)
    if not text:
        return None
    for fmt in _DATE_FORMATS:
        try:
            return datetime.strptime(text, fmt).date().isoformat()
        except ValueError:
            continue
    return None


def _confidence(value):
    amount = to_decimal(value)
    if amount is None:
        # Unstated confidence is neither trusted nor distrusted; the tiered
        # matcher, not the model's self-report, decides what auto-matches.
        return 0.5
    return float(max(Decimal("0"), min(Decimal("1"), amount)))


def _barcode(value):
    text = _text(value, limit=64)
    digits = text.translate(_DIGITS)
    # A barcode is a code, not prose: keep alphanumerics only so "باركود: 6221"
    # or "6221 155 000 123" both normalise to something lookup-able.
    cleaned = re.sub(r"[^0-9A-Za-z]", "", digits)
    return cleaned or None


def normalise_line(raw, *, index):
    if not isinstance(raw, dict):
        raw = {}
    return {
        "index": index,
        "raw_name": _text(raw.get("raw_name") or raw.get("name")),
        "quantity": _decimal_text(raw.get("quantity")),
        "unit_label": _optional_text(raw.get("unit_label") or raw.get("unit"), limit=64),
        "pack_size": _decimal_text(raw.get("pack_size")),
        "unit_cost": _decimal_text(raw.get("unit_cost")),
        "line_total": _decimal_text(raw.get("line_total")),
        "barcode": _barcode(raw.get("barcode")),
        "notes": _text(raw.get("notes"), limit=500),
        "confidence": _confidence(raw.get("confidence")),
    }


def normalise_extraction(raw):
    """Coerce a model's ``InvoiceExtraction`` JSON into the canonical dict every
    later stage reads. Never raises: a malformed payload yields an extraction
    with no lines and a warning saying so, which the review card can show."""
    warnings = []
    if isinstance(raw, str):
        import json

        try:
            raw = json.loads(raw)
        except ValueError:
            raw = None
            warnings.append("extraction_not_json")
    if not isinstance(raw, dict):
        raw = {}
        if "extraction_not_json" not in warnings:
            warnings.append("extraction_missing")

    supplier_raw = raw.get("supplier")
    if not isinstance(supplier_raw, dict):
        supplier_raw = {"name": supplier_raw} if supplier_raw else {}

    raw_lines = raw.get("lines")
    raw_lines = raw_lines if isinstance(raw_lines, list) else []
    limit = _max_lines()
    truncated = len(raw_lines) > limit
    # Indexes are assigned by position: the model's own numbering repeats across
    # pages often enough that keying reconciliation on it would collide.
    lines = [
        normalise_line(entry, index=position)
        for position, entry in enumerate(raw_lines[:limit])
    ]
    lines = [line for line in lines if line["raw_name"] or line["barcode"]]
    # Re-index after dropping the empty rows so indexes stay dense.
    for position, line in enumerate(lines):
        line["index"] = position

    for entry in raw.get("warnings") or []:
        text = _text(entry, limit=200)
        if text and text not in warnings:
            warnings.append(text)
    if truncated:
        warnings.append(f"truncated_to_{limit}_lines")

    return {
        "supplier": {
            "name": _optional_text(supplier_raw.get("name")),
            "phone": _optional_text(supplier_raw.get("phone"), limit=64),
            "tax_id": _optional_text(supplier_raw.get("tax_id"), limit=64),
            "address": _optional_text(supplier_raw.get("address"), limit=500),
        },
        "invoice_number": _optional_text(raw.get("invoice_number"), limit=64),
        "date": _date_text(raw.get("date")),
        "currency": (_optional_text(raw.get("currency"), limit=8) or "").upper() or None,
        "lines": lines,
        "subtotal": _decimal_text(raw.get("subtotal")),
        "discount": _decimal_text(raw.get("discount")),
        "tax": _decimal_text(raw.get("tax")),
        "total": _decimal_text(raw.get("total")),
        "page_count": (
            int(to_decimal(raw.get("page_count")))
            if to_decimal(raw.get("page_count")) is not None
            else None
        ),
        "warnings": warnings,
    }
