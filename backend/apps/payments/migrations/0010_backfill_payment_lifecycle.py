"""Every payment that already exists is one that already happened.

There is no draft state for money changing hands, so this is the whole
migration: one column, one value.
"""

from django.db import migrations


def backfill(apps, schema_editor):
    Payment = apps.get_model("payments", "Payment")
    Payment.objects.exclude(doc_status="submitted").update(doc_status="submitted")


def unbackfill(apps, schema_editor):
    """Nothing to undo: the column this wrote is dropped by the migration that
    added it."""


class Migration(migrations.Migration):
    dependencies = [
        ("payments", "0009_payment_amended_from_payment_amendment_index_and_more"),
    ]

    operations = [
        migrations.RunPython(backfill, unbackfill),
    ]
