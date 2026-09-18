"""Buying a handset and selling one, in a single act across the counter.

A trade-in is a **purchase and a sale in one transaction**, which is exactly how
``OrderExchange`` already frames a return-and-replace: two real, independently
correct documents, linked by a row that records the net the customer settled.
Building it that way rather than as a new kind of tender is what keeps revenue,
COGS, stock, the drawer and every report working without learning a new word.

The money, precisely. The shop records:

* a counter purchase of the incoming article at the agreed value, paid from the
  drawer like any POS cash purchase, and
* the sale, settled in full.

Physically the customer hands over the difference, and that is exactly what the
drawer ends up expecting: ``RegisterSession.expected_cash`` nets pay-outs
against sales, so a 1,400 sale against a 500 trade-in leaves the till expecting
900 more than it started with — one net movement, arrived at from two documents
that are each true on their own.
"""

from __future__ import annotations

from decimal import Decimal

from django.db import transaction
from rest_framework import serializers


@transaction.atomic
def record_trade_in(*, purchase_payload, checkout, request):
    """Take the old article in, sell the new one, and link the two.

    ``purchase_payload`` is a validated ``PurchaseOrderSerializer`` payload —
    one supplier (the customer selling their handset), one line, the agreed
    value as its cost, and the identifier captured on the line. ``checkout`` is
    the validated sale, run afterwards so a refused sale takes the purchase down
    with it.
    """
    from apps.purchasing.services import create_pos_cash_purchase

    purchase_order = create_pos_cash_purchase(
        request=request, validated_data=purchase_payload
    )
    order = checkout()
    _link(purchase_order, order, request=request)
    return purchase_order, order


def _link(purchase_order, order, *, request):
    from apps.sales.models import TradeIn

    return TradeIn.objects.create(
        purchase_order=purchase_order,
        order=order,
        register_session=order.register_session,
        trade_in_amount=purchase_order.total,
        sale_amount=order.total,
        net_amount=order.total - purchase_order.total,
        created_by=(
            request.user
            if getattr(getattr(request, "user", None), "is_authenticated", False)
            else None
        ),
    )


def refuse_trade_in_above_sale(*, trade_in_total, sale_total):
    """A trade-in worth more than the sale is a cash refund wearing a hat.

    Refused rather than handled: paying a customer the difference in cash for
    goods the shop has not resold is a decision with its own risks — it is how a
    till is emptied by somebody bringing in stolen handsets — and it belongs in
    a counter purchase the shop makes deliberately, not in the tail of a sale.
    """
    if Decimal(trade_in_total) > Decimal(sale_total):
        raise serializers.ValidationError(
            {
                "trade_in": (
                    "قيمة الجهاز المستبدل أكبر من قيمة الفاتورة. "
                    "سجّل شراءً نقديًا منفصلًا."
                )
            }
        )


__all__ = ["record_trade_in", "refuse_trade_in_above_sale"]
