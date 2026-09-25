"""What a register session sold for outside providers, and where the money went.

A top-up is two events that must not be confused (see
:class:`~apps.integrations.models.IntegrationFulfillment`): the shop **sold** it
— the customer's money is in the drawer — and the provider **performed** it,
taking its cost out of the agency float. A shift review that showed only the
first would let a manager count the drawer against the sales and call the
shift clean while a customer's renewal never happened, or while a recharge the
provider had already performed was refunded over the counter and the float
paid for it anyway.

So every provider line a session rang up lands in exactly one bucket:

``delivered``  Kept, and the provider confirmed it. The customer's money is the
               shop's to keep; the provider's share has left the float.
``awaiting``   Kept, and the provider has not performed it — never sent, or
               refused (an empty float is the usual reason). The customer has
               paid for something they have not received yet.
``unknown``    Kept, sent, and nobody knows what happened. The float may or may
               not have paid. Must not be retried; somebody has to look.
``refunded``   The sale was voided or the line given back. The customer has the
               money again — and if the provider had already performed it, the
               float paid for a sale the shop no longer has. That case is
               counted on its own (``refunded_after_delivery``), because it is
               the one no other report shows: a voided sale restocks goods, but
               a performed top-up cannot come back.

The bucket codes are API contract, like the provider keys: add, never rename.
The Arabic lives in the Flutter layer.

Attribution follows the register summary's sales figures: a line belongs to the
session that *issued* its order, whenever it was later refunded.
"""

from __future__ import annotations

from decimal import Decimal

from . import catalog
from .fulfillment import fulfillment_kind
from .models import IntegrationFulfillment

MONEY = Decimal("0.01")
ZERO = Decimal("0.00")

BUCKET_DELIVERED = "delivered"
BUCKET_AWAITING = "awaiting"
BUCKET_UNKNOWN = "unknown"
BUCKET_REFUNDED = "refunded"
BUCKETS = (BUCKET_DELIVERED, BUCKET_AWAITING, BUCKET_UNKNOWN, BUCKET_REFUNDED)

#: The buckets whose money the shop still holds — everything but refunds.
KEPT_BUCKETS = (BUCKET_DELIVERED, BUCKET_AWAITING, BUCKET_UNKNOWN)


def _money(value) -> str:
    return str((value or ZERO).quantize(MONEY))


def bucket_for(status: str, *, refunded: bool) -> str:
    """Which bucket one sold provider line belongs in."""
    if refunded or status == IntegrationFulfillment.Status.CANCELLED:
        return BUCKET_REFUNDED
    if status == IntegrationFulfillment.Status.CONFIRMED:
        return BUCKET_DELIVERED
    if status == IntegrationFulfillment.Status.SUBMITTED:
        return BUCKET_UNKNOWN
    # ``pending`` — never sent, or refused and put back — and ``failed``: the
    # customer paid and the provider did nothing, whatever the reason.
    return BUCKET_AWAITING


def build_integration_breakdown(orders) -> dict:
    """Per-provider money and every provider transaction on ``orders``.

    ``orders`` is the session's transactional orders (recognized sales plus
    their voids): which orders count is the sales app's call, what their
    provider lines mean is this one's. Two queries whatever the size of the
    shift — the lines with their order and fulfillment, and the refund lines
    that say whether each was given back.
    """
    from apps.sales.models import Order, OrderLine

    lines = (
        OrderLine.objects.filter(
            order__in=orders, integration_fulfillment__isnull=False
        )
        .select_related("order", "integration_fulfillment__subscriber__customer")
        .prefetch_related("adjustment_lines")
        .order_by("order__created_at", "order_id", "id")
    )

    transactions = []
    rollups: dict[str, dict] = {}
    for line in lines:
        fulfillment = line.integration_fulfillment
        order = line.order
        refund_lines = list(line.adjustment_lines.all())
        refunded = order.status == Order.Status.VOID or bool(refund_lines)
        bucket = bucket_for(fulfillment.status, refunded=refunded)
        price = line.line_total
        # What the customer got back. A void always writes refund lines, so the
        # fallback only covers a sale voided by some path that did not.
        refunded_amount = (
            sum((row.line_total for row in refund_lines), ZERO)
            if refund_lines
            else price
        )
        amount = refunded_amount if bucket == BUCKET_REFUNDED else price
        cost = fulfillment.cost or ZERO

        rollup = rollups.get(fulfillment.provider)
        if rollup is None:
            rollup = rollups[fulfillment.provider] = _empty_rollup()
        _add(rollup, bucket, amount=amount, cost=cost)
        if (
            bucket == BUCKET_REFUNDED
            and fulfillment.status == IntegrationFulfillment.Status.CONFIRMED
        ):
            rollup["refunded_after_delivery"]["count"] += 1
            rollup["refunded_after_delivery"]["cost"] += cost

        subscriber = fulfillment.subscriber
        transactions.append(
            {
                "id": fulfillment.pk,
                "provider": fulfillment.provider,
                "kind": fulfillment_kind(fulfillment),
                "order_id": order.pk,
                "receipt_number": order.receipt_number or "",
                "sold_at": order.created_at.isoformat() if order.created_at else None,
                "subscriber_ref": fulfillment.subscriber_ref,
                "subscriber_label": subscriber.label if subscriber else "",
                "option_label": fulfillment.option_label,
                "price": _money(price),
                "cost": _money(cost),
                "refunded_amount": _money(
                    refunded_amount if bucket == BUCKET_REFUNDED else ZERO
                ),
                "status": fulfillment.status,
                "bucket": bucket,
                "error_code": fulfillment.last_error_code,
                "provider_reference": fulfillment.provider_reference,
            }
        )

    totals = _empty_rollup()
    providers = []
    for key in _provider_order(rollups):
        rollup = rollups[key]
        _merge(totals, rollup)
        providers.append({"provider": key, **_render(rollup)})
    return {
        "providers": providers,
        "totals": _render(totals),
        "transactions": transactions,
    }


def _provider_order(rollups: dict) -> list[str]:
    """The catalog's order, so a provider keeps its place from shift to shift;
    anything the catalog no longer lists goes last rather than vanishing."""
    known = [spec.key for spec in catalog.PROVIDERS if spec.key in rollups]
    return known + sorted(key for key in rollups if key not in known)


def _empty_rollup() -> dict:
    return {
        **{bucket: {"count": 0, "amount": ZERO, "cost": ZERO} for bucket in BUCKETS},
        "refunded_after_delivery": {"count": 0, "cost": ZERO},
    }


def _add(rollup: dict, bucket: str, *, amount: Decimal, cost: Decimal) -> None:
    rollup[bucket]["count"] += 1
    rollup[bucket]["amount"] += amount
    rollup[bucket]["cost"] += cost


def _merge(into: dict, rollup: dict) -> None:
    for key, figures in rollup.items():
        for field, value in figures.items():
            into[key][field] += value


def _render(rollup: dict) -> dict:
    """Headline figures over the kept sales, then every bucket as sent."""
    sold = sum((rollup[bucket]["amount"] for bucket in KEPT_BUCKETS), ZERO)
    cost = sum((rollup[bucket]["cost"] for bucket in KEPT_BUCKETS), ZERO)
    return {
        "count": sum(rollup[bucket]["count"] for bucket in KEPT_BUCKETS),
        # What customers paid for the provider's services and kept.
        "sold": _money(sold),
        # The provider's share of that — already out of the float for the
        # delivered ones, still owed for the rest.
        "cost": _money(cost),
        # What the shop keeps once every kept sale is delivered.
        "margin": _money(sold - cost),
        **{
            bucket: {
                "count": rollup[bucket]["count"],
                "amount": _money(rollup[bucket]["amount"]),
                "cost": _money(rollup[bucket]["cost"]),
            }
            for bucket in BUCKETS
        },
        "refunded_after_delivery": {
            "count": rollup["refunded_after_delivery"]["count"],
            "cost": _money(rollup["refunded_after_delivery"]["cost"]),
        },
    }
