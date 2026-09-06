"""Give a customer's credit policy a database default.

Django backfills a new column with the *Python* default and then drops the
database default it used to do it, which leaves a NOT NULL column with nothing
to fall back on. That is fine until a live update, where the previous backend
keeps serving for about a minute against the new schema
(``deploy/onprem/README.md``) and its ``INSERT`` names no such column — and a
customer row is created on the checkout path, where the card deduper makes one
for an unrecognised card. A sale would have failed mid-flip.

Safe to apply whether or not the column has been created yet: it only sets a
default that should have been there from the start.
"""

from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("customers", "0009_customer_credit_limit_customer_credit_limit_policy"),
    ]

    operations = [
        migrations.AlterField(
            model_name="customer",
            name="credit_limit_policy",
            field=models.CharField(
                choices=[
                    ("shop_default", "Shop default"),
                    ("unlimited", "No limit"),
                    ("custom", "Custom limit"),
                ],
                db_default="shop_default",
                default="shop_default",
                max_length=16,
            ),
        ),
    ]
