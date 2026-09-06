"""Every expense that already exists is one that was already spent."""

from django.db import migrations


def backfill(apps, schema_editor):
    Expense = apps.get_model("expenses", "Expense")
    Expense.objects.exclude(doc_status="submitted").update(doc_status="submitted")


def unbackfill(apps, schema_editor):
    """Nothing to undo: the column this wrote is dropped by the migration that
    added it."""


class Migration(migrations.Migration):
    dependencies = [
        ("expenses", "0004_expense_amended_from_expense_amendment_index_and_more"),
    ]

    operations = [
        migrations.RunPython(backfill, unbackfill),
    ]
