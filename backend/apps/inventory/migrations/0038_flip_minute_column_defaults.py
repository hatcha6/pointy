"""Keep a database default on the columns the previous release cannot name.

Five columns this plan adds are ``NOT NULL`` with no database default, because
that is what Django does with a ``CharField(blank=True)``: it adds the column
``DEFAULT ''``, backfills the existing rows, and then **drops the default**
again. The model is satisfied — every write Django makes names every concrete
field — but the previous release's model does not have these fields, so its
``INSERT`` omits the column and Postgres has nothing to fall back on:

    null value in column "gtin" of relation "catalog_productvariant"
    violates not-null constraint

The edge nginx runs that release against this schema for about a minute during
an update (``zero-downtime-updates``), and for that minute
``catalog_productvariant.gtin`` makes **creating a product fail** — which is an
ordinary thing for somebody to be doing.

Putting the default back costs nothing and removes the window. It is a
database-level default only; Django neither knows nor cares, the columns stay
``NOT NULL``, and every write the new code makes still names them explicitly.
Drop these together with ``Product.tracks_expiry``, in the release after the
whole fleet is past this one (``make backend-contract-gate``).

The three on ``inventory_stockbatch`` are unreachable — the previous release
only inserts a lot from ``create_expiring_stock_batch``, which returns early
unless the product tracks expiry, and none does. They are here anyway so the
argument does not rest on that: a default that costs nothing is cheaper than a
premise that has to keep being true.
"""

from django.db import migrations

COLUMNS = (
    ("catalog_productvariant", "gtin"),
    ("core_shopsettings", "shop_phone"),
    ("inventory_stockbatch", "barcode"),
    ("inventory_stockbatch", "gtin"),
    ("inventory_stockbatch", "notes"),
)


def _set(apps, schema_editor):
    if schema_editor.connection.vendor != "postgresql":
        return
    with schema_editor.connection.cursor() as cursor:
        for table, column in COLUMNS:
            cursor.execute(
                f'ALTER TABLE "{table}" ALTER COLUMN "{column}" SET DEFAULT \'\''
            )


def _drop(apps, schema_editor):
    if schema_editor.connection.vendor != "postgresql":
        return
    with schema_editor.connection.cursor() as cursor:
        for table, column in COLUMNS:
            cursor.execute(
                f'ALTER TABLE "{table}" ALTER COLUMN "{column}" DROP DEFAULT'
            )


class Migration(migrations.Migration):

    dependencies = [
        ("catalog", "0030_product_tracking_since_backfill"),
        ("core", "0035_shopsettings_shop_phone"),
        ("inventory", "0037_drop_legacy_batch_columns"),
    ]

    operations = [migrations.RunPython(_set, _drop)]
