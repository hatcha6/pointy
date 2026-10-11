"""Undo the surname the user screen added again on every save.

That screen shows a user's first and last name together in one field, but saved
the whole of it as ``first_name`` and left ``last_name`` alone. «الحسين» +
«حمودة» became «الحسين حمودة» + «حمودة», then «الحسين حمودة حمودة» + «حمودة»: one
more copy per save (Annaseem, 2026-10-12: «الحسين حمودة حمودة حمودة»). The app
now clears ``last_name`` whenever it writes the name.

Here every copy of the last name stuck to the end of the first name is taken
off again, which is exactly what the bug put there. The first name never
becomes empty: a first name that is the surname itself keeps that one copy.
"""

from django.db import migrations


def collapsed_first_name(first_name: str, last_name: str) -> str:
    last = (last_name or "").strip()
    first = (first_name or "").strip()
    if not last:
        return first_name
    suffix = f" {last}"
    trimmed = first
    while trimmed.endswith(suffix):
        trimmed = trimmed[: -len(suffix)].rstrip()
    return trimmed if trimmed else first_name


def collapse_repeated_last_names(apps, schema_editor):
    User = apps.get_model("auth", "User")
    for user in User.objects.exclude(last_name="").only("id", "first_name", "last_name"):
        fixed = collapsed_first_name(user.first_name, user.last_name)
        if fixed != user.first_name:
            User.objects.filter(pk=user.pk).update(first_name=fixed)


class Migration(migrations.Migration):
    dependencies = [
        ("auth", "0012_alter_user_first_name_max_length"),
        ("core", "0042_relayinstallation_wallet_plans_sms_balance"),
    ]

    operations = [
        migrations.RunPython(collapse_repeated_last_names, migrations.RunPython.noop),
    ]
