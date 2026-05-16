from django.db import migrations, models


class Migration(migrations.Migration):
    initial = True

    dependencies = []

    operations = [
        migrations.CreateModel(
            name="ShopSettings",
            fields=[
                (
                    "id",
                    models.BigAutoField(
                        auto_created=True,
                        primary_key=True,
                        serialize=False,
                        verbose_name="ID",
                    ),
                ),
                ("created_at", models.DateTimeField(auto_now_add=True)),
                ("updated_at", models.DateTimeField(auto_now=True)),
                ("shop_name", models.CharField(default="نقطة البيع", max_length=120)),
                ("receipt_header", models.CharField(blank=True, max_length=240)),
                ("receipt_footer", models.CharField(blank=True, max_length=240)),
                ("require_opening_cash", models.BooleanField(default=True)),
                ("auto_print_receipts", models.BooleanField(default=False)),
                ("low_stock_threshold", models.PositiveIntegerField(default=5)),
            ],
            options={
                "verbose_name": "shop settings",
                "verbose_name_plural": "shop settings",
            },
        ),
    ]
