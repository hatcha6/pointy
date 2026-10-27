"""Index the SKU series, so the next number is a lookup and not a scan.

``sku_series._highest_code`` takes the highest plain-number code across variant
SKUs, variant barcodes, packaging barcodes and extra barcodes. Unindexed, each
of those four is a full scan with a regex, and it runs for every variant saved
without a SKU — so a data migration from a system with no codes did a full
catalogue scan per product, and slowed down as the catalogue it was building
grew.

Each index holds exactly the rows the series counts (one to seven digits, the
same predicate the query uses) keyed by their numeric value, so the highest is
the last entry: Postgres answers ``max`` with one backward index step.

Built ``CONCURRENTLY`` (hence ``atomic = False``) so a live shop's catalogue
is never locked against writes while it builds, and ``IF NOT EXISTS`` like the
trigram indexes. Postgres-only: on sqlite the series still scans, which the
tiny test catalogues never notice.
"""

from django.db import migrations

# Must match ``sku_series._SERIES_CODE`` and the query there character for
# character, or the planner cannot prove the predicate and falls back to a scan.
SERIES_PREDICATE = "~ '^[0-9]{1,7}$'"

INDEXES = [
    ("catalog_variant_sku_series", "catalog_productvariant", "sku"),
    ("catalog_variant_barcode_series", "catalog_productvariant", "barcode"),
    ("catalog_unitbarcode_series", "catalog_productunitbarcode", "barcode"),
    ("catalog_extrabarcode_series", "catalog_productvariantbarcode", "barcode"),
]


def _create(apps, schema_editor):
    connection = schema_editor.connection
    if connection.vendor != "postgresql":
        return
    with connection.cursor() as cursor:
        for index, table, column in INDEXES:
            cursor.execute(
                f"CREATE INDEX CONCURRENTLY IF NOT EXISTS {index} "
                f"ON {table} ((({column})::bigint)) WHERE {column} {SERIES_PREDICATE};"
            )


def _drop(apps, schema_editor):
    connection = schema_editor.connection
    if connection.vendor != "postgresql":
        return
    with connection.cursor() as cursor:
        for index, _table, _column in INDEXES:
            cursor.execute(f"DROP INDEX CONCURRENTLY IF EXISTS {index};")


class Migration(migrations.Migration):
    # CONCURRENTLY cannot run inside a transaction.
    atomic = False

    dependencies = [
        ("catalog", "0040_bulk_price_change"),
    ]

    operations = [
        migrations.RunPython(_create, _drop),
    ]
