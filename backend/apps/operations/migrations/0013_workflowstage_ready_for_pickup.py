from django.db import migrations, models

# Workflows whose "ready" stage means the customer can come and collect: a
# repair order and a work order. A kitchen's "ready" is a plate on the pass,
# and production has no customer at the counter.
_PICKUP_JOB_TYPES = ("repair", "work_order")


def mark_ready_stages(apps, schema_editor):
    WorkflowStage = apps.get_model("operations", "WorkflowStage")
    WorkflowStage.objects.filter(
        code="ready",
        template__job_type__in=_PICKUP_JOB_TYPES,
    ).update(ready_for_pickup=True)


class Migration(migrations.Migration):
    dependencies = [
        ("operations", "0012_seed_job_number_series"),
    ]

    operations = [
        # A database default as well, so the release still running during an
        # update can keep creating stages without naming the new column.
        migrations.AddField(
            model_name="workflowstage",
            name="ready_for_pickup",
            field=models.BooleanField(db_default=False, default=False),
        ),
        migrations.RunPython(mark_ready_stages, migrations.RunPython.noop),
    ]
