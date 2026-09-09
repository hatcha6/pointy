"""The contract half for stock holds: every reservation names a location.

``0029`` added the column nullable so the release before it could keep inserting
during a live update, and left the backfill for later. Later is now — see
``inventory.0023`` for the whole story of this phase.

The fill mirrors ``StockReservation.save``: the shop's default. A hold placed
before locations existed was, by definition, a hold on the only place there was.
"""

from django.db import migrations, models
import django.db.models.deletion

NEW_DEFAULT_NAME = "المعرض"


def land_reservations(apps, schema_editor):
    Warehouse = apps.get_model("inventory", "Warehouse")
    StockReservation = apps.get_model("sales", "StockReservation")

    warehouse = Warehouse.objects.filter(is_default=True).first()
    if warehouse is None:
        warehouse, _ = Warehouse.objects.get_or_create(
            code="main",
            defaults={"name": NEW_DEFAULT_NAME, "is_default": True},
        )
    StockReservation.objects.filter(warehouse__isnull=True).update(warehouse=warehouse)


def unland(apps, schema_editor):
    """Nothing to undo: the column goes back to nullable and a null location is
    the state being left behind."""


class Migration(migrations.Migration):
    dependencies = [
        ("sales", "0029_reservation_warehouse"),
        # Ordered after the inventory contract so the default location is
        # guaranteed to exist before anything is pointed at it.
        ("inventory", "0023_warehouse_required"),
    ]

    operations = [
        migrations.RunPython(land_reservations, unland),
        migrations.AlterField(
            model_name="stockreservation",
            name="warehouse",
            field=models.ForeignKey(
                blank=True,
                on_delete=django.db.models.deletion.PROTECT,
                related_name="stock_reservations",
                to="inventory.warehouse",
            ),
        ),
    ]
