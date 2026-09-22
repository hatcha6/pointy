"""End-to-end tests for the data-migration pipeline.

Everything runs against the working reference SQLite connector + a seeded toy
database, so the whole pipeline (upload → prepare → detect → dry-run → import →
re-run → purge) is exercised without any vendor dump.

Every test overrides the staging root to a temp directory: the pipeline resolves
a source's file from ``POINTY_MIGRATION_STAGING_ROOT`` and deletes it when the
import lands, and neither of those should touch a real deployment's volume.
"""

import errno
import io
import sqlite3
import tempfile
from decimal import Decimal
from pathlib import Path
from unittest import mock

from django.test import TestCase, override_settings

from apps.catalog.models import (
    Product,
    ProductCategory,
    ProductUnit,
    ProductUnitBarcode,
    ProductVariant,
)
from apps.customers.models import Customer
from apps.inventory.models import StockItem
from apps.purchasing.models import Supplier

from . import canonical, services, storage, uploads
from .connectors import get_connector
from .connectors.base import ExtractContext
from .connectors.reference_sqlite import build_sample_database
from .identity import IdentityResolver
from .preparation import detect as detection
from .preparation import identify as identification
from .preparation import pipeline
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
        self.staging = Path(self._tmpdir.name) / "staging"
        self.staging.mkdir()
        staging_override = override_settings(POINTY_MIGRATION_STAGING_ROOT=self.staging)
        staging_override.enable()
        self.addCleanup(staging_override.disable)
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
        """A source whose preparation already succeeded, pointing at db_path.

        Most tests are about the engine, not the pipeline that feeds it, so this
        shortcut puts the fixture where a prepared file would be and marks the
        source ready. The pipeline itself is covered by
        :class:`PreparationPipelineTests`.
        """
        defaults = dict(
            name="Old POS",
            original_filename="legacy.sqlite",
            system_key="reference_sqlite",
            upload_state=MigrationSource.UploadState.READY,
        )
        defaults.update(overrides)
        source = MigrationSource.objects.create(**defaults)
        if not source.prepared_filename and self.db_path.exists():
            source.prepared_filename = storage.prepared_name(source.pk)
            storage.adopt(self.db_path, self.staging / source.prepared_filename)
            source.prepared_size_bytes = storage.file_size(storage.prepared_path(source))
            source.save(
                update_fields=["prepared_filename", "prepared_size_bytes", "updated_at"]
            )
        return source

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
        # keep_file: a clean import normally deletes the uploaded database (see
        # services._finalize_source), so re-running against the same file is
        # something only an operator asks for explicitly.
        self.run_sync(source, IMPORT, options={"keep_file": True})

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
                SER_GOMLA REAL, SER_KETAEE REAL, TAK_ONE REAL, TASNEEF TEXT,
                hideornot INTEGER
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
            # ser, id, CAR_PART, COUNT_ORG, BUY_PRICE, SER_GOMLA, SER_KETAEE,
            # TAK_ONE, TASNEEF, hideornot
            "INSERT INTO CAR_PART VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            [
                # System placeholder (ser '0' / "دين سابق") -> skipped.
                ("0", 1989, "دين سابق", 0, 4, 0, 0, 1, "عام", 1),
                # A real native item.
                ("5000", 2000, "مفتاح ربط", 12, 20, 28, 35, 1, "عدة يدوية", 0),
                # Same code as an asnaf$ row -> the CAR_PART row is what lands.
                ("2661-15", 2001, "رول مبطن (محدّث)", 5, 70, 95, 120, 1, "عام", 0),
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
            system_key="aboghris",
        )


class AboGhrisConnectorTests(MigrationTestBase):
    def _aboghris_source(self, **overrides):
        return self.make_source(
            name="AboGhris",
            system_key="aboghris",
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


def _add_empty_reconstruction_tables(path):
    """Add the tables ``preparation.fahd_reconstruct`` writes, with no rows.

    A Fahd shop whose audit log holds no invoices — a till installed last month,
    or one whose log was truncated — produces exactly this: a full catalogue and
    empty invoice tables. The connector must read that rather than reject it.
    """
    connection = sqlite3.connect(path)
    try:
        connection.executescript(
            """
            CREATE TABLE IF NOT EXISTS fahd_sales (
                invoice_no INTEGER PRIMARY KEY, occurred_at TEXT, doc_date TEXT,
                cashier TEXT, gross REAL, discount REAL, net REAL, n_lines INTEGER,
                total_qty REAL, status TEXT
            );
            CREATE TABLE IF NOT EXISTS fahd_sale_lines (
                invoice_no INTEGER, ser TEXT, qty REAL, unit_price REAL, total REAL
            );
            CREATE TABLE IF NOT EXISTS fahd_purchases (
                id INTEGER PRIMARY KEY, supplier_name TEXT, invoice_no TEXT,
                occurred_at TEXT, is_opening INTEGER DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS fahd_purchase_lines (
                purchase_id INTEGER, ser TEXT, qty REAL, unit_cost REAL, total REAL
            );
            CREATE TABLE IF NOT EXISTS CAR_PART_D (ser TEXT, NO_N TEXT, PLACE TEXT);
            CREATE TABLE IF NOT EXISTS CAR_PART_D2 (ser TEXT, NO_N TEXT, TAK_ONE REAL);
            """
        )
        connection.commit()
    finally:
        connection.close()


class FahdConnectorTests(MigrationTestBase):
    """The Fahd master-data mapping: categories, products, parties, stock.

    Fed the catalogue fixture plus empty reconstructed-invoice tables — the shape
    a Fahd file has when its audit log carries no invoices. Transactions are
    covered by :class:`FahdSqliteTests`, against a fixture that has some.
    """

    def _fahd_fixture(self):
        build_fahd_sample(self.db_path)
        _add_empty_reconstruction_tables(self.db_path)
    def _fahd_source(self, **overrides):
        return self.make_source(
            name="Fahd",
            system_key="fahd",
            **overrides,
        )

    def test_compatible_schema(self):
        self._fahd_fixture()
        connector = get_connector("fahd")
        with build_transport("sqlite", {"database": str(self.db_path)}) as transport:
            report = connector.check_compatibility(transport)
        self.assertTrue(report.compatible)
        self.assertEqual(report.detected_version, "fahd-mdb-recon-1")

    def test_master_data_import(self):
        self._fahd_fixture()
        source = self._fahd_source()

        run = self.run_sync(source, IMPORT)

        self.assertIn(run.status, (MigrationRun.Status.SUCCEEDED, MigrationRun.Status.PARTIAL))
        # Categories from TASNEEF.
        self.assertCreated(ProductCategory, 2)
        # Products: the two real CAR_PART rows (the "دين سابق" system row is
        # skipped). `asnaf$` is deliberately not read on this build — it is a
        # stale Excel side-catalogue whose codes mostly do not exist in the
        # master and never appear on an invoice.
        self.assertCreated(Product, 2)
        self.assertCreated(ProductVariant, 2)
        # The CAR_PART row is the one that lands, with its own name + price.
        v_dedup = ProductVariant.objects.get(barcode="2661-15")
        self.assertEqual(v_dedup.unit_price, Decimal("120.00"))
        self.assertEqual(v_dedup.product.name, "رول مبطن (محدّث)")
        # Native CAR_PART item carries its category + retail price.
        native = Product.objects.get(name="مفتاح ربط")
        self.assertEqual(native.categories.first().name, "عدة يدوية")
        self.assertEqual(ProductVariant.objects.get(sku="5000").unit_price, Decimal("35.00"))
        # An `asnaf$`-only code is not a product at all.
        self.assertFalse(ProductVariant.objects.filter(barcode="2229-10").exists())
        # Stock only from the real CAR_PART rows (the system row is skipped).
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

    def test_products_without_quantities_option_skips_stock(self):
        self._fahd_fixture()
        source = self._fahd_source()
        stock_before = StockItem.objects.count()

        run = self.run_sync(source, IMPORT, options={"products_without_quantities": True})

        self.assertIn(run.status, (MigrationRun.Status.SUCCEEDED, MigrationRun.Status.PARTIAL))
        self.assertCreated(Product, 2)
        self.assertEqual(StockItem.objects.count(), stock_before)
        self.assertNotIn("stock", run.summary)


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
        CREATE TABLE CAR_PART_D2 (
            ser TEXT, NO_N TEXT, CAR_PART TEXT, PLACE TEXT, TAK_ONE REAL
        );
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
        "INSERT INTO CAR_PART_D2 VALUES (?, ?, ?, ?, ?)",
        [
            # Pack barcode (6-pack): barely sold -> becomes a unit barcode.
            ("SUB222", "2002", "حليب مجفف", "0", 6.0),
            ("SUB111", "2002", "0", "0", 12.0),  # duplicate of the D row -> skipped
            # Pack code that the shop really used to ring loose pieces (its
            # sale history below is predominantly piece-priced): the barcode
            # stays on the alias variant, but the pack unit is still created
            # (barcode-less) with the observed pack price.
            ("SUB333", "1001", "عصير برتقال", "0", 12.0),
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
            # SUB333's history: mostly loose pieces at the piece price, with a
            # few genuine pack-priced sales that establish the pack's price.
            (104, "2024-04-01 09:00:00", "2024-04-01", "عصام", 96.0, 0.0, 96.0,
             9, 9, None, None, None, None, None, "no_print"),
        ],
    )
    connection.executemany(
        "INSERT INTO fahd_sale_lines VALUES (?, ?, ?, ?, ?)",
        [
            (101, "1001", 2, 2.5, 5.0),
            (101, "SUB222", 1, 10.0, 10.0),
            (102, "9999", 1, 3.0, 3.0),
            (103, "1001", 3, 0.466666666666667, 1.4),
            # 6 piece-priced lines (majority) + 3 pack-priced lines at 27.
            (104, "SUB333", 1, 2.5, 2.5),
            (104, "SUB333", 1, 2.5, 2.5),
            (104, "SUB333", 1, 2.5, 2.5),
            (104, "SUB333", 1, 2.5, 2.5),
            (104, "SUB333", 1, 2.5, 2.5),
            (104, "SUB333", 1, 2.5, 2.5),
            (104, "SUB333", 1, 27.0, 27.0),
            (104, "SUB333", 1, 27.0, 27.0),
            (104, "SUB333", 1, 27.0, 27.0),
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
        return self.make_source(system_key="fahd")

    def test_compatibility_requires_reconstructed_tables(self):
        build_fahd_database(self.db_path)
        connection = sqlite3.connect(self.db_path)
        connection.execute("DROP TABLE fahd_sales")
        connection.commit()
        connection.close()
        connector = get_connector("fahd")
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
        # A default variant per product + the three sub-barcode variants.
        self.assertCreated(ProductVariant, 7)

        # Sub-barcodes scan straight to their parent product.
        sub = ProductVariant.objects.get(barcode="SUB111")
        self.assertEqual(sub.product.name, "عصير برتقال")
        self.assertFalse(sub.is_default)
        self.assertEqual(sub.name, "برتقالي")
        self.assertEqual(sub.unit_price, Decimal("2.50"))
        # The pack (D2) code became a ProductUnit barcode on the parent, and
        # its pseudo-variant was retired: inactive, barcode-less, history-only.
        pack_variant = ProductVariant.objects.get(sku="SUB222")
        self.assertEqual(pack_variant.product.name, "حليب مجفف")
        self.assertEqual(pack_variant.barcode, "")
        self.assertFalse(pack_variant.is_active)
        pack_unit = ProductUnit.objects.get(product__name="حليب مجفف")
        self.assertEqual(pack_unit.unit.code, "carton")
        self.assertEqual(pack_unit.factor_to_base, Decimal("6"))
        self.assertIsNone(pack_unit.price)  # derived: piece price × 6
        self.assertEqual(
            [entry.barcode for entry in pack_unit.barcodes.all()], ["SUB222"]
        )
        # Lines still default to the piece — the pack is an option, never the
        # default (a pack default proved too surprising when typing quantities).
        self.assertEqual(pack_unit.product.default_purchase_unit, "")
        # A pack code that really rang loose pieces keeps its alias variant
        # (scanning must keep selling one piece), while the pack unit is still
        # created barcode-less with the observed pack price.
        alias = ProductVariant.objects.get(barcode="SUB333")
        self.assertTrue(alias.is_active)
        self.assertEqual(alias.unit_price, Decimal("2.50"))
        juice_unit = ProductUnit.objects.get(product__name="عصير برتقال")
        self.assertEqual(juice_unit.factor_to_base, Decimal("12"))
        self.assertEqual(juice_unit.price, Decimal("27.00"))
        self.assertEqual(juice_unit.barcodes.count(), 0)
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

        # Sales: all four invoices, exact totals, original dates, cash walk-in.
        orders = {
            identity.source_key: identity.target
            for identity in MigrationIdentityMap.objects.filter(entity_type="sale")
        }
        self.assertEqual(len(orders), 4)
        # The mixed piece/pack history behind SUB333 keeps its exact total.
        self.assertEqual(orders["sale-104"].total, Decimal("96.00"))
        sale_101 = orders["sale-101"]
        self.assertEqual(sale_101.total, Decimal("14.50"))
        self.assertEqual(sale_101.discount_total, Decimal("0.50"))
        self.assertEqual(sale_101.lines.count(), 2)
        self.assertIsNone(sale_101.customer_id)
        self.assertEqual(sale_101.created_at.date().isoformat(), "2024-01-15")
        self.assertEqual(sale_101.payments.get().amount, Decimal("14.50"))
        # The pack line still resolves through the retired pseudo-variant, so
        # historical invoices keep their totals after the code moved to a unit.
        self.assertEqual(
            set(sale_101.lines.values_list("variant__sku", flat=True)),
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
            ProductUnit.objects.count(),
            ProductUnitBarcode.objects.count(),
            Order.objects.count(),
            OrderLine.objects.count(),
        )
        self.run_sync(source, IMPORT, options={"stock_source": "none"})
        second = (
            Product.objects.count(),
            ProductVariant.objects.count(),
            ProductUnit.objects.count(),
            ProductUnitBarcode.objects.count(),
            Order.objects.count(),
            OrderLine.objects.count(),
        )
        self.assertEqual(first, second)

    def test_unit_backfill_upgrades_prior_import(self):
        """A shop migrated before pack codes became units (D2 rows imported as
        plain active variants) is repaired in place by re-running just the
        unit entities — the exact flow of deploy/onprem/backfill-fahd-units.sh."""
        source = self.make_fahd_source()
        # keep_file: this flow re-runs against the same file, which a clean
        # import would otherwise have deleted.
        self.run_sync(
            source, IMPORT, options={"stock_source": "none", "keep_file": True}
        )

        # Rewind to the pre-units state the old importer left behind: the pack
        # code lives on an active variant, no units, no purchasing default.
        MigrationIdentityMap.objects.filter(entity_type="product_unit").delete()
        ProductUnit.objects.all().delete()
        ProductVariant.objects.filter(sku="SUB222").update(
            barcode="SUB222", is_active=True
        )
        Product.objects.all().update(default_purchase_unit="")

        run = self.run_sync(
            source,
            IMPORT,
            entities=["unit", "product_unit"],
            options={"stock_source": "none", "keep_file": True},
        )
        self.assertEqual(run.status, MigrationRun.Status.SUCCEEDED)

        # The barcode moved from the pseudo-variant onto the pack unit, and the
        # variant was retired in place (history untouched).
        pack_variant = ProductVariant.objects.get(sku="SUB222")
        self.assertEqual(pack_variant.barcode, "")
        self.assertFalse(pack_variant.is_active)
        pack_unit = ProductUnit.objects.get(product__name="حليب مجفف")
        self.assertEqual(
            [entry.barcode for entry in pack_unit.barcodes.all()], ["SUB222"]
        )
        self.assertEqual(pack_unit.product.default_purchase_unit, "")
        # The piece-alias code was left alone: still an active scannable variant.
        alias = ProductVariant.objects.get(barcode="SUB333")
        self.assertTrue(alias.is_active)

    def test_stock_snapshot_mode_still_available(self):
        source = self.make_fahd_source()
        self.run_sync(source, IMPORT, options={"stock_source": "snapshot"})
        item = StockItem.objects.get(variant__barcode="1001")
        self.assertEqual(item.quantity_on_hand, Decimal("7"))


class PurchaseQuantityFidelityTests(MigrationTestBase):
    """A historical purchase of a fractional quantity must import as that
    fraction.

    ``PurchaseLine.quantity`` is ``Decimal(12, 3)`` precisely so a shop can buy
    half a tray of eggs or 2.5 kg of anything, and the sale side of the importer
    already carries ``Decimal`` end to end. The purchase side is the odd one
    out, and every quantity it changes moves money: the line total is
    ``unit_cost × quantity``, so the invoice total, the supplier payable and the
    product's purchase history all follow it.
    """

    def _resolver_with_variant(self, sku="KG-1"):
        source = self.make_source()
        run = MigrationRun.objects.create(source=source, mode=IMPORT)
        resolver = IdentityResolver(source, run, dry_run=False)
        ProductLoader().load(
            canonical.CanonicalProduct(source_key="p1", name="Rice"), resolver, dry_run=False
        )
        VariantLoader().load(
            canonical.CanonicalVariant(
                source_key="v1",
                product_source_key="p1",
                sku=sku,
                unit_price=Decimal("6.00"),
                is_default=True,
            ),
            resolver,
            dry_run=False,
        )
        return resolver

    def test_fractional_purchase_quantity_is_preserved(self):
        from apps.purchasing.models import PurchaseOrder

        from .loaders.purchasing import PurchaseOrderLoader, SupplierLoader

        resolver = self._resolver_with_variant()
        SupplierLoader().load(
            canonical.CanonicalSupplier(source_key="s1", name="Wholesaler"),
            resolver,
            dry_run=False,
        )
        record = canonical.CanonicalPurchaseOrder(
            source_key="po-1",
            supplier_source_key="s1",
            supplier_invoice_number="FRAC-1",
            lines=[
                canonical.CanonicalPurchaseLine(
                    variant_source_key="v1",
                    quantity=Decimal("2.5"),
                    unit_cost=Decimal("4.00"),
                )
            ],
        )

        PurchaseOrderLoader().load(record, resolver, dry_run=False)

        po = PurchaseOrder.objects.get(supplier_invoice_number="FRAC-1")
        line = po.lines.get()
        self.assertEqual(line.quantity, Decimal("2.500"))
        # 2.5 × 4.00 — anything else misstates what the shop owes the supplier.
        self.assertEqual(line.net_line_total, Decimal("10.00"))
        self.assertEqual(po.total, Decimal("10.00"))

    def test_sub_unit_purchase_line_is_not_dropped(self):
        """Half a unit is a real purchase, not a zero one.

        Truncating it to 0 removes the line, and when it is the invoice's only
        line the whole historical bill is lost with a ``no_lines`` error.
        """
        from apps.purchasing.models import PurchaseOrder

        from .loaders.purchasing import PurchaseOrderLoader, SupplierLoader

        resolver = self._resolver_with_variant()
        SupplierLoader().load(
            canonical.CanonicalSupplier(source_key="s1", name="Wholesaler"),
            resolver,
            dry_run=False,
        )
        record = canonical.CanonicalPurchaseOrder(
            source_key="po-2",
            supplier_source_key="s1",
            supplier_invoice_number="FRAC-2",
            lines=[
                canonical.CanonicalPurchaseLine(
                    variant_source_key="v1",
                    quantity=Decimal("0.5"),
                    unit_cost=Decimal("30.00"),
                )
            ],
        )

        PurchaseOrderLoader().load(record, resolver, dry_run=False)

        po = PurchaseOrder.objects.get(supplier_invoice_number="FRAC-2")
        self.assertEqual(po.lines.get().quantity, Decimal("0.500"))
        self.assertEqual(po.total, Decimal("15.00"))

    def test_zero_quantity_purchase_line_is_still_skipped(self):
        """Fidelity is not the same as accepting nothing: a genuinely zero (or
        negative) source quantity remains a skipped line."""
        from .loaders.purchasing import PurchaseOrderLoader, SupplierLoader
        from .loaders.base import LoaderError

        resolver = self._resolver_with_variant()
        SupplierLoader().load(
            canonical.CanonicalSupplier(source_key="s1", name="Wholesaler"),
            resolver,
            dry_run=False,
        )
        record = canonical.CanonicalPurchaseOrder(
            source_key="po-3",
            supplier_source_key="s1",
            supplier_invoice_number="FRAC-3",
            lines=[
                canonical.CanonicalPurchaseLine(
                    variant_source_key="v1",
                    quantity=Decimal("0"),
                    unit_cost=Decimal("30.00"),
                )
            ],
        )

        with self.assertRaises(LoaderError) as ctx:
            PurchaseOrderLoader().load(record, resolver, dry_run=False)
        self.assertEqual(ctx.exception.code, "no_lines")

    def test_sale_loader_already_preserves_fractional_quantity(self):
        """The control: the sale side has always carried the fraction, which is
        what makes the purchase side's truncation an asymmetry rather than a
        product decision."""
        from apps.sales.models import Order

        from .loaders.sales import SaleLoader

        resolver = self._resolver_with_variant()
        record = canonical.CanonicalSale(
            source_key="sale-1",
            lines=[
                canonical.CanonicalSaleLine(
                    variant_source_key="v1",
                    quantity=Decimal("2.5"),
                    unit_price=Decimal("4.00"),
                )
            ],
        )

        outcome = SaleLoader().load(record, resolver, dry_run=False)

        order = Order.objects.get(pk=outcome.target_pk)
        self.assertEqual(order.lines.get().quantity, Decimal("2.500"))
        self.assertEqual(order.total, Decimal("10.00"))

    def test_aboghris_connector_carries_a_fractional_buy_line(self):
        """End to end through a real connector: a legacy buy invoice recorded
        as 2.5 units must arrive as 2.5, not 2."""
        import sqlite3

        from apps.purchasing.models import PurchaseOrder

        build_aboghris_sample(self.db_path)
        connection = sqlite3.connect(self.db_path)
        try:
            connection.execute(
                "INSERT INTO BUY_INVOICE VALUES (?, ?, ?, ?, ?)",
                (2, "2026-05-16 09:00:00", 2, "REF-FRAC", 0),
            )
            connection.execute(
                "INSERT INTO BUY_ITEMS VALUES (?, ?, ?, ?, ?)",
                (3, 2, 401, 2.5, 4.0),
            )
            connection.commit()
        finally:
            connection.close()

        source = self.make_source(
            name="AboGhris",
            system_key="aboghris",
        )
        run = self.run_sync(source, IMPORT)

        self.assertIn(run.status, (MigrationRun.Status.SUCCEEDED, MigrationRun.Status.PARTIAL))
        po = PurchaseOrder.objects.get(supplier_invoice_number="REF-FRAC")
        self.assertEqual(po.lines.get().quantity, Decimal("2.500"))
        self.assertEqual(po.total, Decimal("10.00"))


# --- the file pipeline ------------------------------------------------------
class UploadTests(MigrationTestBase):
    """Chunked, resumable receipt of a database file."""

    def _begin(self, payload=b"x" * 100, filename="db.mdb"):
        return uploads.begin_upload(filename=filename, size_bytes=len(payload))

    def test_chunks_assemble_in_order(self):
        payload = b"".join(bytes([index % 256]) * 64 for index in range(40))
        source = self._begin(payload)
        cursor = 0
        while cursor < len(payload):
            chunk = payload[cursor : cursor + 512]
            source = uploads.append_chunk(source, cursor, io.BytesIO(chunk))
            cursor += len(chunk)
        self.assertEqual(source.upload_state, MigrationSource.UploadState.UPLOADED)
        self.assertEqual(storage.staged_path(source).read_bytes(), payload)

    def test_wrong_offset_is_refused_with_the_real_one(self):
        """A chunk written at the wrong place corrupts a database silently.

        So the server never guesses: it refuses and reports where it actually is,
        and the client re-syncs to that.
        """
        source = self._begin(b"y" * 100)
        source = uploads.append_chunk(source, 0, io.BytesIO(b"y" * 40))
        with self.assertRaises(uploads.OffsetConflict) as ctx:
            uploads.append_chunk(source, 90, io.BytesIO(b"y" * 10))
        self.assertEqual(ctx.exception.expected, 40)
        # Nothing was written past the real offset.
        self.assertEqual(storage.file_size(storage.staged_path(source)), 40)

    def test_resume_continues_from_the_recorded_offset(self):
        payload = b"z" * 300
        source = self._begin(payload)
        source = uploads.append_chunk(source, 0, io.BytesIO(payload[:120]))
        # The client "reconnects" and asks where to continue.
        resumed = MigrationSource.objects.get(pk=source.pk)
        self.assertEqual(resumed.received_bytes, 120)
        source = uploads.append_chunk(resumed, 120, io.BytesIO(payload[120:]))
        self.assertEqual(storage.staged_path(source).read_bytes(), payload)

    def test_chunk_cannot_overrun_the_declared_size(self):
        source = self._begin(b"q" * 50)
        source = uploads.append_chunk(source, 0, io.BytesIO(b"q" * 500))
        self.assertEqual(source.received_bytes, 50)
        self.assertEqual(storage.file_size(storage.staged_path(source)), 50)

    def test_oversize_upload_is_refused_up_front(self):
        with override_settings(POINTY_MIGRATION_MAX_UPLOAD_BYTES=10):
            with self.assertRaises(Exception) as ctx:
                uploads.begin_upload(filename="huge.mdb", size_bytes=11)
        self.assertIn("الحد المسموح", str(ctx.exception))

    def test_completing_a_short_upload_is_refused(self):
        source = self._begin(b"a" * 100)
        uploads.append_chunk(source, 0, io.BytesIO(b"a" * 30))
        with self.assertRaises(Exception):
            uploads.complete_upload(MigrationSource.objects.get(pk=source.pk))

    def test_checksum_mismatch_is_refused(self):
        payload = b"b" * 64
        source = self._begin(payload)
        source = uploads.append_chunk(source, 0, io.BytesIO(payload))
        with self.assertRaises(Exception) as ctx:
            uploads.complete_upload(source, expected_checksum="0" * 64)
        self.assertIn("تالف", str(ctx.exception))

    def test_filename_cannot_escape_the_staging_root(self):
        """The client's filename is a label, never part of a path."""
        source = uploads.begin_upload(filename="../../etc/passwd", size_bytes=8)
        staged = storage.staged_path(source)
        self.assertEqual(staged.parent.resolve(), self.staging.resolve())
        self.assertNotIn("..", source.staged_filename)

    def test_a_bodyless_chunk_is_refused_not_crashed(self):
        """No body reached the view, so there is nothing to read off.

        DRF hands the parser ``None`` when a request carries no length, and
        calling ``.read()`` on that raised an AttributeError — a 500, which the
        client receives as Django's HTML page and reports as a JSON parse error.
        """
        source = self._begin(b"z" * 20)
        with self.assertRaises(Exception) as ctx:
            uploads.append_chunk(source, 0, None)
        self.assertIn("محتوى", str(ctx.exception))
        self.assertEqual(MigrationSource.objects.get(pk=source.pk).received_bytes, 0)

    def test_a_full_disk_is_reported_as_a_refusal_with_a_reason(self):
        """ENOSPC is the operator's problem, and must say so rather than crash."""
        source = self._begin(b"z" * 64)

        def _full(*args, **kwargs):
            raise OSError(errno.ENOSPC, "No space left on device")

        with mock.patch.object(uploads, "_write_at", _full):
            with self.assertRaises(Exception) as ctx:
                uploads.append_chunk(source, 0, io.BytesIO(b"z" * 64))
        message = str(ctx.exception)
        self.assertIn("مساحة", message)
        self.assertEqual(MigrationSource.objects.get(pk=source.pk).received_bytes, 0)

    def test_a_write_that_dies_halfway_does_not_double_on_retry(self):
        """The bytes that landed before the failure must not be written twice.

        ``received_bytes`` does not advance when a chunk fails, so the client
        retries the same offset — correctly. While the file was opened for
        append, those retried bytes landed *after* the partial ones and the
        upload finished at the right size with the database shifted at the seam.
        """
        payload = bytes(range(256)) * 4
        source = self._begin(payload)

        class _DiesHalfway(io.BytesIO):
            def read(self, size=-1):
                data = super().read(size)
                if self.tell() >= 512:
                    raise OSError(errno.EIO, "I/O error")
                return data

        with self.assertRaises(Exception):
            uploads.append_chunk(source, 0, _DiesHalfway(payload))
        source.refresh_from_db()
        self.assertEqual(source.received_bytes, 0)

        source = uploads.append_chunk(source, 0, io.BytesIO(payload))
        self.assertEqual(source.received_bytes, len(payload))
        self.assertEqual(storage.staged_path(source).read_bytes(), payload)

    def test_stray_bytes_past_the_offset_are_cut_back(self):
        """Whatever a previous attempt left behind, the file follows the offset."""
        payload = b"".join(bytes([index % 256]) * 32 for index in range(16))
        source = self._begin(payload)
        source = uploads.append_chunk(source, 0, io.BytesIO(payload[:128]))

        staged = storage.staged_path(source)
        with open(staged, "ab") as handle:
            handle.write(b"!" * 99)

        source = uploads.append_chunk(source, 128, io.BytesIO(payload[128:]))
        self.assertEqual(source.received_bytes, len(payload))
        self.assertEqual(staged.read_bytes(), payload)


class IdentifyTests(MigrationTestBase):
    def _write(self, header, name="f.bin"):
        path = Path(self._tmpdir.name) / name
        path.write_bytes(header + b"\x00" * 64)
        return path

    def test_recognises_sqlite(self):
        build_sample_database(self.db_path)
        self.assertEqual(identification.identify(self.db_path), identification.SQLITE)

    def test_recognises_access(self):
        path = self._write(b"\x00\x01\x00\x00Standard Jet DB\x00")
        self.assertEqual(identification.identify(path), identification.ACCESS)

    def test_recognises_accdb(self):
        path = self._write(b"\x00\x01\x00\x00Standard ACE DB\x00")
        self.assertEqual(identification.identify(path), identification.ACCESS)

    def test_names_what_it_found_for_a_zip(self):
        """A dead end helps nobody; "this is a ZIP" is a next step."""
        path = self._write(b"PK\x03\x04")
        with self.assertRaises(identification.UnsupportedFile) as ctx:
            identification.identify(path)
        self.assertEqual(ctx.exception.detected, "ZIP")
        self.assertIn("مضغوط", str(ctx.exception))

    def test_explains_a_sql_server_backup(self):
        path = self._write(b"TAPE")
        with self.assertRaises(identification.UnsupportedFile) as ctx:
            identification.identify(path)
        self.assertIn("SQL Server", str(ctx.exception))

    def test_empty_file(self):
        path = Path(self._tmpdir.name) / "empty.mdb"
        path.write_bytes(b"")
        with self.assertRaises(identification.UnsupportedFile):
            identification.identify(path)


class DetectionTests(MigrationTestBase):
    def test_identifies_the_reference_schema(self):
        build_sample_database(self.db_path)
        with build_transport("sqlite", {"database": str(self.db_path)}) as transport:
            result = detection.detect(transport)
        self.assertTrue(result.matched)
        self.assertEqual(result.match.system_key, "reference_sqlite")

    def test_identifies_a_prepared_fahd_file(self):
        build_fahd_database(self.db_path)
        with build_transport("sqlite", {"database": str(self.db_path)}) as transport:
            result = detection.detect(transport)
        self.assertTrue(result.matched)
        self.assertEqual(result.match.system_key, "fahd")

    def test_raw_phase_spots_an_unreconstructed_fahd_file(self):
        """A converted .mdb has the catalogue and the log, and no invoices.

        Matching the raw shape is what tells the pipeline to run the replay.
        """
        build_fahd_sample(self.db_path)
        connection = sqlite3.connect(self.db_path)
        connection.execute(
            "CREATE TABLE control (id INTEGER, emp_id INTEGER, prog TEXT, "
            "op TEXT, descrip TEXT, op_date TEXT)"
        )
        connection.commit()
        connection.close()
        with build_transport("sqlite", {"database": str(self.db_path)}) as transport:
            final = detection.detect(transport)
            raw = detection.detect(transport, raw=True)
        self.assertFalse(final.matched)  # no invoice tables yet
        self.assertTrue(raw.matched)
        self.assertEqual(raw.match.system_key, "fahd")

    def test_unknown_file_explains_the_closest_miss(self):
        connection = sqlite3.connect(self.db_path)
        connection.execute("CREATE TABLE unrelated (id INTEGER)")
        connection.commit()
        connection.close()
        with build_transport("sqlite", {"database": str(self.db_path)}) as transport:
            result = detection.detect(transport)
        self.assertFalse(result.matched)
        message = result.failure_message()
        self.assertTrue(message)
        self.assertIn("جداول", message)


class PreparationPipelineTests(MigrationTestBase):
    """The whole path from staged bytes to a source a run can use."""

    def _staged_source(self, path):
        source = MigrationSource.objects.create(
            name=path.name,
            original_filename=path.name,
            declared_size_bytes=path.stat().st_size,
            received_bytes=path.stat().st_size,
            upload_state=MigrationSource.UploadState.UPLOADED,
        )
        source.staged_filename = storage.staged_name(source.pk, "sqlite")
        source.save(update_fields=["staged_filename"])
        storage.adopt(path, storage.staged_path(source))
        return source

    def test_sqlite_upload_becomes_a_ready_source(self):
        build_sample_database(self.db_path)
        source = self._staged_source(self.db_path)

        pipeline.prepare_source(source)
        source.refresh_from_db()

        self.assertEqual(source.upload_state, MigrationSource.UploadState.READY)
        self.assertEqual(source.system_key, "reference_sqlite")
        self.assertTrue(storage.prepared_path(source).exists())
        # Conversion is skipped for a file that is already SQLite; identification
        # and detection are not.
        statuses = {stage["key"]: stage["status"] for stage in source.stages}
        self.assertEqual(statuses["identify"], "done")
        self.assertEqual(statuses["convert"], "skipped")
        self.assertEqual(statuses["detect"], "done")

    def test_analysis_counts_what_is_in_the_file(self):
        build_sample_database(self.db_path)
        source = self._staged_source(self.db_path)

        pipeline.prepare_source(source)
        source.refresh_from_db()

        entities = source.analysis["entities"]
        self.assertEqual(entities["product"]["count"], 5)
        self.assertEqual(entities["customer"]["count"], 2)

    def test_unreadable_file_fails_with_an_explanation(self):
        path = Path(self._tmpdir.name) / "notes.txt"
        path.write_bytes(b"PK\x03\x04 not a database")
        source = self._staged_source(path)

        pipeline.prepare_source(source)
        source.refresh_from_db()

        self.assertEqual(source.upload_state, MigrationSource.UploadState.FAILED)
        self.assertIn("مضغوط", source.error_message)
        self.assertEqual(source.stages[0]["status"], "failed")
        # Stages after the failure say they never ran rather than looking queued.
        self.assertEqual(source.stages[-1]["status"], "skipped")

    def test_unrecognised_schema_fails_at_detection(self):
        connection = sqlite3.connect(self.db_path)
        connection.execute("CREATE TABLE nothing_we_know (id INTEGER)")
        connection.commit()
        connection.close()
        source = self._staged_source(self.db_path)

        pipeline.prepare_source(source)
        source.refresh_from_db()

        self.assertEqual(source.upload_state, MigrationSource.UploadState.FAILED)
        self.assertTrue(source.error_message)
        self.assertFalse(source.detection["matched"])


class PurgeTests(MigrationTestBase):
    def test_clean_import_deletes_the_file(self):
        """The point of the feature: the shop's history does not linger here."""
        build_sample_database(self.db_path)
        source = self.make_source()
        prepared = storage.prepared_path(source)
        self.assertTrue(prepared.exists())

        run = self.run_sync(source, IMPORT)
        source.refresh_from_db()

        self.assertEqual(run.status, MigrationRun.Status.SUCCEEDED)
        self.assertEqual(source.upload_state, MigrationSource.UploadState.PURGED)
        self.assertFalse(prepared.exists())
        self.assertIsNotNone(source.purged_at)

    def test_identity_map_survives_the_purge(self):
        """Deleting the file must not make a re-import duplicate the catalogue."""
        build_sample_database(self.db_path)
        source = self.make_source()
        self.run_sync(source, IMPORT)

        source.refresh_from_db()
        self.assertTrue(source.is_purged)
        self.assertEqual(
            MigrationIdentityMap.objects.filter(source=source, entity_type="product").count(),
            5,
        )

    def test_partial_import_keeps_the_file(self):
        """A run with failures may be re-run after a fix; do not make them
        re-upload a gigabyte to do it."""
        build_sample_database(self.db_path)
        connection = sqlite3.connect(self.db_path)
        connection.execute("UPDATE products SET name = '' WHERE id = 1")
        connection.commit()
        connection.close()
        source = self.make_source()

        run = self.run_sync(source, IMPORT)
        source.refresh_from_db()

        if run.status == MigrationRun.Status.PARTIAL:
            self.assertNotEqual(source.upload_state, MigrationSource.UploadState.PURGED)
            self.assertTrue(storage.prepared_path(source).exists())

    def test_expired_uploads_are_swept(self):
        from datetime import timedelta

        from django.utils import timezone

        build_sample_database(self.db_path)
        source = self.make_source()
        MigrationSource.objects.filter(pk=source.pk).update(
            updated_at=timezone.now() - timedelta(hours=100)
        )

        freed = pipeline.purge_expired()
        source.refresh_from_db()

        self.assertGreater(freed, 0)
        self.assertEqual(source.upload_state, MigrationSource.UploadState.PURGED)

    def test_a_run_cannot_start_against_a_purged_source(self):
        build_sample_database(self.db_path)
        source = self.make_source()
        pipeline.purge(source)
        source.refresh_from_db()
        with self.assertRaises(Exception) as ctx:
            services.queue_migration_run(source, mode=IMPORT, dispatch=False)
        self.assertIn("غير جاهز", str(ctx.exception))


class RunStageTests(MigrationTestBase):
    def test_import_reports_a_stage_per_entity(self):
        build_sample_database(self.db_path)
        source = self.make_source()

        run = self.run_sync(source, IMPORT)

        stages = {stage["key"]: stage for stage in run.stages}
        self.assertIn("product", stages)
        self.assertEqual(stages["product"]["status"], "done")
        self.assertEqual(stages["product"]["counts"]["created"], 5)
        self.assertTrue(stages["product"]["detail"])

    def test_dry_run_stages_survive_the_rollback(self):
        """A dry run's writes are discarded; its report is not."""
        build_sample_database(self.db_path)
        source = self.make_source()

        run = self.run_sync(source, DRY_RUN)

        self.assertTrue(run.stages)
        self.assertEqual(
            {stage["key"] for stage in run.stages if stage["status"] == "done"} >= {"product"},
            True,
        )


class AccessConversionTests(MigrationTestBase):
    """The Access → SQLite conversion, including its subprocess plumbing.

    mdbtools is stood in for rather than required: what belongs to us is the
    pumping of bytes between two processes, the per-table progress, and what
    happens when one table fails — not whether mdbtools reads Jet correctly.
    The stand-in emits exactly what the real tools emit, so the pipe mechanics
    under test are the real ones.
    """

    def setUp(self):
        super().setUp()
        self.bin = Path(self._tmpdir.name) / "bin"
        self.bin.mkdir()

    def _install_fake_mdbtools(self, *, tables, failing=()):
        import os
        import stat

        table_list = "\\n".join(tables)
        schema = "".join(
            f'CREATE TABLE "{table}" (id INTEGER, label TEXT);\\n' for table in tables
        )
        fail_check = ""
        if failing:
            names = " ".join(f'"{name}"' for name in failing)
            fail_check = (
                f'for bad in {names}; do\n'
                '  if [ "$TABLE" = "$bad" ]; then echo "boom" >&2; exit 3; fi\n'
                'done\n'
            )
        scripts = {
            "mdb-tables": f'#!/bin/sh\nprintf "{table_list}\\n"\n',
            "mdb-schema": f'#!/bin/sh\nprintf \'{schema}\'\n',
            # mdb-export's argv is (..., source, table): the table is last.
            # `for last; do :; done` walks to it — `$12` would parse as `$1`
            # followed by a literal 2, and mdb-export gets twelve arguments.
            "mdb-export": (
                "#!/bin/sh\n"
                'for last; do :; done\nTABLE="$last"\n'
                f"{fail_check}"
                'printf "INSERT INTO \\"$TABLE\\" VALUES (1, \'قيمة ; مع فاصلة\');\\n"\n'
                'printf "INSERT INTO \\"$TABLE\\" VALUES (2, \'two\');\\n"\n'
            ),
        }
        for name, body in scripts.items():
            path = self.bin / name
            path.write_text(body)
            path.chmod(path.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)
        original = os.environ["PATH"]
        os.environ["PATH"] = f"{self.bin}{os.pathsep}{original}"
        self.addCleanup(lambda: os.environ.__setitem__("PATH", original))

    def _convert(self, source_name="db.mdb"):
        from .preparation import access

        source = Path(self._tmpdir.name) / source_name
        source.write_bytes(b"\x00\x01\x00\x00Standard Jet DB\x00" + b"\x00" * 64)
        destination = Path(self._tmpdir.name) / "converted.sqlite"
        return access.convert(source, destination), destination

    def test_every_table_lands_with_its_rows(self):
        self._install_fake_mdbtools(tables=["CAR_PART", "TASNEEF", "control"])

        stats, destination = self._convert()

        self.assertEqual(stats["tables_converted"], 3)
        self.assertEqual(stats["tables_failed"], [])
        self.assertGreater(stats["bytes_streamed"], 0)
        connection = sqlite3.connect(destination)
        try:
            for table in ("CAR_PART", "TASNEEF", "control"):
                count = connection.execute(
                    f'SELECT COUNT(*) FROM "{table}"'
                ).fetchone()[0]
                self.assertEqual(count, 2, table)
            # A value containing a quote and a semicolon survives, because
            # sqlite3 parses the SQL rather than us splitting it on lines.
            label = connection.execute(
                "SELECT label FROM CAR_PART WHERE id = 1"
            ).fetchone()[0]
            self.assertEqual(label, "قيمة ; مع فاصلة")
        finally:
            connection.close()

    def test_one_bad_table_does_not_lose_the_others(self):
        """Legacy Access files routinely carry one unreadable table nothing
        reads. Losing the other sixty because of it helps nobody."""
        self._install_fake_mdbtools(
            tables=["CAR_PART", "broken", "TASNEEF"], failing=["broken"]
        )

        stats, destination = self._convert()

        self.assertEqual(stats["tables_failed"], ["broken"])
        self.assertEqual(stats["tables_converted"], 2)
        connection = sqlite3.connect(destination)
        try:
            self.assertEqual(
                connection.execute("SELECT COUNT(*) FROM CAR_PART").fetchone()[0], 2
            )
        finally:
            connection.close()

    def test_progress_is_reported_per_table(self):
        from .preparation.stages import Stage, StageTracker

        self._install_fake_mdbtools(tables=["one", "two", "three"])
        source = MigrationSource.objects.create(name="db.mdb")
        tracker = StageTracker(source, [Stage("convert", "تحويل")])

        self._convert()
        # Re-run under the tracker so the stage transitions are observable.
        from .preparation import access

        path = Path(self._tmpdir.name) / "db.mdb"
        destination = Path(self._tmpdir.name) / "tracked.sqlite"
        access.convert(path, destination, tracker=tracker)

        stage = tracker.as_list()[0]
        self.assertEqual(stage["status"], "done")
        self.assertEqual(stage["counts"]["tables_total"], 3)
        self.assertEqual(stage["counts"]["tables_converted"], 3)

    def test_missing_tools_say_so(self):
        import shutil
        from unittest import mock

        from .preparation import access

        with mock.patch.object(shutil, "which", return_value=None):
            with self.assertRaises(access.ConversionError) as ctx:
                access.require_tools()
        self.assertIn("mdb-tables", str(ctx.exception))

    def test_access_upload_runs_the_whole_pipeline(self):
        """An .mdb goes in; a prepared, identified source comes out."""
        # The stand-in emits the reference connector's schema so detection has
        # something real to match against on the far side of the conversion.
        import os
        import stat

        schema = (
            "CREATE TABLE categories (id INTEGER, name TEXT, parent_id INTEGER);\n"
            "CREATE TABLE products (id INTEGER, name TEXT, sku TEXT, barcode TEXT, "
            "price REAL, cost REAL, category_id INTEGER, is_service INTEGER, "
            "is_active INTEGER);\n"
            "CREATE TABLE customers (id INTEGER, full_name TEXT, phone TEXT);\n"
            "CREATE TABLE suppliers (id INTEGER, name TEXT, phone TEXT);\n"
            "CREATE TABLE stock (product_id INTEGER, quantity REAL);\n"
        )
        rows = {
            "categories": "INSERT INTO categories VALUES (1, 'مشروبات', NULL);",
            "products": (
                "INSERT INTO products VALUES "
                "(1, 'شاي', 'SKU1', '111', 2.5, 1.0, 1, 0, 1);"
            ),
            "customers": "INSERT INTO customers VALUES (1, 'أحمد', '0910000000');",
            "suppliers": "INSERT INTO suppliers VALUES (1, 'مورد', '0920000000');",
            "stock": "INSERT INTO stock VALUES (1, 7);",
        }
        cases = "".join(
            f'  {name}) printf "{sql}\\n" ;;\n' for name, sql in rows.items()
        )
        scripts = {
            "mdb-tables": (
                "#!/bin/sh\n"
                'printf "categories\\nproducts\\ncustomers\\nsuppliers\\nstock\\n"\n'
            ),
            "mdb-schema": f"#!/bin/sh\nprintf '{schema}'\n",
            "mdb-export": (
                "#!/bin/sh\n"
                'for last; do :; done\nTABLE="$last"\n'
                'case "$TABLE" in\n'
                f"{cases}"
                "esac\n"
            ),
        }
        for name, body in scripts.items():
            path = self.bin / name
            path.write_text(body)
            path.chmod(path.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)
        original = os.environ["PATH"]
        os.environ["PATH"] = f"{self.bin}{os.pathsep}{original}"
        self.addCleanup(lambda: os.environ.__setitem__("PATH", original))

        payload = b"\x00\x01\x00\x00Standard Jet DB\x00" + b"\x00" * 64
        source = uploads.begin_upload(filename="db.mdb", size_bytes=len(payload))
        source = uploads.append_chunk(source, 0, io.BytesIO(payload))
        uploads.complete_upload(source)
        source.refresh_from_db()

        pipeline.prepare_source(source)
        source.refresh_from_db()

        self.assertEqual(
            source.upload_state,
            MigrationSource.UploadState.READY,
            source.error_message,
        )
        self.assertEqual(source.system_key, "reference_sqlite")
        statuses = {stage["key"]: stage["status"] for stage in source.stages}
        self.assertEqual(statuses["convert"], "done")
        # The multi-GB original is deleted as soon as it has been converted.
        self.assertEqual(source.staged_filename, "")
        self.assertTrue(storage.prepared_path(source).exists())
        self.assertEqual(source.analysis["entities"]["product"]["count"], 1)

    def test_a_conversion_that_fails_later_leaves_nothing_behind(self):
        """Detection can reject a file the conversion produced fine.

        The intermediate is the size of the whole database and nothing on the
        source row names it, so only a derived name can find it afterwards.
        """
        import os
        import stat

        scripts = {
            "mdb-tables": '#!/bin/sh\nprintf "unrelated\\n"\n',
            "mdb-schema": "#!/bin/sh\nprintf 'CREATE TABLE unrelated (id INTEGER);\\n'\n",
            "mdb-export": (
                "#!/bin/sh\n"
                'for last; do :; done\nTABLE="$last"\n'
                'printf "INSERT INTO unrelated VALUES (1);\\n"\n'
            ),
        }
        for name, body in scripts.items():
            path = self.bin / name
            path.write_text(body)
            path.chmod(path.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)
        original = os.environ["PATH"]
        os.environ["PATH"] = f"{self.bin}{os.pathsep}{original}"
        self.addCleanup(lambda: os.environ.__setitem__("PATH", original))

        payload = b"\x00\x01\x00\x00Standard Jet DB\x00" + b"\x00" * 64
        source = uploads.begin_upload(filename="db.mdb", size_bytes=len(payload))
        source = uploads.append_chunk(source, 0, io.BytesIO(payload))
        uploads.complete_upload(source)
        source.refresh_from_db()

        pipeline.prepare_source(source)
        source.refresh_from_db()

        self.assertEqual(source.upload_state, MigrationSource.UploadState.FAILED)
        working = self.staging / storage.working_name(source.pk)
        self.assertFalse(working.exists(), "the converted intermediate leaked")
        # The upload itself is kept: preparation can be retried without asking
        # for the gigabytes again.
        self.assertTrue(storage.staged_path(source).exists())


class UploadApiTests(MigrationTestBase):
    """The HTTP layer of the upload — the parser wiring in particular.

    ``append_chunk`` is unit-tested above; what these cover is that a raw
    ``application/octet-stream`` body actually reaches it. DRF materialises a
    request body through a parser by default, and a chunk is a slice of a
    database that must arrive byte for byte, so the view installs one that hands
    the stream straight through. That is easy to break and invisible when it is.
    """

    def setUp(self):
        super().setUp()
        from django.contrib.auth import get_user_model
        from django.contrib.auth.models import Group
        from rest_framework.test import APIClient

        from apps.core.roles import MANAGER_GROUP

        self.user = get_user_model().objects.create_user(
            username="owner", password="pass"
        )
        self.user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.api = APIClient()
        self.api.force_authenticate(self.user)

    def _begin(self, payload, filename="db.sqlite"):
        response = self.api.post(
            "/api/migration/sources/begin/",
            {"filename": filename, "size_bytes": len(payload)},
            format="json",
        )
        self.assertEqual(response.status_code, 201, response.data)
        return response.data["source"]["id"], response.data["chunk_size"]

    def _put_chunk(self, source_id, offset, chunk):
        return self.api.put(
            f"/api/migration/sources/{source_id}/chunk/?offset={offset}",
            data=chunk,
            content_type="application/octet-stream",
        )

    def test_a_raw_body_reaches_the_file_intact(self):
        # Bytes that would not survive being decoded as text or re-encoded.
        payload = bytes(range(256)) * 4
        source_id, _ = self._begin(payload)

        response = self._put_chunk(source_id, 0, payload)

        self.assertEqual(response.status_code, 200, response.data)
        self.assertEqual(response.data["received_bytes"], len(payload))
        source = MigrationSource.objects.get(pk=source_id)
        self.assertEqual(storage.staged_path(source).read_bytes(), payload)

    def test_chunks_arrive_in_sequence(self):
        payload = bytes(range(256)) * 8
        source_id, _ = self._begin(payload)
        cursor = 0
        while cursor < len(payload):
            chunk = payload[cursor : cursor + 300]
            response = self._put_chunk(source_id, cursor, chunk)
            self.assertEqual(response.status_code, 200)
            cursor = response.data["received_bytes"]

        source = MigrationSource.objects.get(pk=source_id)
        self.assertEqual(storage.staged_path(source).read_bytes(), payload)
        self.assertEqual(response.data["upload_percent"], 100)

    def test_a_wrong_offset_is_a_409_carrying_the_real_one(self):
        payload = b"a" * 100
        source_id, _ = self._begin(payload)
        self._put_chunk(source_id, 0, payload[:40])

        response = self._put_chunk(source_id, 90, payload[90:])

        self.assertEqual(response.status_code, 409)
        self.assertEqual(response.data["received_bytes"], 40)

    def test_a_missing_offset_is_rejected_rather_than_guessed(self):
        payload = b"b" * 20
        source_id, _ = self._begin(payload)

        response = self.api.put(
            f"/api/migration/sources/{source_id}/chunk/",
            data=payload,
            content_type="application/octet-stream",
        )

        self.assertEqual(response.status_code, 400)

    def test_completing_queues_preparation(self):
        build_sample_database(self.db_path)
        payload = self.db_path.read_bytes()
        source_id, _ = self._begin(payload)
        self._put_chunk(source_id, 0, payload)

        with mock.patch("apps.migration.services._dispatch_preparation") as dispatch:
            response = self.api.post(
                f"/api/migration/sources/{source_id}/complete/",
                {"checksum_sha256": uploads.checksum(
                    storage.staged_path(MigrationSource.objects.get(pk=source_id))
                )},
                format="json",
            )

        self.assertEqual(response.status_code, 202, response.data)
        dispatch.assert_called_once()
        self.assertEqual(response.data["upload_state"], "uploaded")

    def test_the_advertised_chunk_never_exceeds_what_the_proxy_carries(self):
        """The chunk size and the front door's cap live in different files.

        The browser reaches the backend through `web` (client_max_body_size
        100m); a native till reaches `edge` (uncapped). So an over-large chunk
        fails only from the browser, with a bare nginx 413 — a failure that
        depends on how you opened the app. Clamping the advertised value is what
        makes that impossible to configure.
        """
        with override_settings(
            POINTY_MIGRATION_CHUNK_BYTES=512 * 1024 * 1024,
            POINTY_MIGRATION_MAX_CHUNK_BYTES=64 * 1024 * 1024,
        ):
            # The setting is clamped where it is read, so an override that skips
            # settings.py's own clamp is still caught at the boundary.
            response = self.api.get("/api/migration/systems/")
        advertised = response.data["upload"]["chunk_size"]
        self.assertLessEqual(advertised, 64 * 1024 * 1024)

    def test_the_catalogue_tells_the_client_how_to_upload(self):
        response = self.api.get("/api/migration/systems/")

        self.assertEqual(response.status_code, 200)
        upload = response.data["upload"]
        self.assertGreater(upload["chunk_size"], 0)
        self.assertIn(".mdb", upload["accepted_extensions"])
        # The connection-era catalogue fields are gone.
        self.assertNotIn("required_transport", response.data["systems"][0])

    def test_discarding_deletes_the_file(self):
        payload = b"c" * 64
        source_id, _ = self._begin(payload)
        self._put_chunk(source_id, 0, payload)
        source = MigrationSource.objects.get(pk=source_id)
        staged = storage.staged_path(source)
        self.assertTrue(staged.exists())

        response = self.api.post(f"/api/migration/sources/{source_id}/discard/")

        self.assertEqual(response.status_code, 200)
        self.assertGreater(response.data["freed_bytes"], 0)
        self.assertFalse(staged.exists())
        self.assertEqual(response.data["source"]["upload_state"], "purged")

    def test_a_cashier_cannot_upload_a_database(self):
        from django.contrib.auth import get_user_model

        cashier = get_user_model().objects.create_user(
            username="cashier", password="pass"
        )
        api = self.api.__class__()
        api.force_authenticate(cashier)

        response = api.post(
            "/api/migration/sources/begin/",
            {"filename": "db.mdb", "size_bytes": 10},
            format="json",
        )

        self.assertEqual(response.status_code, 403)

    def test_a_prepared_file_written_before_a_late_failure_is_still_purged(self):
        """Reconstruction can succeed and identification still reject the result.

        The prepared database is written before the row names it, so only a
        derived name finds it afterwards.
        """
        source = MigrationSource.objects.create(name="db.mdb")
        orphan = self.staging / storage.prepared_name(source.pk)
        orphan.write_bytes(b"x" * 4096)
        self.assertEqual(source.prepared_filename, "")

        freed = pipeline.purge(source)

        self.assertEqual(freed, 4096)
        self.assertFalse(orphan.exists())


def rewrite_as_access_conversion(path, boolean_columns):
    """Rewrite a fixture the way ``mdbtools`` hands an Access database over.

    Two things change on the way through ``preparation/access.py``, and both are
    invisible until a real shop's file arrives:

    * **Every value becomes text.** ``mdb-export`` emits SQL literals, and
      ``mdb-schema`` types the columns loosely, so a connector that was written
      against a driver returning ``int``/``Decimal``/``datetime`` now sees
      strings.
    * **Access stores True as -1.** A Jet Yes/No field is a bitmask, so a
      boolean column arrives as ``"-1"`` rather than ``"1"``.

    ``boolean_columns`` names the Yes/No fields, which is the one thing that
    cannot be inferred from a SQL Server-shaped fixture: nothing distinguishes a
    flag from a count once both are integers.
    """
    connection = sqlite3.connect(path)
    try:
        tables = [
            row[0]
            for row in connection.execute(
                "SELECT name FROM sqlite_master WHERE type='table'"
            )
        ]
        flags = {name.lower() for name in boolean_columns}
        for table in tables:
            columns = [
                row[1] for row in connection.execute(f'PRAGMA table_info("{table}")')
            ]
            rows = list(connection.execute(f'SELECT * FROM "{table}"'))
            connection.execute(f'DROP TABLE "{table}"')
            declared = ", ".join(f'"{column}" TEXT' for column in columns)
            connection.execute(f'CREATE TABLE "{table}" ({declared})')
            converted = []
            for row in rows:
                values = []
                for column, value in zip(columns, row):
                    if value is None:
                        values.append(None)
                    elif column.lower() in flags:
                        values.append("-1" if value else "0")
                    else:
                        values.append(str(value))
                converted.append(tuple(values))
            placeholders = ", ".join("?" for _ in columns)
            connection.executemany(
                f'INSERT INTO "{table}" VALUES ({placeholders})', converted
            )
        connection.commit()
    finally:
        connection.close()


#: The Yes/No fields in the AboGhris schema.
ABOGHRIS_BOOLEAN_COLUMNS = (
    "CUST_VENDOR",
    "CUST_INVISIBLE",
    "ITEM_INVISIBLE",
    "CAT1_INVISIBLE",
    "CAT2_INVISIBLE",
    "EXPENSE_INVISIBLE",
)


class AboGhrisAccessConversionTests(MigrationTestBase):
    """AboGhris arriving as an Access file rather than a SQL Server connection.

    The connector was written from a SQL Server schema export and read through
    pyodbc. Shops hand over `.mdb` files, so the same mapping now runs over an
    mdbtools conversion — every value text, every Yes/No field ``-1``. These
    assert the import is *identical* either way, because a difference here would
    not raise: it would quietly file every supplier as a customer.
    """

    def _access_source(self):
        build_aboghris_sample(self.db_path)
        rewrite_as_access_conversion(self.db_path, ABOGHRIS_BOOLEAN_COLUMNS)
        return self.make_source(name="AboGhris", system_key="aboghris")

    def test_the_schema_is_still_recognised_after_conversion(self):
        build_aboghris_sample(self.db_path)
        rewrite_as_access_conversion(self.db_path, ABOGHRIS_BOOLEAN_COLUMNS)

        with build_transport("sqlite", {"database": str(self.db_path)}) as transport:
            result = detection.detect(transport)

        self.assertTrue(result.matched, result.failure_message())
        self.assertEqual(result.match.system_key, "aboghris")

    def test_suppliers_are_still_suppliers(self):
        """The one that would have been silent.

        Suppliers are split from customers on ``CUST_VENDOR``. Read Access's
        ``-1`` as false and every supplier lands in the customer list instead,
        with no error and no missing rows to notice.
        """
        source = self._access_source()

        run = self.run_sync(source, IMPORT, options={"stock_source": "none"})

        self.assertIn(
            run.status, (MigrationRun.Status.SUCCEEDED, MigrationRun.Status.PARTIAL)
        )
        self.assertTrue(Supplier.objects.filter(name="شركة النسيم").exists())
        self.assertFalse(Customer.objects.filter(full_name="شركة النسيم").exists())
        # And the one genuine customer did not drift the other way.
        self.assertTrue(Customer.objects.filter(full_name="زبون نقدي").exists())

    def test_hidden_rows_stay_hidden(self):
        source = self._access_source()

        self.run_sync(source, IMPORT, options={"stock_source": "none"})

        # ITEM_INVISIBLE is set on item 500 only.
        hidden = Product.objects.filter(name="Item 500").first()
        self.assertIsNotNone(hidden)
        self.assertFalse(hidden.is_active)
        self.assertTrue(Product.objects.get(name="Item 401").is_active)

    def test_the_connector_reads_both_shapes_identically(self):
        """The strongest form of the claim: same records out, either way in.

        Comparing imported row counts cannot show this — the loaders dedupe on
        natural keys, so importing the same shop twice correctly updates rather
        than duplicates. What matters is upstream of that: whether the connector
        understands a converted file the same way it understood a live one. So
        compare the canonical records it emits, field by field.
        """
        native_path = Path(self._tmpdir.name) / "native.sqlite"
        build_aboghris_sample(native_path)
        access_path = Path(self._tmpdir.name) / "access.sqlite"
        build_aboghris_sample(access_path)
        rewrite_as_access_conversion(access_path, ABOGHRIS_BOOLEAN_COLUMNS)

        connector = get_connector("aboghris")

        def extracted(path):
            out = {}
            with build_transport("sqlite", {"database": str(path)}) as transport:
                for entity_type in connector.supported_entities:
                    context = ExtractContext(run_options={})
                    out[entity_type] = [
                        repr(record)
                        for record in connector.extract(entity_type, transport, context)
                    ]
            return out

        native = extracted(native_path)
        converted = extracted(access_path)

        self.assertEqual(sorted(native), sorted(converted))
        for entity_type in native:
            self.assertEqual(
                native[entity_type],
                converted[entity_type],
                f"{entity_type} differs between the two shapes",
            )
        # Guard against the comparison passing because both read nothing.
        self.assertGreater(len(native["product"]), 0)
        self.assertGreater(len(native["supplier"]), 0)


class JetBooleanTests(TestCase):
    """Access's -1, and everything else a legacy boolean arrives as."""

    def test_access_true_is_minus_one(self):
        from .connectors.values import to_bool

        self.assertTrue(to_bool("-1"))
        self.assertTrue(to_bool(-1))

    def test_sql_server_and_driver_shapes_still_work(self):
        from .connectors.values import to_bool

        for truthy in (True, 1, "1", "true", "True", "yes", "Y", "t", 2, "2"):
            self.assertTrue(to_bool(truthy), truthy)

    def test_falsehood(self):
        from .connectors.values import to_bool

        for falsy in (None, "", "  ", False, 0, "0", "-0", "no", "false", "n"):
            self.assertFalse(to_bool(falsy), repr(falsy))
