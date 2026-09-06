"""Every supplier payment that already exists is one that already happened."""

from django.db import migrations


def backfill(apps, schema_editor):
    SupplierPayment = apps.get_model("purchasing", "SupplierPayment")
    SupplierPayment.objects.exclude(doc_status="submitted").update(
        doc_status="submitted"
    )


def unbackfill(apps, schema_editor):
    """Nothing to undo: the column this wrote is dropped by the migration that
    added it."""


class Migration(migrations.Migration):
    dependencies = [
        ("purchasing", "0029_backfill_purchase_order_lifecycle"),
    ]

    operations = [
        migrations.RunPython(backfill, unbackfill),
    ]
