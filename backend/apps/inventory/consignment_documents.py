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
    """Money back into the drawer, and the units owed again.

    Any **advance** this payout created or consumed goes back with it
    (§15.3). The amounts are read off the unit events the disbursement wrote
    rather than recomputed, because recomputing them from today's terms would
    reverse a different number than the one that moved — which is the whole
    reason the advance is a stored figure and not an inference.
    """
    from apps.inventory.models import StockUnit, StockUnitEvent
    from apps.sales.models import RegisterCashMovement

    units = list(StockUnit.objects.filter(consignor_payout=payout))
    adjustments = _advance_movements_for(payout, StockUnitEvent)
    for unit in units:
        unit.consignor_paid_at = None
        unit.consignor_payout = None
        delta = adjustments.get(unit.pk)
        if delta is not None:
            unit.consignor_advance = max(
                Decimal(unit.consignor_advance) + delta, Decimal("0.00")
            )
    if units:
        StockUnit.objects.bulk_update(
            units,
            [
                "consignor_paid_at",
                "consignor_payout",
                "consignor_advance",
                "updated_at",
            ],
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


def reverse_incident(incident, *, at, actor, reason="", context=None):
    """Withdraw a custody record, and refuse once money has moved on it.

    An incident is *"this is what we found, and when"*. Cancelling it says the
    finding was wrong — a camera that turned up, a bag that was in the back
    room all along — and that is a legitimate thing to have to say. What it
    must never do is quietly unwind a settlement: once a consignor has been
    paid or the goods replaced, the record of why is part of the money trail,
    and the way back is a counter-document, not a cancellation.
    """
    from apps.documents.errors import DocumentBlocked

    if incident.settlement_payout_id is not None:
        raise DocumentBlocked(
            number=incident.number,
            blockers=[
                {
                    "label": "سبق صرف تسوية على هذا المحضر",
                    "field": "settlement_payout",
                    "count": 1,
                }
            ],
        )
    incident.resolution = incident.Resolution.NO_CLAIM
    incident.resolved_at = at
    incident.is_assessed = False
    incident.assessed_value = Decimal("0")
    incident.save(
        update_fields=[
            "resolution",
            "resolved_at",
            "is_assessed",
            "assessed_value",
            "updated_at",
        ]
    )
    return incident


def _advance_movements_for(payout, StockUnitEvent):
    """How much advance this payout moved, per unit, signed for the undo.

    ``advance_settled`` reduced an advance, so undoing puts it back (+).
    ``advance_opened`` created one out of this payout, so undoing removes it
    (−). A unit that saw neither is absent, and is left alone.
    """
    deltas = {}
    rows = StockUnitEvent.objects.filter(
        reference_type="consignor_payout",
        reference_id=payout.pk,
        kind__in=("advance_settled", "advance_opened"),
    ).values_list("unit_id", "kind", "from_value")
    for unit_id, kind, amount in rows:
        try:
            value = Decimal(amount or "0")
        except (ArithmeticError, ValueError):
            continue
        sign = Decimal("1") if kind == "advance_settled" else Decimal("-1")
        deltas[unit_id] = deltas.get(unit_id, Decimal("0")) + sign * value
    return deltas
