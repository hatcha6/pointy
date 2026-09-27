"""A purchase unit cost is a rate, not an amount of money.

Money is two places. A unit cost is what a supplier's figure works out to per
piece, and that is rarely two places: 58.00 for fifteen loaves is 3.8666… each.
Stored as 3.87 it became 58.05 on the order — a sum the shop owed the supplier
that no invoice ever said. The buying screen lets a buyer key the total off the
paper precisely so the division is done for them, and the two-place column
undid it: in one field week a single 107-line delivery keyed that way was saved
28.74 above the total the buyer had been shown.

So a unit cost keeps six places, like the stock ledger's rates, and only the
figures that are money — line totals, subtotals, what is owed — are rounded to
two.
"""

from decimal import ROUND_HALF_UP, Decimal

COST_PLACES = Decimal("0.000001")


def quantize_cost(value) -> Decimal:
    return Decimal(value).quantize(COST_PLACES, rounding=ROUND_HALF_UP)


def cost_string(value) -> str:
    """Six places at most, two at least: ``"12.50"``, ``"3.866667"``.

    The trailing zeros are dropped so that an ordinary cost reads exactly as
    it did when the column held two places — only a cost that needs the
    places shows them.
    """
    text = f"{quantize_cost(value):f}"
    whole, _, fraction = text.partition(".")
    return f"{whole}.{fraction.rstrip('0').ljust(2, '0')}"
