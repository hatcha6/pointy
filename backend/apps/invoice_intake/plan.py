"""Turn a reconciliation into an ``IntakePlan``: exactly what would be created.

The plan is the contract between the server and the review card. It is a
*proposal* — the card edits it and posts it back to ``apply`` — so it names
everything by reference: a line points at a ``variant_id`` when the product
exists, or at a ``create_ref`` naming an entry in ``creates`` when it does not.
Nothing in it is written until apply runs.

Shape (see AI_GENERATIVE_UI_AND_INVOICE_INTAKE_PLAN.md § B.3)::

    {
      "supplier": {"id": 4} | {"create": {"name": "...", "phone": "..."}},
      "creates": [{"line_index", "create_ref", "product": {...}, "unit": {...}}],
      "lines":   [{"line_index", "variant_id"|"create_ref", "unit", "quantity",
                   "unit_cost", "status", "confidence", "warnings"}],
      "totals_check": {...},
      "po": {"supplier_invoice_number", "supplier_invoice_date", "currency", "notes"},
      "summary": {...}
    }
"""

from decimal import Decimal

from .checks import arithmetic_checks
from .models import LINE_NEW


def _money_2dp(value):
    """The AI matcher's 2dp money normaliser — ``PurchaseLine.unit_cost`` is
    ``decimal_places=2``, and an invoice printed in 3-decimal dinars would
    otherwise be rejected outright by the PO serializer."""
    from apps.ai.tools import _money_2dp as money_2dp

    return money_2dp(value)


def _decimal(value):
    from .schemas import to_decimal

    return to_decimal(value)


def _quantity_text(value):
    amount = _decimal(value)
    if amount is None or amount <= 0:
        return None
    return format(amount.normalize(), "f")


def create_ref_for(line_index):
    return f"line:{line_index}"


def _base_unit_cost(unit_cost, factor):
    """A cost per base unit — the only scale on which a cost and a sale price
    are comparable, and therefore the only one to price a new product from."""
    if unit_cost is None:
        return None
    factor = factor or Decimal("1")
    if factor <= 0:
        factor = Decimal("1")
    return unit_cost / factor


def _new_product_payload(line, *, unit_cost, factor):
    """What to create for a line with no product behind it, priced off the
    shop's own typical markup rather than a blind margin."""
    from apps.purchasing.pricing import pricing_suggestion

    base_cost = _base_unit_cost(unit_cost, factor)
    suggestion = {"suggested_price": None, "markup_percent": None, "markup_source": None}
    if base_cost is not None and base_cost > 0:
        suggestion = pricing_suggestion(base_cost)
    product = {
        "name": line.get("raw_name") or "",
        "barcode": line.get("barcode") or "",
        "unit_price": suggestion.get("suggested_price"),
        "unit": "piece",
        "tracks_expiry": False,
        "categories": [],
    }
    return product, suggestion


def build_plan(extraction, reconciliation, user=None):
    """Build the ``IntakePlan`` for ``extraction`` + ``reconciliation``."""
    extraction = extraction if isinstance(extraction, dict) else {}
    reconciliation = reconciliation if isinstance(reconciliation, dict) else {}
    rec_lines = reconciliation.get("lines") or []

    supplier_match = reconciliation.get("supplier") or {}
    if supplier_match.get("id"):
        supplier_plan = {
            "id": supplier_match["id"],
            "name": supplier_match.get("matched_name") or supplier_match.get("name"),
            "match_by": supplier_match.get("match_by"),
        }
    else:
        supplier_raw = extraction.get("supplier") or {}
        supplier_plan = {
            "id": None,
            "create": {
                "name": supplier_raw.get("name") or "مورد غير معروف",
                "phone": supplier_raw.get("phone") or "",
                "address": supplier_raw.get("address") or "",
                # Supplier carries no tax-id column; keep what was printed with
                # the record rather than dropping it on the floor.
                "notes": (
                    f"الرقم الضريبي: {supplier_raw['tax_id']}"
                    if supplier_raw.get("tax_id")
                    else ""
                ),
            },
            "candidates": supplier_match.get("candidates") or [],
        }

    creates = []
    lines = []
    for line in rec_lines:
        index = line.get("index")
        unit = line.get("unit") or {}
        factor = _decimal(unit.get("factor")) or Decimal("1")
        unit_cost = _decimal(line.get("unit_cost"))
        entry = {
            "line_index": index,
            "raw_name": line.get("raw_name"),
            "variant_id": line.get("variant_id"),
            "create_ref": None,
            "product_name": line.get("product_name"),
            "quantity": _quantity_text(line.get("quantity")),
            "unit_cost": _money_2dp(unit_cost),
            "unit": unit.get("code") or "",
            "unit_factor": unit.get("factor"),
            "unit_create": unit.get("propose"),
            "status": line.get("status"),
            "confidence": line.get("confidence"),
            "match_by": line.get("match_by"),
            "candidates": line.get("candidates") or [],
            "warnings": list(line.get("warnings") or []),
            "cost_warnings": line.get("cost_warnings") or [],
        }
        if line.get("variant_id") is None and line.get("status") == LINE_NEW:
            product, suggestion = _new_product_payload(
                line, unit_cost=unit_cost, factor=factor
            )
            ref = create_ref_for(index)
            entry["create_ref"] = ref
            creates.append(
                {
                    "line_index": index,
                    "create_ref": ref,
                    "product": product,
                    "unit": unit.get("propose"),
                    "pricing": suggestion,
                }
            )
        lines.append(entry)

    summary = dict(reconciliation.get("summary") or {})
    totals_check = arithmetic_checks(extraction)
    return {
        "supplier": supplier_plan,
        "creates": creates,
        "lines": lines,
        "totals_check": totals_check,
        "po": {
            "supplier_invoice_number": extraction.get("invoice_number") or "",
            "supplier_invoice_date": extraction.get("date"),
            "currency": extraction.get("currency"),
            "notes": "",
        },
        "summary": summary,
    }
