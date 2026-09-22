"""Mark the products a feature created, so they stop being browsable.

Additive (expand): the column defaults to False, so the release currently in
shops keeps working against it unchanged. The backfill names the only rows
that are system products today — the one service product per recharge
provider, keyed on the stable ``INTEG-`` SKU that apps.integrations.provisioning
owns — and is written both ways so a rollback leaves nothing behind.
"""

from django.db import migrations, models

SERVICE_SKU_PREFIX = "INTEG-"


def mark_integration_products(apps, schema_editor):
    Product = apps.get_model("catalog", "Product")
    Product.objects.filter(
        variants__sku__startswith=SERVICE_SKU_PREFIX
    ).distinct().update(is_system=True)


def unmark_integration_products(apps, schema_editor):
    Product = apps.get_model("catalog", "Product")
    Product.objects.filter(is_system=True).update(is_system=False)


class Migration(migrations.Migration):
    dependencies = [
        ("catalog", "0030_product_tracking_since_backfill"),
    ]

    operations = [
        migrations.AddField(
            model_name="product",
            name="is_system",
            field=models.BooleanField(db_index=True, default=False),
        ),
        migrations.RunPython(
            mark_integration_products, unmark_integration_products
        ),
    ]
