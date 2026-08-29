import django.db.models.deletion
from django.db import migrations, models

# The seven values the old enum hardcoded, now rows a shop can edit, reorder,
# deactivate or add to. The ``tracks_*`` flags carry what the intake form used
# to decide from a Dart `switch`: a television is not asked for a number plate
# and a car is not asked for an IMEI.
SEEDED_TYPES = [
    # (slug, name, icon, order, serial, imei, vin, plate, engine, year, odo)
    ("phone", "هاتف", "phone", 0, True, True, False, False, False, False, False),
    ("tablet", "تابلت", "tablet", 1, True, True, False, False, False, False, False),
    ("laptop", "حاسوب محمول", "laptop", 2, True, False, False, False, False, False, False),
    ("console", "جهاز ألعاب", "console", 3, True, False, False, False, False, False, False),
    ("appliance", "جهاز منزلي", "appliance", 4, True, False, False, False, False, False, False),
    ("vehicle", "مركبة", "vehicle", 5, False, False, True, True, True, True, True),
    ("other", "أخرى", "device", 6, True, False, False, False, False, False, False),
]


def seed_types_and_link_assets(apps, schema_editor):
    AssetType = apps.get_model("customers", "AssetType")
    Asset = apps.get_model("customers", "Asset")

    by_slug = {}
    for (
        slug, name, icon, order,
        serial, imei, vin, plate, engine, year, odo,
    ) in SEEDED_TYPES:
        by_slug[slug], _ = AssetType.objects.get_or_create(
            slug=slug,
            defaults={
                "name": name,
                "icon_key": icon,
                "display_order": order,
                "is_system": True,
                "tracks_serial_number": serial,
                "tracks_imei": imei,
                "tracks_vin": vin,
                "tracks_plate_number": plate,
                "tracks_engine_number": engine,
                "tracks_model_year": year,
                "tracks_odometer": odo,
            },
        )

    fallback = by_slug["other"]
    for asset in Asset.objects.all().only("id", "asset_type"):
        # ``asset_type`` still holds the old enum string at this point. Anything
        # unrecognised lands on "other" rather than failing the migration: a
        # shop's data is not worth losing over a value we did not anticipate.
        Asset.objects.filter(pk=asset.pk).update(
            asset_type_link=by_slug.get(asset.asset_type, fallback)
        )


def unlink_assets(apps, schema_editor):
    Asset = apps.get_model("customers", "Asset")
    Asset.objects.all().update(asset_type_link=None)


class Migration(migrations.Migration):
    dependencies = [
        ("customers", "0007_asset_vehicle_identity_and_ownership"),
    ]

    operations = [
        migrations.CreateModel(
            name="AssetType",
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
                ("created_at", models.DateTimeField(auto_now_add=True, db_index=True)),
                ("updated_at", models.DateTimeField(auto_now=True)),
                ("name", models.CharField(max_length=120)),
                (
                    "slug",
                    models.SlugField(allow_unicode=True, max_length=48, unique=True),
                ),
                ("icon_key", models.CharField(default="device", max_length=32)),
                ("display_order", models.PositiveIntegerField(default=0)),
                ("is_active", models.BooleanField(default=True)),
                ("is_system", models.BooleanField(default=False)),
                ("tracks_serial_number", models.BooleanField(default=True)),
                ("tracks_imei", models.BooleanField(default=False)),
                ("tracks_vin", models.BooleanField(default=False)),
                ("tracks_plate_number", models.BooleanField(default=False)),
                ("tracks_engine_number", models.BooleanField(default=False)),
                ("tracks_model_year", models.BooleanField(default=False)),
                ("tracks_odometer", models.BooleanField(default=False)),
                ("custom_identifier_label", models.CharField(blank=True, max_length=60)),
            ],
            options={"ordering": ["display_order", "name"]},
        ),
        migrations.AddField(
            model_name="asset",
            name="custom_identifier",
            field=models.CharField(blank=True, max_length=120),
        ),
        # Three-step column swap: add the FK nullable, fill it from the enum
        # string, then drop the string and make the FK required. Doing it in one
        # step would need a default that points at a row that does not exist yet.
        migrations.AddField(
            model_name="asset",
            name="asset_type_link",
            field=models.ForeignKey(
                null=True,
                on_delete=django.db.models.deletion.PROTECT,
                related_name="assets",
                to="customers.assettype",
            ),
        ),
        migrations.RunPython(seed_types_and_link_assets, unlink_assets),
        migrations.RemoveField(model_name="asset", name="asset_type"),
        migrations.RenameField(
            model_name="asset",
            old_name="asset_type_link",
            new_name="asset_type",
        ),
        migrations.AlterField(
            model_name="asset",
            name="asset_type",
            field=models.ForeignKey(
                on_delete=django.db.models.deletion.PROTECT,
                related_name="assets",
                to="customers.assettype",
            ),
        ),
        migrations.AddIndex(
            model_name="asset",
            index=models.Index(
                fields=["custom_identifier"], name="asset_custom_id_idx"
            ),
        ),
    ]
