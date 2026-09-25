"""Let a feature own a category — a provider's shelf of cards, one tap away.

Additive (expand): the column defaults to blank — in the database too, so the
release still serving during a live update can insert a category without
naming it — and that release never reads it. No backfill: every category that
exists today is the shop's own, and the shelf's category is made by
apps.integrations on its next sync after this runs.
"""

from django.db import migrations, models


class Migration(migrations.Migration):
    dependencies = [
        ("catalog", "0032_product_system_kind"),
    ]

    operations = [
        migrations.AddField(
            model_name="productcategory",
            name="system_key",
            field=models.CharField(
                blank=True, db_default="", default="", editable=False, max_length=64
            ),
        ),
        migrations.AddConstraint(
            model_name="productcategory",
            constraint=models.UniqueConstraint(
                condition=models.Q(("system_key", ""), _negated=True),
                fields=("system_key",),
                name="unique_product_category_system_key",
            ),
        ),
    ]
