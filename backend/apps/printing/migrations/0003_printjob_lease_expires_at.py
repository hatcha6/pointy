from django.db import migrations, models


class Migration(migrations.Migration):
    dependencies = [
        ("printing", "0002_printauditevent"),
    ]

    operations = [
        migrations.AddField(
            model_name="printjob",
            name="lease_expires_at",
            field=models.DateTimeField(blank=True, db_index=True, null=True),
        ),
    ]
