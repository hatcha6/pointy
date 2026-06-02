from django.db import migrations, models


class Migration(migrations.Migration):
    dependencies = [
        ("core", "0007_relayconnectorsetuptoken"),
    ]

    operations = [
        migrations.AddField(
            model_name="shopsettings",
            name="require_card_payment_receipt",
            field=models.BooleanField(default=False),
        ),
        migrations.AddField(
            model_name="shopsettings",
            name="trusted_card_terminal_ids",
            field=models.JSONField(blank=True, default=list),
        ),
    ]
