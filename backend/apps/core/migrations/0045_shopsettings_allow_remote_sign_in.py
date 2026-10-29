from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("core", "0044_relayinstallation_public_pages_url"),
    ]

    operations = [
        migrations.AddField(
            model_name="shopsettings",
            name="allow_remote_sign_in",
            field=models.BooleanField(default=False),
        ),
    ]
