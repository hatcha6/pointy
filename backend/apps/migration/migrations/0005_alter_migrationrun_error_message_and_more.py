"""Give the file-upload columns a database default.

Django backfills a new column with the *Python* default and then drops the
database default it used to do it, which leaves a NOT NULL column with nothing
to fall back on. That is fine until a live update, where the previous backend
keeps serving for about a minute against the new schema
(``deploy/onprem/README.md``) and its ``INSERT`` names no such column — so a
data import started during an update would fail. The least likely of the three
to be hit, and the same fix.

Safe to apply whether or not the column has been created yet: it only sets a
default that should have been there from the start.
"""

from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("migration", "0004_drop_source_archive_flag"),
    ]

    operations = [
        migrations.AlterField(
            model_name="migrationrun",
            name="error_message",
            field=models.TextField(blank=True, db_default=""),
        ),
        migrations.AlterField(
            model_name="migrationrun",
            name="stages",
            field=models.JSONField(blank=True, db_default=[], default=list),
        ),
        migrations.AlterField(
            model_name="migrationsource",
            name="analysis",
            field=models.JSONField(blank=True, db_default={}, default=dict),
        ),
        migrations.AlterField(
            model_name="migrationsource",
            name="checksum_sha256",
            field=models.CharField(blank=True, db_default="", max_length=64),
        ),
        migrations.AlterField(
            model_name="migrationsource",
            name="declared_size_bytes",
            field=models.PositiveBigIntegerField(db_default=0, default=0),
        ),
        migrations.AlterField(
            model_name="migrationsource",
            name="detection",
            field=models.JSONField(blank=True, db_default={}, default=dict),
        ),
        migrations.AlterField(
            model_name="migrationsource",
            name="error_message",
            field=models.TextField(blank=True, db_default=""),
        ),
        migrations.AlterField(
            model_name="migrationsource",
            name="original_filename",
            field=models.CharField(blank=True, db_default="", max_length=255),
        ),
        migrations.AlterField(
            model_name="migrationsource",
            name="prepared_filename",
            field=models.CharField(blank=True, db_default="", max_length=255),
        ),
        migrations.AlterField(
            model_name="migrationsource",
            name="prepared_size_bytes",
            field=models.PositiveBigIntegerField(db_default=0, default=0),
        ),
        migrations.AlterField(
            model_name="migrationsource",
            name="received_bytes",
            field=models.PositiveBigIntegerField(db_default=0, default=0),
        ),
        migrations.AlterField(
            model_name="migrationsource",
            name="staged_filename",
            field=models.CharField(blank=True, db_default="", max_length=255),
        ),
        migrations.AlterField(
            model_name="migrationsource",
            name="staged_size_bytes",
            field=models.PositiveBigIntegerField(db_default=0, default=0),
        ),
        migrations.AlterField(
            model_name="migrationsource",
            name="stages",
            field=models.JSONField(blank=True, db_default=[], default=list),
        ),
        migrations.AlterField(
            model_name="migrationsource",
            name="upload_state",
            field=models.CharField(
                choices=[
                    ("uploading", "Receiving"),
                    ("uploaded", "Received"),
                    ("preparing", "Preparing"),
                    ("ready", "Ready"),
                    ("failed", "Failed"),
                    ("purged", "Deleted"),
                ],
                db_default="uploading",
                db_index=True,
                default="uploading",
                max_length=16,
            ),
        ),
    ]
