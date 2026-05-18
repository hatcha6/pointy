from django.core.validators import MinValueValidator
from django.db import migrations, models


class Migration(migrations.Migration):
    dependencies = [
        ("core", "0003_shopsettings_cashier_return_window_hours"),
    ]

    operations = [
        migrations.AddField(
            model_name="shopsettings",
            name="enable_cash_payments",
            field=models.BooleanField(default=True),
        ),
        migrations.AddField(
            model_name="shopsettings",
            name="enable_card_payments",
            field=models.BooleanField(default=True),
        ),
        migrations.AddField(
            model_name="shopsettings",
            name="enable_transfer_payments",
            field=models.BooleanField(default=True),
        ),
        migrations.AddField(
            model_name="shopsettings",
            name="card_commission_percent",
            field=models.DecimalField(
                decimal_places=2,
                default=1,
                max_digits=5,
                validators=[MinValueValidator(0)],
            ),
        ),
        migrations.AddField(
            model_name="shopsettings",
            name="transfer_commission_percent",
            field=models.DecimalField(
                decimal_places=2,
                default=0,
                max_digits=5,
                validators=[MinValueValidator(0)],
            ),
        ),
    ]
