"""When a lot's stop-sale went on, and why — for staff, never the kiosk.

Both columns are safe to add under a running previous release: the timestamp
is nullable and the reason carries a database default, so an ``INSERT`` that
omits them (the old model) still succeeds during the update window.
"""

from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("inventory", "0038_flip_minute_column_defaults"),
    ]

    operations = [
        migrations.AddField(
            model_name="stockbatch",
            name="quarantine_reason",
            field=models.CharField(
                blank=True, db_default="", default="", max_length=200
            ),
        ),
        migrations.AddField(
            model_name="stockbatch",
            name="quarantined_at",
            field=models.DateTimeField(blank=True, null=True),
        ),
    ]
