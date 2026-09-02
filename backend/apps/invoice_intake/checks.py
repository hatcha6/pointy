"""Deterministic arithmetic on what the model read.

A vision model misreads a digit long before it misreads a word: "12" for "72",
a dropped decimal point, a quantity column read off by one row. The paper
invoice, though, carries its own proof — every line multiplies out, the lines
sum to the subtotal, and the subtotal, discount and tax make the total. Checking
that costs nothing and catches exactly the failures the model is prone to.

Two uses for the result:

* ``line_indexes`` is the targeted-re-extraction list — re-send the page asking
  only for those lines, instead of re-reading the whole invoice and rolling the
  dice again on the lines that were already right.
* ``totals`` is shown on the review card. A total that does not reconcile is
  surfaced, never silently accepted: the paper document is the legally
  authoritative record here, and a PO that disagrees with it is worse than no PO.
"""

from decimal import Decimal

# 1% — loose enough for a supplier's own rounding on a per-line discount, tight
# enough that a misread digit never hides inside it.
TOLERANCE = Decimal("0.01")
# Below this, relative comparison is meaningless (a 1% tolerance on 0.00 is
# 0.00), so fall back to a flat one-piastre allowance.
ABSOLUTE_FLOOR = Decimal("0.01")

LINE_TOTAL_MISMATCH = "line_total_mismatch"
MISSING_QUANTITY = "missing_quantity"
MISSING_UNIT_COST = "missing_unit_cost"
SUBTOTAL_MISMATCH = "subtotal_mismatch"
TOTAL_MISMATCH = "total_mismatch"


def _decimal(value):
    from .schemas import to_decimal

    return to_decimal(value)


def _within_tolerance(expected, stated):
    """True when ``stated`` is within 1% of ``expected`` (or within a piastre of
    it, whichever is looser)."""
    delta = abs(expected - stated)
    allowance = max(abs(expected) * TOLERANCE, ABSOLUTE_FLOOR)
    return delta <= allowance


def _money(value):
    return format(value.quantize(Decimal("0.01")), "f")


def arithmetic_checks(extraction):
    """Return every arithmetic problem in ``extraction``, per line and overall.

    ``{"ok", "lines": [...], "line_indexes": [...], "totals": [...],
    "computed": {...}}`` — all money as decimal strings so the result stores as
    JSON on the intake unchanged.
    """
    extraction = extraction if isinstance(extraction, dict) else {}
    lines = extraction.get("lines")
    lines = lines if isinstance(lines, list) else []

    line_problems = []
    lines_sum = Decimal("0")
    have_line_totals = False

    for line in lines:
        if not isinstance(line, dict):
            continue
        index = line.get("index")
        quantity = _decimal(line.get("quantity"))
        unit_cost = _decimal(line.get("unit_cost"))
        line_total = _decimal(line.get("line_total"))

        if quantity is None or quantity <= 0:
            line_problems.append({"index": index, "kind": MISSING_QUANTITY})
        if unit_cost is None or unit_cost <= 0:
            line_problems.append({"index": index, "kind": MISSING_UNIT_COST})

        computed = None
        if quantity is not None and unit_cost is not None:
            computed = quantity * unit_cost
        if computed is not None and line_total is not None:
            if not _within_tolerance(computed, line_total):
                line_problems.append(
                    {
                        "index": index,
                        "kind": LINE_TOTAL_MISMATCH,
                        "expected": _money(computed),
                        "stated": _money(line_total),
                        "delta": _money(line_total - computed),
                    }
                )
        # The invoice's own line total is the better summand when it is there:
        # it is what the supplier is actually charging, quantity misread or not.
        summand = line_total if line_total is not None else computed
        if summand is not None:
            have_line_totals = True
            lines_sum += summand

    subtotal = _decimal(extraction.get("subtotal"))
    discount = _decimal(extraction.get("discount")) or Decimal("0")
    tax = _decimal(extraction.get("tax")) or Decimal("0")
    total = _decimal(extraction.get("total"))

    totals_problems = []
    if subtotal is not None and have_line_totals:
        if not _within_tolerance(subtotal, lines_sum):
            totals_problems.append(
                {
                    "kind": SUBTOTAL_MISMATCH,
                    "expected": _money(subtotal),
                    "stated": _money(lines_sum),
                    "delta": _money(lines_sum - subtotal),
                }
            )
    basis = subtotal if subtotal is not None else (lines_sum if have_line_totals else None)
    computed_total = None
    if basis is not None:
        computed_total = basis - discount + tax
        if total is not None and not _within_tolerance(computed_total, total):
            totals_problems.append(
                {
                    "kind": TOTAL_MISMATCH,
                    "expected": _money(computed_total),
                    "stated": _money(total),
                    "delta": _money(total - computed_total),
                }
            )

    # De-duplicated, ordered: the second pass asks for these lines by number.
    flagged = []
    for problem in line_problems:
        index = problem.get("index")
        if index is not None and index not in flagged:
            flagged.append(index)

    return {
        "ok": not line_problems and not totals_problems,
        "lines": line_problems,
        "line_indexes": flagged,
        "totals": totals_problems,
        "computed": {
            "lines_sum": _money(lines_sum) if have_line_totals else None,
            "subtotal": None if subtotal is None else _money(subtotal),
            "total": None if computed_total is None else _money(computed_total),
            "stated_total": None if total is None else _money(total),
        },
    }
