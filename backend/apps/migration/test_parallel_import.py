"""The parallel import: same result as a serial run, on two worker threads.

These run on a ``TransactionTestCase``. The workers have database connections
of their own, and a ``TestCase``'s rows sit in a transaction no other
connection can see — which is also why the suite's default is one worker and
these opt in.
"""

import sqlite3
import threading
from collections import Counter
from unittest import mock, skipUnless

from django.db import connection
from django.test import TransactionTestCase, override_settings

from apps.catalog.models import (
    ProductUnitBarcode,
    ProductVariant,
    ProductVariantBarcode,
    SkuSeriesReservation,
)
from apps.purchasing.models import PurchaseOrder, Supplier
from apps.sales.models import Order

from .engine import MigrationEngine
from .loaders.purchasing import _FALLBACK_SUPPLIER_NAME
from .models import MigrationIdentityMap, MigrationIssue, MigrationRun
from .planning import PLACEHOLDER_PREFIX
from .tests import DRY_RUN, IMPORT, MigrationFixtures, build_aboghris_sample

ITEMS = 120
SALES = 90
PURCHASES = 30


def build_busy_aboghris(path):
    """The AboGhris sample, grown into something worth two workers.

    With the collisions a real file has: one model number on many items (a
    duplicate SKU), one EAN filed under two items, and a purchase from a
    supplier the file never lists.
    """
    build_aboghris_sample(path)
    db = sqlite3.connect(path)
    try:
        items, codes, sales, sale_lines, buys, buy_lines = [], [], [], [], [], []
        bar_id = 5000
        for index in range(ITEMS):
            item = 2000 + index
            model = "SHARED-MODEL" if index % 10 == 0 else ""
            items.append((item, model, f"صنف {index}", 59, 44, 0, 3.0, 2.5))
            bar_id += 1
            # Every seventh item is filed under the EAN of the item before it.
            ean = 7100000000000 + (index - 1 if index % 7 == 0 and index else index)
            codes.append((bar_id, 92, item, str(ean), 5, 0, 1))
            if index % 3 == 0:
                bar_id += 1
                codes.append((bar_id, 94, item, str(7200000000000 + index), 0, 40, 10))
        for invoice in range(SALES):
            s_id = 100 + invoice
            sales.append((s_id, f"2026-07-{invoice % 28 + 1:02d} 10:00:00", 1, 0, 0, 1))
            for line in range(3):
                item = 2000 + (invoice * 3 + line) % ITEMS
                sale_lines.append((s_id * 10 + line, s_id, item, 1, 5, 5, 5, 2.5, 2.5))
        for order in range(PURCHASES):
            b_id = 100 + order
            supplier = 99 if order % 10 == 0 else 2  # 99: nowhere in CUSTOMERS
            buys.append((b_id, f"2026-06-{order % 28 + 1:02d} 09:00:00", supplier, "", 0, 1))
            for line in range(2):
                item = 2000 + (order * 2 + line) % ITEMS
                buy_lines.append((b_id * 10 + line, b_id, item, 4, 2.5))
        db.executemany("INSERT INTO ITEMS VALUES (?, ?, ?, ?, ?, ?, ?, ?)", items)
        db.executemany("INSERT INTO BARCODE VALUES (?, ?, ?, ?, ?, ?, ?)", codes)
        db.executemany("INSERT INTO SALE_INVOICE VALUES (?, ?, ?, ?, ?, ?)", sales)
        db.executemany("INSERT INTO SALE_ITEMS VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)", sale_lines)
        db.executemany("INSERT INTO BUY_INVOICE VALUES (?, ?, ?, ?, ?, ?)", buys)
        db.executemany("INSERT INTO BUY_ITEMS VALUES (?, ?, ?, ?, ?)", buy_lines)
        db.commit()
    finally:
        db.close()


def _issues(run):
    return Counter(
        MigrationIssue.objects.filter(run=run).values_list("entity_type", "code", "source_key")
    )


@skipUnless(connection.vendor == "postgresql", "parallel workers are a Postgres feature")
@override_settings(POINTY_MIGRATION_IMPORT_WORKERS=2)
class ParallelImportTests(MigrationFixtures, TransactionTestCase):
    serialized_rollback = True

    def setUp(self):
        super().setUp()
        build_busy_aboghris(self.db_path)
        self.source = self.make_source(name="AboGhris", system_key="aboghris")

    def _import_watching_threads(self):
        threads: set[str] = set()
        load_one = MigrationEngine._load_one

        def spy(engine, spec, *args, **kwargs):
            threads.add(f"{spec.entity_type}:{threading.current_thread().name}")
            return load_one(engine, spec, *args, **kwargs)

        with mock.patch.object(MigrationEngine, "_load_one", spy):
            run = self.run_sync(self.source, IMPORT)
        return run, threads

    def test_the_import_does_what_the_serial_preview_said(self):
        preview = self.run_sync(self.source, DRY_RUN)
        run, threads = self._import_watching_threads()

        self.assertIn(run.status, (MigrationRun.Status.SUCCEEDED, MigrationRun.Status.PARTIAL))
        self.assertEqual(run.summary, preview.summary)
        self.assertEqual(_issues(run), _issues(preview))
        # It really did run on two workers, for the catalogue and the documents.
        for entity in ("product", "sale", "purchase_order"):
            workers = {name for name in threads if name.startswith(f"{entity}:migration-")}
            self.assertEqual(len(workers), 2, entity)

    def test_documents_are_numbered_without_a_gap_in_file_order(self):
        run, _threads = self._import_watching_threads()

        for model, field, letter in (
            (Order, "receipt_number", "R"),
            (PurchaseOrder, "order_number", "P"),
        ):
            numbers = list(model.objects.values_list(field, flat=True))
            self.assertFalse([n for n in numbers if n.startswith(PLACEHOLDER_PREFIX)])
            serial = sorted(int(number[-6:]) for number in numbers if number.startswith(letter))
            self.assertEqual(serial, list(range(serial[0], serial[0] + len(serial))), field)
        # File order: the earlier source invoice has the lower number.
        sale_keys = dict(
            MigrationIdentityMap.objects.filter(source=self.source, entity_type="sale")
            .values_list("source_key", "target_object_id")
        )
        numbered = {
            int(key): Order.objects.get(pk=pk).receipt_number for key, pk in sale_keys.items()
        }
        in_file_order = [numbered[key] for key in sorted(numbered)]
        self.assertEqual(in_file_order, sorted(in_file_order))
        self.assertEqual(run.summary["sale"]["created"], len(sale_keys))

    def test_no_code_ends_up_on_two_things(self):
        run, _threads = self._import_watching_threads()

        codes = Counter(
            list(ProductVariant.objects.exclude(barcode="").values_list("barcode", flat=True))
            + list(ProductVariantBarcode.objects.values_list("barcode", flat=True))
            + list(ProductUnitBarcode.objects.values_list("barcode", flat=True))
        )
        self.assertEqual([code for code, seen in codes.items() if seen > 1], [])
        # The duplicate EANs and the shared model number were reported, not raced.
        self.assertTrue(
            MigrationIssue.objects.filter(run=run, code="duplicate_code_in_file").exists()
        )
        # Every item still came across: the duplicates lost a code, not a product.
        self.assertEqual(run.summary["product"]["failed"], 0)

    def test_generated_skus_come_from_one_released_block(self):
        self._import_watching_threads()

        generated = sorted(
            int(sku)
            for sku in ProductVariant.objects.filter(sku__regex=r"^[0-9]{1,7}$").values_list(
                "sku", flat=True
            )
        )
        # Every item but the first that shares the model number lost it.
        self.assertEqual(len(generated), ITEMS // 10 - 1)
        self.assertEqual(generated, list(range(generated[0], generated[0] + len(generated))))
        self.assertFalse(SkuSeriesReservation.objects.exists())

    def test_one_stand_in_supplier_however_many_orders_need_it(self):
        self._import_watching_threads()

        self.assertEqual(Supplier.objects.filter(name=_FALLBACK_SUPPLIER_NAME).count(), 1)
