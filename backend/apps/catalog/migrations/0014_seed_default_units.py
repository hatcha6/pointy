from django.db import migrations

from apps.catalog.unit_defaults import DEFAULT_UNITS, DEFAULT_UNIT_CODES


def seed_units(apps, schema_editor):
    UnitOfMeasure = apps.get_model("catalog", "UnitOfMeasure")
    for code, name, abbreviation, dimension, reference_factor, allows_fractional, order in (
        DEFAULT_UNITS
    ):
        UnitOfMeasure.objects.update_or_create(
            code=code,
            defaults={
                "name": name,
                "abbreviation": abbreviation,
                "dimension": dimension,
                "reference_factor": reference_factor,
                "allows_fractional": allows_fractional,
                "display_order": order,
                "is_system": True,
                "is_active": True,
            },
        )


def remove_units(apps, schema_editor):
    UnitOfMeasure = apps.get_model("catalog", "UnitOfMeasure")
    # Only drop seeded units that no product references, to keep rollback safe.
    UnitOfMeasure.objects.filter(
        code__in=DEFAULT_UNIT_CODES,
        is_system=True,
        product_units__isnull=True,
    ).delete()


class Migration(migrations.Migration):

    dependencies = [
        ("catalog", "0013_units_of_measure"),
    ]

    operations = [
        migrations.RunPython(seed_units, remove_units),
    ]
