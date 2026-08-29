from decimal import Decimal

import django.core.validators
import django.db.models.deletion
from django.conf import settings
from django.db import migrations, models

# The stages the seeded repair workflow ships with, in order. Used only to
# recognise an untouched system template — a shop that renamed, reordered or
# added stages has made the workflow its own and must not be rewritten.
SEEDED_REPAIR_CODES = [
    "received",
    "diagnosing",
    "waiting_approval",
    "repairing",
    "testing",
    "ready",
    "delivered",
]


def flag_seeded_repair_terminal(apps, schema_editor):
    """Teach the seeded repair workflow that a phone must be paid for to leave.

    Before this, invoicing a repair drove the job straight to "تم التسليم" and
    marked it complete, so the system claimed the customer had their device back
    at the instant the cashier took the money. The two flags split those apart:
    the terminal stage now *is* the handover, and it cannot be entered until the
    job is settled.

    Only the untouched ``is_system`` template is changed. A shop that edited its
    workflow keeps exactly what it built and can set the same flags itself in the
    workflow editor.
    """
    WorkflowTemplate = apps.get_model("operations", "WorkflowTemplate")
    for template in WorkflowTemplate.objects.filter(
        job_type="repair",
        is_system=True,
    ):
        stages = list(template.stages.order_by("display_order", "id"))
        if [stage.code for stage in stages] != SEEDED_REPAIR_CODES:
            continue
        terminal = stages[-1]
        terminal.requires_settlement = True
        terminal.releases_custody = True
        terminal.save(update_fields=["requires_settlement", "releases_custody"])


def unflag_seeded_repair_terminal(apps, schema_editor):
    WorkflowStage = apps.get_model("operations", "WorkflowStage")
    WorkflowStage.objects.filter(
        template__job_type="repair",
        template__is_system=True,
    ).update(requires_settlement=False, releases_custody=False)


class Migration(migrations.Migration):
    dependencies = [
        migrations.swappable_dependency(settings.AUTH_USER_MODEL),
        ("catalog", "0001_initial"),
        ("operations", "0006_job_job_status_created_idx"),
    ]

    operations = [
        migrations.AddField(
            model_name="workflowstage",
            name="requires_settlement",
            field=models.BooleanField(default=False),
        ),
        migrations.AddField(
            model_name="workflowstage",
            name="releases_custody",
            field=models.BooleanField(default=False),
        ),
        migrations.AddField(
            model_name="job",
            name="handed_over_at",
            field=models.DateTimeField(blank=True, null=True),
        ),
        migrations.AddField(
            model_name="job",
            name="handed_over_to",
            field=models.CharField(blank=True, max_length=120),
        ),
        migrations.AddField(
            model_name="job",
            name="on_hold_since",
            field=models.DateTimeField(blank=True, null=True),
        ),
        migrations.AddField(
            model_name="job",
            name="hold_reason",
            field=models.CharField(blank=True, max_length=200),
        ),
        migrations.AddField(
            model_name="job",
            name="held_seconds",
            field=models.PositiveIntegerField(default=0),
        ),
        migrations.AlterModelOptions(
            name="job",
            options={
                "ordering": ["-created_at"],
                "permissions": [
                    ("approve_job_quote", "Can approve a job quote"),
                    ("reopen_job", "Can reopen a completed or cancelled job"),
                    ("assign_job", "Can assign jobs to users"),
                    (
                        "release_unpaid_job",
                        "Can hand a job's property back before it is settled",
                    ),
                ],
            },
        ),
        migrations.CreateModel(
            name="JobService",
            fields=[
                (
                    "id",
                    models.BigAutoField(
                        auto_created=True,
                        primary_key=True,
                        serialize=False,
                        verbose_name="ID",
                    ),
                ),
                ("created_at", models.DateTimeField(auto_now_add=True, db_index=True)),
                ("updated_at", models.DateTimeField(auto_now=True)),
                (
                    "quantity",
                    models.DecimalField(
                        decimal_places=3,
                        default=Decimal("1"),
                        max_digits=10,
                        validators=[
                            django.core.validators.MinValueValidator(Decimal("0.001"))
                        ],
                    ),
                ),
                (
                    "unit_price",
                    models.DecimalField(decimal_places=2, default=0, max_digits=10),
                ),
                ("note", models.CharField(blank=True, max_length=200)),
                (
                    "added_by",
                    models.ForeignKey(
                        blank=True,
                        null=True,
                        on_delete=django.db.models.deletion.SET_NULL,
                        related_name="+",
                        to=settings.AUTH_USER_MODEL,
                    ),
                ),
                (
                    "job",
                    models.ForeignKey(
                        on_delete=django.db.models.deletion.CASCADE,
                        related_name="services",
                        to="operations.job",
                    ),
                ),
                (
                    "variant",
                    models.ForeignKey(
                        on_delete=django.db.models.deletion.PROTECT,
                        related_name="job_services",
                        to="catalog.productvariant",
                    ),
                ),
            ],
            options={"ordering": ["created_at", "id"]},
        ),
        migrations.RunPython(
            flag_seeded_repair_terminal,
            unflag_seeded_repair_terminal,
        ),
    ]
