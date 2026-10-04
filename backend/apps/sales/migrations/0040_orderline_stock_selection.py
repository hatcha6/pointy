from django.db import migrations, models


class Migration(migrations.Migration):
    """Keep the articles an open order names until it is paid.

    Nullable with no default: a nullable column ADD is catalog-only on
    Postgres, and the previous release — whose model lacks the field — can
    still INSERT an order line during the flip minute (§15.1).
    """

    dependencies = [
        ("sales", "0039_order_sale_type_account_entry"),
    ]

    operations = [
        migrations.AddField(
            model_name="orderline",
            name="stock_selection",
            field=models.JSONField(blank=True, null=True),
        ),
    ]
