"""Give every payroll run the lifecycle its status implied.

A run is a document from the moment money leaves, which is when it is paid.
Approval is a gate before that, not a state of the document, so an approved run
is still a draft as far as the lifecycle is concerned — its own ``approved_at``
stamp is what says otherwise, and the derived status keeps reading it.
"""

from django.db import migrations
from django.db.models import F


def backfill(apps, schema_editor):
    PayrollRun = apps.get_model("employees", "PayrollRun")
    PayrollRun.objects.filter(status="paid").update(doc_status="submitted")
    PayrollRun.objects.filter(status="void").update(doc_status="cancelled")
    PayrollRun.objects.filter(status__in=["draft", "approved"]).update(
        doc_status="draft"
    )
    # The lifecycle's own columns take over from the payroll dialect — in one
    # statement, so a long payroll history costs one round trip rather than one
    # per run.
    PayrollRun.objects.filter(status="void", voided_at__isnull=False).update(
        cancelled_at=F("voided_at"), cancelled_by_id=F("voided_by_id")
    )


def unbackfill(apps, schema_editor):
    """Nothing to undo: the columns this wrote are dropped by the migration
    that added them."""


class Migration(migrations.Migration):
    dependencies = [
        ("employees", "0011_payrollrun_amended_from_payrollrun_amendment_index_and_more"),
    ]

    operations = [
        migrations.RunPython(backfill, unbackfill),
    ]
