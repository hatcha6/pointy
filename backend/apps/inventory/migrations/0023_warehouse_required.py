"""The contract half of the warehouse phase: every stock row has a location.

``0018``–``0022`` added these columns nullable on purpose. A live update runs the
previous release against the new schema for about a minute, and that release
knew nothing about warehouses, so a NOT NULL column would have failed its
inserts — on ``StockMovement``, that is every sale. The plan was always to make
them required once a release had shipped in between, and 0.5.1 was it.

**Only ``StockItem`` was ever backfilled** (``0019``). The other columns were
added and left, so every row written before the warehouse phase still holds a
null — on a shop with a year of trading that is every movement it ever recorded.

**Why this is not one ``AlterField``.** Measured against 1.6M movements with a
till still selling, the obvious version failed twice: once because a writer
inserted a null between the backfill and the constraint, and once with
``deadlock detected`` — the backfill holding row locks across a 648 MB table
while ``SET NOT NULL`` queued for ACCESS EXCLUSIVE, with the shop's inserts
queued behind that. Both failed safely, but a release that can only be applied
with the shop shut is a release nobody applies.

So the movement table gets the three-step form instead, which never holds a
long lock:

1. the backfill runs in **batches, each its own transaction**, so no statement
   holds row locks across the table;
2. ``CHECK (... IS NOT NULL) NOT VALID`` is added — metadata only, instant, and
   from this moment the database refuses new nulls;
3. ``VALIDATE CONSTRAINT`` scans the table under SHARE UPDATE EXCLUSIVE, which
   does **not** block reads, inserts or updates — the shop keeps trading;
4. ``SET NOT NULL`` is then free: Postgres 12+ trusts the validated check
   instead of rescanning.

Every lock this takes is either weak or held for microseconds, and each one is
taken under a short ``lock_timeout`` with retries, so a momentary pile-up backs
off instead of queueing the shop behind us.

The remaining nullable warehouse column after this is
``sales.RegisterProfile.warehouse``, which is not debt: a till that has not been
pointed at a location yet is a real state.
"""

import copy
import time

from django.db import migrations, models, OperationalError
import django.db.models.deletion

NEW_DEFAULT_NAME = "المعرض"

#: Rows per backfill statement. Small enough that no transaction holds locks
#: long enough to matter, large enough that 1.6M rows is a few hundred
#: round trips rather than a million.
BATCH = 5_000

#: Never wait long for a lock. If something is mid-transaction on this table we
#: back off and try again, because the alternative — queueing — puts every
#: checkout behind us for as long as that transaction runs.
LOCK_TIMEOUT = "2s"
LOCK_ATTEMPTS = 10


def default_warehouse(apps):
    """The shop's default location, created if this install somehow lacks one.

    Mirrors ``0019``: a fresh install that never ran the stock backfill (because
    it had no stock) can still reach this migration, and a contract that cannot
    name a location would fail on the first row it had to fill.
    """
    Warehouse = apps.get_model("inventory", "Warehouse")
    warehouse = Warehouse.objects.filter(is_default=True).first()
    if warehouse is None:
        warehouse, _ = Warehouse.objects.get_or_create(
            code="main",
            defaults={"name": NEW_DEFAULT_NAME, "is_default": True},
        )
    return warehouse


def _batched(model, fill, *, ordering="pk"):
    """Walk the table in primary-key windows, one transaction each.

    Ranges rather than ``filter(...isnull=True)[:n]`` repeatedly: as the nulls
    thin out, that form rescans further each time and the tail of the backfill
    slows to a crawl. A pk window is an index range whatever is left in it.
    """
    bounds = model.objects.aggregate(
        low=models.Min(ordering), high=models.Max(ordering)
    )
    low, high = bounds["low"], bounds["high"]
    if low is None:
        return 0
    moved = 0
    start = low
    while start <= high:
        moved += fill(model.objects.filter(pk__gte=start, pk__lt=start + BATCH))
        start += BATCH
    return moved


def land_everything_somewhere(apps, schema_editor):
    from django.db.models import OuterRef, Subquery

    StockItem = apps.get_model("inventory", "StockItem")
    StockMovement = apps.get_model("inventory", "StockMovement")
    StockCount = apps.get_model("inventory", "StockCount")
    warehouse = default_warehouse(apps)

    # Bounded by the variant count, so one statement is fine.
    StockItem.objects.filter(warehouse__isnull=True).update(warehouse=warehouse)

    # The big one. A movement takes the location of the stock row it moved,
    # which is exactly what ``StockMovement.save`` does for new rows.
    def fill(window):
        return window.filter(
            warehouse__isnull=True, stock_item__isnull=False
        ).update(
            warehouse_id=Subquery(
                StockItem.objects.filter(pk=OuterRef("stock_item_id")).values(
                    "warehouse_id"
                )[:1]
            )
        ) + window.filter(warehouse__isnull=True).update(warehouse=warehouse)

    _batched(StockMovement, fill)

    StockCount.objects.filter(warehouse__isnull=True).update(warehouse=warehouse)


def unland(apps, schema_editor):
    """Nothing to undo: the column goes back to nullable, and which rows were
    filled by hand versus by the shop is neither recoverable nor worth
    recovering — a null location is the state being left behind."""


def _run_locking(schema_editor, sql):
    """Take a lock briefly or not at all, and try again rather than queue."""
    last = None
    for attempt in range(LOCK_ATTEMPTS):
        try:
            with schema_editor.connection.cursor() as cursor:
                cursor.execute(f"SET lock_timeout = '{LOCK_TIMEOUT}'")
                try:
                    cursor.execute(sql)
                finally:
                    cursor.execute("SET lock_timeout = DEFAULT")
            return
        except OperationalError as exc:  # lock_timeout, or a deadlock victim
            last = exc
            time.sleep(min(2 ** attempt * 0.25, 5.0))
    raise last


def require_warehouse(apps, schema_editor):
    """Steps 2-4 of the module docstring, on the movement table only."""
    if schema_editor.connection.vendor != "postgresql":
        # sqlite (the fast test path) rebuilds the whole table for any ALTER, so
        # there is no lock to dance around — but the schema still has to change,
        # or the model would claim NOT NULL over a column that permits nulls.
        model = apps.get_model("inventory", "StockMovement")
        old = model._meta.get_field("warehouse")
        new = copy.deepcopy(old)
        new.null = False
        schema_editor.alter_field(model, old, new)
        return
    _run_locking(
        schema_editor,
        "ALTER TABLE inventory_stockmovement "
        "ADD CONSTRAINT stockmovement_warehouse_not_null "
        "CHECK (warehouse_id IS NOT NULL) NOT VALID",
    )
    # The long part, and the one that does not block the shop.
    with schema_editor.connection.cursor() as cursor:
        cursor.execute(
            "ALTER TABLE inventory_stockmovement "
            "VALIDATE CONSTRAINT stockmovement_warehouse_not_null"
        )
    _run_locking(
        schema_editor,
        "ALTER TABLE inventory_stockmovement "
        "ALTER COLUMN warehouse_id SET NOT NULL",
    )
    # Redundant now that the column itself is NOT NULL, and a check Postgres
    # would otherwise evaluate on every insert forever.
    _run_locking(
        schema_editor,
        "ALTER TABLE inventory_stockmovement "
        "DROP CONSTRAINT stockmovement_warehouse_not_null",
    )


def allow_null_warehouse(apps, schema_editor):
    if schema_editor.connection.vendor != "postgresql":
        model = apps.get_model("inventory", "StockMovement")
        old = model._meta.get_field("warehouse")
        new = copy.deepcopy(old)
        new.null = True
        schema_editor.alter_field(model, old, new)
        return
    _run_locking(
        schema_editor,
        "ALTER TABLE inventory_stockmovement ALTER COLUMN warehouse_id DROP NOT NULL",
    )


class Migration(migrations.Migration):
    # Each batch and each ALTER commits on its own. Wrapping the lot in one
    # transaction is the thing that deadlocked against a trading till.
    atomic = False

    dependencies = [
        ("inventory", "0022_stock_transfers"),
    ]

    operations = [
        migrations.RunPython(land_everything_somewhere, unland),
        # Small tables: bounded by the variant count and by how often anyone
        # counts stock. The plain form costs a scan of nothing.
        migrations.AlterField(
            model_name="stockitem",
            name="warehouse",
            field=models.ForeignKey(
                blank=True,
                on_delete=django.db.models.deletion.PROTECT,
                related_name="stock_items",
                to="inventory.warehouse",
            ),
        ),
        migrations.AlterField(
            model_name="stockcount",
            name="warehouse",
            field=models.ForeignKey(
                blank=True,
                on_delete=django.db.models.deletion.PROTECT,
                related_name="stock_counts",
                to="inventory.warehouse",
            ),
        ),
        # The movement table is the one with a year of history in it, so Django
        # is told what the model looks like while the database is changed the
        # slow, unblocking way.
        migrations.SeparateDatabaseAndState(
            database_operations=[
                migrations.RunPython(require_warehouse, allow_null_warehouse),
            ],
            state_operations=[
                migrations.AlterField(
                    model_name="stockmovement",
                    name="warehouse",
                    field=models.ForeignKey(
                        blank=True,
                        on_delete=django.db.models.deletion.PROTECT,
                        related_name="stock_movements",
                        to="inventory.warehouse",
                    ),
                ),
            ],
        ),
    ]
