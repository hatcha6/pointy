"""A voucher brand's two logos: the tile's, and the receipt's.

Remembers which provider logo each card product shows and when the provider
was last asked (see ``apps.integrations.voucher_logos``), and keeps the
receipt version of the logo inline for the receipts to print. Additive only:
nullable columns, and text columns with a database default, so an older
backend still writing voucher brands during a live update inserts rows
without knowing any of them exists.
"""

from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("integrations", "0014_hdbox_labels_without_price"),
    ]

    operations = [
        migrations.AddField(
            model_name="integrationvoucherbrand",
            name="logo_checked_at",
            field=models.DateTimeField(blank=True, null=True),
        ),
        migrations.AddField(
            model_name="integrationvoucherbrand",
            name="logo_source",
            field=models.CharField(
                blank=True, db_default="", default="", max_length=255
            ),
        ),
        migrations.AddField(
            model_name="integrationvoucherbrand",
            name="print_logo",
            field=models.BinaryField(blank=True, null=True),
        ),
        migrations.AddField(
            model_name="integrationvoucherbrand",
            name="print_logo_checked_at",
            field=models.DateTimeField(blank=True, null=True),
        ),
        migrations.AddField(
            model_name="integrationvoucherbrand",
            name="print_logo_path",
            field=models.CharField(
                blank=True, db_default="", default="", max_length=255
            ),
        ),
        migrations.AddField(
            model_name="integrationvoucherbrand",
            name="print_logo_source",
            field=models.CharField(
                blank=True, db_default="", default="", max_length=255
            ),
        ),
    ]
