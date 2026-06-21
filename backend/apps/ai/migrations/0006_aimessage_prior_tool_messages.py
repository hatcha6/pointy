# Persist a paused turn's prior tool round-trips (e.g. an invoice extracted via
# match_invoice_products) so they survive the ask_user pause and are replayed on
# resume instead of being lost with the in-memory state.

from django.db import migrations, models


class Migration(migrations.Migration):
    dependencies = [
        ("ai", "0005_aimessage_ask_user"),
    ]

    operations = [
        migrations.AddField(
            model_name="aimessage",
            name="prior_tool_messages",
            field=models.JSONField(blank=True, default=list),
        ),
    ]
