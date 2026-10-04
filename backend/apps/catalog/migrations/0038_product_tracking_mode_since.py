"""When a product's current tracking mode began, and which stretch it is in.

The integrity checks judge history by the mode it was written under, not by
today's: ``tracking_mode_since`` is when the current mode began (and, while the
mode is ``serial_batch``, when lots became required — the allocation guard
reads it to let a grandfathered unit leave without a lot, §4.2), and
``tracking_since`` now marks the current stretch of being tracked rather than
the first one ever.

Expand-only and safe across a live update: a nullable column with no default,
so the release still running during the flip inserts products without it.

Nobody can say when an existing product's mode began, so every tracked product
is stamped now: history written before this migration is held only to what is
true in every mode, and every unit on a ``serial_batch`` shelf today counts as
born before lots were required. Products counted by quantity lose a
``tracking_since`` left over from a stretch that has ended, so switching them on
again starts a new one.
"""

from django.db import migrations, models
from django.utils import timezone


def stamp_existing_products(apps, schema_editor):
    Product = apps.get_model("catalog", "Product")
    Product.objects.exclude(tracking_mode="quantity").filter(
        tracking_mode_since__isnull=True
    ).update(tracking_mode_since=timezone.now())
    Product.objects.filter(
        tracking_mode="quantity", tracking_since__isnull=False
    ).update(tracking_since=None)


class Migration(migrations.Migration):

    dependencies = [
        ("catalog", "0037_searchmiss"),
    ]

    operations = [
        migrations.AddField(
            model_name="product",
            name="tracking_mode_since",
            field=models.DateTimeField(blank=True, editable=False, null=True),
        ),
        migrations.RunPython(stamp_existing_products, migrations.RunPython.noop),
    ]
