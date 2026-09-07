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
from django.test import TransactionTestCase

MIGRATE_FROM = ("inventory", "0014_warehouse_stockvaluationbin_stockledgerentry")
MIGRATE_TO = ("inventory", "0015_seed_valuation_opening_balances")


class OpeningBalanceMigrationTests(TransactionTestCase):
    # The migration rewrites rows outside the test's own transaction, so the
    # tables have to be reset the slow, honest way.
    available_apps = None

    def setUp(self):
        super().setUp()
        self._migrate([MIGRATE_FROM])

    def tearDown(self):
        # Leave the database at the latest state so the next test in the run
        # does not inherit a half-migrated schema.
        self._migrate([MIGRATE_TO])
        super().tearDown()

    def _historical(self, app_label, model_name):
        """The model as it stood at ``MIGRATE_FROM``, not as it stands today."""
        executor = MigrationExecutor(connection)
        state = executor.loader.project_state([MIGRATE_FROM])
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

        received = PurchaseOrder.objects.create(
            supplier=supplier,
            status=PurchaseOrder.Status.RECEIVED,
        )
        PurchaseLine.objects.create(
            purchase_order=received,
            variant=variant,
            quantity=Decimal("10"),
            unit_cost=Decimal("3.00"),
            unit_factor=Decimal("1"),
        )
        cancelled = PurchaseOrder.objects.create(
            supplier=supplier,
            status=PurchaseOrder.Status.CANCELLED,
        )
        PurchaseLine.objects.create(
            purchase_order=cancelled,
            variant=variant,
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
