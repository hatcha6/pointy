from decimal import Decimal

import django.core.validators
from django.db import migrations, models
from django.db.models import Sum


def _backfill_cancelled_totals(apps, schema_editor):
    """Give existing orders the payable they should always have had.

    Before this field, an order that cancelled part of its shipment kept
    billing for the goods that never arrived — and nothing downstream could
    ever clear it, because cancelled units are not returnable. Those phantom
    payables are already sitting in shops' supplier balances, so recompute them
    here rather than only fixing orders received from now on.

    The arithmetic is ``purchase_order_cancelled_total``'s, restated against
    historical models: each line contributes its cancelled units' share of
    ``net_line_total``, multiplying before dividing so a fully cancelled line
    comes out exact.
    """
    PurchaseReceiptLine = apps.get_model("purchasing", "PurchaseReceiptLine")
    PurchaseOrder = apps.get_model("purchasing", "PurchaseOrder")

    cancelled_rows = (
        PurchaseReceiptLine.objects.filter(cancelled_quantity__gt=0)
        .values("purchase_line_id", "purchase_line__purchase_order_id")
        .annotate(total=Sum("cancelled_quantity"))
    )
    per_order = {}
    lines_seen = {}
    for row in cancelled_rows.iterator(chunk_size=2000):
        per_order.setdefault(row["purchase_line__purchase_order_id"], []).append(
            (row["purchase_line_id"], row["total"] or Decimal("0"))
        )
        lines_seen[row["purchase_line_id"]] = None
    if not per_order:
        return

    line_facts = {
        line["id"]: (
            line["quantity"] or Decimal("0"),
            line["net_line_total"] or Decimal("0.00"),
        )
        for line in apps.get_model("purchasing", "PurchaseOrderLine")
        .objects.filter(id__in=list(lines_seen))
        .values("id", "quantity", "net_line_total")
    }

    updates = []
    for order_id, rows in per_order.items():
        exact = Decimal("0")
        for line_id, cancelled in rows:
            ordered, net_line_total = line_facts.get(
                line_id, (Decimal("0"), Decimal("0.00"))
            )
            if ordered <= 0:
                continue
            capped = min(cancelled, ordered)
            if capped <= 0:
                continue
            exact += net_line_total * capped / ordered
        value = exact.quantize(Decimal("0.01"))
        if value > 0:
            updates.append(PurchaseOrder(id=order_id, cancelled_total=value))

    for start in range(0, len(updates), 500):
        PurchaseOrder.objects.bulk_update(
            updates[start : start + 500], ["cancelled_total"]
        )


def _noop_reverse(apps, schema_editor):
    """Nothing to undo: the column goes away with the AddField reversal."""


class Migration(migrations.Migration):

    dependencies = [
        ("purchasing", "0023_alter_purchaseorder_options_and_more"),
    ]

    operations = [
        migrations.AddField(
            model_name="purchaseorder",
            name="cancelled_total",
            field=models.DecimalField(
                decimal_places=2,
                default=Decimal("0.00"),
                max_digits=10,
                validators=[django.core.validators.MinValueValidator(Decimal("0.00"))],
            ),
        ),
        migrations.RunPython(_backfill_cancelled_totals, _noop_reverse),
    ]
