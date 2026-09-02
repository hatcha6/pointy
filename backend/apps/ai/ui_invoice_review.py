"""Builds the invoice-intake review card.

Unlike an ordinary answer's UI, this surface is composed by the server rather
than by the model. The card is a control surface for a money-moving action, so
what it shows has to be exactly what the pipeline computed — the model is not in
a position to be creative about which lines need attention.

It is still an ordinary catalog surface, validated by the same rules as anything
the model draws, so it cannot drift from the product's design either.
"""

from __future__ import annotations

from decimal import Decimal, InvalidOperation

from .ui_catalog import UiValidationError, validate_surface

# Line states, in the order a person should deal with them.
_STATE_LABELS = {
    "review": "يحتاج مراجعة",
    "new": "صنف جديد",
    "auto": "مطابقة مقترحة",
    "matched": "مطابق",
}
_STATE_ORDER = ["review", "new", "auto", "matched"]


def _decimal(value):
    try:
        return Decimal(str(value or "0"))
    except (InvalidOperation, TypeError, ValueError):
        return Decimal("0")


def _line_rows(plan, extraction):
    """One table row per invoice line, worst state first."""
    raw_lines = {
        line.get("index"): line
        for line in (extraction.get("lines") or [])
        if isinstance(line, dict)
    }
    rows = []
    for line in plan.get("lines") or []:
        if not isinstance(line, dict):
            continue
        index = line.get("line_index")
        source = raw_lines.get(index) or {}
        quantity = _decimal(line.get("quantity") or source.get("quantity"))
        unit_cost = _decimal(line.get("unit_cost") or source.get("unit_cost"))
        rows.append(
            {
                "name": line.get("name") or source.get("raw_name") or "",
                "state": _STATE_LABELS.get(line.get("status"), line.get("status") or ""),
                "_state": line.get("status") or "matched",
                "quantity": float(quantity),
                "unit_cost": float(unit_cost),
                "total": float(quantity * unit_cost),
            }
        )
    rows.sort(key=lambda row: _STATE_ORDER.index(row["_state"])
              if row["_state"] in _STATE_ORDER else len(_STATE_ORDER))
    for row in rows:
        row.pop("_state", None)
    return rows


def _warning_lines(plan):
    """The lines a person actually has to look at, with why."""
    problems = []
    for line in plan.get("lines") or []:
        if not isinstance(line, dict):
            continue
        warnings = line.get("warnings") or []
        if not warnings:
            continue
        name = line.get("name") or f"سطر {line.get('line_index')}"
        problems.append(f"{name}: {'، '.join(str(w) for w in warnings)}")
    return problems


def build_invoice_review_surface(intake):
    """The review card for one intake, or ``None`` when there is nothing to show."""
    plan = intake.plan or {}
    extraction = intake.extraction or {}
    lines = plan.get("lines") or []
    if not lines:
        return None

    counts = intake.counts()
    supplier_plan = plan.get("supplier") or {}
    supplier_name = (
        (supplier_plan.get("create") or {}).get("name")
        or supplier_plan.get("name")
        or (extraction.get("supplier") or {}).get("name")
        or "مورّد غير محدّد"
    )
    is_new_supplier = not supplier_plan.get("id")
    po = plan.get("po") or {}
    invoice_number = po.get("supplier_invoice_number") or ""
    invoice_date = po.get("supplier_invoice_date") or ""

    subtitle_bits = []
    if invoice_number:
        subtitle_bits.append(f"فاتورة رقم {invoice_number}")
    if invoice_date:
        subtitle_bits.append(invoice_date)
    subtitle_bits.append(f"{len(lines)} سطراً")

    rows = _line_rows(plan, extraction)
    grand_total = sum(row["total"] for row in rows)
    totals_check = plan.get("totals_check") or {}
    totals_ok = bool(totals_check.get("ok", True))
    warnings = _warning_lines(plan)

    components = [
        {
            "id": "root",
            "component": "Column",
            "children": ["header", "counts", "lines_card"],
        },
        {
            "id": "header",
            "component": "Callout",
            "tone": "info" if is_new_supplier is False else "neutral",
            "title": (
                f"قرأت الفاتورة: {supplier_name}"
                + (" (مورّد جديد)" if is_new_supplier else "")
            ),
            "body": " — ".join(subtitle_bits),
        },
        {
            "id": "counts",
            "component": "MetricGrid",
            "metrics": [
                {"label": "مطابق", "value": counts.get("matched", 0), "kind": "number"},
                {"label": "مقترح", "value": counts.get("auto", 0), "kind": "number"},
                {"label": "جديد", "value": counts.get("new", 0), "kind": "number"},
                {
                    "label": "يحتاج مراجعة",
                    "value": counts.get("review", 0),
                    "kind": "number",
                },
            ],
        },
        {
            "id": "lines_card",
            "component": "Card",
            "title": "سطور الفاتورة",
            "subtitle": f"الإجمالي المحسوب {grand_total:.2f}",
            "child": "lines",
        },
        {
            "id": "lines",
            "component": "Table",
            "columns": [
                {"key": "name", "label": "الصنف"},
                {"key": "state", "label": "الحالة"},
                {"key": "quantity", "label": "الكمية", "kind": "number", "total": True},
                {"key": "unit_cost", "label": "التكلفة", "kind": "money"},
                {"key": "total", "label": "الإجمالي", "kind": "money", "total": True},
            ],
            "rows": rows,
        },
    ]

    if not totals_ok:
        components[0]["children"].append("totals_warning")
        components.append(
            {
                "id": "totals_warning",
                "component": "Callout",
                "tone": "warning",
                "title": "إجمالي الفاتورة لا يطابق مجموع السطور",
                "body": (
                    "راجع الأرقام قبل الاعتماد — قد تكون قراءة أحد السطور غير دقيقة."
                ),
            }
        )

    if warnings:
        components[0]["children"].append("line_warnings")
        components.append(
            {
                "id": "line_warnings",
                "component": "Callout",
                "tone": "warning",
                "title": f"{len(warnings)} سطر يحتاج انتباهك",
                "body": "\n".join(warnings[:5]),
            }
        )

    # The actions. Creating a draft is always safe; anything that moves money or
    # stock is left to the purchase-order screen, where the existing permission
    # checks and confirmations already live.
    components[0]["children"].append("actions")
    components.extend(
        [
            {
                "id": "actions",
                "component": "Row",
                "justify": "start",
                "children": ["act_create", "act_open"],
            },
            {
                "id": "act_create",
                "component": "Button",
                "label": "أنشئ أمر شراء مسودة",
                "variant": "primary",
                "icon": "check",
                "action": {
                    "event": {
                        "name": "submit:apply_invoice_intake",
                        "context": {"intake_id": intake.pk},
                    }
                },
            },
            {
                "id": "act_open",
                "component": "Button",
                "label": "اشرح السطور التي تحتاج مراجعة",
                "variant": "secondary",
                "icon": "search",
                "action": {
                    "event": {
                        "name": "ask:intake_lines",
                        "context": {
                            "prompt": (
                                "اشرح لي السطور التي تحتاج مراجعة في الفاتورة "
                                f"رقم {intake.pk} وما المشكلة في كل منها."
                            )
                        },
                    }
                },
            },
        ]
    )

    try:
        return validate_surface(
            {
                "surface_id": f"intake-{intake.pk}",
                "title": "مراجعة فاتورة مورّد",
                "components": components,
            }
        )
    except UiValidationError:
        # A card we build ourselves failing validation is a bug in this module,
        # not something the user should see half-rendered.
        return None
