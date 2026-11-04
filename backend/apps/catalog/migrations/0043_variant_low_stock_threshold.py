from decimal import Decimal

from django.core.validators import MinValueValidator
from django.db import migrations, models
from django.db.models import Max, Q

#: The ``StockItem.reorder_level`` every row was born with. No screen ever let
#: anyone change it, so a row still holding it is nobody's decision.
_HIDDEN_DEFAULT = 5


def carry_over_imported_levels(apps, schema_editor):
    """Keep the thresholds somebody actually chose, and only those.

    The only way a stock row ever got a level other than 5 was a data
    migration from the shop's previous system, so those are the values worth
    keeping. Everything else starts blank — not watched — and the owner sets
    the variants they care about. A shop's several locations collapse to the
    highest level any of them carried: the threshold is now shop-wide, and the
    highest one is the one that warned soonest before.
    """
    StockItem = apps.get_model("inventory", "StockItem")
    ProductVariant = apps.get_model("catalog", "ProductVariant")
    levels = (
        StockItem.objects.filter(reorder_level__gt=0)
        .exclude(reorder_level=_HIDDEN_DEFAULT)
        .order_by()
        .values("variant_id")
        .annotate(level=Max("reorder_level"))
    )
    batch = []
    for row in levels.iterator(chunk_size=2000):
        batch.append(
            ProductVariant(pk=row["variant_id"], low_stock_threshold=Decimal(row["level"]))
        )
        if len(batch) >= 2000:
            ProductVariant.objects.bulk_update(batch, ["low_stock_threshold"])
            batch = []
    if batch:
        ProductVariant.objects.bulk_update(batch, ["low_stock_threshold"])


class Migration(migrations.Migration):
    # Expand only: ``StockItem.reorder_level`` and the shop-wide
    # ``low_stock_threshold`` setting stay in the schema for one release, so the
    # backend still serving during a live update keeps reading and writing them.

    dependencies = [
        ("catalog", "0042_sku_series_reservation"),
        # Only ``StockItem.reorder_level`` is read, and it has existed since
        # inventory's first migration. Depending on the tip instead would make
        # every test that rewinds inventory unapply this one too.
        ("inventory", "0001_initial"),
    ]

    operations = [
        migrations.AddField(
            model_name="productvariant",
            name="low_stock_threshold",
            field=models.DecimalField(
                blank=True,
                decimal_places=3,
                max_digits=12,
                null=True,
                validators=[MinValueValidator(Decimal("0"))],
            ),
        ),
        migrations.AddConstraint(
            model_name="productvariant",
            constraint=models.CheckConstraint(
                condition=Q(low_stock_threshold__isnull=True) | Q(low_stock_threshold__gte=0),
                name="product_variant_low_stock_threshold_non_negative",
            ),
        ),
        migrations.RunPython(carry_over_imported_levels, migrations.RunPython.noop),
    ]
