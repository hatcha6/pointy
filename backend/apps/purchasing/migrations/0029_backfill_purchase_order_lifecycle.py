"""Give every existing purchase order the lifecycle its progress implied.

One column, deterministically. No stock moves, no money moves, nothing is
recomputed: ``status`` was carrying two meanings and this migration copies out
the half that is about the document rather than the delivery.
"""

from django.db import migrations

PROGRESS_TO_LIFECYCLE = {
    "draft": "draft",
    "submitted": "submitted",
    "partially_received": "submitted",
    "received": "submitted",
    "cancelled": "cancelled",
}


def backfill(apps, schema_editor):
    PurchaseOrder = apps.get_model("purchasing", "PurchaseOrder")
    for progress, lifecycle in PROGRESS_TO_LIFECYCLE.items():
        PurchaseOrder.objects.filter(status=progress).exclude(
            doc_status=lifecycle
        ).update(doc_status=lifecycle)


def unbackfill(apps, schema_editor):
    """Nothing to undo: the columns this wrote are dropped by the migration
    that added them."""


class Migration(migrations.Migration):
    dependencies = [
        ("purchasing", "0028_purchaseorder_amended_from_and_more"),
    ]

    operations = [
        migrations.RunPython(backfill, unbackfill),
    ]
