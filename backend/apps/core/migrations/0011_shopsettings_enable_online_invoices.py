from django.db import migrations, models


class Migration(migrations.Migration):
    dependencies = [
        ("core", "0010_systembackupschedule_systemmaintenancejob"),
    ]

    operations = [
        migrations.AddField(
            model_name="shopsettings",
            name="enable_online_invoices",
            field=models.BooleanField(default=False),
        ),
    ]
