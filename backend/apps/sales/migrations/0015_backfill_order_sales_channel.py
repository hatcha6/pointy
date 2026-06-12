from django.db import migrations


def backfill_orders_to_pos_channel(apps, schema_editor):
    """Existing orders all came from the shop's own POS app."""
    SalesChannel = apps.get_model("channels", "SalesChannel")
    Order = apps.get_model("sales", "Order")
    pos_channel, _created = SalesChannel.objects.get_or_create(
        slug="pos",
        defaults={
            "name": "نقطة البيع",
            "channel_type": "pos",
            "is_system": True,
            "is_active": True,
        },
    )
    Order.objects.filter(sales_channel__isnull=True).update(sales_channel=pos_channel)


def unlink_orders_from_channels(apps, schema_editor):
    Order = apps.get_model("sales", "Order")
    Order.objects.update(sales_channel=None)


class Migration(migrations.Migration):
    dependencies = [
        ("channels", "0002_seed_pos_channel"),
        ("sales", "0014_order_sales_channel"),
    ]

    operations = [
        migrations.RunPython(backfill_orders_to_pos_channel, unlink_orders_from_channels),
    ]
