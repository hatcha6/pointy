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

    def run_sync(self, source, mode, entities=None, options=None):
        run = services.queue_migration_run(
            source,
            mode=mode,
            entities=entities,
            options=options,
            user=None,
            dispatch=False,
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


def build_aboghris_sample(path):
    """A tiny SQLite database shaped like the AboGhris (SQL Server) schema, so
    the AboGhris connector's mapping is testable without pyodbc/MSSQL."""
    import sqlite3

    connection = sqlite3.connect(path)
    try:
        connection.executescript(
            """
            CREATE TABLE UNITS (UNIT_ID INTEGER, UNIT_DISC TEXT);
            CREATE TABLE CATEGORY1 (CAT1_ID INTEGER, CAT1_NAME TEXT, CAT1_INVISIBLE INTEGER);
            CREATE TABLE CATEGORY2 (CAT2_ID INTEGER, CAT2_NAME TEXT, CAT2_INVISIBLE INTEGER);
            CREATE TABLE ITEMS (ITEM_ID INTEGER, ITEM_MODEL TEXT, ITEM_NAME TEXT,
                                CAT1_ID INTEGER, CAT2_ID INTEGER, ITEM_INVISIBLE INTEGER);
            CREATE TABLE BARCODE (BAR_ID INTEGER, UNIT_ID INTEGER, ITEM_ID INTEGER,
                                  BARCODE TEXT, PRICE1 REAL, PUBLIC_PRICE REAL, UNIT_QTY REAL);
            CREATE TABLE ITEMS_SUB (ITEM_SUB_ID INTEGER, ITEM_ID INTEGER, STORE_ID INTEGER, QTY REAL);
            CREATE TABLE CUSTOMERS (CUST_ID INTEGER, CUST_NAME TEXT, CUST_PHONE TEXT,
                                    CUST_MOBILE TEXT, CUST_E_MAIL TEXT, CUST_ADRESS TEXT,
                                    CUST_VENDOR INTEGER, CUST_INVISIBLE INTEGER);
            CREATE TABLE SALE_INVOICE (S_ID INTEGER, S_DATE TEXT, CUST_ID INTEGER,
                                       S_DISCOUNT REAL, BANK_ID INTEGER);
            CREATE TABLE SALE_ITEMS (S_ITEM_ID INTEGER, S_ID INTEGER, ITEM_ID INTEGER,
                                     QTY REAL, PRICE REAL, UNIT_PRICE REAL,
                                     PUBLIC_PRICE REAL, AVER_COST REAL, LAST_COST REAL);
            CREATE TABLE BUY_INVOICE (B_ID INTEGER, B_DATE TEXT, CUST_ID INTEGER,
                                      S_REF_NO TEXT, B_DISCOUNT REAL);
            CREATE TABLE BUY_ITEMS (B_ITEM_ID INTEGER, B_ID INTEGER, ITEM_ID INTEGER,
                                    QTY REAL, PRICE REAL);
            CREATE TABLE EXPENCES (EXPENCES_ID INTEGER, EXPENSE_DISC TEXT,
                                   EXPENSE_INVISIBLE INTEGER);
            CREATE TABLE GIVE (G_ID INTEGER, G_DATE TEXT, G_VALUE REAL, G_NOTE TEXT,
                               G_NO TEXT, EXPENCES_ID INTEGER, BANK_ID INTEGER,
                               CUST_ID INTEGER);
            """
        )
        connection.executemany(
            "INSERT INTO UNITS VALUES (?, ?)",
            [(0, "N/A"), (92, "قطعة"), (94, "علبة")],
        )
        connection.executemany(
            "INSERT INTO CATEGORY1 VALUES (?, ?, ?)",
            [(0, "N/A", 0), (59, "Company A", 0)],
        )
        connection.executemany(
            "INSERT INTO CATEGORY2 VALUES (?, ?, ?)",
            [(0, "N/A", 0), (44, "Group A", 0), (45, "Group B", 0)],
        )
        connection.executemany(
            "INSERT INTO ITEMS VALUES (?, ?, ?, ?, ?, ?)",
            [
                (401, "", "Item 401", 59, 44, 0),
                (402, "", "Item 402", 59, 44, 0),
                (404, "", "Item 404", 59, 45, 0),
                (500, "MODEL-X", "Item 500", 0, 0, 1),
            ],
        )
        connection.executemany(
            "INSERT INTO BARCODE VALUES (?, ?, ?, ?, ?, ?, ?)",
            [
                (1155, 92, 401, "6291100080489", 12, 0, 1),
                (1156, 94, 402, "6267638162164", 0, 0, 3),  # box, has the barcode
                (1157, 92, 402, "", 0, 0, 1),  # base piece, no barcode
                (1159, 94, 404, "8600097001533", 0, 3, 2),  # box, public price 3
                (1160, 92, 404, "", 0, 1.5, 1),  # base piece, public price 1.5
                (1161, 92, 500, "5550005", 5, 0, 1),
            ],
        )
        connection.executemany(
            "INSERT INTO ITEMS_SUB VALUES (?, ?, ?, ?)",
            [(1, 401, 1, 50), (2, 402, 1, 12), (3, 500, 1, 0)],
        )
        connection.executemany(
            "INSERT INTO CUSTOMERS VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            [
                (0, "N/A", "", "", "", "", 1, 0),
                (1, "زبون نقدي", "2676373", "", "", "", 0, 0),
                (2, "شركة النسيم", "", "0912000002", "", "طرابلس", 1, 0),
                (3, "", "", "", "", "", 1, 0),
            ],
        )
        connection.executemany(
            "INSERT INTO SALE_INVOICE VALUES (?, ?, ?, ?, ?)",
            [
                (1, "2026-06-13 00:58:52", 1, 0, 0),
                (2, "2026-06-13 16:22:07", 1, 0, 0),
            ],
        )
        connection.executemany(
            "INSERT INTO SALE_ITEMS VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            [
                # invoice 1: 2 × item 401 @ 12 (cost 10)
                (1, 1, 401, 2, 12, 12, 12, 10, 10),
                # invoice 2: 1 × item 402 @ 5 + 3 × item 404 @ 1.5
                (2, 2, 402, 1, 5, 5, 5, 4, 4),
                (3, 2, 404, 3, 1.5, 1.5, 1.5, 1, 1),
            ],
        )
        connection.executemany(
            "INSERT INTO BUY_INVOICE VALUES (?, ?, ?, ?, ?)",
            [(1, "2026-05-15 19:48:40", 2, "REF-001", 0)],
        )
        connection.executemany(
            "INSERT INTO BUY_ITEMS VALUES (?, ?, ?, ?, ?)",
            [
                (1, 1, 401, 10, 9.0),
                (2, 1, 402, 5, 2.0),
            ],
        )
        connection.executemany(
            "INSERT INTO EXPENCES VALUES (?, ?, ?)",
            [
                (0, "N/A", 0),
                (1, "مصاريف رواتب", 0),
                (2, "مصاريف كهرباء", 0),
            ],
        )
        connection.executemany(
            "INSERT INTO GIVE VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            [
                # expense: electricity (category 2), 250
                (1, "2026-05-20 10:00:00", 250.0, "كهرباء مايو", "V1", 2, 1, 0),
                # supplier payment (EXPENCES_ID 0) to vendor 2 (شركة النسيم)
                (2, "2026-05-21 10:00:00", 6200.0, "دفعة مورد", "V2", 0, 1, 2),
                # zero-amount expense voucher -> skipped
                (3, "2026-05-22 10:00:00", 0.0, "صفر", "V3", 1, 1, 0),
            ],
        )
        connection.commit()
    finally:
        connection.close()


class ResolverPerformanceTests(MigrationTestBase):
    def test_resolve_is_in_memory_after_preload(self):
        from django.db import connection
        from django.test.utils import CaptureQueriesContext

        from .identity import IdentityResolver

        build_aboghris_sample(self.db_path)
        source = self._make_aboghris_source()
        self.run_sync(source, IMPORT)  # populate the identity map

        run = MigrationRun.objects.create(source=source, mode=IMPORT)
        # Construction preloads the whole map in a single query…
        with CaptureQueriesContext(connection) as preload:
            resolver = IdentityResolver(source, run, dry_run=False)
        self.assertLessEqual(len(preload.captured_queries), 1)

        # …after which resolving foreign keys issues no queries at all.
        with CaptureQueriesContext(connection) as resolves:
            for item_id in ("401", "402", "404", "500"):
                resolver.resolve("product", item_id)
                resolver.resolve_pk("variant", item_id)
        self.assertEqual(len(resolves.captured_queries), 0)

    def test_reimport_does_not_grow_identity_map(self):
        from .models import MigrationIdentityMap

        build_aboghris_sample(self.db_path)
        source = self._make_aboghris_source()
        self.run_sync(source, IMPORT)
        first = MigrationIdentityMap.objects.filter(source=source).count()
        self.run_sync(source, IMPORT)
        second = MigrationIdentityMap.objects.filter(source=source).count()
        self.assertEqual(first, second)
        self.assertGreater(first, 0)

    def _make_aboghris_source(self):
        return self.make_source(
            name="AboGhris",
            system_key="aboghris_mssql",
            transport_kind="sqlite",
            database_name=str(self.db_path),
        )


class AboGhrisConnectorTests(MigrationTestBase):
    def _aboghris_source(self, **overrides):
        return self.make_source(
            name="AboGhris",
            system_key="aboghris_mssql",
            transport_kind="sqlite",
            database_name=str(self.db_path),
            **overrides,
        )

    def test_full_import(self):
        from apps.catalog.models import ProductUnit, UnitOfMeasure

        build_aboghris_sample(self.db_path)
        source = self._aboghris_source()

        run = self.run_sync(source, IMPORT)

        self.assertIn(run.status, (MigrationRun.Status.SUCCEEDED, MigrationRun.Status.PARTIAL))
        # Units (skip the N/A placeholder).
        self.assertTrue(UnitOfMeasure.objects.filter(code="u92").exists())
        self.assertTrue(UnitOfMeasure.objects.filter(code="u94").exists())
        self.assertFalse(UnitOfMeasure.objects.filter(code="u0").exists())
        # Categories from both axes, N/A skipped.
        self.assertCreated(ProductCategory, 3)
        # Four products, each with a default variant.
        self.assertCreated(Product, 4)
        self.assertCreated(ProductVariant, 4)
        # Base-unit price + barcode landed on the default variant.
        v401 = ProductVariant.objects.get(barcode="6291100080489")
        self.assertEqual(v401.unit_price, Decimal("12.00"))
        v404 = ProductVariant.objects.get(product__name="Item 404")
        self.assertEqual(v404.unit_price, Decimal("1.50"))  # base piece public price
        # Extra units became ProductUnits (box of 3 for 402, box of 2 @3 for 404).
        item402 = Product.objects.get(name="Item 402")
        box402 = ProductUnit.objects.get(product=item402, unit__code="u94")
        self.assertEqual(box402.factor_to_base, Decimal("3.000000"))
        item404 = Product.objects.get(name="Item 404")
        box404 = ProductUnit.objects.get(product=item404, unit__code="u94")
        self.assertEqual(box404.factor_to_base, Decimal("2.000000"))
        self.assertEqual(box404.price, Decimal("3.00"))
        # Stock summed from ITEMS_SUB (404 has no row -> no stock item).
        self.assertEqual(StockItem.objects.get(variant=v401).quantity_on_hand, Decimal("50.000"))
        self.assertFalse(StockItem.objects.filter(variant=v404).exists())
        # Customers vs suppliers split on CUST_VENDOR; N/A row skipped.
        self.assertCreated(Customer, 1)
        self.assertCreated(Supplier, 2)
        self.assertTrue(Supplier.objects.filter(name="شركة النسيم").exists())
        self.assertTrue(Supplier.objects.filter(name="مورّد 3").exists())

    def test_transactional_import(self):
        from apps.expenses.models import Expense, ExpenseCategory
        from apps.payments.models import Payment
        from apps.purchasing.models import PurchaseOrder, SupplierPayment
        from apps.sales.models import Order

        build_aboghris_sample(self.db_path)
        source = self._aboghris_source()
        orders_before = Order.objects.count()
        payments_before = Payment.objects.count()
        pos_before = PurchaseOrder.objects.count()
        expenses_before = Expense.objects.count()
        supplier_payments_before = SupplierPayment.objects.count()

        run = self.run_sync(source, IMPORT)

        self.assertIn(run.status, (MigrationRun.Status.SUCCEEDED, MigrationRun.Status.PARTIAL))
        # Sales: two invoices, each fully paid; totals computed from lines.
        self.assertEqual(Order.objects.count() - orders_before, 2)
        self.assertEqual(Payment.objects.count() - payments_before, 2)
        sale1 = Order.objects.get(total=Decimal("24.00"))  # 2 × 12
        self.assertEqual(sale1.status, "paid")
        self.assertEqual(sale1.payments.first().amount, Decimal("24.00"))
        self.assertEqual(sale1.created_at.year, 2026)  # historical date preserved
        self.assertTrue(Order.objects.filter(total=Decimal("9.50")).exists())  # 5 + 3×1.5
        # Purchase order: one invoice, two lines, total 10×9 + 5×2 = 100.
        self.assertEqual(PurchaseOrder.objects.count() - pos_before, 1)
        po = PurchaseOrder.objects.get(supplier_invoice_number="REF-001")
        self.assertEqual(po.total, Decimal("100.00"))
        self.assertEqual(po.lines.count(), 2)
        self.assertEqual(po.supplier.name, "شركة النسيم")
        self.assertEqual(po.status, "received")
        # Expense categories imported (N/A skipped).
        self.assertTrue(ExpenseCategory.objects.filter(name="مصاريف رواتب").exists())
        self.assertTrue(ExpenseCategory.objects.filter(name="مصاريف كهرباء").exists())
        # Expense transactions from GIVE (EXPENCES_ID>0); supplier payment and
        # zero-amount voucher are skipped, so exactly one expense lands.
        self.assertEqual(Expense.objects.count() - expenses_before, 1)
        expense = Expense.objects.get(reference="V1")
        self.assertEqual(expense.amount, Decimal("250.00"))
        self.assertEqual(expense.category.name, "مصاريف كهرباء")
        self.assertEqual(expense.spent_at.year, 2026)
        # Supplier payment from the EXPENCES_ID=0 GIVE voucher paid to a vendor.
        self.assertEqual(SupplierPayment.objects.count() - supplier_payments_before, 1)
        payment = SupplierPayment.objects.get(reference="V2")
        self.assertEqual(payment.amount, Decimal("6200.00"))
        self.assertEqual(payment.supplier.name, "شركة النسيم")

    def test_products_without_quantities_option_skips_stock(self):
        build_aboghris_sample(self.db_path)
        source = self._aboghris_source()
        stock_before = StockItem.objects.count()

        run = self.run_sync(source, IMPORT, options={"products_without_quantities": True})

        self.assertIn(run.status, (MigrationRun.Status.SUCCEEDED, MigrationRun.Status.PARTIAL))
        # Products imported, but no stock rows were created.
        self.assertCreated(Product, 4)
        self.assertEqual(StockItem.objects.count(), stock_before)
        self.assertNotIn("stock", run.summary)
