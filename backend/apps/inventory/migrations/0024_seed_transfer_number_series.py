"""Continue the stock-transfer series from where it already is.

A transfer number is how a count discrepancy is traced back to the movement
that caused it, so the existing numbers must keep meaning what they meant. This
only tells the new counter where the series got to.

Seeded from the highest number the series has reached — the largest transfer id
or the largest trailing number on an existing transfer number, whichever is
higher, because `transfer_number` is unique and a low seed would refuse a
transfer.
"""

from django.db import migrations

STOCK_TRANSFER_SERIES = "stock_transfer"


def _trailing_number(transfer_number: str) -> int:
    """The counter part of ``T20260916000123``, or 0 if it is not that shape."""
    if not transfer_number.startswith("T"):
        return 0
    tail = transfer_number[9:]
    return int(tail) if tail.isdigit() else 0


def seed(apps, schema_editor):
    StockTransfer = apps.get_model("inventory", "StockTransfer")
    DocumentNumberSeries = apps.get_model("documents", "DocumentNumberSeries")

    highest = (
        StockTransfer.objects.order_by("-id").values_list("id", flat=True).first() or 0
    )
    for transfer_number in (
        StockTransfer.objects.exclude(transfer_number="")
        .values_list("transfer_number", flat=True)
        .iterator(chunk_size=2000)
    ):
        highest = max(highest, _trailing_number(transfer_number))

    series, created = DocumentNumberSeries.objects.get_or_create(
        pk=STOCK_TRANSFER_SERIES,
        defaults={"last_value": highest},
    )
    if not created and series.last_value < highest:
        series.last_value = highest
        series.save(update_fields=["last_value"])


def unseed(apps, schema_editor):
    apps.get_model("documents", "DocumentNumberSeries").objects.filter(
        pk=STOCK_TRANSFER_SERIES
    ).delete()


class Migration(migrations.Migration):
    dependencies = [
        ("inventory", "0023_warehouse_required"),
        ("documents", "0002_documentnumberseries"),
    ]

    operations = [migrations.RunPython(seed, unseed)]
