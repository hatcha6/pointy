"""One-off repair of Annaseem's drawers after the refused cards of 2026-10-11.

At 10:48–10:58 a cashier sold eight «ببجي 16200 UC» cards (1,919 د.ل each) in
RS-36; Qareeb refused every one, each was rung up again, and nothing gave the
money back, so RS-36 closed 15,352 د.ل short of what it "expected". At 22:52 a
manager voided the eight from their own open drawer, RS-25 — booking a cash
refund out of RS-25 that never happened, and leaving RS-36 still short. At
22:48 the owner's own sale of a 20 د.ل «كروت دفتر» card (R20261011000526) was
refused too («رصيد الكروت» was empty) and stayed a paid sale in RS-25.

1. The eight void adjustments move to RS-36: no money moved at 22:52, it had
   never stayed in RS-36. RS-36 then reads what was counted, RS-25 what it holds.
2. The refused card is given back in RS-25, the drawer that sold it — what the
   till now does by itself the moment a provider refuses
   (``apps.integrations.refusal_refund``).

Runs after every migrate (``post_migrate``, like :mod:`.reconciliation`) so the
void goes through the app's own code against the current schema, never a
copy of it. Does nothing anywhere but that installation, and nothing to a row
that no longer matches every fingerprint; once done, every later run finds
nothing to do. A drawer's expected cash is worked out from its records each time
it is read, so a drawer closed before the update is put right all the same.

Safe to delete once Annaseem has run a release that carries it.
"""

from __future__ import annotations

import logging
from decimal import Decimal

from django.db import transaction
from django.db.models.signals import post_migrate
from django.dispatch import receiver

logger = logging.getLogger(__name__)

ANNASEEM = "208266c8-10c9-471f-b68f-8152a74f8600"
SOLD_IN = 36
VOIDED_IN = 25
CARD_AMOUNT = Decimal("1919.00")
CARD_RECEIPTS = (
    "R20261011000487",
    "R20261011000488",
    "R20261011000489",
    "R20261011000492",
    "R20261011000493",
    "R20261011000494",
    "R20261011000495",
    "R20261011000496",
)
REFUSED_DAFTAR_CARD = "R20261011000526"
REFUSED_DAFTAR_TOTAL = Decimal("20.00")
REASON = "لم ينفّذ المزوّد العملية — أُعيد المبلغ (تصحيح 2026-10-11)"


def is_annaseem() -> bool:
    from apps.core.models import RelayInstallation

    return RelayInstallation.objects.filter(installation_id=ANNASEEM).exists()


def move_card_voids_to_their_drawer() -> int:
    """Step 1. Returns how many void adjustments moved."""
    from apps.sales.models import OrderAdjustment

    return OrderAdjustment.objects.filter(
        adjustment_type=OrderAdjustment.AdjustmentType.VOID,
        register_session_id=VOIDED_IN,
        amount=CARD_AMOUNT,
        order__receipt_number__in=CARD_RECEIPTS,
        order__register_session_id=SOLD_IN,
        order__status="void",
    ).update(register_session_id=SOLD_IN)


def give_back_refused_daftar_card() -> bool:
    """Step 2. True when the refused card's sale was given back now."""
    from apps.integrations.models import IntegrationFulfillment
    from apps.sales.models import Order
    from apps.sales.services import void_order

    order = Order.objects.filter(
        receipt_number=REFUSED_DAFTAR_CARD,
        register_session_id=VOIDED_IN,
        status=Order.Status.PAID,
        total=REFUSED_DAFTAR_TOTAL,
    ).first()
    if order is None:
        return False
    # Only while nothing was ever delivered for it: never a card the customer has.
    delivered = IntegrationFulfillment.objects.filter(order_line__order=order).exclude(
        status__in=(
            IntegrationFulfillment.Status.PENDING,
            IntegrationFulfillment.Status.FAILED,
        )
    )
    if delivered.exists() or not IntegrationFulfillment.objects.filter(
        order_line__order=order
    ).exists():
        return False
    with transaction.atomic():
        void_order(
            order=order,
            reason=REASON,
            request=None,
            register_session=order.register_session,
        )
    return True


def repair() -> dict:
    if not is_annaseem():
        return {}
    moved = move_card_voids_to_their_drawer()
    given_back = give_back_refused_daftar_card()
    if moved or given_back:
        logger.warning(
            "annaseem repair: moved %s card voids to RS-%s; refused Daftar card given back: %s",
            moved,
            SOLD_IN,
            given_back,
        )
    return {"moved": moved, "given_back": given_back}


@receiver(post_migrate)
def _repair_after_migrate(sender, **kwargs):
    if getattr(sender, "label", None) != "sales":
        return
    try:
        repair()
    except Exception:  # noqa: BLE001 - a repair must never break a migrate
        logger.exception("annaseem repair failed; the next boot tries again")
