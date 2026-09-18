"""R1 of §15.1: the pre-split columns are **loosened, not dropped**.

0026 moved what they held onto ``StockBatchBalance``, and the temptation is to
remove them in the same breath. That is the one change in this whole plan that
is not an ordinary live update. During an update the edge nginx serves the
*previous* release against this schema for about a minute
(`zero-downtime-updates`), and that release decrements
``StockBatch.remaining_quantity`` inside ``record_sale_stock_movements`` and
joins ``source_receipt_line`` in its expiry-alert query. Drop them here and
every sale of an expiry-tracked product 500s for that minute — and the rollback
is gone too, since Django's auto-reverse of a ``RemoveField`` re-adds a
no-default ``DecimalField`` to a populated table.

So they stay, nullable and defaulted so the new code can create lots that never
came from a receipt line, and ``apps.inventory.tracking`` keeps them current
(dual-write) so a rollback to the previous release loses nothing. **The drop is
its own later release** — the contract step — and it is gated on the fleet's
*minimum* version being past this one, which `relay-remote-update` can answer as
a query rather than a hope. The file name is kept so the history reads honestly:
this migration was written to drop them, and was corrected on 2026-09-18 before
it ever reached a shop.

``stock_batch_code_unique_per_variant`` lands here rather than in 0025 because
it can only hold once every existing row has a code, which is 0026's job.
"""

from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("catalog", "0027_identified_stock"),
        ("inventory", "0026_split_batch_identity_and_balance"),
        ("purchasing", "0034_seed_order_number_series"),
    ]

    operations = [
        # PROTECT → SET_NULL and NOT NULL → NULL. The previous release still
        # writes this column; it simply stops being required, because a lot
        # captured from a printed code has no receipt line behind it.
        migrations.AlterField(
            model_name="stockbatch",
            name="source_receipt_line",
            field=models.ForeignKey(
                blank=True,
                null=True,
                on_delete=models.SET_NULL,
                related_name="legacy_stock_batches",
                to="purchasing.purchasereceiptline",
            ),
        ),
        migrations.AlterField(
            model_name="stockbatch",
            name="received_quantity",
            field=models.DecimalField(decimal_places=3, default=0, max_digits=12),
        ),
        migrations.AlterField(
            model_name="stockbatch",
            name="remaining_quantity",
            field=models.DecimalField(decimal_places=3, default=0, max_digits=12),
        ),
        migrations.AddConstraint(
            model_name="stockbatch",
            constraint=models.UniqueConstraint(
                fields=("variant", "code_normalized"),
                name="stock_batch_code_unique_per_variant",
            ),
        ),
    ]
