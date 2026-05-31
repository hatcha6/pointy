from django.db import migrations, models


class Migration(migrations.Migration):
    dependencies = [
        ("core", "0004_shopsettings_payment_methods"),
    ]

    operations = [
        migrations.AddField(
            model_name="shopsettings",
            name="prevent_selling_at_loss",
            field=models.BooleanField(default=True),
        ),
    ]
