from django.db import migrations, models


class Migration(migrations.Migration):
    dependencies = [
        ("messaging", "0003_relay_provider_and_templates"),
    ]

    operations = [
        migrations.AddField(
            model_name="messaginggateway",
            name="auto_messages",
            field=models.JSONField(blank=True, db_default={}, default=dict),
        ),
    ]
