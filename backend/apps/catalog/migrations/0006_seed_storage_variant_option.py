from django.db import migrations


def seed_storage_variant_option(apps, schema_editor):
    VariantOption = apps.get_model("catalog", "VariantOption")
    VariantOptionValue = apps.get_model("catalog", "VariantOptionValue")

    option, _ = VariantOption.objects.update_or_create(
        code="storage",
        defaults={
            "name": "السعة",
            "display_order": 25,
            "is_active": True,
        },
    )
    values = [
        ("64gb", "64GB", 10),
        ("128gb", "128GB", 20),
        ("256gb", "256GB", 30),
        ("512gb", "512GB", 40),
        ("1tb", "1TB", 50),
    ]
    for code, name, display_order in values:
        VariantOptionValue.objects.update_or_create(
            option=option,
            code=code,
            defaults={
                "name": name,
                "display_order": display_order,
                "is_active": True,
            },
        )


class Migration(migrations.Migration):
    dependencies = [
        ("catalog", "0005_variant_option_schema"),
    ]

    operations = [
        migrations.RunPython(seed_storage_variant_option, migrations.RunPython.noop),
    ]
