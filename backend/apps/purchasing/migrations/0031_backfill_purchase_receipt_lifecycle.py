"""Every delivery already recorded is one that already arrived."""

from django.db import migrations


def backfill(apps, schema_editor):
    PurchaseReceipt = apps.get_model("purchasing", "PurchaseReceipt")
    PurchaseReceipt.objects.exclude(doc_status="submitted").update(
        doc_status="submitted"
    )


def unbackfill(apps, schema_editor):
    """Nothing to undo: the column this wrote is dropped by the migration that
    added it."""


class Migration(migrations.Migration):
    dependencies = [
        ("purchasing", "0030_backfill_supplier_payment_lifecycle"),
    ]

    operations = [
        migrations.RunPython(backfill, unbackfill),
    ]
