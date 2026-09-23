"""Say which kind of system product a row is, so the till can list the right ones.

Additive (expand): the column defaults to blank — in the database too, so the
release still serving during a live update can insert a product without naming
it — and that release only ever reads ``is_system``.
Every system product that exists today is a recharge service product, so the
backfill marks them all ``service``; the provider cards that are *listed* on the
till are created by apps.integrations after this runs.
"""

from django.db import migrations, models


def mark_existing_as_service(apps, schema_editor):
    Product = apps.get_model("catalog", "Product")
    Product.objects.filter(is_system=True, system_kind="").update(
        system_kind="service"
    )


def unmark(apps, schema_editor):
    Product = apps.get_model("catalog", "Product")
    Product.objects.exclude(system_kind="").update(system_kind="")


class Migration(migrations.Migration):
    dependencies = [
        ("catalog", "0031_product_is_system"),
    ]

    operations = [
        migrations.AddField(
            model_name="product",
            name="system_kind",
            field=models.CharField(
                blank=True,
                choices=[
                    ("service", "Sold through its own flow"),
                    ("voucher", "Provider card"),
                ],
                db_default="",
                default="",
                max_length=16,
            ),
        ),
        migrations.AlterField(
            model_name="productalias",
            name="source",
            field=models.CharField(
                choices=[
                    ("invoice", "Invoice match"),
                    ("manual", "Manual"),
                    ("ai_adjudicated", "AI adjudicated"),
                    ("system", "Set by a feature"),
                ],
                default="manual",
                max_length=16,
            ),
        ),
        migrations.RunPython(mark_existing_as_service, unmark),
    ]
