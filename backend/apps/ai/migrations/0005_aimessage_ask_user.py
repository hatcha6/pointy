# Interactive ask_user elicitation: a paused assistant turn (tool_calls +
# pending_question + status) and the user's answer (a tool role + tool_call_id).

from django.db import migrations, models


class Migration(migrations.Migration):
    dependencies = [
        ("ai", "0004_aimessage_tool_events"),
    ]

    operations = [
        migrations.AddField(
            model_name="aimessage",
            name="tool_calls",
            field=models.JSONField(blank=True, default=list),
        ),
        migrations.AddField(
            model_name="aimessage",
            name="tool_call_id",
            field=models.CharField(blank=True, default="", max_length=64),
        ),
        migrations.AddField(
            model_name="aimessage",
            name="pending_question",
            field=models.JSONField(blank=True, null=True),
        ),
        migrations.AddField(
            model_name="aimessage",
            name="status",
            field=models.CharField(blank=True, default="", max_length=20),
        ),
        migrations.AlterField(
            model_name="aimessage",
            name="role",
            field=models.CharField(
                choices=[
                    ("user", "user"),
                    ("assistant", "assistant"),
                    ("system", "system"),
                    ("tool", "tool"),
                ],
                max_length=16,
            ),
        ),
    ]
