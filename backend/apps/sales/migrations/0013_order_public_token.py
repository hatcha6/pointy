import secrets

from django.db import migrations, models


def populate_public_tokens(apps, schema_editor):
    Order = apps.get_model("sales", "Order")
    used_tokens = set(
        Order.objects.exclude(public_token__isnull=True)
        .exclude(public_token="")
        .values_list("public_token", flat=True)
    )
    for order in Order.objects.filter(public_token__isnull=True).iterator():
        while True:
            token = secrets.token_urlsafe(24)
            if token not in used_tokens:
                used_tokens.add(token)
                break
        order.public_token = token
        order.save(update_fields=["public_token"])


class Migration(migrations.Migration):
    dependencies = [
        ("sales", "0012_remove_order_line_product_fields"),
    ]

    operations = [
        migrations.AddField(
            model_name="order",
            name="public_token",
            field=models.CharField(
                blank=True,
                max_length=64,
                null=True,
                unique=True,
            ),
        ),
        migrations.RunPython(populate_public_tokens, migrations.RunPython.noop),
    ]
