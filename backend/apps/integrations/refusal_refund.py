"""Give back what a refused provider line was paid, in the drawer that took it.

A sale's provider lines are paid at checkout and performed straight after
(:mod:`.recharge`). When the provider definitely refuses one — an empty float,
a moved price, a card out of stock, an outright "no" — nothing was delivered
and the till tells the cashier the customer's money goes back. Until this
module, nothing recorded that it did: the sale stayed paid, the drawer kept
expecting the money, and a cashier who rang the card up again after each
refusal left one undelivered sale per attempt behind.

Annaseem, 2026-10-11: eight PUBG cards at 1,919 د.ل refused by Qareeb in a row
(``checkout answered 400``), each rung up again; the drawer closed 15,352 د.ل
short of what it "expected", and a manager voiding them that night put the
refunds into *their own* open drawer instead.

So a refusal now returns its line at once, through the ordinary return path
(stock, tenders, the drawer's ``cash_refund_total``), into the session that sold
it. ``created_by`` stays empty on purpose: the system gave the money back, not
the cashier, and the fraud metrics count returns by who made them.

Only a definite refusal. An unknown outcome may have spent the float, and is
never refunded here — reconciliation settles it against the provider's log.
"""

from __future__ import annotations

import logging
from decimal import Decimal

from django.db import transaction
from rest_framework import serializers

from .models import IntegrationFulfillment
from .recharge import OUTCOME_REFUSED

logger = logging.getLogger(__name__)

#: The adjustment's reason, as the invoice's history shows it.
REFUSAL_REFUND_REASON = "لم ينفّذ المزوّد العملية — أُعيد المبلغ تلقائياً"


def refund_refused(outcomes) -> dict[int, Decimal]:
    """Return every refused line in ``outcomes``; ``{order_line_id: amount}``.

    A line that cannot be given back here — a credit sale still open, a drawer
    already closed, a line already returned — is left as it was and logged:
    a refund is never worth failing the till's charge call over.
    """
    lines_by_order: dict[int, list[int]] = {}
    for outcome in outcomes:
        row = outcome.fulfillment
        if outcome.outcome != OUTCOME_REFUSED or row is None:
            continue
        lines_by_order.setdefault(row.order_line.order_id, []).append(
            row.order_line_id
        )

    refunded: dict[int, Decimal] = {}
    for order_id, line_ids in lines_by_order.items():
        try:
            refunded.update(_refund_order_lines(order_id, line_ids))
        except serializers.ValidationError as exc:
            logger.warning(
                "refused provider lines %s of order %s not refunded: %s",
                line_ids,
                order_id,
                exc.detail,
            )
    return refunded


def _refund_order_lines(order_id: int, line_ids: list[int]) -> dict[int, Decimal]:
    from apps.sales.models import Order, RegisterSession
    from apps.sales.services import line_refund_amount, return_order_items

    with transaction.atomic():
        order = (
            Order.objects.select_for_update(of=("self",))
            .select_related("register_session")
            .get(pk=order_id)
        )
        session = order.register_session
        # A paid sale in a drawer that is still counting. A credit sale owes
        # nothing back in cash, and a closed drawer is not this one's to change.
        if (
            order.status != Order.Status.PAID
            or session is None
            or session.status != RegisterSession.Status.OPEN
        ):
            return {}
        # Refused for good: a refusal is final (``recharge``), so nothing in
        # between can have charged it.
        unperformed = set(
            IntegrationFulfillment.objects.filter(
                order_line_id__in=line_ids,
                status=IntegrationFulfillment.Status.FAILED,
            ).values_list("order_line_id", flat=True)
        )
        lines = [
            (line, line.returnable_quantity)
            for line in order.lines.filter(pk__in=unperformed).order_by("pk")
            if line.returnable_quantity > 0
        ]
        if not lines:
            return {}
        amounts = {
            line.pk: line_refund_amount(line, quantity) for line, quantity in lines
        }
        return_order_items(
            order=order,
            lines=lines,
            reason=REFUSAL_REFUND_REASON,
            request=None,
            register_session=session,
        )
    return amounts
