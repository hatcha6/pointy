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


def build_fahd_sample(path):
    """A tiny SQLite database shaped like the Fahd (SQL Server 2000) schema, so
    the Fahd connector's mapping is testable without FreeTDS/MSSQL.

    Exercises the interesting cases: the ``CAR_PART`` system placeholder row, a
    catalogue split between ``CAR_PART`` and the Excel ``asnaf$`` table with one
    overlapping code (dedup), system/opening-balance party rows, and movement
    lines that reference the system item (``SER='0'``) which must be skipped.
    """
    import sqlite3

    connection = sqlite3.connect(path)
    try:
        connection.executescript(
            """
            CREATE TABLE TASNEEF (NO INTEGER, TASNEEF TEXT);
            CREATE TABLE CAR_PART (
                ser TEXT, id INTEGER, CAR_PART TEXT, COUNT_ORG REAL, BUY_PRICE REAL,
                SER_GOMLA REAL, SER_KETAEE REAL, TASNEEF TEXT, hideornot INTEGER
            );
            CREATE TABLE "asnaf$" (
                buy_price TEXT, ser_gomla TEXT, ser_ketaee TEXT, place TEXT,
                car_part TEXT, ser TEXT
            );
            CREATE TABLE COUSTMER (
                NO_SADER INTEGER, S_NAME TEXT, S_ADDRESS TEXT, S_PHONE TEXT, Hideornot INTEGER
            );
            CREATE TABLE DEON_SADER (
                NO_SADER INTEGER, S_NAME TEXT, S_ADDRESS TEXT, S_PHONE TEXT, Hideornot INTEGER
            );
            CREATE TABLE WARED (
                NO_SADER INTEGER, S_NAME TEXT, S_ADDRESS TEXT, S_PHONE TEXT, Hideornot INTEGER
            );
            CREATE TABLE WARED1 (
                NO_SADER INTEGER, ID INTEGER, NO_FATORA INTEGER, NEW_F REAL, S_DAIN REAL,
                S_DATE TEXT, SER TEXT, SER_KETAEE REAL, SER_GOMLA REAL, BUY_PRICE REAL, KASM REAL
            );
            CREATE TABLE SADER1 (
                NO_SADER INTEGER, ID INTEGER, NO_FATORA INTEGER, NEW_F REAL, S_DAIN REAL,
                S_DATE TEXT, SER TEXT, SER_KETAEE REAL, SER_GOMLA REAL, BUY_PRICE REAL, KASM REAL
            );
            CREATE TABLE COUSTMER1 (
                NO_SADER INTEGER, ID INTEGER, NO_FATORA INTEGER, NEW_F REAL, S_DAIN REAL,
                S_DATE TEXT, SER TEXT, SER_KETAEE REAL, SER_GOMLA REAL, BUY_PRICE REAL, KASM REAL
            );
            CREATE TABLE ESAL_WARED1 (
                NO_SADER INTEGER, ID INTEGER, V_ESAL REAL, DATE_ESAL TEXT, ESAL_NO TEXT
            );
            CREATE TABLE MASAREEF_S (
                ID INTEGER, DATE_M TEXT, V_M REAL, MEMO TEXT, S_NAME TEXT, NO_FATORA INTEGER
            );
            """
        )
        connection.executemany(
            "INSERT INTO TASNEEF VALUES (?, ?)",
            [(59, "عام"), (60, "عدة يدوية")],
        )
        connection.executemany(
            "INSERT INTO CAR_PART VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            [
                # System placeholder (ser '0' / "دين سابق") -> skipped.
                ("0", 1989, "دين سابق", 0, 4, 0, 0, "عام", 1),
                # A real native item.
                ("5000", 2000, "مفتاح ربط", 12, 20, 28, 35, "عدة يدوية", 0),
                # Same code as an asnaf$ row -> CAR_PART wins on dedup.
                ("2661-15", 2001, "رول مبطن (محدّث)", 5, 70, 95, 120, "عام", 0),
            ],
        )
        connection.executemany(
            'INSERT INTO "asnaf$" VALUES (?, ?, ?, ?, ?, ?)',
            [
                ("71.5", "95", "110", "1", "رول مبطن", "2661-15"),  # deduped (in CAR_PART)
                ("8.8", "13.5", "16", "72", "طاجين شواء", "2229-10"),
                ("35", "40", "45", "32", "بكرج اكسبرس", "0161"),
            ],
        )
        connection.executemany(
            "INSERT INTO COUSTMER VALUES (?, ?, ?, ?, ?)",
            [
                (8435, "المعدوم", "0", "0", 1),  # system account -> skipped
                (8436, "1/مدير النظام29/04/2024", "0", "0", 1),  # admin -> skipped
                (9001, "أحمد علي", "طرابلس", "0911111111", 0),
            ],
        )
        connection.executemany(
            "INSERT INTO DEON_SADER VALUES (?, ?, ?, ?, ?)",
            [
                (7, "رصيد اول المدة 2024", "0", "0", 1),  # opening balance -> skipped
                (6, "كمال", "0", "0922222222", 0),
            ],
        )
        connection.executemany(
            "INSERT INTO WARED VALUES (?, ?, ?, ?, ?)",
            [
                (1221, "رصيد اول المدة 2024", "0", "0", 1),  # opening balance -> skipped
                (1300, "شركة قطع الغيار", "بنغازي", "0913333333", 0),
            ],
        )
        connection.executemany(
            "INSERT INTO WARED1 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            [
                # Purchase invoice 10 from supplier 1300: 10×20 + 5×80 = 600.
                (1300, 1, 10, 10, 200, "2024-07-18", "5000", 35, 28, 20, 0),
                (1300, 2, 10, 5, 400, "2024-07-18", "2661-15", 120, 95, 80, 0),
                # Opening-balance line referencing the system item -> skipped, no PO.
                (1221, 3, 2, 1, 4, "2024-01-01", "0", 0, 0, 4, 0),
            ],
        )
        connection.executemany(
            "INSERT INTO SADER1 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            [
                # Sale invoice 101 to customer 9001: 2×35 + 1×120 = 190.
                (9001, 1, 101, 2, 70, "2024-08-01", "5000", 35, 28, 20, 0),
                (9001, 2, 101, 1, 120, "2024-08-01", "2661-15", 120, 95, 80, 0),
                # Invoice referencing the system item only -> no sale emitted.
                (9001, 3, 999, 1, 5, "2024-08-02", "0", 0, 0, 0, 0),
            ],
        )
        connection.executemany(
            "INSERT INTO ESAL_WARED1 VALUES (?, ?, ?, ?, ?)",
            [(1300, 1, 600, "2024-07-20", "R-1")],
        )
        connection.executemany(
            "INSERT INTO MASAREEF_S VALUES (?, ?, ?, ?, ?, ?)",
            [
                (1, "2024-06-01", 250.0, "فاتورة كهرباء", "كهرباء", 5),
                (2, "2024-06-02", 0.0, "صفر", "", 0),  # zero amount -> skipped
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

    def test_stock_source_none_skips_stock(self):
        """The explicit ``stock_source: none`` matches the legacy boolean."""
        build_aboghris_sample(self.db_path)
        source = self._aboghris_source()
        stock_before = StockItem.objects.count()

        run = self.run_sync(source, IMPORT, options={"stock_source": "none"})

        self.assertIn(run.status, (MigrationRun.Status.SUCCEEDED, MigrationRun.Status.PARTIAL))
        self.assertCreated(Product, 4)
        self.assertEqual(StockItem.objects.count(), stock_before)
        self.assertNotIn("stock", run.summary)

    def test_reconstruct_stock_from_transactions(self):
        build_aboghris_sample(self.db_path)
        source = self._aboghris_source()

        run = self.run_sync(source, IMPORT, options={"stock_source": "reconstruct"})

        self.assertIn(run.status, (MigrationRun.Status.SUCCEEDED, MigrationRun.Status.PARTIAL))
        v401 = ProductVariant.objects.get(barcode="6291100080489")
        v402 = ProductVariant.objects.get(product__name="Item 402")
        v404 = ProductVariant.objects.get(product__name="Item 404")
        # On-hand = purchases − sales, NOT the stored snapshot (50 / 12 / none):
        #   401: bought 10, sold 2 -> 8     402: bought 5, sold 1 -> 4
        self.assertEqual(StockItem.objects.get(variant=v401).quantity_on_hand, Decimal("8.000"))
        self.assertEqual(StockItem.objects.get(variant=v402).quantity_on_hand, Decimal("4.000"))
        # 404 sold 3 but was never purchased -> clamped to 0 with a clear hint.
        self.assertEqual(StockItem.objects.get(variant=v404).quantity_on_hand, Decimal("0.000"))
        warning = MigrationIssue.objects.get(
            run=run, entity_type="stock", code="sold_without_purchase"
        )
        self.assertIn("Item 404", warning.message)
        self.assertEqual(warning.detail["sold"], "3")
        self.assertEqual(warning.detail["purchased"], "0")
        # Reconstruction stats ride along in the stock summary bucket…
        recon = run.summary["stock"]["reconstruction"]
        self.assertEqual(recon["products_set"], 2)
        self.assertEqual(recon["products_zeroed"], 1)
        self.assertEqual(recon["sold_without_purchase"], 1)
        self.assertEqual(recon["total_deficit_units"], "3")
        # …and the operator gets a single headline they can relay to the client.
        self.assertTrue(
            MigrationIssue.objects.filter(
                run=run, code="reconstruction_incomplete_history"
            ).exists()
        )
        # The stored snapshot (50 / 12) is read back and compared: both 401 and
        # 402 reconstructed lower than the old system claimed, so the difference
        # is reported as a likely un-invoiced opening balance.
        self.assertEqual(recon["old_system_higher"], 2)
        self.assertEqual(recon["total_implied_opening_units"], "50")  # (50-8)+(12-4)
        self.assertTrue(MigrationIssue.objects.filter(run=run, code="snapshot_comparison").exists())
        higher = {
            issue.detail.get("product"): issue.detail
            for issue in MigrationIssue.objects.filter(
                run=run, code="quantity_higher_in_old_system"
            )
        }
        self.assertEqual(higher["Item 401"]["old_system"], "50")
        self.assertEqual(higher["Item 401"]["reconstructed"], "8")
        self.assertEqual(higher["Item 401"]["difference"], "42")
        # Money view: stored vs invoice-supported stock value at last cost (401@9,
        # 402@2) — 8×9+4×2=80 reconstructed vs 50×9+12×2=474 stored.
        self.assertEqual(recon["reconstructed_inventory_value"], "80.00")
        self.assertEqual(recon["snapshot_inventory_value"], "474.00")
        self.assertTrue(MigrationIssue.objects.filter(run=run, code="inventory_valuation").exists())

    def test_reconstruct_auto_includes_transactions_when_not_selected(self):
        """Reconstruct needs the history, so the engine pulls it in even when the
        operator only ticked the catalog entities."""
        build_aboghris_sample(self.db_path)
        source = self._aboghris_source()

        run = self.run_sync(
            source,
            IMPORT,
            entities=["unit", "category", "product", "product_unit"],
            options={"stock_source": "reconstruct"},
        )

        self.assertIn(run.status, (MigrationRun.Status.SUCCEEDED, MigrationRun.Status.PARTIAL))
        v401 = ProductVariant.objects.get(barcode="6291100080489")
        self.assertEqual(StockItem.objects.get(variant=v401).quantity_on_hand, Decimal("8.000"))


class StockReconstructorTests(MigrationTestBase):
    """Directly exercises the snapshot-comparison branches with a fake resolver,
    so all four divergence directions are covered without a connector dump."""

    class _FakeResolver:
        def __init__(self, mapping):
            self._mapping = mapping

        def resolve(self, entity_type, key):
            return self._mapping.get((entity_type, str(key)))

    def _variant(self, name, sku):
        product = Product.objects.create(name=name)
        return product.ensure_default_variant(sku=sku, unit_price=Decimal("1"))

    def test_snapshot_comparison_directions(self):
        from .entity_plan import PURCHASE_ORDER, SALE, VARIANT
        from .reconstruct import StockReconstructor

        a = self._variant("A higher", "SKU-A")  # invoices 8  vs old 50
        b = self._variant("B lower", "SKU-B")  # invoices 4  vs old 2
        c = self._variant("C no history", "SKU-C")  # invoices 0  vs old 7
        d = self._variant("D match", "SKU-D")  # invoices 0  vs old 0
        resolver = self._FakeResolver(
            {(VARIANT, "A"): a.pk, (VARIANT, "B"): b.pk, (VARIANT, "C"): c.pk, (VARIANT, "D"): d.pk}
        )

        recon = StockReconstructor(resolver)
        recon.observe(
            PURCHASE_ORDER,
            canonical.CanonicalPurchaseOrder(
                source_key="po1",
                lines=[
                    canonical.CanonicalPurchaseLine(variant_source_key="A", quantity=10, unit_cost=Decimal("9")),
                    canonical.CanonicalPurchaseLine(variant_source_key="B", quantity=5, unit_cost=Decimal("2")),
                    canonical.CanonicalPurchaseLine(variant_source_key="D", quantity=3, unit_cost=Decimal("1")),
                ],
            ),
        )
        recon.observe(
            SALE,
            canonical.CanonicalSale(
                source_key="s1",
                lines=[
                    canonical.CanonicalSaleLine(variant_source_key="A", quantity=Decimal("2")),
                    canonical.CanonicalSaleLine(variant_source_key="B", quantity=Decimal("1")),
                    canonical.CanonicalSaleLine(variant_source_key="D", quantity=Decimal("3")),
                ],
            ),
        )
        for key, qty in (("A", 50), ("B", 2), ("C", 7), ("D", 0)):
            recon.observe_snapshot(
                canonical.CanonicalStock(
                    source_key=f"st-{key}", variant_source_key=key, quantity_on_hand=Decimal(qty)
                ),
                resolver,
            )

        result = recon.flush(dry_run=False)

        # Reconstructed on-hand: A 8, B 4, D 0; C has no invoices -> no stock row.
        self.assertEqual(StockItem.objects.get(variant=a).quantity_on_hand, Decimal("8.000"))
        self.assertEqual(StockItem.objects.get(variant=b).quantity_on_hand, Decimal("4.000"))
        self.assertEqual(StockItem.objects.get(variant=d).quantity_on_hand, Decimal("0.000"))
        self.assertFalse(StockItem.objects.filter(variant=c).exists())

        stats = result.stats
        self.assertEqual(stats["snapshot_compared"], 4)
        self.assertEqual(stats["snapshot_matching"], 1)  # D
        self.assertEqual(stats["snapshot_match_rate"], 25)
        self.assertEqual(stats["old_system_higher"], 2)  # A, C
        self.assertEqual(stats["old_system_lower"], 1)  # B
        self.assertEqual(stats["total_implied_opening_units"], "49")  # (50-8) + (7-0)
        self.assertEqual(stats["total_unexplained_shrinkage_units"], "2")  # (4-2)
        self.assertEqual(stats["snapshot_only_no_history"], 1)  # C

        # Valuation: both quantities costed at the last purchase price (A 9, B 2,
        # D 1); C has no purchase so it can't be valued.
        self.assertEqual(stats["reconstructed_inventory_value"], "80.00")  # 8×9 + 4×2 + 0×1
        self.assertEqual(stats["snapshot_inventory_value"], "454.00")  # 50×9 + 2×2 + 0×1
        self.assertEqual(stats["inventory_value_difference"], "-374.00")
        self.assertEqual(stats["products_without_cost"], 1)  # C

        codes = {issue.code for issue in result.issues}
        self.assertIn("quantity_higher_in_old_system", codes)  # A
        self.assertIn("quantity_lower_in_old_system", codes)  # B
        self.assertIn("snapshot_without_history", codes)  # C
        self.assertIn("snapshot_comparison", codes)  # headline
        self.assertIn("snapshot_only_no_history", codes)  # headline
        self.assertIn("inventory_valuation", codes)  # headline


class FahdConnectorTests(MigrationTestBase):
    def _fahd_source(self, **overrides):
        return self.make_source(
            name="Fahd",
            system_key="fahd_mssql",
            transport_kind="sqlite",
            database_name=str(self.db_path),
            **overrides,
        )

    def test_compatible_schema(self):
        build_fahd_sample(self.db_path)
        connector = get_connector("fahd_mssql")
        with build_transport("sqlite", {"database": str(self.db_path)}) as transport:
            report = connector.check_compatibility(transport)
        self.assertTrue(report.compatible)
        self.assertEqual(report.detected_version, "fahd-v22-2023")

    def test_master_data_import(self):
        build_fahd_sample(self.db_path)
        source = self._fahd_source()

        run = self.run_sync(source, IMPORT)

        self.assertIn(run.status, (MigrationRun.Status.SUCCEEDED, MigrationRun.Status.PARTIAL))
        # Categories from TASNEEF.
        self.assertCreated(ProductCategory, 2)
        # Products: 2 from CAR_PART (system row skipped) + 2 from asnaf$ (the
        # overlapping "2661-15" is deduped to the CAR_PART row) = 4.
        self.assertCreated(Product, 4)
        self.assertCreated(ProductVariant, 4)
        # The CAR_PART row wins the dedup (its name + price, not the asnaf$ one).
        v_dedup = ProductVariant.objects.get(barcode="2661-15")
        self.assertEqual(v_dedup.unit_price, Decimal("120.00"))
        self.assertEqual(v_dedup.product.name, "رول مبطن (محدّث)")
        # Native CAR_PART item carries its category + retail price.
        native = Product.objects.get(name="مفتاح ربط")
        self.assertEqual(native.categories.first().name, "عدة يدوية")
        self.assertEqual(ProductVariant.objects.get(sku="5000").unit_price, Decimal("35.00"))
        # asnaf$-only product imported at its retail (ser_ketaee) price.
        asnaf = ProductVariant.objects.get(barcode="2229-10")
        self.assertEqual(asnaf.unit_price, Decimal("16.00"))
        # Stock only from CAR_PART real rows (asnaf$ has none, system row skipped).
        self.assertCreated(StockItem, 2)
        self.assertEqual(
            StockItem.objects.get(variant=ProductVariant.objects.get(sku="5000")).quantity_on_hand,
            Decimal("12.000"),
        )
        # Customers from COUSTMER + DEON_SADER; system/opening rows skipped.
        self.assertCreated(Customer, 2)
        self.assertTrue(Customer.objects.filter(full_name="أحمد علي").exists())
        self.assertTrue(Customer.objects.filter(full_name="كمال").exists())
        # Suppliers from WARED; opening-balance row skipped.
        self.assertCreated(Supplier, 1)
        self.assertTrue(Supplier.objects.filter(name="شركة قطع الغيار").exists())

    def test_transactional_import(self):
        from apps.expenses.models import Expense
        from apps.payments.models import Payment
        from apps.purchasing.models import PurchaseOrder, SupplierPayment
        from apps.sales.models import Order

        build_fahd_sample(self.db_path)
        source = self._fahd_source()
        orders_before = Order.objects.count()
        payments_before = Payment.objects.count()
        pos_before = PurchaseOrder.objects.count()
        expenses_before = Expense.objects.count()
        supplier_payments_before = SupplierPayment.objects.count()

        run = self.run_sync(source, IMPORT)

        self.assertIn(run.status, (MigrationRun.Status.SUCCEEDED, MigrationRun.Status.PARTIAL))
        # Sales: one resolvable invoice (the system-item invoice yields no lines).
        self.assertEqual(Order.objects.count() - orders_before, 1)
        self.assertEqual(Payment.objects.count() - payments_before, 1)
        sale = Order.objects.get(total=Decimal("190.00"))  # 2×35 + 1×120
        self.assertEqual(sale.status, "paid")
        self.assertEqual(sale.payments.first().amount, Decimal("190.00"))
        self.assertEqual(sale.created_at.year, 2024)  # historical date preserved
        self.assertEqual(sale.customer.full_name, "أحمد علي")
        # Purchase order: one invoice, two lines, 10×20 + 5×80 = 600.
        self.assertEqual(PurchaseOrder.objects.count() - pos_before, 1)
        po = PurchaseOrder.objects.get(total=Decimal("600.00"))
        self.assertEqual(po.lines.count(), 2)
        self.assertEqual(po.supplier.name, "شركة قطع الغيار")
        self.assertEqual(po.status, "received")
        # Supplier payment from ESAL_WARED1.
        self.assertEqual(SupplierPayment.objects.count() - supplier_payments_before, 1)
        payment = SupplierPayment.objects.get(reference="R-1")
        self.assertEqual(payment.amount, Decimal("600.00"))
        self.assertEqual(payment.supplier.name, "شركة قطع الغيار")
        # Expense from MASAREEF_S (zero-amount row skipped); category from S_NAME.
        self.assertEqual(Expense.objects.count() - expenses_before, 1)
        expense = Expense.objects.get(amount=Decimal("250.00"))
        self.assertEqual(expense.category.name, "كهرباء")
        self.assertEqual(expense.spent_at.year, 2024)

    def test_products_without_quantities_option_skips_stock(self):
        build_fahd_sample(self.db_path)
        source = self._fahd_source()
        stock_before = StockItem.objects.count()

        run = self.run_sync(source, IMPORT, options={"products_without_quantities": True})

        self.assertIn(run.status, (MigrationRun.Status.SUCCEEDED, MigrationRun.Status.PARTIAL))
        self.assertCreated(Product, 4)
        self.assertEqual(StockItem.objects.count(), stock_before)
        self.assertNotIn("stock", run.summary)


class MssqlConnectionStringTests(TestCase):
    def _conn_string(self, options):
        transport = build_transport(
            "mssql",
            {
                "host": "10.0.0.5",
                "port": 1433,
                "database": "FAHD2023",
                "username": "sa",
                "password": "secret",
                "options": options,
            },
        )
        return transport._build_connection_string()

    def test_freetds_for_sql_server_2000(self):
        # FreeTDS needs a separate PORT + TDS version and rejects the TLS keywords.
        conn = self._conn_string({"odbc_driver": "FreeTDS", "tds_version": "7.0"})
        self.assertIn("DRIVER={FreeTDS}", conn)
        self.assertIn("SERVER=10.0.0.5", conn)
        self.assertIn("PORT=1433", conn)
        self.assertIn("TDS_Version=7.0", conn)
        self.assertNotIn("Encrypt", conn)
        self.assertNotIn("10.0.0.5,1433", conn)

    def test_modern_driver_keeps_tls_keywords(self):
        conn = self._conn_string({})
        self.assertIn("ODBC Driver 18 for SQL Server", conn)
        self.assertIn("SERVER=10.0.0.5,1433", conn)
        self.assertIn("Encrypt=yes", conn)
        self.assertIn("TrustServerCertificate=yes", conn)

    def test_trusted_auth_connection_string(self):
        # A None username switches to Windows/trusted auth, omitting UID/PWD.
        transport = build_transport("mssql", {"host": "h", "database": "d"})
        conn = transport._build_connection_string(None, "")
        self.assertIn("Trusted_Connection=yes", conn)
        self.assertNotIn("UID=", conn)
        self.assertNotIn("PWD=", conn)


class MssqlDefaultCredentialTests(TestCase):
    def _candidates(self, config):
        return build_transport("mssql", config)._credential_candidates()

    def test_explicit_login_is_only_candidate(self):
        # When the operator supplies a login we never try anything else.
        cands = self._candidates(
            {"host": "h", "database": "d", "username": "sa", "password": "secret"}
        )
        self.assertEqual(cands, [("sa", "secret")])

    def test_blank_login_falls_back_to_vendor_defaults(self):
        cands = self._candidates({"host": "h", "database": "d"})
        self.assertGreater(len(cands), 1)
        self.assertEqual(cands[0], (None, ""))  # trusted auth first
        self.assertIn(("sa", ""), cands)  # blank sa (MSDE / SQL 2000)

    def test_fallback_can_be_disabled(self):
        # With the toggle off and no login, only trusted auth is attempted.
        cands = self._candidates(
            {"host": "h", "database": "d", "options": {"try_default_credentials": False}}
        )
        self.assertEqual(cands, [(None, "")])


class SsrpDiscoveryParseTests(TestCase):
    def _payload(self, body: str) -> bytes:
        encoded = body.encode("latin-1")
        return b"\x05" + len(encoded).to_bytes(2, "little") + encoded

    def test_parses_single_instance(self):
        from .discovery import _parse_ssrp_payload

        raw = self._payload(
            "ServerName;POSPC;InstanceName;SQLEXPRESS;IsClustered;No;"
            "Version;10.50.1600.1;tcp;1433;;"
        )
        instances = _parse_ssrp_payload("192.168.1.20", raw)
        self.assertEqual(len(instances), 1)
        inst = instances[0]
        self.assertEqual(inst.server_name, "POSPC")
        self.assertEqual(inst.instance_name, "SQLEXPRESS")
        self.assertEqual(inst.version, "10.50.1600.1")
        self.assertEqual(inst.tcp_port, 1433)
        self.assertEqual(inst.host, "192.168.1.20")

    def test_parses_multiple_instances(self):
        from .discovery import _parse_ssrp_payload

        raw = self._payload(
            "ServerName;SRV;InstanceName;MSSQLSERVER;Version;8.00.760;tcp;1433;;"
            "ServerName;SRV;InstanceName;POS;Version;10.0.0;tcp;1450;;"
        )
        instances = _parse_ssrp_payload("10.0.0.9", raw)
        self.assertEqual({i.instance_name for i in instances}, {"MSSQLSERVER", "POS"})

    def test_ignores_non_ssrp_bytes(self):
        from .discovery import _parse_ssrp_payload

        self.assertEqual(_parse_ssrp_payload("10.0.0.1", b"\x00garbage"), [])
        self.assertEqual(_parse_ssrp_payload("10.0.0.1", b""), [])


# --- Fahd (Access/SQLite export) connector ------------------------------------


def build_fahd_database(path):
    """A miniature file in the shape scripts/fahd_reconstruct.py produces:
    Fahd catalogue tables + the reconstructed invoice tables."""
    connection = sqlite3.connect(path)
    connection.executescript(
        """
        CREATE TABLE TASNEEF (NO INTEGER, TASNEEF TEXT);
        CREATE TABLE CAR_PART (
            ser TEXT, CAR_PART TEXT, SER_KETAEE REAL, SER_GOMLA REAL,
            TAK_ONE REAL, COUNT_ORG REAL, TASNEEF TEXT
        );
        CREATE TABLE CAR_PART_D (ser TEXT, NO_N TEXT, CAR_PART TEXT, PLACE TEXT);
        CREATE TABLE CAR_PART_D2 (ser TEXT, NO_N TEXT, CAR_PART TEXT, PLACE TEXT);
        CREATE TABLE COUSTMER (NO_SADER REAL, S_NAME TEXT, S_ADDRESS TEXT, S_PHONE TEXT);
        CREATE TABLE WARED (NO_SADER REAL, S_NAME TEXT, S_ADDRESS TEXT, S_PHONE TEXT);
        CREATE TABLE fahd_sales (
            invoice_no INTEGER PRIMARY KEY, occurred_at TEXT, doc_date TEXT,
            cashier TEXT, gross REAL, discount REAL, net REAL, n_lines INTEGER,
            total_qty REAL, print_items INTEGER, print_qty REAL, print_gross REAL,
            print_discount REAL, print_net REAL, status TEXT
        );
        CREATE TABLE fahd_sale_lines (
            invoice_no INTEGER, ser TEXT, qty REAL, unit_price REAL, line_total REAL
        );
        CREATE TABLE fahd_purchases (
            id INTEGER PRIMARY KEY, supplier_name TEXT, invoice_no TEXT,
            doc_date TEXT, occurred_at TEXT, gross REAL, n_lines INTEGER,
            is_opening INTEGER
        );
        CREATE TABLE fahd_purchase_lines (
            purchase_id INTEGER, ser TEXT, qty REAL, unit_cost REAL, line_total REAL
        );
        """
    )
    connection.executemany(
        "INSERT INTO TASNEEF VALUES (?, ?)",
        [(1, "مشروبات")],
    )
    connection.executemany(
        "INSERT INTO CAR_PART VALUES (?, ?, ?, ?, ?, ?, ?)",
        [
            ("1001", "عصير برتقال", 2.5, 2.0, 1.8, 7, "مشروبات"),
            ("2002", "حليب مجفف", 10.0, 0.0, 8.0, 3, "مشروبات"),
            ("3003", "0", 5.0, 0.0, 4.0, 0, "0"),  # placeholder name + category
        ],
    )
    connection.executemany(
        "INSERT INTO CAR_PART_D VALUES (?, ?, ?, ?)",
        [
            ("SUB111", "1001", "عصير برتقال", "برتقالي"),  # real sub-barcode
            ("2002", "1001", "0", "0"),  # collides with a main code -> skipped
        ],
    )
    connection.executemany(
        "INSERT INTO CAR_PART_D2 VALUES (?, ?, ?, ?)",
        [
            ("SUB222", "2002", "حليب مجفف", "0"),  # pack barcode
            ("SUB111", "2002", "0", "0"),  # duplicate of the D row -> skipped
        ],
    )
    connection.executemany(
        "INSERT INTO COUSTMER VALUES (?, ?, ?, ?)",
        [
            (1, "زبون تجريبي", "طرابلس", "0911234567"),
            (2, "المبيعات اليومية", "", ""),  # system account -> skipped
        ],
    )
    connection.executemany(
        "INSERT INTO WARED VALUES (?, ?, ?, ?)",
        [
            (10, "شركة الحسن", "بنغازي", "0923334444"),
            (11, "جرد بداية المدة 2023", "", ""),  # opening pseudo-supplier
            (12, "المعدوم", "", ""),  # system account
        ],
    )
    connection.executemany(
        "INSERT INTO fahd_sales VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        [
            # gross 15, print discount 0.5 -> net 14.5; one line via a sub-barcode
            (101, "2024-01-15 10:00:00", "2024-01-15", "عصام", 15.0, 0.5, 14.5,
             2, 3, 2, 3, 15.0, 0.5, 14.5, "ok"),
            # references an item deleted from the catalogue (ghost product)
            (102, "2024-02-20 18:30:00", "2024-02-20", "عصام", 3.0, 0.0, 3.0,
             1, 1, None, None, None, None, None, "no_print"),
            # 3dp unit price typed as a line total in Fahd (1.4 / 3)
            (103, "2024-03-05 12:00:00", "2024-03-05", "سالم", 1.4, 0.0, 1.4,
             1, 3, None, None, None, None, None, "no_print"),
        ],
    )
    connection.executemany(
        "INSERT INTO fahd_sale_lines VALUES (?, ?, ?, ?, ?)",
        [
            (101, "1001", 2, 2.5, 5.0),
            (101, "SUB222", 1, 10.0, 10.0),
            (102, "9999", 1, 3.0, 3.0),
            (103, "1001", 3, 0.466666666666667, 1.4),
        ],
    )
    connection.executemany(
        "INSERT INTO fahd_purchases VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        [
            (1, "شركة الحسن", "INV-77", "2023-05-01", "2023-05-01", 99.996, 1, 0),
            (2, "مورد محذوف", "B-1", "2023-06-01", "2023-06-01", 20.0, 1, 0),
            (3, "جرد بداية المدة 2023", "X", "2023-01-01", "2023-01-01", 500.0, 1, 1),
        ],
    )
    connection.executemany(
        "INSERT INTO fahd_purchase_lines VALUES (?, ?, ?, ?, ?)",
        [
            (1, "2002", 12, 8.333, 99.996),
            (2, "1001", 10, 2.0, 20.0),
            (3, "2002", 100, 5.0, 500.0),
        ],
    )
    connection.commit()
    connection.close()


class FahdSqliteTests(MigrationTestBase):
    def make_fahd_source(self):
        build_fahd_database(self.db_path)
        return self.make_source(system_key="fahd_sqlite")

    def test_compatibility_requires_reconstructed_tables(self):
        build_fahd_database(self.db_path)
        connection = sqlite3.connect(self.db_path)
        connection.execute("DROP TABLE fahd_sales")
        connection.commit()
        connection.close()
        connector = get_connector("fahd_sqlite")
        with build_transport("sqlite", {"database": str(self.db_path)}) as transport:
            report = connector.check_compatibility(transport)
        self.assertFalse(report.compatible)
        self.assertIn("fahd_sales", report.missing_tables)

    def test_dry_run_writes_nothing(self):
        source = self.make_fahd_source()
        run = self.run_sync(source, DRY_RUN, options={"stock_source": "none"})
        self.assertEqual(run.status, MigrationRun.Status.SUCCEEDED)
        self.assertCreated(Product, 0)
        self.assertCreated(ProductVariant, 0)

    def test_import_products_variants_and_sub_barcodes(self):
        from apps.sales.models import Order

        source = self.make_fahd_source()
        run = self.run_sync(source, IMPORT, options={"stock_source": "none"})
        self.assertIn(
            run.status, (MigrationRun.Status.SUCCEEDED, MigrationRun.Status.PARTIAL)
        )

        # 3 catalogue products + 1 ghost for the deleted item in invoice 102.
        self.assertCreated(Product, 4)
        # A default variant per product + the two sub-barcode variants.
        self.assertCreated(ProductVariant, 6)

        # Sub-barcodes scan straight to their parent product.
        sub = ProductVariant.objects.get(barcode="SUB111")
        self.assertEqual(sub.product.name, "عصير برتقال")
        self.assertFalse(sub.is_default)
        self.assertEqual(sub.name, "برتقالي")
        self.assertEqual(sub.unit_price, Decimal("2.50"))
        pack = ProductVariant.objects.get(barcode="SUB222")
        self.assertEqual(pack.product.name, "حليب مجفف")
        self.assertEqual(pack.unit_price, Decimal("10.00"))
        # The colliding rows were deduplicated: the main product kept its code.
        self.assertEqual(
            ProductVariant.objects.filter(barcode="2002").count(), 1
        )

        # Placeholder-name product gets a readable fallback, ghosts stay hidden.
        self.assertTrue(Product.objects.filter(name="صنف 3003", is_active=True).exists())
        ghost = ProductVariant.objects.get(barcode="9999")
        self.assertFalse(ghost.product.is_active)

        # No stock was carried over.
        self.assertCreated(StockItem, 0)

        # Sales: all three invoices, exact totals, original dates, cash walk-in.
        orders = {
            identity.source_key: identity.target
            for identity in MigrationIdentityMap.objects.filter(entity_type="sale")
        }
        self.assertEqual(len(orders), 3)
        sale_101 = orders["sale-101"]
        self.assertEqual(sale_101.total, Decimal("14.50"))
        self.assertEqual(sale_101.discount_total, Decimal("0.50"))
        self.assertEqual(sale_101.lines.count(), 2)
        self.assertIsNone(sale_101.customer_id)
        self.assertEqual(sale_101.created_at.date().isoformat(), "2024-01-15")
        self.assertEqual(sale_101.payments.get().amount, Decimal("14.50"))
        self.assertEqual(
            set(sale_101.lines.values_list("variant__barcode", flat=True)),
            {"1001", "SUB222"},
        )
        self.assertEqual(sale_101.status, Order.Status.PAID)
        # 3 × 0.466666… rounds up to 0.47 with the residue returned as a
        # discount, so the legacy total is preserved exactly.
        sale_103 = orders["sale-103"]
        self.assertEqual(sale_103.total, Decimal("1.40"))

        # Purchases: opening-balance pseudo-bill excluded, totals exact.
        purchases = {
            identity.source_key: identity.target
            for identity in MigrationIdentityMap.objects.filter(entity_type="purchase_order")
        }
        self.assertEqual(len(purchases), 2)
        bill = purchases["buy-شركة الحسن-INV-77"]
        self.assertEqual(bill.supplier.name, "شركة الحسن")
        self.assertEqual(bill.total, Decimal("100.00"))  # 99.996 in 2dp money
        self.assertEqual(bill.supplier_invoice_number, "INV-77")
        ghost_bill = purchases["buy-مورد محذوف-B-1"]
        self.assertEqual(ghost_bill.supplier.name, "مورد محذوف")
        self.assertEqual(ghost_bill.total, Decimal("20.00"))

        # Parties: the opening/system suppliers were not imported.
        self.assertCreated(Customer, 1)
        supplier_names = set(
            Supplier.objects.values_list("name", flat=True)
        )
        self.assertIn("شركة الحسن", supplier_names)
        self.assertIn("مورد محذوف", supplier_names)
        self.assertNotIn("جرد بداية المدة 2023", supplier_names)
        self.assertNotIn("المعدوم", supplier_names)

    def test_import_is_idempotent(self):
        from apps.sales.models import Order, OrderLine

        source = self.make_fahd_source()
        self.run_sync(source, IMPORT, options={"stock_source": "none"})
        first = (
            Product.objects.count(),
            ProductVariant.objects.count(),
            Order.objects.count(),
            OrderLine.objects.count(),
        )
        self.run_sync(source, IMPORT, options={"stock_source": "none"})
        second = (
            Product.objects.count(),
            ProductVariant.objects.count(),
            Order.objects.count(),
            OrderLine.objects.count(),
        )
        self.assertEqual(first, second)

    def test_stock_snapshot_mode_still_available(self):
        source = self.make_fahd_source()
        self.run_sync(source, IMPORT, options={"stock_source": "snapshot"})
        item = StockItem.objects.get(variant__barcode="1001")
        self.assertEqual(item.quantity_on_hand, Decimal("7"))
