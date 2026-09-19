"""When a lot has to come back off the shelves.

§6.8.1. In a regulated trade — pharmacy, packaged food, cosmetics — a
manufacturer, a distributor or a health authority issues an urgent recall, and
the shop has minutes rather than days. Three things have to happen and this
module is the second and third of them:

1. **Stop-sale** is one write on the lot identity, and it already exists:
   ``StockBatch.save`` propagates ``is_locked`` onto every balance in the same
   transaction, so there is no window in which one branch is quarantined and
   another is still selling. Under a warehouse-scoped batch table that was N
   writes with N chances to miss one, on the operation where missing one is the
   whole problem (§4.7).
2. **The audit** — where this lot came from, where its goods are now, and who
   walked out with the rest. One query per question, all of them against one
   lot, because the lot is one row however many places its goods have been.
3. **The alert** — a transactional SMS to every customer on file who bought
   from it, deduplicated so tapping the button twice does not message a
   frightened customer twice.

Under ``serial_batch`` the outward list narrows to **individual serials**,
which is what saleable-return verification under DSCSA/FMD-style rules
actually needs, and what lets a pharmacist tell a customer whether *their* box
is the recalled one.
"""

from __future__ import annotations

from decimal import Decimal

from django.db import transaction
from .models import StockAllocation, StockBatch

ZERO = Decimal("0")

#: The alert a customer receives. Short on purpose: it has to be readable on a
#: feature phone, and the only actions it asks for are *stop using it* and
#: *come in*.
RECALL_SMS_TEMPLATE = (
    "تنبيه هام من {shop_name}:\n"
    "نرجو التوقف عن استخدام المنتج {product_name} (دفعة رقم {batch_code}) "
    "ومراجعة أقرب فرع فوراً للاسترجاع واسترداد كامل القيمة.\n"
    "للاستفسار: {shop_phone}."
)


def lot_family(batch):
    """This lot and every sub-lot repacking ever made from it.

    Genealogy is part of a recall, not a nicety: a pharmacy that repacked a
    drum into fifty bottles has fifty lots to find, and a report that swept
    only the drum would leave them on the shelf.
    """
    seen = {batch.pk}
    frontier = [batch.pk]
    while frontier:
        children = list(
            StockBatch.objects.filter(parent_batch_id__in=frontier)
            .exclude(pk__in=seen)
            .values_list("pk", flat=True)
        )
        if not children:
            break
        seen.update(children)
        frontier = children
    return list(StockBatch.objects.filter(pk__in=seen).select_related("variant"))


def inward_provenance(batches):
    """Where these goods came from: supplier, delivery, order, quantity."""
    rows = []
    for allocation in (
        StockAllocation.objects.filter(
            batch__in=batches, direction=StockAllocation.Direction.IN
        )
        .select_related("batch", "batch__supplier", "warehouse")
        .order_by("posting_at", "id")
    ):
        rows.append(
            {
                "batch": allocation.batch_id,
                "batch_code": allocation.batch.code,
                "supplier": allocation.batch.supplier_id,
                "supplier_name": getattr(
                    allocation.batch.supplier, "name", ""
                ),
                "received_at": allocation.posting_at,
                "quantity": allocation.quantity,
                "rate": allocation.rate,
                "warehouse": allocation.warehouse_id,
                "warehouse_name": allocation.warehouse.name,
                "voucher_type": allocation.voucher_type,
                "voucher_id": allocation.voucher_id,
            }
        )
    return rows


def remaining_stock(batches):
    """Every warehouse still holding any of it, and how much."""
    rows = []
    for batch in batches:
        for balance in batch.balances.select_related("warehouse").order_by(
            "-remaining_quantity", "id"
        ):
            if balance.remaining_quantity <= ZERO:
                continue
            rows.append(
                {
                    "batch": batch.pk,
                    "batch_code": batch.code,
                    "warehouse": balance.warehouse_id,
                    "warehouse_name": balance.warehouse.name,
                    "remaining": balance.remaining_quantity,
                    "is_sellable": balance.is_sellable,
                }
            )
    return rows


def outward_sales(batches):
    """Who walked out with the rest of it.

    One row per sale allocation, carrying the customer when the invoice named
    one and the **serial** when the pack had one — which is the difference
    between "your branch sold 40 boxes of this lot" and "this is the box".
    """
    from apps.sales.models import Order

    rows = []
    from .models import StockLedgerEntry

    allocations = list(
        StockAllocation.objects.filter(
            batch__in=batches,
            direction=StockAllocation.Direction.OUT,
            voucher_type=StockLedgerEntry.VoucherType.SALE,
        )
        .select_related("batch", "unit", "warehouse")
        .order_by("posting_at", "id")
    )
    order_ids = {row.voucher_id for row in allocations if row.voucher_id}
    orders = {
        order.pk: order
        for order in Order.objects.filter(pk__in=order_ids).select_related("customer")
    }
    for allocation in allocations:
        order = orders.get(allocation.voucher_id)
        rows.append(
            {
                "batch": allocation.batch_id,
                "batch_code": allocation.batch.code,
                "sold_at": allocation.posting_at,
                "quantity": allocation.quantity,
                "unit": allocation.unit_id,
                "unit_code": allocation.unit.code if allocation.unit_id else "",
                "order": allocation.voucher_id,
                "invoice_number": getattr(order, "receipt_number", ""),
                "customer": getattr(order, "customer_id", None),
                "customer_name": getattr(
                    getattr(order, "customer", None), "full_name", ""
                ),
                "customer_phone": getattr(
                    getattr(order, "customer", None), "phone", ""
                ),
                "warehouse": allocation.warehouse_id,
            }
        )
    return rows


def recall_report(batch):
    """Everything a recall needs, in one answer (§6.8.1 step 2)."""
    batches = lot_family(batch)
    sales = outward_sales(batches)
    reachable = {
        row["customer"]: row["customer_phone"]
        for row in sales
        if row["customer"] and row["customer_phone"]
    }
    return {
        "batch": batch.pk,
        "batch_code": batch.code,
        "variant": batch.variant_id,
        "product_name": batch.variant.full_name,
        "expiry_date": batch.expiry_date,
        "status": batch.status,
        "is_locked": batch.is_locked,
        "sub_lots": [
            {"id": row.pk, "code": row.code}
            for row in batches
            if row.pk != batch.pk
        ],
        "inward": inward_provenance(batches),
        "remaining": remaining_stock(batches),
        "outward": sales,
        "customers_reachable": len(reachable),
        "customers_unreachable": len(
            {row["customer"] for row in sales if row["customer"]}
        )
        - len(reachable),
        "walk_in_sales": len([row for row in sales if not row["customer"]]),
    }


@transaction.atomic
def notify_affected_customers(batch, *, settings=None, actor=None):
    """One tap, one message each, to everybody the shop can reach.

    Deduplicated per (recall, customer) rather than per message: a pharmacist
    who taps twice, or who recalls the drum and then its sub-lot, must not
    send a second frightening message to the same person about the same goods.
    """
    from apps.core.models import ShopSettings
    from apps.messaging import services as messaging
    from apps.messaging.models import MessagingGateway, OutboundMessage

    settings = settings or ShopSettings.load()
    report = recall_report(batch)
    shop_name = getattr(settings, "shop_name", "") or ""
    shop_phone = getattr(settings, "shop_phone", "") or ""
    body = RECALL_SMS_TEMPLATE.format(
        shop_name=shop_name,
        product_name=report["product_name"],
        batch_code=batch.code,
        shop_phone=shop_phone,
    )

    targets = {}
    for row in report["outward"]:
        if row["customer"] and row["customer_phone"]:
            targets[row["customer"]] = row["customer_phone"]

    queued, skipped = [], 0
    for customer_id, phone in sorted(targets.items()):
        try:
            message = messaging.enqueue_message(
                to=phone,
                body=body,
                consent_class=OutboundMessage.ConsentClass.TRANSACTIONAL,
                channel=MessagingGateway.Channel.SMS,
                dedup_key=f"recall_{batch.pk}_{customer_id}",
                source_type="batch_recall",
                source_id=batch.pk,
            )
        except messaging.NoGatewayConfigured:
            # No gateway is a shop configuration problem, not a reason to lose
            # the recall: the report still names everybody who bought one.
            skipped = len(targets) - len(queued)
            break
        queued.append(message.pk)
    return {
        "queued": len(queued),
        "skipped": skipped,
        "unreachable": report["customers_unreachable"],
        "walk_in_sales": report["walk_in_sales"],
        "message_ids": queued,
    }


__all__ = [
    "RECALL_SMS_TEMPLATE",
    "inward_provenance",
    "lot_family",
    "notify_affected_customers",
    "outward_sales",
    "recall_report",
    "remaining_stock",
]
