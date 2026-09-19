"""Consignment as it actually happens across a counter.

Intake, disbursement, and the two ways goods leave again. The arithmetic and
the four money definitions live in :mod:`apps.inventory.consignment`; this is
the part that writes rows.

Every path here is one transaction, because each of them is one act in the
shop: a voucher signed, money handed over, a watch given back. Half of any of
those is worse than none of it.
"""

from __future__ import annotations

from decimal import Decimal

from django.db import transaction
from django.utils import timezone
from rest_framework import serializers

from apps.core.models import ShopSettings

from . import consignment as figures
from . import tracking
from .models import (
    ConsignorPayout,
    StockLedgerEntry,
    StockUnit,
    Warehouse,
)
from .services import (
    build_stock_movement,
    create_stock_movements,
    lock_stock_item,
    save_stock_item_quantities_bulk,
    stock_snapshot,
)

ZERO = Decimal("0.00")


def _actor(request):
    user = getattr(request, "user", None)
    return user if getattr(user, "is_authenticated", False) else None


# ---------------------------------------------------------------------------
# Intake — submitting the voucher is what starts custody
# ---------------------------------------------------------------------------


@transaction.atomic
def take_into_consignment(
    *,
    agreement,
    items,
    warehouse=None,
    request=None,
    settings=None,
    at=None,
):
    """Put the consignor's goods on the shelf.

    ``items`` is one row per article: ``variant``, ``code``, and optionally
    ``secondary_code``, ``identifier_kind``, ``declared_value``, ``list_price``,
    ``attributes``, ``notes`` and any of the three payout terms as a per-unit
    override.

    The units enter at ``incoming_rate = 0`` and **count** — the watch is on the
    shelf, it gets counted at stock count, and it has to be sellable. What they
    do not do is add value: they are somebody else's property, and a bin that
    said otherwise would inflate the shop's stock with other people's watches.
    """
    settings = settings or ShopSettings.load()
    at = at or timezone.now()
    warehouse_id = getattr(warehouse, "pk", warehouse) or Warehouse.default_id()
    rows = list(items or [])
    if not rows:
        raise serializers.ValidationError(
            {"items": "سند الأمانة يجب أن يشمل صنفًا واحدًا على الأقل."}
        )
    if settings.consignment_require_declared_value:
        for index, row in enumerate(rows):
            if row.get("declared_value") in (None, ""):
                raise serializers.ValidationError(
                    {"items": {index: {"declared_value": "القيمة المقدّرة مطلوبة."}}}
                )

    by_variant = {}
    for row in rows:
        by_variant.setdefault(row["variant"].pk, []).append(row)

    created_by = _actor(request)
    movements = []
    adjusted = []
    plans = []
    for variant_id in sorted(by_variant):
        variant_rows = by_variant[variant_id]
        variant = variant_rows[0]["variant"]
        if not tracking.tracks_units(tracking.mode_of(variant)):
            raise serializers.ValidationError(
                {
                    "items": (
                        "الأمانات تُسجَّل بالوحدة: اختر منتجًا متتبَّعًا برقم "
                        "تسلسلي."
                    )
                }
            )
        plan = tracking.plan_receipt(
            variant=variant,
            warehouse=warehouse_id,
            quantity=len(variant_rows),
            rate=ZERO,
            units=[_capture_row(row) for row in variant_rows],
            at=at,
        )
        _mark_consigned(plan, variant_rows, agreement=agreement, at=at)
        tracking.apply_receipt(plan, at=at)
        plans.append(plan)

        stock_item = lock_stock_item(variant=variant, warehouse=warehouse_id)
        before = stock_snapshot(stock_item)
        stock_item.quantity_on_hand += Decimal(len(variant_rows))
        adjusted.append(stock_item)
        movement = build_stock_movement(
            variant=variant,
            stock_item=stock_item,
            movement_type=_increase(),
            quantity=Decimal(len(variant_rows)),
            note=f"أمانة {agreement.number or agreement.pk}",
            created_by=created_by,
            before=before,
            unit_cost=ZERO,
            tracked_plan=plan,
        )
        movements.append(movement)

    save_stock_item_quantities_bulk(adjusted)
    create_stock_movements(
        movements,
        voucher_type=StockLedgerEntry.VoucherType.CONSIGNMENT_INTAKE,
        voucher_id=agreement.pk,
        posting_at=at,
    )
    return [unit for plan in plans for unit in plan.new_units]


def _increase():
    from .models import StockMovement

    return StockMovement.Type.INCREASE


def _capture_row(row):
    return {
        key: row[key]
        for key in (
            "code",
            "secondary_code",
            "identifier_kind",
            "attributes",
            "notes",
        )
        if row.get(key) not in (None, "")
    }


def _mark_consigned(plan, rows, *, agreement, at):
    """Stamp whose goods these are onto the units the plan just built.

    ``plan_receipt`` knows about identity and cost and deliberately nothing
    about ownership, so this is where the units learn they are not the shop's.
    The consignor is denormalised onto each one — checked equal to the
    agreement's — so the payables screen and the POS picker never join to read
    who is owed.
    """
    if plan is None:
        return
    for unit, row in zip(plan.new_units, rows):
        unit.is_consignment = True
        unit.agreement = agreement
        unit.consignor_id = agreement.consignor_id
        unit.declared_value = row.get("declared_value")
        unit.list_price = row.get("list_price")
        unit.incoming_rate = ZERO
        unit.acquired_at = at
        unit.in_stock_since = at
        for field in (
            "consignor_payout_mode",
            "consignor_payout_rate",
            "consignor_commission_pct",
            "consignor_reserve_price",
        ):
            value = row.get(field)
            if value not in (None, ""):
                setattr(unit, field, value)


@transaction.atomic
def submit_agreement(agreement, *, items=None, request=None, settings=None):
    """Sign the voucher, and with it start custody.

    The liability clause is copied here, from the shop's editable sentence for
    the policy chosen, and never re-read afterwards: a shop that rewords its
    voucher next year has not reworded the pages people have already signed.
    """
    from apps.documents import services as document_services

    settings = settings or ShopSettings.load()
    if not agreement.liability_clause:
        agreement.liability_clause = figures.clause_for(
            agreement.liability_policy, settings=settings
        )
        agreement.save(update_fields=["liability_clause", "updated_at"])
    units = []
    if items:
        units = take_into_consignment(
            agreement=agreement, items=items, request=request, settings=settings
        )
    document_services.submit(agreement, request=request)
    return agreement, units


# ---------------------------------------------------------------------------
# Disbursement
# ---------------------------------------------------------------------------


@transaction.atomic
def disburse_payout(
    *,
    units=None,
    unit_ids=None,
    method=ConsignorPayout.Method.CASH,
    request=None,
    reference="",
    notes="",
    settings=None,
):
    """Hand a consignor the money their sold goods earned them.

    One payout row covers however many of their articles are being settled at
    once, which is what a counter actually does: the owner of eight handbags
    collects for three of them and signs once.

    Cash leaves the drawer through a ``RegisterCashMovement``, exactly like a
    supplier pay-out, so the blind close still reconciles. It is deliberately
    **not** an ``Expense`` and **not** a ``SupplierPayment``: both already carry
    exclusion rules in ``treasury/position.py``, and reusing one would file this
    money under a category it does not belong to.
    """
    from apps.sales.models import RegisterCashMovement, RegisterSession

    settings = settings or ShopSettings.load()
    # Locked **here**, not by the caller: ``select_for_update`` outside a
    # transaction is an error, and a view that evaluated the queryset before
    # calling in would take no lock at all — which is exactly how the same
    # payout gets disbursed twice from two tills.
    wanted = list(unit_ids) if unit_ids is not None else [unit.pk for unit in units]
    units = list(
        # ``of=("self",)`` locks the unit rows and nothing else: ``consignor``
        # is nullable, so select_related puts it on the nullable side of a LEFT
        # JOIN and Postgres refuses ``FOR UPDATE`` there. Locking the customer
        # is not wanted anyway — this reads their name, it does not change them.
        StockUnit.objects.select_for_update(of=("self",))
        .select_related("consignor", "variant", "variant__product")
        .filter(pk__in=wanted)
        .order_by("pk")
    )
    if not units:
        raise serializers.ValidationError({"units": "اختر أمانة واحدة على الأقل."})

    consignor_ids = {unit.consignor_id for unit in units}
    if len(consignor_ids) != 1 or None in consignor_ids:
        raise serializers.ValidationError(
            {"units": "سند الصرف الواحد يخص صاحب أمانة واحدًا."}
        )
    for unit in units:
        if not unit.is_consignment:
            raise serializers.ValidationError({"units": "هذه الوحدة ليست أمانة."})
        if unit.status != StockUnit.Status.SOLD:
            raise serializers.ValidationError(
                {"units": "لا تُصرف مستحقات أمانة لم تُبَع بعد."}
            )
        if unit.consignor_paid_at is not None:
            raise serializers.ValidationError(
                {"units": f"سبق صرف مستحقات «{unit.code}»."}
            )

    amount = sum((figures.consignor_payout_due(unit) for unit in units), ZERO)
    if amount <= ZERO:
        raise serializers.ValidationError({"units": "لا يوجد مبلغ مستحق للصرف."})

    created_by = _actor(request)
    session = None
    movement = None
    if method == ConsignorPayout.Method.CASH:
        session = RegisterSession.open_for(created_by)
        if session is None:
            raise serializers.ValidationError(
                {"detail": "الصرف نقدًا يحتاج وردية مفتوحة."}
            )

    # The drawer movement is written *first* and handed to the document, not
    # attached afterwards: a payout has no draft state, so it is frozen from the
    # moment it exists and a later ``save(update_fields=["cash_movement"])``
    # would be refused by the lifecycle — correctly, because a document that can
    # still acquire the money it represents is one whose money can be changed.
    if session is not None:
        consignor_name = getattr(units[0].consignor, "full_name", "") or ""
        movement = RegisterCashMovement.objects.create(
            register_session=session,
            movement_type=RegisterCashMovement.MovementType.PAY_OUT,
            amount=amount,
            reason=f"صرف مستحقات أمانة: {consignor_name}".strip(),
            created_by=created_by,
        )
    payout = ConsignorPayout.objects.create(
        consignor_id=units[0].consignor_id,
        amount=amount,
        method=method,
        paid_at=timezone.now(),
        reference=reference,
        notes=notes,
        register_session=session,
        cash_movement=movement,
        created_by=created_by,
    )

    now = timezone.now()
    for unit in units:
        unit.consignor_paid_at = now
        unit.consignor_payout = payout
    StockUnit.objects.bulk_update(
        units, ["consignor_paid_at", "consignor_payout", "updated_at"]
    )
    # No submit call: a payout has no draft state, so it is born submitted —
    # the same as a supplier payment and an expense, and for the same reason.
    # There is no moment at which money has half left the drawer.
    _notify_payout(units, payout, settings=settings)
    return payout


def _notify_payout(units, payout, *, settings):
    from apps.messaging import services as messaging
    from apps.messaging.models import MessagingGateway, OutboundMessage

    if not settings.consignment_auto_sms_on_sale:
        return
    unit = units[0]
    phone = getattr(unit.consignor, "phone", "") if unit.consignor_id else ""
    if not phone:
        return
    body = figures.render_payout_sms(unit, payout, settings=settings)

    def _send():
        try:
            messaging.enqueue_message(
                to=phone,
                body=body,
                consent_class=OutboundMessage.ConsentClass.TRANSACTIONAL,
                channel=MessagingGateway.Channel.SMS,
                dedup_key=f"consignment_payout_{payout.pk}",
                source_type="consignment_payout",
                source_id=payout.pk,
            )
        except messaging.NoGatewayConfigured:
            return

    transaction.on_commit(_send)


# ---------------------------------------------------------------------------
# Leaving again
# ---------------------------------------------------------------------------


@transaction.atomic
def return_to_consignor(unit, *, request=None, note=""):
    """Give unsold goods back to the person who left them.

    No ledger value moves, because none ever arrived: the quantity leaves, the
    zero leaves with it, and no payout is generated. The agreement closes when
    its last unit has gone.
    """
    unit = (
        StockUnit.objects.select_for_update(of=("self",))
        .select_related("variant", "variant__product")
        .get(pk=unit.pk)
    )
    if not unit.is_consignment:
        raise serializers.ValidationError({"detail": "هذه الوحدة ليست أمانة."})
    if unit.status not in StockUnit.ON_HAND_STATUSES:
        raise serializers.ValidationError(
            {"detail": "لا يمكن إرجاع أمانة ليست في المخزون."}
        )

    at = timezone.now()
    plan = tracking.plan_issue(
        variant=unit.variant,
        warehouse=unit.warehouse_id,
        quantity=Decimal("1"),
        unit_ids=[unit.pk],
        allow_short=False,
    )
    stock_item = lock_stock_item(variant=unit.variant, warehouse=unit.warehouse_id)
    before = stock_snapshot(stock_item)
    stock_item.quantity_on_hand -= Decimal("1")
    tracking.apply_issue(plan, status=StockUnit.Status.RETURNED, at=at)
    movement = build_stock_movement(
        variant=unit.variant,
        stock_item=stock_item,
        movement_type=_decrease(),
        quantity=Decimal("1"),
        note=note or f"إرجاع أمانة {unit.code}",
        created_by=_actor(request),
        before=before,
        tracked_plan=plan,
    )
    save_stock_item_quantities_bulk([stock_item])
    create_stock_movements(
        [movement],
        voucher_type=StockLedgerEntry.VoucherType.CONSIGNMENT_RETURN,
        voucher_id=unit.pk,
        posting_at=at,
    )
    return unit


def _decrease():
    from .models import StockMovement

    return StockMovement.Type.DECREASE


def agreement_is_closed(agreement):
    """An agreement is over when the last article it covers has left.

    A question, not an act — which is why nothing calls it to "close" anything.
    Not a status column either: "are any of its units still here?" is one
    indexed existence check, and a stored flag is a second answer that can
    disagree with the first. The agreements list asks the same question through
    its ``open_only`` filter, in SQL, over many rows at once.
    """
    return agreement is not None and not StockUnit.objects.filter(
        agreement=agreement, status__in=StockUnit.LIVE_STATUSES
    ).exists()


@transaction.atomic
def buy_in_returned_consignment(unit, *, request=None):
    """A customer brought a paid-out consignment back. The shop keeps it.

    The unit converts to owned stock at what the consignor was actually paid,
    which is exactly what happened: the shop owns a watch it paid ten thousand
    for. The consignment closes with it.
    """
    payout = figures.consignor_payout_due(unit)
    unit.is_consignment = False
    unit.incoming_rate = payout
    unit.save(
        update_fields=["is_consignment", "incoming_rate", "updated_at"]
    )
    return unit


def reopen_consignment(unit, *, request=None):
    """…or it goes back on the shelf as the consignor's, and they owe the shop.

    Two situations wear the same name, and the difference is whether money has
    left the building.

    **Nothing was paid yet.** The sale is simply undone, so the payout stamped
    on the article at checkout describes a sale that no longer exists. It goes.

    **The consignor has collected.** Then the payout is the *only* record of how
    much the shop handed over for an article it no longer has sold, and that is
    exactly the sum it is now owed back — so it stays on the row, and
    ``consignment.consignor_receivable`` is what reads it. Zeroing it here is
    what used to happen, and it left a shop ten thousand dinars down with no
    screen, figure or report saying so.

    Either way the article is worth nothing to the shop while it sits there:
    ``StockUnit.stock_value`` answers zero for a consignment whatever its rate,
    so the bin, the ledger and the return's own allocation are unaffected.
    """
    if unit.consignor_payout_id is not None:
        return unit
    unit.incoming_rate = ZERO
    unit.save(update_fields=["incoming_rate", "updated_at"])
    return unit


def resend_sale_sms(unit, *, settings=None):
    """Re-queue the "your goods sold" message.

    Idempotent by construction — the dedup key is the unit and the order — so a
    cashier who taps it twice queues one message, and one that failed
    terminally is re-sendable by cancelling the old row first.
    """
    order = getattr(unit.sold_order_line, "order", None)
    if order is None:
        raise serializers.ValidationError(
            {"detail": "لم تُبع هذه الأمانة بعد."}
        )
    return figures.notify_consignor_of_sale(unit, order, settings=settings)


__all__ = [
    "agreement_is_closed",
    "buy_in_returned_consignment",
    "disburse_payout",
    "reopen_consignment",
    "resend_sale_sms",
    "return_to_consignor",
    "submit_agreement",
    "take_into_consignment",
]
