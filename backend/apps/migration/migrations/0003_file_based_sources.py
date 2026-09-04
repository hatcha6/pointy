"""Migration sources become uploaded files instead of database connections.

Every column that described a *server* goes: host, port, database name, username,
password, transport kind, driver options. They are replaced by the fields that
describe a *file* and its journey through the preparation pipeline.

Existing rows survive the change. They are worth keeping even though their
connection details are gone, because ``MigrationIdentityMap`` hangs off them and
is what makes a second import update the same products rather than duplicate
them — throwing the row away would turn a re-import into a duplicate catalogue.
Their files (if any) were never managed by us, so they are marked purged, and
their renamed connector keys are carried across.
"""

from django.db import migrations, models

# fahd_mssql/fahd_sqlite collapsed into one Fahd connector when the SQL Server
# transport was removed; aboghris_mssql lost its suffix for the same reason.
_RENAMED_SYSTEM_KEYS = {
    "fahd_sqlite": "fahd",
    "fahd_mssql": "fahd",
    "aboghris_mssql": "aboghris",
}


def carry_system_keys_forward(apps, schema_editor):
    MigrationSource = apps.get_model("migration", "MigrationSource")
    for old, new in _RENAMED_SYSTEM_KEYS.items():
        MigrationSource.objects.filter(system_key=old).update(system_key=new)
    # Nothing on disk is ours any more: these rows referenced a database server
    # or an operator's own file, neither of which the staging store manages.
    MigrationSource.objects.all().update(upload_state="purged")


def restore_system_keys(apps, schema_editor):
    MigrationSource = apps.get_model("migration", "MigrationSource")
    MigrationSource.objects.filter(system_key="fahd").update(system_key="fahd_sqlite")
    MigrationSource.objects.filter(system_key="aboghris").update(system_key="aboghris_mssql")


class Migration(migrations.Migration):
    dependencies = [("migration", "0002_migrationrun_options")]

    operations = [
        # --- new: the file and its preparation --------------------------
        migrations.AddField(
            model_name="migrationsource",
            name="original_filename",
            field=models.CharField(blank=True, max_length=255),
        ),
        migrations.AddField(
            model_name="migrationsource",
            name="declared_size_bytes",
            field=models.PositiveBigIntegerField(default=0),
        ),
        migrations.AddField(
            model_name="migrationsource",
            name="received_bytes",
            field=models.PositiveBigIntegerField(default=0),
        ),
        migrations.AddField(
            model_name="migrationsource",
            name="checksum_sha256",
            field=models.CharField(blank=True, max_length=64),
        ),
        migrations.AddField(
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
                db_index=True,
                default="uploading",
                max_length=16,
            ),
        ),
        migrations.AddField(
            model_name="migrationsource",
            name="staged_filename",
            field=models.CharField(blank=True, max_length=255),
        ),
        migrations.AddField(
            model_name="migrationsource",
            name="prepared_filename",
            field=models.CharField(blank=True, max_length=255),
        ),
        migrations.AddField(
            model_name="migrationsource",
            name="staged_size_bytes",
            field=models.PositiveBigIntegerField(default=0),
        ),
        migrations.AddField(
            model_name="migrationsource",
            name="prepared_size_bytes",
            field=models.PositiveBigIntegerField(default=0),
        ),
        migrations.AddField(
            model_name="migrationsource",
            name="stages",
            field=models.JSONField(blank=True, default=list),
        ),
        migrations.AddField(
            model_name="migrationsource",
            name="error_message",
            field=models.TextField(blank=True),
        ),
        migrations.AddField(
            model_name="migrationsource",
            name="detection",
            field=models.JSONField(blank=True, default=dict),
        ),
        migrations.AddField(
            model_name="migrationsource",
            name="analysis",
            field=models.JSONField(blank=True, default=dict),
        ),
        migrations.AddField(
            model_name="migrationsource",
            name="purged_at",
            field=models.DateTimeField(blank=True, null=True),
        ),
        migrations.AddField(
            model_name="migrationrun",
            name="stages",
            field=models.JSONField(blank=True, default=list),
        ),
        # system_key is now detected rather than chosen, so a file we have not
        # identified yet has none.
        migrations.AlterField(
            model_name="migrationsource",
            name="system_key",
            field=models.CharField(blank=True, max_length=64),
        ),
        migrations.RunPython(carry_system_keys_forward, restore_system_keys),
        # --- gone: everything that described a server --------------------
        migrations.RemoveField(model_name="migrationsource", name="transport_kind"),
        migrations.RemoveField(model_name="migrationsource", name="host"),
        migrations.RemoveField(model_name="migrationsource", name="port"),
        migrations.RemoveField(model_name="migrationsource", name="database_name"),
        migrations.RemoveField(model_name="migrationsource", name="username"),
        migrations.RemoveField(model_name="migrationsource", name="password"),
        migrations.RemoveField(model_name="migrationsource", name="extra_options"),
        migrations.RemoveField(model_name="migrationsource", name="credentials_cleared"),
        migrations.AddIndex(
            model_name="migrationsource",
            index=models.Index(
                fields=["upload_state", "-created_at"],
                name="migration_m_upload__5acf54_idx",
            ),
        ),
    ]
