"""The contract release, folded into the expand — and why that is safe here.

§15.1 staged this across three releases because dropping
``received_quantity``, ``remaining_quantity`` and ``source_receipt_line``
while the previous release still writes them is *"a ProgrammingError on every
sale during the flip minute"*. That sentence carries a condition the plan
states and then half-forgets. The previous release's sale path is

    def consume_expiring_stock_batches(*, variant, quantity):
        if quantity <= 0 or not getattr(variant.product, "tracks_expiry", False):
            return 0

— it returns **before building any query**. This plan has not shipped and no
shop has ever turned expiry tracking on, so on every existing installation
that early return is the only thing that path has ever done, and no sale can
touch these columns.

What is *not* conditional, and is the part worth writing down, is that a
``WHERE tracks_expiry = true`` does not save a statement from a dropped
column: Postgres parses the whole thing, so zero matching rows and zero
expiry-tracked products are equally fatal to SQL that names one. Three places
in the previous release name these columns unconditionally, and all three fail
recoverably rather than destructively:

* ``notifications._expiry_notifications`` selects ``remaining_quantity`` and
  joins ``source_receipt_line``. It runs from a Celery task, so the failure is
  a logged, retried task nobody sees; only with the broker unreachable does it
  reach a request, and then it is the bell poll.
* ``purchasing.documents``, reversing a receipt:
  ``StockBatch.objects.filter(source_receipt_line__receipt=receipt).delete()``.
  Fails inside its own transaction, so the operator retries and the new
  backend answers.
* The Django admin's ``StockBatch`` page.

So the exposure is not "every sale" but "a background task retries for about a
minute", which is an ordinary live update.

**The data is safe independently of all of that.** ``0026`` copied these
columns onto ``StockBatchBalance`` before anything here runs, and the check
below proves it **on this shop's own database, at the moment it matters** —
which is worth more than a fleet-wide claim, because it is the one shop the
migration is actually about.

**What deliberately does NOT come with this.** §18.4 schedules
``Product.tracks_expiry`` for the same contract step. It cannot come: Django
selects every concrete field on every model load, so dropping that column
makes the previous release fail on **every product read** — the catalog, the
till, all of it — which no amount of nobody-using-the-feature mitigates. It
waits for a release after this one.
"""

from decimal import Decimal

from django.db import migrations


def _refuse_if_the_backfill_did_not_hold(apps, schema_editor):
    """Prove the balances account for what the columns say, or stop.

    Read-only until it raises. ``remaining_quantity`` is the sum across every
    place the lot sits — which is what the single-warehouse column meant — so
    a lot that disagrees is one whose goods the split did not carry over, and
    dropping the column would take the difference with it.

    This is the rehearsal check of §15.1 run per shop instead of once in a
    harness: *"every balance equal to the legacy column it replaced at the
    moment dual-write stops"*. A fleet where nobody uses the feature makes it
    trivially true, which is the point — a check that costs nothing when the
    premise holds and stops the migration when it does not.
    """
    from django.db.models import Sum

    StockBatch = apps.get_model("inventory", "StockBatch")
    StockBatchBalance = apps.get_model("inventory", "StockBatchBalance")

    held = {
        row["batch_id"]: row["total"] or Decimal("0")
        for row in StockBatchBalance.objects.values("batch_id").annotate(
            total=Sum("remaining_quantity")
        )
    }
    stranded = []
    for batch in StockBatch.objects.all().only(
        "id", "code", "remaining_quantity"
    ):
        legacy = Decimal(batch.remaining_quantity or 0)
        balances = Decimal(held.get(batch.pk, 0))
        # A thousandth: both sides are stored at three places, and a lot that
        # has been re-weighted is not exact.
        if abs(legacy - balances) > Decimal("0.001"):
            stranded.append(f"{batch.code}: column {legacy}, balances {balances}")
    if stranded:
        raise RuntimeError(
            "Refusing to drop the legacy StockBatch columns: "
            f"{len(stranded)} lot(s) hold quantity the balances do not account "
            "for, so the split did not carry them over. Put the balances right "
            "first — the numbers are all still here until this migration runs. "
            + "; ".join(stranded[:10])
        )


class Migration(migrations.Migration):

    dependencies = [
        ("inventory", "0036_consignor_advance"),
    ]

    operations = [
        migrations.RunPython(
            _refuse_if_the_backfill_did_not_hold, migrations.RunPython.noop
        ),
        migrations.RemoveField(
            model_name="stockbatch",
            name="received_quantity",
        ),
        migrations.RemoveField(
            model_name="stockbatch",
            name="remaining_quantity",
        ),
        migrations.RemoveField(
            model_name="stockbatch",
            name="source_receipt_line",
        ),
    ]
