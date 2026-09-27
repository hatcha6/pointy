"""Continue the job-number series from where it already is.

Job numbers used to be the job's own id, so a shop's series stands at its
highest id — or higher, where an imported or hand-corrected job carries a
number that never came from an id. Seeded from whichever is larger, because
``job_number`` is unique and a counter that started below an existing number
would refuse the next intake. Numbers already printed on tickets do not change.
"""

from django.db import migrations

JOB_SERIES = "job"


def _trailing_number(job_number: str) -> int:
    """The counter part of ``REP-20260926-000036``, or 0 if it is not that shape."""
    tail = job_number.rsplit("-", 1)[-1]
    return int(tail) if tail.isdigit() and tail != job_number else 0


def seed(apps, schema_editor):
    Job = apps.get_model("operations", "Job")
    DocumentNumberSeries = apps.get_model("documents", "DocumentNumberSeries")

    highest = Job.objects.order_by("-id").values_list("id", flat=True).first() or 0
    for job_number in (
        Job.objects.exclude(job_number="")
        .values_list("job_number", flat=True)
        .iterator(chunk_size=2000)
    ):
        highest = max(highest, _trailing_number(job_number))

    series, created = DocumentNumberSeries.objects.get_or_create(
        pk=JOB_SERIES,
        defaults={"last_value": highest},
    )
    if not created and series.last_value < highest:
        series.last_value = highest
        series.save(update_fields=["last_value"])


def unseed(apps, schema_editor):
    apps.get_model("documents", "DocumentNumberSeries").objects.filter(
        pk=JOB_SERIES
    ).delete()


class Migration(migrations.Migration):
    dependencies = [
        ("operations", "0011_builtin_workflows_follow_shop_modes"),
        ("documents", "0002_documentnumberseries"),
    ]

    operations = [migrations.RunPython(seed, unseed)]
