"""Adopting stock rows an older backend wrote during a live update.

``StockItem.warehouse`` is nullable for exactly one release, because a live
update runs the old backend against the new schema for about a minute
(``deploy/onprem/README.md``) and the old backend inserts stock rows knowing
nothing about warehouses. A ``NOT NULL`` column with no database default would
fail those inserts, and on this table a failed insert is a till that cannot
sell — so the column accepts a null rather than the shop losing a minute of
trading.

What it must not do is *stay* null. A stock row belonging to no warehouse is
counted by ``quantity_on_hand`` (which sums every row) and missed by
``quantity_on_hand_at`` (which filters), so the shop's total would be right
while the showroom's was short — the two disagreeing quietly, which is the
failure mode this product exists to prevent.

Same mechanism, same reasoning and the same DB-introspection guard as
``apps.documents.reconciliation``: it runs on ``post_migrate``, which fires
again when the managed container is rebuilt on the new image after the flip, by
which time the window has closed and every stray is visible. Idempotent, and a
no-op on a fresh install.
"""

from django.db import connection
from django.db.models.signals import post_migrate
from django.dispatch import receiver


def adopt_orphan_stock_rows() -> int:
    """Give every warehouse-less stock row the default warehouse.

    Returns the number adopted, which is zero on every install that did not
    take a write during its own upgrade window.
    """
    from .models import StockItem, Warehouse

    if not _has_warehouse_column():
        return 0
    if not StockItem.objects.filter(warehouse__isnull=True).exists():
        return 0
    return StockItem.objects.filter(warehouse__isnull=True).update(
        warehouse_id=Warehouse.default_id()
    )


def _has_warehouse_column() -> bool:
    """Whether the table actually carries ``warehouse_id`` yet.

    Asked of the database, not the model. ``post_migrate`` fires for partial and
    backwards runs too — ``test_opening_balance_migration`` rewinds this very
    app to exercise a historical migration, and Django re-emits the signal after
    the flush around such a test — and there the live model has the column while
    the table does not. Nothing to adopt in that state, so nothing is attempted.
    """
    from .models import StockItem

    with connection.cursor() as cursor:
        try:
            columns = connection.introspection.get_table_description(
                cursor, StockItem._meta.db_table
            )
        except Exception:
            return False
    return any(column.name == "warehouse_id" for column in columns)


@receiver(post_migrate)
def _adopt_after_migrate(sender, **kwargs):
    # Once per ``migrate``, not once per installed app.
    if getattr(sender, "name", "") != "apps.inventory":
        return
    adopt_orphan_stock_rows()
