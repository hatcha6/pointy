"""Seed the one rule that reproduces what the till already did.

Before this feature the client read *any* 13-digit code starting with 2 as
"prefix, five-digit item code, five digits of grams". Shops are running on that
today, with labels already on shelves, so the seeded rule is that exact layout
rather than the tidier GS1 defaults (21 weight / 23 price). A shop that wants
the tidier split narrows this rule and adds its own; a shop that does nothing
keeps the behaviour it has.

Its sequence is high so that every rule a shop adds later — necessarily more
specific than "any second digit" — is ordered ahead of it.
"""

from django.db import migrations

from apps.catalog.scale_defaults import SEEDED_SCALE_RULE as COMPAT_RULE


def seed(apps, schema_editor):
    ScaleBarcodeRule = apps.get_model("catalog", "ScaleBarcodeRule")
    if ScaleBarcodeRule.objects.exists():
        return
    ScaleBarcodeRule.objects.create(**COMPAT_RULE)


def unseed(apps, schema_editor):
    ScaleBarcodeRule = apps.get_model("catalog", "ScaleBarcodeRule")
    ScaleBarcodeRule.objects.filter(pattern=COMPAT_RULE["pattern"]).delete()


class Migration(migrations.Migration):
    dependencies = [("catalog", "0024_scalebarcoderule")]

    operations = [migrations.RunPython(seed, unseed)]
