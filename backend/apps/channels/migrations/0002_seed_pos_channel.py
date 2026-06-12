from django.db import migrations

POS_SLUG = "pos"
POS_NAME = "نقطة البيع"


def seed_pos_channel(apps, schema_editor):
    SalesChannel = apps.get_model("channels", "SalesChannel")
    SalesChannel.objects.get_or_create(
        slug=POS_SLUG,
        defaults={
            "name": POS_NAME,
            "channel_type": "pos",
            "is_system": True,
            "is_active": True,
        },
    )


def remove_pos_channel(apps, schema_editor):
    SalesChannel = apps.get_model("channels", "SalesChannel")
    SalesChannel.objects.filter(slug=POS_SLUG, is_system=True).delete()


class Migration(migrations.Migration):
    dependencies = [
        ("channels", "0001_initial"),
    ]

    operations = [
        migrations.RunPython(seed_pos_channel, remove_pos_channel),
    ]
