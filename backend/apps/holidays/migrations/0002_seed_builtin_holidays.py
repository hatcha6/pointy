from django.db import migrations

from apps.holidays import rules


def seed_builtin_holidays(apps, schema_editor):
    """Seed the fixed Gregorian holidays + White Friday so the calendar works
    offline, before the relay has ever been reached. Idempotent (upsert by key)."""
    Holiday = apps.get_model("holidays", "Holiday")
    for data in rules.BUILTIN_HOLIDAYS:
        Holiday.objects.update_or_create(
            key=data["key"],
            defaults=rules.row_fields(data, source=rules.SOURCE_BUILTIN),
        )


def remove_builtin_holidays(apps, schema_editor):
    Holiday = apps.get_model("holidays", "Holiday")
    Holiday.objects.filter(key__in=[d["key"] for d in rules.BUILTIN_HOLIDAYS]).delete()


class Migration(migrations.Migration):
    dependencies = [("holidays", "0001_initial")]

    operations = [
        migrations.RunPython(seed_builtin_holidays, remove_builtin_holidays),
    ]
