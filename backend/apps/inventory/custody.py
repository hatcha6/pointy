"""When goods the shop was holding for someone else break, vanish or are stolen.

§6.2.2, and the path a consignment module is actually judged on. §6.2.1 covers
the two happy endings — it sells, or the owner takes it back. This is the third
one: the camera is dropped, the bag goes with the window, the laptop is handed
to the wrong cousin. The shop's reputation, and sometimes a court, turns on
whether it can produce a record made **at the time** rather than an argument
made afterwards.

Three rules hold the whole module up.

**The record does not wait for the judgement.** ``responsibility`` starts at
*undetermined* and nothing here requires it to be resolved before the incident
can be written. Zero is a legitimate assessment and it is still a row.

**Money state and custody state are different facts.** The unit's inventory
value is zero, so writing it off costs the shop no stock value; the claim, if
there is one, moves as an ordinary disbursement with no relationship to
inventory at all. That is ``repair-settlement-custody`` stated in the ledger.

**The matrix is read from the agreement, not from the settings.** Changing the
shop's default liability policy changes the next voucher and never a claim on
an agreement already in force.
"""

from __future__ import annotations

from decimal import Decimal

from django.db import transaction
from django.utils import timezone
from rest_framework import serializers

from apps.core.models import ShopSettings

from . import tracking
from .models import (
    ConsignmentAgreement,
    ConsignmentIncident,
    ConsignorPayout,
    StockLedgerEntry,
    StockMovement,
    StockUnit,
)

ZERO = Decimal("0.00")


# ---------------------------------------------------------------------------
# The matrix
# ---------------------------------------------------------------------------

#: §6.2.2's table, as data. Rows are the policy the consignor signed; columns
#: are who turned out to be responsible. ``True`` means the declared value is
#: owed, ``False`` means nothing is.
#:
#: Two entries carry the argument. **``third_party`` pays under both liable
#: policies** — from the consignor's side of the counter a burglary is the shop
#: failing to keep their watch safe, and whether the shop then recovers from
#: police or insurance is the shop's business, not a reason to hand the customer
#: a loss. And **``force_majeure`` is the entire difference between the two
#: liable policies**: a fire, a flood, an armed robbery, a period of unrest.
#: That is not a hypothetical distinction here; it is the one a Libyan shop
#: would actually invoke, which is why it is a policy value rather than an
#: argument after the fact.
LIABILITY_MATRIX = {
    ConsignmentAgreement.Liability.OWNER_RISK: {
        ConsignmentIncident.Responsibility.SHOP: False,
        ConsignmentIncident.Responsibility.THIRD_PARTY: False,
        ConsignmentIncident.Responsibility.FORCE_MAJEURE: False,
        ConsignmentIncident.Responsibility.CONSIGNOR: False,
    },
    ConsignmentAgreement.Liability.SHOP_LIABLE_EXCEPT_FM: {
        ConsignmentIncident.Responsibility.SHOP: True,
        ConsignmentIncident.Responsibility.THIRD_PARTY: True,
        ConsignmentIncident.Responsibility.FORCE_MAJEURE: False,
        ConsignmentIncident.Responsibility.CONSIGNOR: False,
    },
    ConsignmentAgreement.Liability.SHOP_LIABLE: {
        ConsignmentIncident.Responsibility.SHOP: True,
        ConsignmentIncident.Responsibility.THIRD_PARTY: True,
        ConsignmentIncident.Responsibility.FORCE_MAJEURE: True,
        ConsignmentIncident.Responsibility.CONSIGNOR: False,
    },
}


def liability_bound(unit, agreement=None) -> Decimal:
    """The most a claim on this article can come to.

    ``agreement.liability_cap`` if the page names one, else what the two
    parties wrote down the thing was worth.
    """
    agreement = agreement or (unit.agreement if unit.agreement_id else None)
    cap = getattr(agreement, "liability_cap", None)
    declared = unit.declared_value or ZERO
    if cap is None:
        return Decimal(declared)
    return min(Decimal(cap), Decimal(declared)) if declared else Decimal(cap)


def default_assessment(unit, *, responsibility, agreement=None):
    """``(value, is_assessed)`` — the matrix crossed with the agreement.

    ``undetermined`` returns ``(0, False)``, which is **not** the same zero as
    an assessed nothing: the incident stays pending, appears in the claims
    report as *unassessed*, and the treasury overlay carries it as a count
    rather than folding a number nobody has decided into a total.
    """
    agreement = agreement or (unit.agreement if unit.agreement_id else None)
    if responsibility == ConsignmentIncident.Responsibility.UNDETERMINED:
        return ZERO, False
    policy = getattr(
        agreement, "liability_policy", ConsignmentAgreement.Liability.OWNER_RISK
    )
    owed = LIABILITY_MATRIX.get(policy, {}).get(responsibility, False)
    if not owed:
        return ZERO, True
    return Decimal(liability_bound(unit, agreement)).quantize(Decimal("0.01")), True


# ---------------------------------------------------------------------------
# Recording one
# ---------------------------------------------------------------------------


@transaction.atomic
def report_incident(
    *,
    unit,
    kind,
    narrative,
    discovered_at=None,
    occurred_on=None,
    responsibility=None,
    request=None,
    camera=None,
    write_off=True,
):
    """Write down what was found, the moment it was found.

    ``write_off`` takes the goods off the shelf, which is what has physically
    happened for everything but a dispute: quantity leaves the bin, the unit's
    status becomes ``damaged`` or ``written_off``, and ``value_change`` is
    **zero**, because the shop never owned the value. The money, if there is
    any, is a claim with no relationship to inventory at all.
    """
    if not unit.is_consignment:
        raise serializers.ValidationError(
            {"unit": "هذه الوحدة ليست أمانة — استخدم شطب المخزون."}
        )
    if not unit.agreement_id:
        raise serializers.ValidationError(
            {"unit": "لا يوجد سند أمانة مرتبط بهذه الوحدة."}
        )
    narrative = str(narrative or "").strip()
    if not narrative:
        raise serializers.ValidationError(
            {"narrative": "اكتب ما حدث بكلماتك — هذا هو المحضر."}
        )

    actor = _actor(request)
    at = discovered_at or timezone.now()
    responsibility = (
        responsibility or ConsignmentIncident.Responsibility.UNDETERMINED
    )
    assessed_value, is_assessed = default_assessment(
        unit, responsibility=responsibility
    )
    incident = ConsignmentIncident.objects.create(
        unit=unit,
        agreement_id=unit.agreement_id,
        kind=kind,
        narrative=narrative,
        discovered_at=at,
        occurred_on=occurred_on,
        reported_by=actor,
        responsibility=responsibility,
        assessed_value=assessed_value,
        is_assessed=is_assessed,
        camera=camera,
        created_by=actor,
    )
    if write_off and kind != ConsignmentIncident.Kind.DISPUTE:
        _take_off_the_shelf(unit, incident, actor=actor, at=at)
    _record_event(unit, incident, actor=actor, at=at)
    return incident


def _take_off_the_shelf(unit, incident, *, actor, at):
    """Quantity leaves, value does not — there was never any to lose."""
    from .services import (
        build_stock_movement,
        create_stock_movements,
        lock_stock_item,
        save_stock_item_quantities_bulk,
        stock_snapshot,
    )

    if unit.status not in StockUnit.ON_HAND_STATUSES:
        return None
    status = (
        StockUnit.Status.DAMAGED
        if incident.kind == ConsignmentIncident.Kind.DAMAGED
        else StockUnit.Status.WRITTEN_OFF
    )
    plan = tracking.plan_issue(
        variant=unit.variant,
        warehouse=unit.warehouse_id,
        quantity=Decimal("1"),
        unit_ids=[unit.pk],
        allow_expired=True,
    )
    stock_item = lock_stock_item(variant=unit.variant, warehouse=unit.warehouse_id)
    before = stock_snapshot(stock_item)
    stock_item.quantity_on_hand -= Decimal("1")
    tracking.apply_issue(plan, status=status, at=at)
    movement = build_stock_movement(
        variant=unit.variant,
        stock_item=stock_item,
        movement_type=StockMovement.Type.DAMAGED
        if status == StockUnit.Status.DAMAGED
        else StockMovement.Type.DECREASE,
        quantity=Decimal("1"),
        note=f"حادث أمانة {incident.number}",
        created_by=actor,
        before=before,
        tracked_plan=plan,
    )
    save_stock_item_quantities_bulk([stock_item])
    create_stock_movements(
        [movement],
        voucher_type=StockLedgerEntry.VoucherType.ADJUSTMENT,
        voucher_id=incident.pk,
        posting_at=at,
    )
    return movement


def _record_event(unit, incident, *, actor, at):
    from .stock_count_tracking import record_unit_event

    return record_unit_event(
        unit,
        kind="incident",
        actor=actor,
        at=at,
        to_value=incident.kind,
        note=incident.number,
        reference_type="consignment_incident",
        reference_id=incident.pk,
    )


# ---------------------------------------------------------------------------
# Assessing and settling
# ---------------------------------------------------------------------------


@transaction.atomic
def assess_incident(
    incident, *, responsibility, assessed_value=None, request=None, note=""
):
    """Decide who is responsible, and what that comes to.

    A value the assessor types wins over the matrix — the matrix is a default
    the shop can argue away from, and the argument is what is being recorded —
    but it is still bounded by what the agreement caps the claim at, because
    that bound is a term both parties signed.
    """
    incident = (
        ConsignmentIncident.objects.select_for_update(of=("self",))
        .select_related("unit", "agreement")
        .get(pk=incident.pk)
    )
    if not incident.is_open:
        raise serializers.ValidationError(
            {"detail": f"سبق إغلاق هذا المحضر ({incident.resolution})."}
        )
    suggested, is_assessed = default_assessment(
        incident.unit, responsibility=responsibility, agreement=incident.agreement
    )
    if assessed_value is None:
        value = suggested
    else:
        bound = liability_bound(incident.unit, incident.agreement)
        value = min(Decimal(assessed_value), bound) if bound else Decimal(
            assessed_value
        )
        is_assessed = True
    incident.responsibility = responsibility
    incident.assessed_value = Decimal(value).quantize(Decimal("0.01"))
    incident.is_assessed = is_assessed
    if note:
        incident.narrative = f"{incident.narrative}\n— {note}".strip()
    incident.save(
        update_fields=[
            "responsibility",
            "assessed_value",
            "is_assessed",
            "narrative",
            "updated_at",
        ]
    )
    return incident


@transaction.atomic
def settle_incident(
    incident,
    *,
    resolution,
    request=None,
    method=ConsignorPayout.Method.CASH,
    replacement_unit=None,
    reference="",
    notes="",
    settings=None,
):
    """Close a claim.

    Paying one is the **same disbursement primitive** as paying a payout — one
    register pay-out, one numbered voucher, one SMS — reused with a different
    reason rather than reinvented, so the blind close still reconciles and the
    money lands in the component it belongs to. A replacement instead of cash
    resolves to ``replaced`` and names the substitute article. Nothing new is
    invented to move the money.
    """

    incident = (
        ConsignmentIncident.objects.select_for_update(of=("self",))
        .select_related("unit", "agreement", "unit__consignor")
        .get(pk=incident.pk)
    )
    if not incident.is_open:
        raise serializers.ValidationError(
            {"detail": f"سبق إغلاق هذا المحضر ({incident.resolution})."}
        )
    settings = settings or ShopSettings.load()
    payout = None
    if resolution == ConsignmentIncident.Resolution.PAID:
        if not incident.is_assessed or incident.assessed_value <= ZERO:
            raise serializers.ValidationError(
                {"assessed_value": "قدّر قيمة المطالبة قبل صرفها."}
            )
        payout = _disburse_claim(
            incident,
            method=method,
            request=request,
            reference=reference,
            notes=notes,
            settings=settings,
        )
    elif resolution == ConsignmentIncident.Resolution.REPLACED:
        if replacement_unit is None:
            raise serializers.ValidationError(
                {"replacement_unit": "حدّد الوحدة البديلة."}
            )
        incident.replacement_unit = replacement_unit

    incident.resolution = resolution
    incident.resolved_at = timezone.now()
    incident.settlement_ref = reference or (
        payout.number if payout is not None else ""
    )
    incident.settlement_payout = payout
    incident.save(
        update_fields=[
            "resolution",
            "resolved_at",
            "settlement_ref",
            "settlement_payout",
            "replacement_unit",
            "updated_at",
        ]
    )
    return incident


def _disburse_claim(incident, *, method, request, reference, notes, settings):
    """One register pay-out, one numbered voucher, one SMS — §6.2.1 step 4."""
    from apps.sales.models import RegisterCashMovement, RegisterSession

    from .consignment_service import _actor

    unit = incident.unit
    amount = Decimal(incident.assessed_value)
    created_by = _actor(request)
    session = None
    movement = None
    if method == ConsignorPayout.Method.CASH:
        session = RegisterSession.open_for(created_by)
        if session is None:
            raise serializers.ValidationError(
                {"detail": "الصرف نقدًا يحتاج وردية مفتوحة."}
            )
        consignor_name = getattr(unit.consignor, "full_name", "") or ""
        movement = RegisterCashMovement.objects.create(
            register_session=session,
            movement_type=RegisterCashMovement.MovementType.PAY_OUT,
            amount=amount,
            reason=f"تسوية حادث أمانة: {consignor_name}".strip(),
            created_by=created_by,
        )
    payout = ConsignorPayout.objects.create(
        consignor_id=unit.consignor_id,
        amount=amount,
        method=method,
        paid_at=timezone.now(),
        reference=reference or incident.number,
        notes=notes,
        register_session=session,
        cash_movement=movement,
        created_by=created_by,
    )
    _notify_settlement(incident, payout, settings=settings)
    return payout


def _notify_settlement(incident, payout, *, settings):
    from apps.messaging import services as messaging
    from apps.messaging.models import MessagingGateway, OutboundMessage

    if not settings.consignment_auto_sms_on_sale:
        return
    unit = incident.unit
    phone = getattr(unit.consignor, "phone", "") if unit.consignor_id else ""
    if not phone:
        return
    body = (
        f"تم تسليمكم مبلغ {payout.amount:.2f} د.ل تسويةً عن "
        f"{unit.variant.full_name if unit.variant_id else ''} "
        f"بموجب المحضر {incident.number}. سند الصرف {payout.number}."
    )

    def _send():
        try:
            messaging.enqueue_message(
                to=phone,
                body=body,
                consent_class=OutboundMessage.ConsentClass.TRANSACTIONAL,
                channel=MessagingGateway.Channel.SMS,
                dedup_key=f"consignment_claim_{payout.pk}",
                source_type="consignment_claim",
                source_id=payout.pk,
            )
        except messaging.NoGatewayConfigured:
            return

    transaction.on_commit(_send)


def _actor(request):
    user = getattr(request, "user", None)
    return user if getattr(user, "is_authenticated", False) else None


__all__ = [
    "LIABILITY_MATRIX",
    "assess_incident",
    "default_assessment",
    "liability_bound",
    "report_incident",
    "settle_incident",
]
