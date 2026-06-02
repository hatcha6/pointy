from django.db import migrations, models


class Migration(migrations.Migration):
    dependencies = [
        ("payments", "0002_transfer_commission_fields"),
    ]

    operations = [
        migrations.AddField(
            model_name="payment",
            name="card_receipt_data",
            field=models.JSONField(blank=True, default=dict),
        ),
    ]
