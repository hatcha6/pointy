"""Give credit invoices their due date back as a column of its own.

``valid_until`` meant two things: when a quotation's offer (and its stock hold)
lapses, and when a credit invoice is to be settled. The lapse sweep and the debt
sweep were reading the same column for opposite purposes, and the frontend had
already given up and called it ``creditDueDate`` in its own copy.

This moves the credit half to ``due_date`` and clears the source, so that after
it runs a credit invoice's due date lives in exactly one place. Clearing matters
as much as copying: leaving both populated would let the live-update
reconciliation (``apps.sales.reconciliation``) resurrect a due date a user had
deliberately cleared.

Quotations are untouched — ``valid_until`` keeps its one remaining meaning.
"""

from django.db import migrations, models


def move_due_dates(apps, schema_editor):
    Order = apps.get_model("sales", "Order")
    Order.objects.filter(sale_type="credit", valid_until__isnull=False).update(
        due_date=models.F("valid_until"), valid_until=None
    )


def restore_due_dates(apps, schema_editor):
    """Reverse cleanly: a rollback puts the dates back where the old code reads
    them. Without this, rolling back a release would silently blind the debt
    reminder to every due date the shop had recorded."""
    Order = apps.get_model("sales", "Order")
    Order.objects.filter(sale_type="credit", due_date__isnull=False).update(
        valid_until=models.F("due_date"), due_date=None
    )


class Migration(migrations.Migration):
    dependencies = [
        ("sales", "0031_order_due_date_order_sales_order_credit_due_idx"),
    ]

    operations = [
        migrations.RunPython(move_due_dates, restore_due_dates),
    ]
