from django.db import migrations

from apps.fx.services import ensure_builtin_currencies


def seed(apps, schema_editor):
    ensure_builtin_currencies(currency_model=apps.get_model("fx", "Currency"))


def unseed(apps, schema_editor):
    # Currencies are referenced by rates and (from phase 3) by products, so
    # removing them on reverse would fail the PROTECT. Reversing this migration
    # leaves the registry in place deliberately: it is inert reference data.
    pass


class Migration(migrations.Migration):
    dependencies = [("fx", "0001_initial")]
    operations = [migrations.RunPython(seed, unseed)]
