from django.db import migrations, models


class Migration(migrations.Migration):
    dependencies = [
        ("core", "0002_shopsettings_allow_overselling"),
    ]

    operations = [
        migrations.AddField(
            model_name="shopsettings",
            name="cashier_return_window_hours",
            field=models.PositiveIntegerField(default=42),
        ),
    ]
