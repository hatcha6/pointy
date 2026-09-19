"""One more voucher type: the repair that capitalises into a handset.

A pure ``choices`` change on a ``CharField`` — no column altered, no constraint
added, no lock taken — so §15.1's live-update rule is satisfied trivially: the
previous release writes and reads the same column, and simply never produces the
new value. Nothing here is the batch split.

Why the value exists at all is §5.6 and :mod:`apps.operations.refurbishment`:
``StockValuationBin`` is a cache of *this ledger*, not of the units, so moving
``StockUnit.refurb_cost`` on its own left the shelf behind the article it
belongs to.
"""

from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("inventory", "0033_stock_unit_recent_index"),
    ]

    operations = [
        migrations.AlterField(
            model_name="stockledgerentry",
            name="voucher_type",
            field=models.CharField(
                choices=[
                    ("sale", "Sale"),
                    ("sale_return", "Sale return"),
                    ("purchase_receipt", "Purchase receipt"),
                    ("purchase_return", "Purchase return"),
                    ("production", "Production"),
                    ("stock_count", "Stock count"),
                    ("adjustment", "Manual adjustment"),
                    ("opening", "Opening balance"),
                    ("transfer", "Warehouse transfer"),
                    ("transfer_receipt", "Warehouse transfer receipt"),
                    ("consignment_cost", "Consignment cost"),
                    ("consignment_intake", "Consignment intake"),
                    ("consignment_return", "Consignment returned to owner"),
                    ("refurbishment", "Refurbishment capitalised"),
                ],
                db_index=True,
                default="adjustment",
                max_length=24,
            ),
        ),
    ]
