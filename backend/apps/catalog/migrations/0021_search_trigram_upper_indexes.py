"""Replace 0020's raw-column trigram indexes with ``UPPER(col::text)`` ones.

0020 built ``gin (col gin_trgm_ops)`` on the bare column, but Django's
``icontains`` / ``istartswith`` / ``iexact`` emit ``UPPER(col::text) LIKE
UPPER(%s)``. A trigram GIN index on the raw column does **not** match an
``UPPER(col::text)`` predicate, so the planner ignored 0020's indexes and fell
back to a sequential scan on every search sub-query. Confirmed with EXPLAIN
ANALYZE on a real ~22k-variant catalogue: ``Seq Scan ... Rows Removed by
Filter: 22290`` on each match sub-query.

These expression indexes match the emitted predicate, so the same searches
become Bitmap Index Scans (measured: the query's DB time roughly halved once
JIT was also disabled). The dead raw-column indexes from 0020 are dropped to
save the write + storage overhead of maintaining an index nothing queries.

``CREATE INDEX CONCURRENTLY`` (hence ``atomic = False``) so applying this on a
live shop never locks the catalogue; ``IF NOT EXISTS`` / ``IF EXISTS`` keep it
idempotent with the same fix applied manually via psql.
"""

from django.db import migrations

# (expression index name, table, column) — matches ``UPPER(col::text) LIKE ...``.
_INDEXES = [
    ("catalog_product_name_uptrgm", "catalog_product", "name"),
    ("catalog_variant_sku_uptrgm", "catalog_productvariant", "sku"),
    ("catalog_variant_barcode_uptrgm", "catalog_productvariant", "barcode"),
    ("catalog_variant_name_uptrgm", "catalog_productvariant", "name"),
    ("catalog_unitbarcode_uptrgm", "catalog_productunitbarcode", "barcode"),
    ("catalog_alias_uptrgm", "catalog_productalias", "alias"),
]

# The dead raw-column indexes from 0020 (same order → same table/column).
_OLD_INDEXES = [
    "catalog_product_name_trgm",
    "catalog_variant_sku_trgm",
    "catalog_variant_barcode_trgm",
    "catalog_variant_name_trgm",
    "catalog_unitbarcode_trgm",
    "catalog_alias_trgm",
]


def _create_upper(index, table, column):
    return (
        f"CREATE INDEX CONCURRENTLY IF NOT EXISTS {index} "
        f"ON {table} USING gin (UPPER({column}::text) gin_trgm_ops);"
    )


def _create_raw(index, table, column):
    return (
        f"CREATE INDEX CONCURRENTLY IF NOT EXISTS {index} "
        f"ON {table} USING gin ({column} gin_trgm_ops);"
    )


def _drop(index):
    return f"DROP INDEX CONCURRENTLY IF EXISTS {index};"


class Migration(migrations.Migration):
    # CONCURRENTLY cannot run inside a transaction.
    atomic = False

    dependencies = [
        ("catalog", "0020_search_trigram_indexes"),
    ]

    operations = [
        *[
            migrations.RunSQL(_create_upper(index, table, column), reverse_sql=_drop(index))
            for index, table, column in _INDEXES
        ],
        *[
            migrations.RunSQL(_drop(old), reverse_sql=_create_raw(old, table, column))
            for old, (_, table, column) in zip(_OLD_INDEXES, _INDEXES)
        ],
    ]
