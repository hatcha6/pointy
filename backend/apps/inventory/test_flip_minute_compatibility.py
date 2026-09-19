"""The flip minute, reproduced: the previous release writing this schema.

``zero-downtime-updates`` is the constraint — the edge nginx serves the
*previous* release against the new schema for about a minute — and the whole
argument for shipping this plan as a single live update rests on knowing what
that release can and cannot do here. This file asks it directly, in raw SQL,
because that is the one way to write a row the way a backend that has never
heard of these columns writes it.

It is deliberately not a mock of the old release. It is the shape of its
statement: an ``INSERT`` naming exactly the columns that existed before the
plan, and nothing else.
"""

from decimal import Decimal

from django.db import connection
from django.test import TestCase

from apps.catalog.models import Product


class ThePreviousReleaseCanStillWriteTests(TestCase):
    """Every column this plan added is either nullable, defaulted, or on a
    table that release has never inserted into."""

    #: Exactly the columns ``catalog.ProductVariant`` had at ``3262afed`` — the
    #: last release before this plan — so the statement below is the shape that
    #: release's ORM emits, not an approximation of it.
    PREVIOUS_RELEASE_VARIANT_COLUMNS = (
        "product_id", "name", "sku", "barcode", "unit_price", "price_amount",
        "price_rate", "price_rate_at", "is_active", "is_default",
        "option_signature", "created_at", "updated_at",
    )

    def test_it_can_still_create_a_product_variant(self):
        """The one that was genuinely broken.

        ``ProductVariant.gtin`` is ``NOT NULL``, and Django drops the database
        default after backfilling — so an ``INSERT`` that does not name it
        failed until ``0038`` put the default back. Adding a product is an
        ordinary thing for somebody to be doing during an update, which is
        what made this the one worth finding.
        """
        product = Product.objects.create(name="قهوة")
        columns = ", ".join(self.PREVIOUS_RELEASE_VARIANT_COLUMNS)
        with connection.cursor() as cursor:
            cursor.execute(
                f"INSERT INTO catalog_productvariant ({columns}) VALUES "
                "(%s, '', %s, '', %s, NULL, NULL, NULL, true, true, '', "
                "now(), now()) RETURNING id",
                [product.pk, "OLD-REL-1", Decimal("10.00")],
            )
            variant_id = cursor.fetchone()[0]
        self.assertTrue(variant_id)

    def test_it_can_still_write_the_shop_settings_row(self):
        """``shop_phone`` is the same shape, reached only on a fresh install —
        but the default costs nothing and the argument should not depend on
        which installs are fresh."""
        with connection.cursor() as cursor:
            cursor.execute(
                "SELECT column_default IS NOT NULL FROM information_schema.columns "
                "WHERE table_name = 'core_shopsettings' AND column_name = 'shop_phone'"
            )
            self.assertTrue(cursor.fetchone()[0])

    def test_the_lot_columns_carry_a_default_too(self):
        """Unreachable — the previous release only inserts a lot from
        ``create_expiring_stock_batch``, which returns before doing anything
        unless the product tracks expiry, and none does. Asserted anyway so
        the safety does not rest on that premise staying true."""
        with connection.cursor() as cursor:
            cursor.execute(
                "SELECT column_name FROM information_schema.columns "
                "WHERE table_name = 'inventory_stockbatch' "
                "AND column_name IN ('barcode', 'gtin', 'notes') "
                "AND column_default IS NULL"
            )
            self.assertEqual(cursor.fetchall(), [])

    def test_every_column_this_plan_added_carries_a_default(self):
        """The guard, over the columns this plan actually added.

        The first version of this test swept the whole schema and found 109
        ``NOT NULL``-with-no-default columns — because Django drops the
        default after **every** backfill, so almost all of them predate this
        plan and are named by the previous release's own ``INSERT``s. That is
        the wrong question, and a 109-line hand-maintained baseline is the
        wrong answer to it.

        The right question is narrow: of the columns *this plan* added to a
        table the previous release writes, does any of them lack a default?
        The list comes from reading the plan's migrations for ``AddField`` on
        a model none of them created, with neither ``null=True`` nor
        ``default=``. If another one is ever added, re-run that audit and add
        it here and to ``0038``.
        """
        added_by_this_plan = (
            ("catalog_productvariant", "gtin"),
            ("core_shopsettings", "shop_phone"),
            ("inventory_stockbatch", "barcode"),
            ("inventory_stockbatch", "gtin"),
            ("inventory_stockbatch", "notes"),
        )
        # A row-comparison against ANY() needs a named composite type in
        # Postgres, so the pair is matched as two lists instead.
        tables = [table for table, _ in added_by_this_plan]
        columns = [column for _, column in added_by_this_plan]
        with connection.cursor() as cursor:
            cursor.execute(
                """
                SELECT table_name, column_name
                FROM information_schema.columns
                WHERE table_name = ANY(%s)
                  AND column_name = ANY(%s)
                  AND column_default IS NULL
                """,
                [tables, columns],
            )
            bare = sorted(
                row for row in cursor.fetchall() if row in added_by_this_plan
            )
        self.assertEqual(
            bare,
            [],
            "These columns are NOT NULL with no database default on a table "
            "the previous release inserts into, so an update would 500 on "
            "that path for its flip minute. Give them a default in "
            f"inventory/migrations/0038: {bare}",
        )
