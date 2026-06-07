from decimal import Decimal

from django.core.validators import MinValueValidator
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("discounts", "0004_rename_discountrule_product_variants_variants"),
    ]

    operations = [
        migrations.AddField(
            model_name="discountrule",
            name="rounding_mode",
            field=models.CharField(
                choices=[
                    ("none", "No rounding"),
                    ("down", "Round down"),
                    ("nearest", "Round to nearest"),
                    ("up", "Round up"),
                ],
                default="none",
                max_length=16,
            ),
        ),
        migrations.AddField(
            model_name="discountrule",
            name="rounding_increment",
            field=models.DecimalField(
                blank=True,
                decimal_places=2,
                max_digits=10,
                null=True,
                validators=[MinValueValidator(Decimal("0.01"))],
            ),
        ),
    ]
