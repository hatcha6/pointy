"""End-to-end tests for the data-migration pipeline.

Everything runs against the working reference SQLite connector + a seeded toy
database, so the whole pipeline (connect → compatibility → dry-run → import →
re-run) is exercised without any vendor dump or optional driver.
"""

import sqlite3
import tempfile
from decimal import Decimal
from pathlib import Path

from django.test import TestCase

from apps.catalog.models import Product, ProductCategory, ProductVariant
from apps.customers.models import Customer
from apps.inventory.models import StockItem
from apps.purchasing.models import Supplier

from . import canonical, services
from .connectors import get_connector
from .connectors.reference_sqlite import build_sample_database
from .exceptions import DriverNotInstalled
from .identity import IdentityResolver
from .loaders.catalog import ProductLoader, VariantLoader
from .models import (
    MigrationIdentityMap,
    MigrationIssue,
    MigrationRun,
    MigrationSource,
)
from .transports import build_transport

DRY_RUN = MigrationRun.Mode.DRY_RUN
IMPORT = MigrationRun.Mode.IMPORT


class MigrationTestBase(TestCase):
    def setUp(self):
        self._tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmpdir.cleanup)
        self.db_path = Path(self._tmpdir.name) / "legacy.sqlite"
        # The fresh test DB already contains seeded rows (e.g. an "unspecified"
        # supplier from a data migration), so assert on deltas, not absolutes.
        self.baseline = {
            Product: Product.objects.count(),
            ProductVariant: ProductVariant.objects.count(),
            ProductCategory: ProductCategory.objects.count(),
            Customer: Customer.objects.count(),
            Supplier: Supplier.objects.count(),
            StockItem: StockItem.objects.count(),
        }

    def assertCreated(self, model, expected):
        self.assertEqual(model.objects.count() - self.baseline[model], expected)

    def make_source(self, **overrides):
        defaults = dict(
            name="Old POS",
            system_key="reference_sqlite",
            transport_kind="sqlite",
            database_name=str(self.db_path),
        )
        defaults.update(overrides)
        return MigrationSource.objects.create(**defaults)

    def run_sync(self, source, mode, entities=None):
        run = services.queue_migration_run(
            source, mode=mode, entities=entities, user=None, dispatch=False
        )
        services.run_migration(run.pk)
        run.refresh_from_db()
        return run


class CompatibilityTests(MigrationTestBase):
    def test_compatible_schema(self):
        build_sample_database(self.db_path)
        connector = get_connector("reference_sqlite")
        with build_transport("sqlite", {"database": str(self.db_path)}) as transport:
            report = connector.check_compatibility(transport)
        self.assertTrue(report.compatible)
        self.assertEqual(report.detected_version, "generic-1")
        self.assertEqual(report.missing_tables, [])

    def test_missing_required_table(self):
        build_sample_database(self.db_path)
        connection = sqlite3.connect(self.db_path)
        connection.execute("DROP TABLE suppliers")
        connection.commit()
        connection.close()

        connector = get_connector("reference_sqlite")
        with build_transport("sqlite", {"database": str(self.db_path)}) as transport:
            report = connector.check_compatibility(transport)
        self.assertFalse(report.compatible)
        self.assertIn("suppliers", report.missing_tables)


class DryRunTests(MigrationTestBase):
    def test_dry_run_persists_nothing_but_reports(self):
        build_sample_database(self.db_path, with_bad_rows=True)
        source = self.make_source()

        run = self.run_sync(source, DRY_RUN)

        # The dry run itself succeeds (its job is to surface problems).
        self.assertEqual(run.status, MigrationRun.Status.SUCCEEDED)
        # Nothing is written to the destination or the identity map.
        self.assertCreated(Product, 0)
        self.assertCreated(ProductVariant, 0)
        self.assertCreated(Customer, 0)
        self.assertCreated(Supplier, 0)
        self.assertEqual(MigrationIdentityMap.objects.count(), 0)
        # …yet the would-be counts are reported.
        self.assertEqual(run.summary["product"]["created"], 5)
        self.assertEqual(run.summary["product"]["failed"], 1)
        # …and the bad row surfaced as an error issue (constraint check).
        self.assertTrue(
            MigrationIssue.objects.filter(run=run, entity_type="product", severity="error").exists()
        )


class ImportTests(MigrationTestBase):
    def test_import_creates_master_data(self):
        build_sample_database(self.db_path)
        source = self.make_source()

        run = self.run_sync(source, IMPORT)

        self.assertEqual(run.status, MigrationRun.Status.SUCCEEDED)
        self.assertCreated(ProductCategory, 3)
        self.assertCreated(Product, 5)
        # One default variant created per product (single-price source schema).
        self.assertCreated(ProductVariant, 5)
        # Stock only for the four non-service products that have a stock row.
        self.assertCreated(StockItem, 4)
        self.assertCreated(Customer, 2)
        self.assertCreated(Supplier, 2)
        # Identity map links every imported product to its Pointy row.
        self.assertEqual(
            MigrationIdentityMap.objects.filter(source=source, entity_type="product").count(),
            5,
        )
        # A child category resolved its parent.
        hot = ProductCategory.objects.get(name="Hot Drinks")
        self.assertEqual(hot.parent.name, "Beverages")

    def test_reimport_updates_in_place(self):
        build_sample_database(self.db_path)
        source = self.make_source()
        self.run_sync(source, IMPORT)

        # Mutate the source and re-run.
        connection = sqlite3.connect(self.db_path)
        connection.execute("UPDATE products SET name='Espresso Doppio' WHERE id=1")
        connection.commit()
        connection.close()

        run2 = self.run_sync(source, IMPORT)

        self.assertEqual(run2.status, MigrationRun.Status.SUCCEEDED)
        # No duplicates: counts stable, all products updated not created.
        self.assertCreated(Product, 5)
        self.assertCreated(ProductVariant, 5)
        self.assertEqual(run2.summary["product"]["updated"], 5)
        self.assertEqual(run2.summary["product"]["created"], 0)
        self.assertTrue(Product.objects.filter(name="Espresso Doppio").exists())

    def test_partial_import_continues_past_bad_record(self):
        build_sample_database(self.db_path, with_bad_rows=True)
        source = self.make_source()

        run = self.run_sync(source, IMPORT)

        self.assertEqual(run.status, MigrationRun.Status.PARTIAL)
        # Good products still imported; the bad one is isolated.
        self.assertCreated(Product, 5)
        self.assertEqual(run.summary["product"]["created"], 5)
        self.assertEqual(run.summary["product"]["failed"], 1)
        self.assertTrue(
            MigrationIssue.objects.filter(run=run, entity_type="product", severity="error").exists()
        )

    def test_stock_skipped_for_service_products(self):
        build_sample_database(self.db_path)
        # Add a stock row for the service product (id=4); it must be skipped.
        connection = sqlite3.connect(self.db_path)
        connection.execute("INSERT INTO stock (product_id, quantity) VALUES (4, 5)")
        connection.commit()
        connection.close()
        source = self.make_source()

        run = self.run_sync(source, IMPORT)

        service_variant = ProductVariant.objects.get(product__name="Cleaning Fee")
        self.assertFalse(StockItem.objects.filter(variant=service_variant).exists())
        self.assertEqual(run.summary["stock"]["skipped"], 1)


class VariantLoaderTests(MigrationTestBase):
    def test_explicit_variant_path(self):
        # The reference connector uses product-level pricing; this drives the
        # explicit-variant loader directly (the path real connectors will use).
        source = self.make_source()
        run = MigrationRun.objects.create(source=source, mode=IMPORT)
        resolver = IdentityResolver(source, run, dry_run=False)

        product = canonical.CanonicalProduct(source_key="p1", name="Widget")
        ProductLoader().load(product, resolver, dry_run=False)
        variant = canonical.CanonicalVariant(
            source_key="v1",
            product_source_key="p1",
            sku="WID-1",
            unit_price=Decimal("9.99"),
            is_default=True,
        )
        outcome = VariantLoader().load(variant, resolver, dry_run=False)

        self.assertEqual(outcome.action, "created")
        self.assertTrue(ProductVariant.objects.filter(sku="WID-1", is_default=True).exists())


class DriverTests(MigrationTestBase):
    def test_missing_mssql_driver_is_friendly(self):
        try:
            import pyodbc  # noqa: F401
        except ImportError:
            pass
        else:
            self.skipTest("pyodbc is installed in this environment")
        transport = build_transport("mssql", {"host": "x", "database": "y"})
        with self.assertRaises(DriverNotInstalled) as ctx:
            transport.connect()
        self.assertIn("pyodbc", str(ctx.exception))

    def test_missing_mongo_driver_is_friendly(self):
        try:
            import pymongo  # noqa: F401
        except ImportError:
            pass
        else:
            self.skipTest("pymongo is installed in this environment")
        transport = build_transport("mongo", {"host": "x", "database": "y"})
        with self.assertRaises(DriverNotInstalled) as ctx:
            transport.connect()
        self.assertIn("pymongo", str(ctx.exception))
