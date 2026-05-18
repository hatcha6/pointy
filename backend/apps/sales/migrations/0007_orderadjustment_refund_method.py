from django.db import migrations, models


class Migration(migrations.Migration):
    dependencies = [
        ("sales", "0006_order_adjustments"),
    ]

    operations = [
        migrations.AddField(
            model_name="orderadjustment",
            name="refund_method",
            field=models.CharField(default="cash", max_length=16),
        ),
    ]
