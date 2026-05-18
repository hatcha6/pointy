from django.core.validators import MinValueValidator
from django.db import migrations, models


class Migration(migrations.Migration):
    dependencies = [
        ("payments", "0001_initial"),
    ]

    operations = [
        migrations.RunSQL(
            "UPDATE payments_payment SET method = 'transfer' WHERE method = 'mobile'",
            reverse_sql=migrations.RunSQL.noop,
        ),
        migrations.AlterField(
            model_name="payment",
            name="method",
            field=models.CharField(
                choices=[("cash", "Cash"), ("card", "Card"), ("transfer", "Transfer")],
                max_length=16,
            ),
        ),
        migrations.AddField(
            model_name="payment",
            name="commission_percent",
            field=models.DecimalField(
                decimal_places=2,
                default=0,
                max_digits=5,
                validators=[MinValueValidator(0)],
            ),
        ),
        migrations.AddField(
            model_name="payment",
            name="commission_amount",
            field=models.DecimalField(decimal_places=2, default=0, max_digits=10),
        ),
    ]
