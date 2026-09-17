"""GIN indexes over the JSONB attribute columns on units and lots.

``StockUnit.attributes`` is the answer to "you don't want 500 columns" that is
neither 500 columns nor an EAV table: one JSONB column per unit, one row, one
read, no join — and Postgres containment and range operators for the filters a
used-goods list actually asks. *"Every iPhone 13 Pro with battery above 85%"* is
``attributes->>'battery_health'``, and without a GIN index it is a sequential
scan over every unit the shop has ever held.

PostgreSQL-only, in the shape ``catalog/0020`` established: on sqlite (the fast
test path) this is a no-op, and the attribute filters fall back to a scan, which
is fine for the tiny datasets there. ``CONCURRENTLY`` — hence ``atomic = False``
— so applying it on a live shop never locks the table against the till.
"""

from django.db import migrations

_INDEXES = [
    ("inventory_stockunit_attrs_gin", "inventory_stockunit", "attributes"),
    ("inventory_stockbatch_attrs_gin", "inventory_stockbatch", "attributes"),
]


def _create(apps, schema_editor):
    connection = schema_editor.connection
    if connection.vendor != "postgresql":
        return
    with connection.cursor() as cursor:
        for index, table, column in _INDEXES:
            cursor.execute(
                f"CREATE INDEX CONCURRENTLY IF NOT EXISTS {index} "
                f"ON {table} USING gin ({column} jsonb_path_ops);"
            )


def _drop(apps, schema_editor):
    connection = schema_editor.connection
    if connection.vendor != "postgresql":
        return
    with connection.cursor() as cursor:
        for index, _table, _column in _INDEXES:
            cursor.execute(f"DROP INDEX CONCURRENTLY IF EXISTS {index};")


class Migration(migrations.Migration):
    # CONCURRENTLY cannot run inside a transaction.
    atomic = False

    dependencies = [
        ("inventory", "0028_batch_code_required"),
    ]

    operations = [
        migrations.RunPython(_create, _drop),
    ]
