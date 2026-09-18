"""The units list's own ordering, indexed — concurrently on Postgres.

``inventory_stockunit`` is one of the tables that grows with *transactions*
rather than with assortment: a used-goods trader holds a row per handset it has
ever touched, and the list orders by ``-in_stock_since, -id`` with no index
behind it, so every page is a full sort before the offset is even applied. That
is the shape `purchases-screen-perf` names.

§15.1 requires the build to be concurrent on a table that size, or it takes an
ACCESS EXCLUSIVE lock and the till stops selling for the duration of an update.
The 0025 indexes did not need that because they landed on tables the same
migration had just created; this one does not have that excuse.

``AddIndexConcurrently`` is Postgres-only and the fast test path is sqlite, so
this splits state from database the way 0029 splits them: Django's model state
learns about the index either way, and the database gets it concurrently where
that means something and plainly where it does not.
"""

from django.db import migrations, models

INDEX_NAME = "stockunit_recent_idx"
_INDEX = models.Index(fields=["-in_stock_since", "-id"], name=INDEX_NAME)


def _create(apps, schema_editor):
    model = apps.get_model("inventory", "StockUnit")
    if schema_editor.connection.vendor != "postgresql":
        schema_editor.add_index(model, _INDEX)
        return
    with schema_editor.connection.cursor() as cursor:
        cursor.execute(
            f'CREATE INDEX CONCURRENTLY IF NOT EXISTS {INDEX_NAME} '
            f'ON inventory_stockunit ("in_stock_since" DESC, "id" DESC);'
        )


def _drop(apps, schema_editor):
    model = apps.get_model("inventory", "StockUnit")
    if schema_editor.connection.vendor != "postgresql":
        schema_editor.remove_index(model, _INDEX)
        return
    with schema_editor.connection.cursor() as cursor:
        cursor.execute(f"DROP INDEX CONCURRENTLY IF EXISTS {INDEX_NAME};")


class Migration(migrations.Migration):
    # CREATE INDEX CONCURRENTLY cannot run inside a transaction.
    atomic = False

    dependencies = [
        ("catalog", "0027_identified_stock"),
        ("customers", "0012_paymentcard_cardholder_name"),
        ("inventory", "0032_unit_attribute_permission"),
        ("purchasing", "0034_seed_order_number_series"),
        ("sales", "0034_trade_in"),
    ]

    operations = [
        migrations.SeparateDatabaseAndState(
            state_operations=[
                migrations.AddIndex(model_name="stockunit", index=_INDEX),
            ],
            database_operations=[migrations.RunPython(_create, _drop)],
        ),
    ]
