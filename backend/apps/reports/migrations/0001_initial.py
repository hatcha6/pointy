from django.conf import settings
from django.db import migrations, models
import django.db.models.deletion


class Migration(migrations.Migration):
    initial = True

    dependencies = [
        migrations.swappable_dependency(settings.AUTH_USER_MODEL),
    ]

    operations = [
        migrations.CreateModel(
            name="ReportRun",
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
                ("created_at", models.DateTimeField(auto_now_add=True)),
                ("updated_at", models.DateTimeField(auto_now=True)),
                (
                    "report_type",
                    models.CharField(
                        choices=[
                            ("sales_summary", "Sales summary"),
                            ("payment_methods", "Payment methods"),
                            ("register_closure", "Register closure"),
                            ("inventory_status", "Inventory status"),
                            ("stock_movements", "Stock movements"),
                            ("purchasing_summary", "Purchasing summary"),
                        ],
                        max_length=48,
                    ),
                ),
                ("params", models.JSONField(blank=True, default=dict)),
                (
                    "output_format",
                    models.CharField(
                        choices=[
                            ("json", "JSON"),
                            ("pdf", "PDF"),
                            ("csv", "CSV"),
                        ],
                        default="pdf",
                        max_length=16,
                    ),
                ),
                (
                    "status",
                    models.CharField(
                        choices=[
                            ("pending", "Pending"),
                            ("success", "Success"),
                            ("failed", "Failed"),
                        ],
                        default="pending",
                        max_length=16,
                    ),
                ),
                ("payload", models.JSONField(blank=True, default=dict)),
                ("row_count", models.PositiveIntegerField(default=0)),
                ("checksum", models.CharField(blank=True, max_length=64)),
                ("completed_at", models.DateTimeField(blank=True, null=True)),
                ("error_message", models.TextField(blank=True)),
                (
                    "requested_by",
                    models.ForeignKey(
                        blank=True,
                        null=True,
                        on_delete=django.db.models.deletion.SET_NULL,
                        related_name="report_runs",
                        to=settings.AUTH_USER_MODEL,
                    ),
                ),
            ],
            options={
                "ordering": ["-created_at", "-id"],
                "indexes": [
                    models.Index(
                        fields=["report_type", "created_at"],
                        name="reports_rep_report__2f705b_idx",
                    ),
                    models.Index(
                        fields=["requested_by", "created_at"],
                        name="reports_rep_request_5c3b96_idx",
                    ),
                    models.Index(
                        fields=["status", "created_at"],
                        name="reports_rep_status_52b871_idx",
                    ),
                ],
            },
        ),
    ]
