from django.conf import settings
from django.db import migrations, models
import django.db.models.deletion


class Migration(migrations.Migration):

    initial = True

    dependencies = [
        migrations.swappable_dependency(settings.AUTH_USER_MODEL),
        ("contenttypes", "0002_remove_content_type_name"),
    ]

    operations = [
        migrations.CreateModel(
            name="AttachmentStorageState",
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
                ("next_index", models.PositiveBigIntegerField(default=0)),
            ],
            options={
                "verbose_name": "attachment storage state",
                "verbose_name_plural": "attachment storage state",
            },
        ),
        migrations.CreateModel(
            name="StorageVolume",
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
                ("name", models.CharField(max_length=120)),
                ("path", models.CharField(max_length=500, unique=True)),
                ("is_active", models.BooleanField(default=True)),
                ("notes", models.TextField(blank=True)),
            ],
            options={
                "ordering": ["id"],
            },
        ),
        migrations.CreateModel(
            name="Attachment",
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
                ("owner_object_id", models.PositiveBigIntegerField()),
                (
                    "role",
                    models.CharField(
                        choices=[
                            ("general", "General"),
                            ("document", "Document"),
                            ("product_image", "Product image"),
                            ("supplier_invoice_scan", "Supplier invoice scan"),
                        ],
                        db_index=True,
                        default="general",
                        max_length=64,
                    ),
                ),
                ("relative_path", models.CharField(max_length=600)),
                ("original_filename", models.CharField(max_length=255)),
                ("content_type", models.CharField(blank=True, max_length=160)),
                ("original_size", models.PositiveBigIntegerField()),
                ("stored_size", models.PositiveBigIntegerField()),
                ("checksum_sha256", models.CharField(db_index=True, max_length=64)),
                (
                    "storage_encoding",
                    models.CharField(
                        choices=[("identity", "Identity"), ("gzip", "Gzip")],
                        default="identity",
                        max_length=16,
                    ),
                ),
                ("is_primary", models.BooleanField(default=False)),
                (
                    "status",
                    models.CharField(
                        choices=[("active", "Active"), ("deleted", "Deleted")],
                        db_index=True,
                        default="active",
                        max_length=16,
                    ),
                ),
                ("metadata", models.JSONField(blank=True, default=dict)),
                ("deleted_at", models.DateTimeField(blank=True, null=True)),
                (
                    "created_by",
                    models.ForeignKey(
                        blank=True,
                        null=True,
                        on_delete=django.db.models.deletion.SET_NULL,
                        related_name="created_attachments",
                        to=settings.AUTH_USER_MODEL,
                    ),
                ),
                (
                    "deleted_by",
                    models.ForeignKey(
                        blank=True,
                        null=True,
                        on_delete=django.db.models.deletion.SET_NULL,
                        related_name="deleted_attachments",
                        to=settings.AUTH_USER_MODEL,
                    ),
                ),
                (
                    "owner_content_type",
                    models.ForeignKey(
                        on_delete=django.db.models.deletion.PROTECT,
                        related_name="owned_attachments",
                        to="contenttypes.contenttype",
                    ),
                ),
                (
                    "storage_volume",
                    models.ForeignKey(
                        on_delete=django.db.models.deletion.PROTECT,
                        related_name="attachments",
                        to="attachments.storagevolume",
                    ),
                ),
            ],
            options={
                "ordering": ["-created_at", "-id"],
            },
        ),
        migrations.AddConstraint(
            model_name="attachment",
            constraint=models.UniqueConstraint(
                fields=("storage_volume", "relative_path"),
                name="unique_attachment_file_path",
            ),
        ),
        migrations.AddConstraint(
            model_name="attachment",
            constraint=models.UniqueConstraint(
                condition=models.Q(("is_primary", True), ("status", "active")),
                fields=("owner_content_type", "owner_object_id", "role"),
                name="unique_primary_attachment_per_owner_role",
            ),
        ),
        migrations.AddIndex(
            model_name="attachment",
            index=models.Index(
                fields=[
                    "owner_content_type",
                    "owner_object_id",
                    "role",
                    "status",
                ],
                name="att_owner_role_status_idx",
            ),
        ),
        migrations.AddIndex(
            model_name="attachment",
            index=models.Index(
                fields=["storage_volume", "status"],
                name="att_volume_status_idx",
            ),
        ),
    ]
