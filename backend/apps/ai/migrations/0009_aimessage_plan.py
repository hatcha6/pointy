from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("ai", "0008_aimessage_ui_surfaces"),
    ]

    operations = [
        migrations.AddField(
            model_name="aimessage",
            name="plan",
            field=models.JSONField(blank=True, default=list),
        ),
    ]
