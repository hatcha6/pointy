"""Give the two roll windows the database default their sibling flag already had.

``0029`` added three columns together and only ``enable_surveillance`` got
``db_default``. Django backfills the other two with the *Python* default and
then drops the database one, so during a live update — where the previous
release keeps serving for about a minute after the schema moves — an INSERT
naming neither column would fail NOT NULL.

In practice ``ShopSettings`` is a singleton that already exists on every
deployed shop, so the only INSERT is on a fresh install where nothing older is
running; this closes the hole rather than repairing damage. It is also what
makes ``scripts/check_upgrade_compatibility.py`` pass again.
"""

import django.core.validators
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("core", "0029_shopsettings_enable_surveillance_and_more"),
    ]

    operations = [
        migrations.AlterField(
            model_name="shopsettings",
            name="surveillance_post_roll_seconds",
            field=models.PositiveSmallIntegerField(
                db_default=40,
                default=40,
                validators=[django.core.validators.MaxValueValidator(600)],
            ),
        ),
        migrations.AlterField(
            model_name="shopsettings",
            name="surveillance_pre_roll_seconds",
            field=models.PositiveSmallIntegerField(
                db_default=20,
                default=20,
                validators=[django.core.validators.MaxValueValidator(600)],
            ),
        ),
    ]
