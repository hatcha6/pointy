"""Every existing stock row lands in the shop's one and only location.

Two things happen here, and both are chosen so a shop that never opens a second
warehouse cannot tell this ran.

The backfill is a single ``UPDATE``: ``StockItem`` is bounded by the variant
count, so this is tens of thousands of rows at the very worst, not the millions
a movement table would carry.

The rename is the part worth explaining. The default warehouse has been called
``المخزن الرئيسي`` — *the main store room* — since it was created, which was the
right neutral name while nothing displayed it. Phase 2 puts it on screen, and it
then describes a back room most Libyan shops have not got: they are one showroom
and always will be. It becomes ``المعرض``. The ``code`` is left alone because
code is what other rows reference and name is what people read, and a shop that
has already renamed its own warehouse keeps whatever it chose.
"""

from django.db import migrations

OLD_DEFAULT_NAME = "المخزن الرئيسي"
NEW_DEFAULT_NAME = "المعرض"


def land_existing_stock_in_the_default_warehouse(apps, schema_editor):
    Warehouse = apps.get_model("inventory", "Warehouse")
    StockItem = apps.get_model("inventory", "StockItem")

    warehouse = Warehouse.objects.filter(is_default=True).first()
    if warehouse is None:
        warehouse, _ = Warehouse.objects.get_or_create(
            code="main",
            defaults={"name": NEW_DEFAULT_NAME, "is_default": True},
        )

    if warehouse.name == OLD_DEFAULT_NAME:
        warehouse.name = NEW_DEFAULT_NAME
        warehouse.save(update_fields=["name", "updated_at"])

    StockItem.objects.filter(warehouse__isnull=True).update(warehouse=warehouse)


def unland(apps, schema_editor):
    """Reversible, so a rollback does not strand the column half-populated.

    The name is deliberately *not* reverted: a shop may have renamed the
    warehouse itself between the two, and guessing which is which would be worse
    than leaving a name alone.
    """
    StockItem = apps.get_model("inventory", "StockItem")
    StockItem.objects.update(warehouse=None)


class Migration(migrations.Migration):
    dependencies = [
        ("inventory", "0018_warehouses_on_stock_items"),
    ]

    operations = [
        migrations.RunPython(
            land_existing_stock_in_the_default_warehouse,
            unland,
        ),
    ]
