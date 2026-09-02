"""Resolve each printed invoice line to a product this shop already sells.

Tiered, deterministic-first — every tier above the last is a fact, not a guess,
and the order is strongest evidence first:

1. **barcode** — the variant's own EAN, or a :class:`ProductUnitBarcode` (the
   carton code), which also tells us the pack the line is priced in.
2. **learned alias** — a name a user already confirmed for a product.
3. **normalized-exact name** — the same name, Arabic-folded.
4. **supplier purchase history** — of everything ever bought from *this*
   supplier, which product does this line's wording and cost look like? This is
   the strongest prior on a repeat invoice, and the tier that makes the second
   invoice from a wholesaler nearly touch-free.
5. **fuzzy candidates** — token overlap, top 6, offered for the user to pick.

Tiers 1–3 and 5 are the existing AI matcher's (``apps.ai.tools``) — imported,
not re-implemented, so the chat path and this pipeline can never disagree about
what "the same product" means. Tier 4 and the unit/cost work below are new.

Nothing here writes anything, and nothing here blocks: a suspicious cost becomes
a warning on the line, because the buyer looking at the paper is the one who can
say whether 130 dinars for a stack of bread was a typo or a wholesale crate.
"""

import logging
from decimal import Decimal

from .models import LINE_AUTO, LINE_MATCHED, LINE_NEW, LINE_REVIEW
from .units import map_line_unit

logger = logging.getLogger(__name__)

# Tier 4 acceptance. A name that is essentially identical stands on its own; a
# merely similar name has to be corroborated by a cost close to what this
# supplier last charged for it.
HISTORY_NAME_STRONG = 0.85
HISTORY_NAME_WEAK = 0.55
HISTORY_COST_PROXIMITY = 0.75
# How many distinct products of this supplier's history to hold in memory.
HISTORY_LIMIT = 400
_HISTORY_SCAN_CAP = 3000

MATCH_BARCODE = "barcode"
MATCH_UNIT_BARCODE = "unit_barcode"
MATCH_ALIAS = "alias"
MATCH_NAME = "name"
MATCH_SUPPLIER_HISTORY = "supplier_history"

# Deterministic tiers → "matched"; the supplier-history prior → "auto" (shown
# with its confidence and one tap from being changed).
_DETERMINISTIC = {MATCH_BARCODE, MATCH_UNIT_BARCODE, MATCH_ALIAS, MATCH_NAME}

WARN_MISSING_QUANTITY = "missing_quantity"
WARN_MISSING_UNIT_COST = "missing_unit_cost"
WARN_NO_NAME = "missing_name"


def _ai_tools():
    """The AI matcher's helpers, imported lazily.

    ``apps.ai`` reaches into this package for its intake tool, so importing it
    at module scope would close an import cycle.
    """
    from apps.ai import tools

    return tools


def _decimal(value):
    from .schemas import to_decimal

    return to_decimal(value)


# ── Tier 1b: packaging barcodes ──────────────────────────────────────────────


def _match_unit_barcode(barcode):
    """A carton EAN → that product's default variant *and* the pack it names.

    The AI matcher only looks at variant barcodes; a scanned/printed carton code
    additionally settles the unit question, which is the half of an invoice line
    most often got wrong.
    """
    if not barcode:
        return None
    from apps.catalog.models import ProductUnitBarcode, ProductVariant

    row = (
        ProductUnitBarcode.objects.filter(barcode=barcode)
        .select_related("product_unit", "product_unit__unit", "product_unit__product")
        .first()
    )
    if row is None:
        return None
    product_unit = row.product_unit
    variant = (
        ProductVariant.objects.filter(product_id=product_unit.product_id, is_default=True)
        .order_by("id")
        .first()
    )
    if variant is None:
        return None
    return {
        "matched": True,
        "match_by": MATCH_UNIT_BARCODE,
        "variant_id": variant.pk,
        "product_id": product_unit.product_id,
        "product_name": product_unit.product.name,
        "current_price": str(variant.unit_price),
        "unit_code": product_unit.unit.code,
    }


# ── Tier 4: this supplier's purchase history ─────────────────────────────────


def supplier_history(supplier_id, *, limit=HISTORY_LIMIT):
    """The most recent purchase of each product bought from ``supplier_id``.

    One query. Ordered newest-first and de-duplicated in Python by variant, so
    each entry carries what that supplier last charged — the number tier 4
    compares an invoice line's cost against.
    """
    if not supplier_id:
        return []
    from apps.catalog.search_terms import normalize_term
    from apps.purchasing.models import PurchaseLine, PurchaseOrder

    rows = (
        PurchaseLine.objects.filter(purchase_order__supplier_id=supplier_id)
        .exclude(purchase_order__status=PurchaseOrder.Status.CANCELLED)
        .select_related("variant", "variant__product")
        .order_by("-created_at", "-id")[:_HISTORY_SCAN_CAP]
    )
    entries = {}
    for line in rows:
        if line.variant_id in entries:
            continue
        product = line.variant.product
        entries[line.variant_id] = {
            "variant_id": line.variant_id,
            "product_id": product.pk,
            "name": product.name,
            "key": normalize_term(product.name),
            "barcode": line.variant.barcode or None,
            "price": str(line.variant.unit_price),
            "last_cost": str(line.base_unit_cost),
            "_cost": line.base_unit_cost,
        }
        if len(entries) >= limit:
            break
    return list(entries.values())


def _cost_proximity(invoice_cost, history_cost):
    """1.0 when the two costs are identical, 0.0 when they are orders apart —
    ``min/max``, so it is symmetric and scale-free."""
    if not invoice_cost or not history_cost:
        return None
    if invoice_cost <= 0 or history_cost <= 0:
        return None
    return float(min(invoice_cost, history_cost) / max(invoice_cost, history_cost))


def _score_history(entry, norm_terms, invoice_base_cost):
    tools = _ai_tools()
    if entry["key"] and entry["key"] in norm_terms:
        name_score = 1.0
    else:
        name_score = tools._term_overlap(entry["key"], norm_terms)
    proximity = _cost_proximity(invoice_base_cost, entry.get("_cost"))
    accepted = name_score >= HISTORY_NAME_STRONG or (
        name_score >= HISTORY_NAME_WEAK
        and proximity is not None
        and proximity >= HISTORY_COST_PROXIMITY
    )
    # Confidence is capped below 1.0 on purpose: this tier is a strong prior,
    # not a proof, and the review card shows the number.
    confidence = min(0.95, round(0.65 * name_score + 0.35 * (proximity or 0.5), 3))
    return name_score, proximity, accepted, confidence


def _match_by_history(history, norm_terms, invoice_base_cost):
    """The best supplier-history match, plus the runners-up as candidates."""
    scored = []
    for entry in history:
        name_score, proximity, accepted, confidence = _score_history(
            entry, norm_terms, invoice_base_cost
        )
        if name_score <= 0:
            continue
        scored.append((name_score, accepted, confidence, proximity, entry))
    if not scored:
        return None, []
    scored.sort(key=lambda row: (row[0], row[2]), reverse=True)
    candidates = [
        {
            "product_id": entry["product_id"],
            "variant_id": entry["variant_id"],
            "name": entry["name"],
            "barcode": entry["barcode"],
            "price": entry["price"],
            "last_cost": entry["last_cost"],
            "source": MATCH_SUPPLIER_HISTORY,
        }
        for *_rest, entry in scored[:6]
    ]
    name_score, accepted, confidence, proximity, entry = scored[0]
    if not accepted:
        return None, candidates
    return (
        {
            "matched": True,
            "match_by": MATCH_SUPPLIER_HISTORY,
            "variant_id": entry["variant_id"],
            "product_id": entry["product_id"],
            "product_name": entry["name"],
            "current_price": entry["price"],
            "confidence": confidence,
            "name_score": round(name_score, 3),
            "cost_proximity": None if proximity is None else round(proximity, 3),
        },
        candidates,
    )


# ── Supplier ─────────────────────────────────────────────────────────────────


def match_supplier(extraction, *, user):
    """The AI matcher's name matching, plus an exact phone hit.

    A wholesaler's printed name drifts ("محلات النور", "النور للمواد الغذائية")
    where the phone number on the header does not, so a phone match outranks a
    fuzzy name.
    """
    tools = _ai_tools()
    supplier_raw = (extraction or {}).get("supplier") or {}
    name = supplier_raw.get("name")
    registry = tools.get_registry()
    result = tools._match_supplier(
        registry.get("suppliers"), user=user, supplier_name=name
    )
    if result.get("matched"):
        result["match_by"] = "name"
        return result

    phone = (supplier_raw.get("phone") or "").strip()
    if phone:
        from apps.purchasing.models import Supplier

        digits = "".join(ch for ch in phone if ch.isdigit())
        if digits:
            existing = (
                Supplier.objects.filter(phone__endswith=digits[-8:])
                .order_by("id")
                .first()
                if len(digits) >= 8
                else Supplier.objects.filter(phone=phone).order_by("id").first()
            )
            if existing is not None:
                result.update(
                    {
                        "matched": True,
                        "match_by": "phone",
                        "id": existing.pk,
                        "matched_name": existing.name,
                    }
                )
                return result
    result["match_by"] = None
    return result


# ── The reconciler ───────────────────────────────────────────────────────────


def reconcile_lines(extraction, user, *, supplier=None):
    """Resolve every line of ``extraction`` against the catalog, as ``user``.

    ``supplier`` overrides the supplier match (the review card lets the user
    correct it and re-run). Returns
    ``{"supplier": {...}, "lines": [...], "summary": {...}}`` — JSON-safe
    throughout, so it stores on the intake as-is.
    """
    tools = _ai_tools()
    extraction = extraction if isinstance(extraction, dict) else {}
    lines = extraction.get("lines")
    lines = lines if isinstance(lines, list) else []

    supplier_match = (
        {"matched": True, "id": supplier.pk, "matched_name": supplier.name, "name": supplier.name}
        if supplier is not None
        else match_supplier(extraction, user=user)
    )
    history = supplier_history(supplier_match.get("id"))

    registry = tools.get_registry()
    products_meta = registry.get("products")
    variants_meta = registry.get("product-variants")

    # Pass 1 — resolve each line to a variant (or to candidates).
    resolved = []
    for line in lines:
        if not isinstance(line, dict):
            continue
        resolved.append(
            _resolve_line(
                line,
                user=user,
                tools=tools,
                products_meta=products_meta,
                variants_meta=variants_meta,
                history=history,
            )
        )

    # Pass 2 — units and cost sanity, over the products we landed on. Bulk-load
    # so a 60-line invoice is a couple of queries, not 120.
    _attach_units(resolved)
    _attach_cost_warnings(resolved)

    out_lines = [entry["out"] for entry in resolved]
    summary = {
        "total": len(out_lines),
        LINE_MATCHED: sum(1 for line in out_lines if line["status"] == LINE_MATCHED),
        LINE_AUTO: sum(1 for line in out_lines if line["status"] == LINE_AUTO),
        LINE_NEW: sum(1 for line in out_lines if line["status"] == LINE_NEW),
        LINE_REVIEW: sum(1 for line in out_lines if line["status"] == LINE_REVIEW),
    }
    return {"supplier": supplier_match, "lines": out_lines, "summary": summary}


def _resolve_line(line, *, user, tools, products_meta, variants_meta, history):
    from apps.catalog.search_terms import normalize_term

    raw_name = (line.get("raw_name") or "").strip()
    barcode = line.get("barcode") or ""
    quantity = _decimal(line.get("quantity"))
    unit_cost = _decimal(line.get("unit_cost"))
    pack_size = _decimal(line.get("pack_size"))
    terms = tools._dedupe_terms([raw_name])
    norm_terms = [key for key in (normalize_term(term) for term in terms) if key]

    warnings = []
    if not raw_name:
        warnings.append(WARN_NO_NAME)
    if quantity is None or quantity <= 0:
        warnings.append(WARN_MISSING_QUANTITY)
    if unit_cost is None or unit_cost <= 0:
        warnings.append(WARN_MISSING_UNIT_COST)

    out = {
        "index": line.get("index"),
        "raw_name": raw_name,
        "barcode": barcode or None,
        "quantity": line.get("quantity"),
        "unit_cost": line.get("unit_cost"),
        "line_total": line.get("line_total"),
        "unit_label": line.get("unit_label"),
        "pack_size": line.get("pack_size"),
        "status": LINE_NEW,
        "confidence": 0.0,
        "match_by": None,
        "variant_id": None,
        "product_id": None,
        "product_name": None,
        "current_price": None,
        "candidates": [],
        "warnings": warnings,
    }

    match = _match_unit_barcode(barcode)
    unit_code_hint = None
    if match is not None:
        unit_code_hint = match.pop("unit_code", None)
    if match is None:
        # Tiers 1 (variant barcode), 2 (alias), 3 (exact name), 5 (fuzzy
        # candidates) — the AI matcher's own, permission-scoped through the
        # real product/variant viewsets.
        try:
            match = tools._match_invoice_line(
                products_meta,
                variants_meta,
                user=user,
                terms=terms,
                barcode=barcode,
            )
        except Exception:
            logger.exception("Invoice intake line matching failed")
            match = {"matched": False, "candidates": []}

    candidates = list(match.get("candidates") or []) if not match.get("matched") else []
    if not match.get("matched"):
        invoice_base_cost = None
        if unit_cost is not None and unit_cost > 0:
            divisor = pack_size if pack_size and pack_size > 0 else Decimal("1")
            invoice_base_cost = unit_cost / divisor
        history_match, history_candidates = _match_by_history(
            history, norm_terms, invoice_base_cost
        )
        if history_match is not None:
            match = history_match
        else:
            # History candidates lead: a product this supplier actually sells is
            # a better guess than a catalog-wide token overlap.
            seen = {entry.get("variant_id") for entry in history_candidates}
            candidates = history_candidates + [
                entry for entry in candidates if entry.get("variant_id") not in seen
            ]

    if match.get("matched"):
        out.update(
            {
                "match_by": match.get("match_by"),
                "variant_id": match.get("variant_id"),
                "product_id": match.get("product_id"),
                "product_name": match.get("product_name"),
                "current_price": match.get("current_price"),
                "status": (
                    LINE_MATCHED
                    if match.get("match_by") in _DETERMINISTIC
                    else LINE_AUTO
                ),
                "confidence": float(
                    match.get("confidence", 1.0 if match.get("match_by") in _DETERMINISTIC else 0.7)
                ),
            }
        )
        for key in ("name_score", "cost_proximity"):
            if match.get(key) is not None:
                out[key] = match[key]
    else:
        out["candidates"] = candidates[:6]
        # Candidates mean "we found something plausible" — that is a question
        # for the user, not a licence to create a duplicate product.
        out["status"] = LINE_REVIEW if candidates else LINE_NEW
        out["confidence"] = 0.0

    if warnings:
        # A line whose numbers were not read cannot be applied, however certain
        # the product match is.
        out["status"] = LINE_REVIEW

    return {"out": out, "unit_code_hint": unit_code_hint, "line": line}


def _attach_units(resolved):
    """Map every line's printed pack onto its product, in bulk."""
    from apps.catalog.models import ProductVariant

    from .units import _unit_index

    variant_ids = {
        entry["out"]["variant_id"] for entry in resolved if entry["out"]["variant_id"]
    }
    variants = {}
    if variant_ids:
        variants = {
            variant.pk: variant
            for variant in ProductVariant.objects.filter(pk__in=variant_ids)
            .select_related("product")
            .prefetch_related("product__units__unit")
        }
    index = _unit_index()

    for entry in resolved:
        out = entry["out"]
        variant = variants.get(out["variant_id"])
        product = getattr(variant, "product", None)
        label = out.get("unit_label")
        if entry.get("unit_code_hint") and not label:
            # A carton barcode names the pack even when the line's text does not.
            label = entry["unit_code_hint"]
        mapping = map_line_unit(product, label, out.get("pack_size"), index=index)
        out["unit"] = {
            "code": mapping["code"],
            "factor": format(Decimal(mapping["factor"]).normalize(), "f"),
            "status": mapping["status"],
            "product_unit_id": mapping["product_unit_id"],
            "propose": mapping["propose"],
        }
        for warning in mapping["warnings"]:
            if warning not in out["warnings"]:
                out["warnings"].append(warning)
        entry["variant"] = variant


def _attach_cost_warnings(resolved):
    """Run the purchase-time cost guard over the matched lines and attach what
    it found. Warnings only — this stage never blocks; the buyer confirms on the
    review card exactly as they do on the purchasing screen."""
    from apps.purchasing.cost_guard import find_cost_anomalies, warn_thresholds

    guard_lines = []
    positions = []
    for entry in resolved:
        out = entry["out"]
        variant = entry.get("variant")
        unit_cost = _decimal(out.get("unit_cost"))
        if variant is None or unit_cost is None or unit_cost <= 0:
            continue
        factor = _decimal(out.get("unit", {}).get("factor")) or Decimal("1")
        guard_lines.append(
            {"variant": variant, "unit_cost": unit_cost, "unit_factor": factor}
        )
        positions.append(entry)

    if not guard_lines:
        return
    try:
        anomalies = find_cost_anomalies(guard_lines, thresholds=warn_thresholds())
    except Exception:  # pragma: no cover - the guard is advisory here
        logger.exception("Invoice intake cost guard failed")
        return
    for anomaly in anomalies:
        entry = positions[anomaly.index]
        payload = anomaly.as_payload()
        payload.pop("blocking", None)
        entry["out"].setdefault("cost_warnings", []).append(payload)
        if anomaly.kind not in entry["out"]["warnings"]:
            entry["out"]["warnings"].append(anomaly.kind)
