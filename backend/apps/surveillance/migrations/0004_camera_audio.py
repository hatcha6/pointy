from django.db import migrations, models


class Migration(migrations.Migration):
    dependencies = [
        ("surveillance", "0003_recorder_max_concurrent_streams"),
    ]

    operations = [
        migrations.AddField(
            model_name="camera",
            name="has_audio",
            field=models.BooleanField(blank=True, default=None, null=True),
        ),
        migrations.AddField(
            model_name="camera",
            name="audio_checked_at",
            field=models.DateTimeField(blank=True, null=True),
        ),
    ]
