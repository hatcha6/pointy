"""Continue the purchase-order series from where it already is.

The numbers a supplier has already been quoted do not change. This only tells
the new counter where the series got to, so the first order raised after the
upgrade is the next one, not the first one.

Seeded from the highest number the series has actually reached — the largest
order id, and the largest trailing number on any existing order number,
whichever is higher. The second is not paranoia: an imported or hand-corrected
order can carry a number that never came from an id, and `order_number` is
unique, so a counter that started below one of those would refuse a purchase.
"""

from django.db import migrations

PURCHASE_ORDER_SERIES = "purchase_order"


def _trailing_number(order_number: str) -> int:
    """The counter part of ``P20260916000123``, or 0 if it is not that shape."""
    if not order_number.startswith("P"):
        return 0
    tail = order_number[9:]
    return int(tail) if tail.isdigit() else 0


def seed(apps, schema_editor):
    PurchaseOrder = apps.get_model("purchasing", "PurchaseOrder")
    DocumentNumberSeries = apps.get_model("documents", "DocumentNumberSeries")

    highest = (
        PurchaseOrder.objects.order_by("-id").values_list("id", flat=True).first() or 0
    )
    for order_number in (
        PurchaseOrder.objects.exclude(order_number="")
        .values_list("order_number", flat=True)
        .iterator(chunk_size=2000)
    ):
        highest = max(highest, _trailing_number(order_number))

    series, created = DocumentNumberSeries.objects.get_or_create(
        pk=PURCHASE_ORDER_SERIES,
        defaults={"last_value": highest},
    )
    if not created and series.last_value < highest:
        series.last_value = highest
        series.save(update_fields=["last_value"])


def unseed(apps, schema_editor):
    apps.get_model("documents", "DocumentNumberSeries").objects.filter(
        pk=PURCHASE_ORDER_SERIES
    ).delete()


class Migration(migrations.Migration):
    dependencies = [
        ("purchasing", "0033_purchase_order_warehouse_required"),
        ("documents", "0002_documentnumberseries"),
    ]

    operations = [migrations.RunPython(seed, unseed)]
