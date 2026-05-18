from django.db import migrations, models


class Migration(migrations.Migration):
    dependencies = [
        ("core", "0001_initial"),
    ]

    operations = [
        migrations.AddField(
            model_name="shopsettings",
            name="allow_overselling",
            field=models.BooleanField(default=False),
        ),
    ]
