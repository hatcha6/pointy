"""Which screen went into which handset.

A job that consumes a serialized part used to raise outright: the
tripwire in ``post_movement_valuations`` refuses a tracked movement that
names nothing, and a job's materials named nothing. Two nullable columns,
and the job now says which article it fitted.
"""


import django.db.models.deletion
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("inventory", "0035_phase_d_custody_and_counting"),
        ("operations", "0008_phase_c_consignment"),
    ]

    operations = [
        migrations.AddField(
            model_name="jobmaterial",
            name="batch",
            field=models.ForeignKey(
                blank=True,
                null=True,
                on_delete=django.db.models.deletion.PROTECT,
                related_name="consumed_by_jobs",
                to="inventory.stockbatch",
            ),
        ),
        migrations.AddField(
            model_name="jobmaterial",
            name="stock_unit",
            field=models.ForeignKey(
                blank=True,
                null=True,
                on_delete=django.db.models.deletion.PROTECT,
                related_name="consumed_by_jobs",
                to="inventory.stockunit",
            ),
        ),
    ]
