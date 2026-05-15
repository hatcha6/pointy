from django.db import migrations


class Migration(migrations.Migration):
    dependencies = [
        ("sales", "0001_initial"),
    ]

    operations = [
        migrations.RemoveField(
            model_name="order",
            name="tax_total",
        ),
        migrations.RemoveField(
            model_name="orderline",
            name="tax_rate",
        ),
    ]
