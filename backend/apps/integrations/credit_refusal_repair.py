"""Strike off the debts left by refused cards sold on account, before the fix.

Until 2026-11-07 a provider's refusal gave a line back only on a paid sale
(:mod:`.refusal_refund`). A card sold on a credit invoice — a cashier buying on
their own staff account, a customer's tab — stayed owed, so payroll took a
card nobody received out of the cashier's wages. Annaseem, 2026-11-05 and
2026-11-07: three Qareeb cards on one staff account, 90 د.ل in all.

Runs after every migrate (``post_migrate``, like ``apps.sales.reconciliation``)
so the return goes through the app's own code against the current schema.
Touches only what the fixed charge would have done itself: a failed provider
line, never returned, on a credit invoice still owed — and only off the debt,
never as money out of a drawer. Once done, every later run finds nothing to do.

An invoice that payroll has already settled is not an open debt any more; it
is logged, not changed, because the wage it took has been paid out.
"""

from __future__ import annotations

import logging

from django.db.models.signals import post_migrate
from django.dispatch import receiver

logger = logging.getLogger(__name__)


def _refused_lines_on_account():
    from apps.sales.models import Order

    from .models import IntegrationFulfillment

    return (
        IntegrationFulfillment.objects.filter(
            status=IntegrationFulfillment.Status.FAILED,
            order_line__order__sale_type=Order.SaleType.CREDIT,
            order_line__adjustment_lines__isnull=True,
        )
        .select_related("order_line__order")
        .order_by("pk")
    )


def repair() -> dict:
    from apps.sales.models import Order

    from . import recharge, refusal_refund

    open_rows, settled = [], []
    for row in _refused_lines_on_account():
        if row.order_line.order.status == Order.Status.OPEN:
            open_rows.append(row)
        elif row.order_line.order.status == Order.Status.PAID:
            settled.append(row.order_line.order.receipt_number)
    refunds = refusal_refund.refund_refused(
        [
            recharge.ChargeOutcome(outcome=recharge.OUTCOME_REFUSED, fulfillment=row)
            for row in open_rows
        ]
    )
    if refunds.amounts:
        logger.warning(
            "credit refusal repair: %s refused lines struck off their debt (%s)",
            len(refunds.amounts),
            sum(refunds.amounts.values()),
        )
    if settled:
        logger.warning(
            "credit refusal repair: refused cards on already-settled credit "
            "invoices, left for the owner: %s",
            ", ".join(sorted(set(settled))),
        )
    return {"struck_off": refunds.amounts, "settled": sorted(set(settled))}


@receiver(post_migrate)
def _repair_after_migrate(sender, **kwargs):
    if getattr(sender, "label", None) != "integrations":
        return
    try:
        repair()
    except Exception:  # noqa: BLE001 - a repair must never break a migrate
        logger.exception("credit refusal repair failed; the next boot tries again")
