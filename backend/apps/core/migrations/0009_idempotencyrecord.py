from django.db import migrations, models


class Migration(migrations.Migration):
    dependencies = [
        ("core", "0008_shopsettings_require_card_payment_receipt"),
    ]

    operations = [
        migrations.CreateModel(
            name="IdempotencyRecord",
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
                ("key", models.CharField(max_length=180)),
                ("owner_key", models.CharField(db_index=True, max_length=128)),
                ("method", models.CharField(max_length=12)),
                ("path", models.CharField(max_length=512)),
                ("request_hash", models.CharField(max_length=64)),
                (
                    "response_status_code",
                    models.PositiveSmallIntegerField(blank=True, null=True),
                ),
                ("response_data", models.JSONField(blank=True, null=True)),
                ("replay_count", models.PositiveIntegerField(default=0)),
                ("completed_at", models.DateTimeField(blank=True, null=True)),
            ],
            options={
                "ordering": ["-created_at"],
                "indexes": [
                    models.Index(
                        fields=["owner_key", "key"],
                        name="core_idempo_owner_k_d429b5_idx",
                    ),
                    models.Index(
                        fields=["method", "path"],
                        name="core_idempo_method_f6bb54_idx",
                    ),
                ],
                "constraints": [
                    models.UniqueConstraint(
                        fields=("owner_key", "method", "path", "key"),
                        name="unique_idempotency_record_per_request_scope",
                    )
                ],
            },
        ),
    ]
