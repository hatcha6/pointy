from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("sales", "0009_orderline_unit_cost"),
    ]

    operations = [
        migrations.AddField(
            model_name="order",
            name="discount_total",
            field=models.DecimalField(decimal_places=2, default=0, max_digits=10),
        ),
        migrations.AddField(
            model_name="orderline",
            name="discount_total",
            field=models.DecimalField(decimal_places=2, default=0, max_digits=10),
        ),
        migrations.AddField(
            model_name="orderadjustmentline",
            name="discount_total",
            field=models.DecimalField(decimal_places=2, default=0, max_digits=10),
        ),
    ]
