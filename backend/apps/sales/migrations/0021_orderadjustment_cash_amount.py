from django.db import migrations, models


def backfill_cash_amount(apps, schema_editor):
    """Historically a refund's drawer impact was the full ``amount`` when
    ``refund_method`` was cash, and 0 otherwise. Reproduce that exactly so
    register reconciliation for existing sessions is unchanged."""
    OrderAdjustment = apps.get_model("sales", "OrderAdjustment")
    OrderAdjustment.objects.filter(refund_method="cash").update(
        cash_amount=models.F("amount")
    )
    OrderAdjustment.objects.exclude(refund_method="cash").update(cash_amount=0)


def noop_reverse(apps, schema_editor):
    pass


class Migration(migrations.Migration):
    dependencies = [
        ("sales", "0020_alter_order_created_at_and_more"),
    ]

    operations = [
        migrations.AddField(
            model_name="orderadjustment",
            name="cash_amount",
            field=models.DecimalField(decimal_places=2, default=0, max_digits=10),
        ),
        migrations.RunPython(backfill_cash_amount, noop_reverse),
    ]
