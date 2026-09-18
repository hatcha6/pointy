"""Ship the intake sheets a serialized trade would otherwise have to design.

A shop that turns on serialized inventory should find "battery health" and
"condition grade" already there, typed and ordered, rather than a blank screen
that asks it to model its own trade. Idempotent by ``(asset_type, key)``, so
re-running it never duplicates a field and never overwrites a label somebody has
edited.
"""

from django.db import migrations

from apps.inventory.unit_attributes import seed_definitions


def seed(apps, schema_editor):
    seed_definitions(
        apps.get_model("customers", "AssetType"),
        apps.get_model("inventory", "UnitAttributeDefinition"),
    )


def unseed(apps, schema_editor):
    """Deliberately nothing.

    Reversing a migration should not delete the condition grades a shop has been
    recording against its stock for a month.
    """


class Migration(migrations.Migration):
    dependencies = [
        ("inventory", "0030_phase_c_consignment"),
        ("customers", "0008_asset_type_model"),
    ]

    operations = [migrations.RunPython(seed, unseed)]
