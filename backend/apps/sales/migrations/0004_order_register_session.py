import django.db.models.deletion
from django.db import migrations, models


class Migration(migrations.Migration):
    dependencies = [
        ("sales", "0003_registersession"),
    ]

    operations = [
        migrations.AddField(
            model_name="order",
            name="register_session",
            field=models.ForeignKey(
                blank=True,
                null=True,
                on_delete=django.db.models.deletion.PROTECT,
                related_name="orders",
                to="sales.registersession",
            ),
        ),
    ]
