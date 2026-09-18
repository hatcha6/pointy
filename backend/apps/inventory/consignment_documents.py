"""Reversing the two consignment documents.

Both reversals are deliberately narrow, and both refuse rather than improvise.

Cancelling an agreement is *tearing up a signed page*. It is allowed while the
goods are untouched — the customer changed their mind on the way out — and
refused the moment any of the articles it covers has moved, because a page
cannot be un-signed after the watch it covers has been sold. The right answer
there is the counter-document: return the unsold goods, or pay out the sold
ones.

Cancelling a payout is giving back money that was handed over. Its opposite is a
pay-in of the same amount and the units becoming payable again.
"""

from __future__ import annotations

from decimal import Decimal


def reverse_agreement(agreement, *, at, actor, reason="", context=None):
    """Take the goods back off the shelf, or refuse if any of them has moved."""
    from apps.documents.errors import DocumentBlocked
    from apps.inventory.models import StockUnit
    from apps.inventory.consignment_service import return_to_consignor

    units = list(
        StockUnit.objects.select_related("variant").filter(agreement=agreement)
    )
    moved = [
        unit
        for unit in units
        if unit.status not in (StockUnit.Status.IN_STOCK, StockUnit.Status.RETURNED)
    ]
    if moved:
        raise DocumentBlocked(
            number=agreement.number,
            blockers=[
                {
                    "label": "وحدات تحرّكت بعد توقيع السند",
                    "field": "units",
                    "count": len(moved),
                }
            ],
        )
    for unit in units:
        if unit.status == StockUnit.Status.IN_STOCK:
            return_to_consignor(
                unit, note=f"إلغاء سند أمانة {agreement.number or agreement.pk}"
            )
    return agreement


def reverse_payout(payout, *, at, actor, reason="", context=None):
    """Money back into the drawer, and the units owed again."""
    from apps.inventory.models import StockUnit
    from apps.sales.models import RegisterCashMovement

    units = list(StockUnit.objects.filter(consignor_payout=payout))
    for unit in units:
        unit.consignor_paid_at = None
        unit.consignor_payout = None
    if units:
        StockUnit.objects.bulk_update(
            units, ["consignor_paid_at", "consignor_payout", "updated_at"]
        )
    if payout.cash_movement_id and payout.register_session_id:
        RegisterCashMovement.objects.create(
            register_session_id=payout.register_session_id,
            movement_type=RegisterCashMovement.MovementType.PAY_IN,
            amount=Decimal(payout.amount),
            reason=f"إلغاء صرف أمانة {payout.number or payout.pk}",
            created_by=actor,
        )
    return payout
