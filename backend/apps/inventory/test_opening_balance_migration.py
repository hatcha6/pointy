"""The valuation ledger's opening-balance migration, run the way a real shop
runs it: against a database that already has stock on the shelf.

This file exists because of a bug that reached every trading shop and no test.
Migration ``0015_seed_valuation_opening_balances`` reached for
``PurchaseOrder.Status.CANCELLED`` on a model from ``apps.get_model()`` — a
*historical* model, rebuilt from migration state, which carries only fields,
managers and Meta and never the nested ``TextChoices`` class. Every upgrade with
stock in it died on ``AttributeError``.

The reason the whole suite stayed green through it is the shape of the migration:
it returns early when no ``StockItem`` has quantity on hand, and a freshly built
test database never has any. So the only test that can hold this line is one that
puts stock in *before* the migration runs — which means driving the migration
executor rather than relying on the test database's own setup.
"""

from decimal import Decimal

from django.db import connection
from django.db.migrations.executor import MigrationExecutor
from django.db.migrations.recorder import MigrationRecorder
from django.test import TransactionTestCase

MIGRATE_FROM = ("inventory", "0014_warehouse_stockvaluationbin_stockledgerentry")
MIGRATE_TO = ("inventory", "0015_seed_valuation_opening_balances")
#: The last purchasing migration that does not depend on warehouses, and so
#: the furthest the database is rewound on that side.
#:
#: Used only to rebuild a *historical model* — never to roll the database
#: forward again. Rewinding ``inventory`` to 0014 unapplies migrations in
#: ``sales`` and ``operations`` as well, which this pin says nothing about, and
#: that gap is precisely what made the old ``tearDown`` wrong.
PURCHASING_AT = ("purchasing", "0031_backfill_purchase_receipt_lifecycle")


class OpeningBalanceMigrationTests(TransactionTestCase):
    # The migration rewrites rows outside the test's own transaction, so the
    # tables have to be reset the slow, honest way.
    available_apps = None

    def setUp(self):
        super().setUp()
        self._migrate([MIGRATE_FROM])

    def tearDown(self):
        """Put the schema back the way this file found it — all the way.

        This used to migrate to ``MIGRATE_TO``, which is the migration *under
        test* and not the tip of the tree. Rewinding ``inventory`` to 0014 and
        then rolling forward only as far as 0015 leaves every later migration
        unapplied, and the next ``TransactionTestCase`` in the run inherits a
        schema missing two years of columns and tables — failing somewhere else
        entirely, with an error that says nothing about this file. It stayed
        hidden because the full ``manage.py test apps`` run happens to order the
        suites so nothing lands after it; ``test apps.inventory apps.core`` does
        not, and eight tests in ``apps.core`` died on a missing
        ``inventory_stockitem.warehouse_id``.

        So: forward to every leaf in the graph, not to a pinned name. There is
        no list here to keep up to date, because a list is what went stale.
        """
        self._migrate_to_leaves()
        self._assert_schema_is_at_the_leaves()
        super().tearDown()

    def _migrate_to_leaves(self):
        executor = MigrationExecutor(connection)
        executor.loader.build_graph()
        executor.migrate(executor.loader.graph.leaf_nodes())

    def _assert_schema_is_at_the_leaves(self):
        """Every migration the tree has is applied again, or say which is not.

        Asserted rather than assumed, and asserted *here* rather than in one
        test, so that a future pin of ``MIGRATE_TO`` — or a rewind that reaches
        an app nobody listed — fails in this file instead of in whichever suite
        happens to run next.
        """
        executor = MigrationExecutor(connection)
        executor.loader.build_graph()
        applied = set(MigrationRecorder(connection).applied_migrations())
        missing = sorted(set(executor.loader.graph.nodes) - applied)
        # ``assertFalse`` rather than ``assertEqual(missing, [])``: the useful
        # output is the list itself, and a sequence diff against an empty list
        # only buries it under "Diff is 1457 characters long".
        self.assertFalse(
            missing,
            "this test rewound the schema and did not put it back; the next "
            "TransactionTestCase in the run will inherit it. Unapplied: "
            + ", ".join(f"{app}.{name}" for app, name in missing),
        )

    def _historical(self, app_label, model_name):
        """The model as the *database* currently has it, not as the code does.

        Both apps are pinned. Rewinding ``inventory`` to 0014 also unapplies
        the purchasing migration that put a ``warehouse`` FK on a purchase
        order — a migration cannot survive its dependency going away — so the
        table has purchasing's columns up to 0031 and no further. Asking for
        state at the inventory target alone would rewind purchasing much
        further than the database actually did, and the model would be missing
        columns the table still requires.
        """
        executor = MigrationExecutor(connection)
        state = executor.loader.project_state([MIGRATE_FROM, PURCHASING_AT])
        return state.apps.get_model(app_label, model_name)

    def _migrate(self, targets):
        executor = MigrationExecutor(connection)
        executor.loader.build_graph()
        executor.migrate(targets)
        return executor.loader.project_state(targets[0]).apps

    def _seed_shop_with_stock(self):
        """A shop mid-trade: stock on hand, a received purchase behind it, and a
        cancelled purchase at a wild price that must not become the opening rate.
        """
        from apps.catalog.testing import create_product_with_default_variant
        from apps.purchasing.models import PurchaseLine, PurchaseOrder, Supplier

        product = create_product_with_default_variant(
            name="سكر",
            sku="OPEN-1",
            unit_price=Decimal("5.00"),
        )
        variant = product.default_variant
        supplier = Supplier.objects.create(name="مورد")

        # Built on the schema this test rewound to, not on today's.
        # ``PurchaseOrder`` gained a ``warehouse`` FK into ``inventory``, so
        # rewinding *inventory* to 0014 necessarily unapplies that purchasing
        # migration too — the column is genuinely gone, and the live model
        # cannot write this table. Only the *enum* comes from the live class,
        # which is exactly what this file exists to protect: historical models
        # carry fields and never nested ``TextChoices``.
        historical_order = self._historical("purchasing", "PurchaseOrder")
        historical_line = self._historical("purchasing", "PurchaseLine")

        # Numbered by hand: the historical model has no ``save()`` to stamp
        # one, and two orders sharing a blank number collide on the unique
        # index.
        received = historical_order.objects.create(
            supplier_id=supplier.pk,
            status=PurchaseOrder.Status.RECEIVED,
            order_number="P-OPEN-RECEIVED",
            special_day_keys=[],
        )
        historical_line.objects.create(
            purchase_order_id=received.pk,
            variant_id=variant.pk,
            quantity=Decimal("10"),
            unit_cost=Decimal("3.00"),
            unit_factor=Decimal("1"),
        )
        cancelled = historical_order.objects.create(
            supplier_id=supplier.pk,
            status=PurchaseOrder.Status.CANCELLED,
            order_number="P-OPEN-CANCELLED",
            special_day_keys=[],
        )
        historical_line.objects.create(
            purchase_order_id=cancelled.pk,
            variant_id=variant.pk,
            quantity=Decimal("10"),
            unit_cost=Decimal("99.00"),
            unit_factor=Decimal("1"),
        )

        # The live ``StockItem`` cannot be used here any more. It grew a
        # ``warehouse`` column in 0018, and the schema this test is standing on
        # was rewound to 0014 — so the live model's own SELECT names a column
        # the database has not got yet. The historical model, rebuilt from the
        # migration state we rewound to, has exactly the fields that existed
        # then, which is the schema a real shop's upgrade actually starts from.
        historical = self._historical("inventory", "StockItem")
        item, _ = historical.objects.get_or_create(variant_id=variant.pk)
        historical.objects.filter(pk=item.pk).update(quantity_on_hand=Decimal("7"))
        return variant

    def test_a_shop_with_stock_can_apply_the_opening_balance(self):
        """The regression itself: with stock present the migration runs past the
        early return and has to survive on historical models alone."""
        variant = self._seed_shop_with_stock()

        self._migrate([MIGRATE_TO])

        from apps.inventory.models import StockLedgerEntry, StockValuationBin

        entry = StockLedgerEntry.objects.get(
            variant_id=variant.pk, voucher_type="opening"
        )
        self.assertEqual(entry.balance_quantity, Decimal("7.000"))
        bin_row = StockValuationBin.objects.get(variant_id=variant.pk)
        self.assertEqual(bin_row.quantity, Decimal("7.000"))

    def test_the_opening_rate_ignores_cancelled_purchases(self):
        """The literal that replaced the enum still has to mean what the enum
        meant — a cancelled order's 99.00 is not what this stock cost."""
        variant = self._seed_shop_with_stock()

        self._migrate([MIGRATE_TO])

        from apps.inventory.models import StockLedgerEntry

        entry = StockLedgerEntry.objects.get(
            variant_id=variant.pk, voucher_type="opening"
        )
        self.assertEqual(entry.valuation_rate, Decimal("3.000000"))
        self.assertEqual(entry.balance_value, Decimal("21.000000"))

    def test_a_shop_with_no_stock_opens_nothing(self):
        """The early return that hid the bug — kept, and now covered."""
        self._migrate([MIGRATE_TO])

        from apps.inventory.models import StockLedgerEntry

        self.assertFalse(
            StockLedgerEntry.objects.filter(voucher_type="opening").exists()
        )
