"""Trigram indexes on the stored search columns from 0035.

Every-word search asks "does the folded name contain this word" once per typed
word; a trigram GIN index answers that from the index instead of reading each
name. The loanword key gets one too — it is the last-resort match, and the
last resort should not be the slow path.

``CREATE INDEX CONCURRENTLY`` (hence ``atomic = False``) so a shop keeps
trading while the index builds; ``IF NOT EXISTS`` keeps a re-run harmless.
PostgreSQL only, like 0020/0021.
"""

from django.db import migrations

_INDEXES = [
    ("catalog_product_search_name_trgm", "catalog_product", "search_name"),
    ("catalog_product_search_skeleton_trgm", "catalog_product", "search_skeleton"),
    ("catalog_variant_search_name_trgm", "catalog_productvariant", "search_name"),
    ("catalog_alias_search_alias_trgm", "catalog_productalias", "search_alias"),
]


def _create(apps, schema_editor):
    connection = schema_editor.connection
    if connection.vendor != "postgresql":
        return
    with connection.cursor() as cursor:
        for index, table, column in _INDEXES:
            cursor.execute(
                f"CREATE INDEX CONCURRENTLY IF NOT EXISTS {index} "
                f"ON {table} USING gin ({column} gin_trgm_ops);"
            )


def _drop(apps, schema_editor):
    connection = schema_editor.connection
    if connection.vendor != "postgresql":
        return
    with connection.cursor() as cursor:
        for index, _table, _column in _INDEXES:
            cursor.execute(f"DROP INDEX CONCURRENTLY IF EXISTS {index};")


class Migration(migrations.Migration):
    atomic = False

    dependencies = [
        ("catalog", "0035_search_generated_columns"),
    ]

    operations = [
        migrations.RunPython(_create, _drop, elidable=False),
    ]
