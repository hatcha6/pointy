"""Continue the receipt series from where it already is.

The numbers a shop has written in its ledger do not change. This only tells the
new counter where the existing series got to, so the first receipt issued after
the upgrade is the next one, not the first one.

Seeded from the highest number the series has actually reached — the largest
order id, and the largest trailing number on any existing receipt, whichever is
higher. The second is not paranoia: an imported or hand-corrected receipt can
carry a number that never came from an id, and `receipt_number` is unique, so a
counter that started below one of those would collide on a sale.
"""

from django.db import migrations

SALE_ORDER_SERIES = "sale_order"


def _trailing_number(receipt_number: str) -> int:
    """The counter part of ``R20260916798785``, or 0 if it is not that shape."""
    if not receipt_number.startswith("R"):
        return 0
    tail = receipt_number[9:]
    return int(tail) if tail.isdigit() else 0


def seed(apps, schema_editor):
    Order = apps.get_model("sales", "Order")
    DocumentNumberSeries = apps.get_model("documents", "DocumentNumberSeries")

    highest = Order.objects.order_by("-id").values_list("id", flat=True).first() or 0
    for receipt_number in (
        Order.objects.exclude(receipt_number="")
        .values_list("receipt_number", flat=True)
        .iterator(chunk_size=2000)
    ):
        highest = max(highest, _trailing_number(receipt_number))

    series, created = DocumentNumberSeries.objects.get_or_create(
        pk=SALE_ORDER_SERIES,
        defaults={"last_value": highest},
    )
    if not created and series.last_value < highest:
        series.last_value = highest
        series.save(update_fields=["last_value"])


def unseed(apps, schema_editor):
    # Leaving the row would be harmless, but removing it keeps a reversal
    # actually reversible: the old code reads the id, not this.
    apps.get_model("documents", "DocumentNumberSeries").objects.filter(
        pk=SALE_ORDER_SERIES
    ).delete()


class Migration(migrations.Migration):
    dependencies = [
        ("sales", "0032_move_credit_due_date_off_valid_until"),
        ("documents", "0002_documentnumberseries"),
    ]

    operations = [migrations.RunPython(seed, unseed)]
