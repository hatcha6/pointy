"""When each tracked product started being tracked, so blame lands correctly.

A shop that switches a product from ``quantity`` to ``serial`` after two years
of trading has two years of ledger entries with no allocations under them —
correctly, because there were no articles to name. Invariant 5 judged them by
today's mode and reported a permanent violation for a shop that had done
everything right, which is worse than no check at all: an invariant nobody can
get to green is one nobody reads.

Additive and nullable, so the previous release runs against this schema
unchanged. The backfill takes the earliest allocation a product's variants
carry — tracking demonstrably started no later than the first article it named
— and otherwise the product's own creation, which for a product that has never
moved tracked stock costs nothing either way.
"""

from django.db import migrations, models


def _backfill(apps, schema_editor):
    from django.db.models import Min

    Product = apps.get_model("catalog", "Product")
    tracked = list(
        Product.objects.exclude(tracking_mode="quantity").filter(
            tracking_since__isnull=True
        )
    )
    if not tracked:
        return

    # Deliberately **no** declared dependency on ``apps.inventory``. Tying
    # this column to that graph makes rewinding inventory drop a catalog
    # column, which is how ``test_opening_balance_migration`` — a test that
    # drives the migration executor backwards on purpose — starts failing in a
    # file that says nothing about tracking. So the allocation table is read
    # if the state has it and skipped if it does not, and a shop with no
    # allocations loses nothing either way.
    earliest = {}
    try:
        StockAllocation = apps.get_model("inventory", "StockAllocation")
    except LookupError:
        StockAllocation = None
    if StockAllocation is not None:
        earliest = dict(
            StockAllocation.objects.filter(variant__product__in=tracked)
            .values_list("variant__product_id")
            .annotate(first=Min("posting_at"))
            .values_list("variant__product_id", "first")
        )

    for product in tracked:
        product.tracking_since = earliest.get(product.pk) or product.created_at
    Product.objects.bulk_update(tracked, ["tracking_since"], batch_size=500)


class Migration(migrations.Migration):

    dependencies = [
        ("catalog", "0029_fold_tracks_expiry_into_tracking_mode"),
    ]

    operations = [
        migrations.AddField(
            model_name="product",
            name="tracking_since",
            field=models.DateTimeField(blank=True, editable=False, null=True),
        ),
        migrations.RunPython(_backfill, migrations.RunPython.noop),
    ]
