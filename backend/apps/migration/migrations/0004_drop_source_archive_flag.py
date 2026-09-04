"""``is_archived`` was how the connection-era screen hid a saved source.

Sources are uploaded files now, and their lifecycle is `upload_state`: an
abandoned one is swept, a finished one is purged. Nothing archives.
"""

from django.db import migrations


class Migration(migrations.Migration):

    dependencies = [
        ("migration", "0003_file_based_sources"),
    ]

    operations = [
        migrations.RemoveField(
            model_name="migrationsource",
            name="is_archived",
        ),
    ]
