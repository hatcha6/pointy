"""Give every stock count the lifecycle its status implied.

Counting is the draft; applying is the submission. The count's own
``applied_at`` stamp becomes the lifecycle's ``submitted_at``, so the two do not
start out disagreeing.
"""

from django.db import migrations
from django.db.models import F


def backfill(apps, schema_editor):
    StockCount = apps.get_model("inventory", "StockCount")
    StockCount.objects.filter(status="applied").update(doc_status="submitted")
    StockCount.objects.filter(status="cancelled").update(doc_status="cancelled")
    StockCount.objects.filter(status="in_progress").update(doc_status="draft")
    # One statement: a shop that counts its shelves weekly has a lot of these.
    StockCount.objects.filter(status="applied", applied_at__isnull=False).update(
        submitted_at=F("applied_at"), submitted_by_id=F("applied_by_id")
    )


def unbackfill(apps, schema_editor):
    """Nothing to undo: the columns this wrote are dropped by the migration
    that added them."""


class Migration(migrations.Migration):
    dependencies = [
        ("inventory", "0016_stockcount_amended_from_stockcount_amendment_index_and_more"),
    ]

    operations = [
        migrations.RunPython(backfill, unbackfill),
    ]
