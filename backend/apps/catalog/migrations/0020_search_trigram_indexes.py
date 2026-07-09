"""Trigram (pg_trgm) GIN indexes for CatalogRelevanceFilter.

The relevance search runs ~10 correlated ``Exists()`` subqueries per query, most
using ``ILIKE`` (``icontains`` / ``istartswith`` / ``iexact``) on variant sku /
barcode / name, unit barcodes, product name and aliases. Without a trigram index
every one of those is a sequential scan, which crawls on a real-shop catalogue
(tens of thousands of variants). ``gin_trgm_ops`` makes ``ILIKE`` (including the
leading-wildcard ``%term%`` case) index-accelerated.

Built with ``CREATE INDEX CONCURRENTLY`` (hence ``atomic = False``) so applying
this on a live shop never locks the catalogue against writes. ``IF NOT EXISTS``
makes it idempotent with the same hotfix run manually via psql.
"""

from django.db import migrations

_INDEXES = [
    ("catalog_product_name_trgm", "catalog_product", "name"),
    ("catalog_variant_sku_trgm", "catalog_productvariant", "sku"),
    ("catalog_variant_barcode_trgm", "catalog_productvariant", "barcode"),
    ("catalog_variant_name_trgm", "catalog_productvariant", "name"),
    ("catalog_unitbarcode_trgm", "catalog_productunitbarcode", "barcode"),
    ("catalog_alias_trgm", "catalog_productalias", "alias"),
]


def _create(index, table, column):
    return (
        f"CREATE INDEX CONCURRENTLY IF NOT EXISTS {index} "
        f"ON {table} USING gin ({column} gin_trgm_ops);"
    )


def _drop(index):
    return f"DROP INDEX CONCURRENTLY IF EXISTS {index};"


def _create_trigram_indexes(apps, schema_editor):
    # pg_trgm / gin_trgm_ops are PostgreSQL-only. On sqlite (the fast/parallel
    # test path) this is a no-op — ILIKE falls back to a scan there, which is
    # fine for the tiny test datasets.
    connection = schema_editor.connection
    if connection.vendor != "postgresql":
        return
    with connection.cursor() as cursor:
        cursor.execute("CREATE EXTENSION IF NOT EXISTS pg_trgm;")
        for index, table, column in _INDEXES:
            cursor.execute(_create(index, table, column))


def _drop_trigram_indexes(apps, schema_editor):
    connection = schema_editor.connection
    if connection.vendor != "postgresql":
        return
    with connection.cursor() as cursor:
        for index, _table, _column in _INDEXES:
            cursor.execute(_drop(index))


class Migration(migrations.Migration):
    # CONCURRENTLY cannot run inside a transaction.
    atomic = False

    dependencies = [
        ("catalog", "0019_product_popularity"),
    ]

    operations = [
        migrations.RunPython(_create_trigram_indexes, _drop_trigram_indexes),
    ]
