"""What a card settlement means to the document lifecycle.

A settlement is undone by exclusion, the way an expense is: once cancelled it
stops counting everywhere (every sum reads ``.live()``), so the bank loses the
deposit and the clearing account gets the takings back. What it must also give
back is its claim on the payments it covered — they are held again, ready to be
settled by the deposit that really paid them. Switching the lines off is that.
"""

from apps.treasury.models import CardSettlement, CardSettlementLine


def reverse_settlement(settlement, *, at, actor, reason="", context=None):
    """Hand the settlement's payments back to the held ones."""
    CardSettlementLine.objects.filter(settlement=settlement, is_live=True).update(
        is_live=False
    )


__all__ = ["CardSettlement", "reverse_settlement"]
