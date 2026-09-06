"""Give the customer-credit switch a database default.

Django backfills a new column with the *Python* default and then drops the
database default it used to do it, which leaves a NOT NULL column with nothing
to fall back on. That is fine until a live update, where the previous backend
keeps serving for about a minute against the new schema
(``deploy/onprem/README.md``) and its ``INSERT`` names no such column — so
creating a shop's settings row would fail.

Safe to apply whether or not the column has been created yet: it only sets a
default that should have been there from the start.
"""

from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("core", "0027_shopsettings_default_customer_credit_limit_and_more"),
    ]

    operations = [
        migrations.AlterField(
            model_name="shopsettings",
            name="enforce_customer_credit_limits",
            field=models.BooleanField(db_default=False, default=False),
        ),
    ]
