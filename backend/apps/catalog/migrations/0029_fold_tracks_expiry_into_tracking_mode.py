"""§18.4: `tracks_expiry` and `tracking_mode` cannot both be the answer.

A product could be ``tracks_expiry`` *and* ``quantity``-mode, which is two flags
governing one behaviour — and the plan is blunt about what that costs: it is how
a shop's expiry tracking stops without anyone noticing. Worse, it left two
parallel implementations of the same idea running side by side. A pharmacy that
ticked the box years ago kept the legacy anonymous-cohort path —
``create_expiring_stock_batch`` and ``consume_expiring_stock_batches``, with
generated ``RL-<pk>`` codes and no allocations — while everything built in
Phases A–C went to lots that have identity, provenance and a recall report.

So every product that tracks expiry becomes ``tracking_mode = batch``. It is
the same claim, said once: a shop that cares when its stock goes off is a shop
whose stock belongs to cohorts.

**What changes for those shops, stated plainly.** Receiving offers the lot
capture sheet, and a delivery whose lot is not typed in still lands — it gets a
generated code the UI renders as «بدون رقم دفعة», exactly as the anonymous
cohort did. Checkout allocates from the earliest-expiring lot instead of
decrementing a bare counter, and refuses an expired one when
``prevent_selling_expired`` is on, which is the behaviour the flag was always
supposed to buy. The bin, the totals and every report are unchanged, because a
batch-mode variant's on-hand is the sum of its balances and the backfill in
inventory.0026 already created one balance per cohort.

The reverse is exact for the rows this touched, and only those: it is recorded
so a rollback puts them back rather than guessing.
"""

from django.db import migrations

FOLDED_MARKER = "batch"


def fold(apps, schema_editor):
    Product = apps.get_model("catalog", "Product")
    # Remember which products genuinely expire *before* the flag becomes a
    # mirror of the mode. Otherwise the fold would make every lot-tracked
    # product demand an expiry date at receiving — right for milk, wrong for a
    # paint batch — and a shop's receiving would change on upgrade day.
    Product.objects.filter(tracks_expiry=True).update(expiry_required=True)
    # Only products that are not already tracked. A product someone deliberately
    # made ``serial`` or ``serial_batch`` keeps the mode they chose — and
    # ``serial_batch`` already tracks lots, so its expiry flag is right either
    # way.
    Product.objects.filter(tracks_expiry=True, tracking_mode="quantity").update(
        tracking_mode=FOLDED_MARKER
    )
    # And make the mirror agree everywhere, in both directions: a lot-tracked
    # product tracks expiry, and a quantity-mode one does not.
    Product.objects.filter(
        tracking_mode__in=(FOLDED_MARKER, "serial_batch"), tracks_expiry=False
    ).update(tracks_expiry=True)
    Product.objects.filter(
        tracking_mode__in=("quantity", "serial"), tracks_expiry=True
    ).update(tracks_expiry=False)


def unfold(apps, schema_editor):
    """Put the folded products back to ``quantity``, keeping the flag on.

    Only the ones this migration could have moved: a ``serial_batch`` product
    was never touched, and a ``batch`` product created after the fold is
    indistinguishable from one folded into it — which is the honest limit of a
    reverse here, and the reason the column survives until the contract release
    rather than being dropped in the same breath.
    """
    Product = apps.get_model("catalog", "Product")
    Product.objects.filter(tracking_mode=FOLDED_MARKER).update(
        tracking_mode="quantity", tracks_expiry=True
    )


class Migration(migrations.Migration):

    dependencies = [
        ("catalog", "0028_product_expiry_required"),
    ]

    operations = [
        migrations.RunPython(fold, unfold),
    ]
