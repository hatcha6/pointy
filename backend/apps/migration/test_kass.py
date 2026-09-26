"""The KASS (Delphi/MySQL) connector, and the SQL-dump input format.

The fixture is a real ``.sql`` dump — Windows-1256 bytes, data-only, no
``CREATE TABLE``, exactly the shape the vendor's backup button produces — so
these run the whole path a shop's file takes: identify → convert → detect →
import. A SQLite fixture would skip the two stages most likely to be wrong.

Its numbers are a miniature of the field data, chosen so every decision the
connector makes has a consequence something here can measure:

* one walk-in cash sale, settled by a receipt that names its invoice
* one آجل sale to a named customer, settled later by a receipt on their account
* one sale to a named customer whose counter receipt was booked to the walk-in
  account — the case that decides whether the shop is owed the money
* parties carrying a balance from before the file's history begins — both
  ways round: customers and a supplier the shop owes, and a customer and a
  supplier who are owed by it
* a daily cash sweep, which must not be imported
"""

import tempfile
from datetime import date, datetime
from decimal import Decimal
from pathlib import Path

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.db import transaction
from django.test import TestCase, override_settings
from django.urls import reverse
from django.utils import timezone
from rest_framework import status
from rest_framework.test import APIClient

from apps.balances.models import (
    BalanceEntry,
    CustomerBalanceEntry,
    SupplierBalanceEntry,
)
from apps.balances.customers import create_customer_entry
from apps.catalog.models import Product, ProductCategory, ProductVariant
from apps.core.models import ShopSettings
from apps.core.roles import CASHIER_GROUP, ensure_role_groups
from apps.customers.models import Customer
from apps.customers.receivables import customer_balance, outstanding_balance
from apps.documents import services as documents
from apps.documents.models import DocumentNumberSeries
from apps.documents.numbering import PARTY_BALANCE_SERIES
from apps.documents.reconciliation import reconcile_lifecycles
from apps.documents.statuses import DocumentStatus
from apps.employees.models import CompensationPlan, Employee, PayrollRun
from apps.expenses.models import Expense
from apps.inventory.models import StockItem, StockLedgerEntry, StockValuationBin
from apps.payments.models import Payment
from apps.purchasing.models import PurchaseOrder, Supplier, SupplierCredit
from apps.sales.models import Order, OrderAdjustment, RegisterSession
from apps.treasury.models import MoneyAccount

from . import canonical, scopes, storage
from .connectors import get_connector
from .connectors.base import ExtractContext
from .entity_plan import CUSTOMER, PARTY_BALANCE, PRODUCT, SALE, SUPPLIER, VARIANT
from .identity import IdentityResolver
from .loaders.base import LoaderError
from .loaders.legacy_openings import OPENING_ITEM_KEY as LEGACY_OPENING_ITEM_KEY
from .loaders.legacy_openings import OPENING_ITEM_NAME as LEGACY_OPENING_ITEM_NAME
from .loaders.parties import IMPORT_NOTE, PartyBalanceLoader
from .loaders.purchasing import PurchaseOrderLoader
from .loaders.sales import PaymentLoader, SaleLoader
from .models import MigrationIssue, MigrationRun, MigrationSource
from .preparation import identify as identification
from .preparation import mysqldump, pipeline
from .transports import build_transport
from .tests import MigrationTestBase

IMPORT = MigrationRun.Mode.IMPORT
DRY_RUN = MigrationRun.Mode.DRY_RUN


def _dump() -> str:
    """A miniature KASS backup, in the vendor's own statement style."""
    rows = []

    def insert(table, columns, *tuples):
        rows.append(f"\n-- \n-- Dumping data for table `{table}`\n-- \n")
        rows.append(f"TRUNCATE TABLE `{table}`;")
        for values in tuples:
            rendered = ", ".join(_literal(value) for value in values)
            cols = ", ".join(f"`{column}`" for column in columns)
            rows.append(f"INSERT INTO `{table}`({cols}) VALUES ({rendered});")

    rows.append("-- UniDAC version: 9.3.0")
    rows.append("-- MySQL server version: 5.5.29")
    rows.append("-- Database: KASS2025")
    # The dump says utf8 and then hands over Windows-1256. Both are true of the
    # real file, and the second one is what counts.
    rows.append("/*!40101 SET NAMES utf8 */;")

    insert(
        "groups",
        ("GroupName", "GroupNo", "ShowinTakrirAam"),
        ("اكسسوارات", 1, 1),
    )
    insert(
        "company",
        ("CompanyName", "CompanyNo", "inTouch"),
        ("نقالات", 1, 0),
    )
    insert(
        "msrftype",
        ("MsrofName", "MsrofNo", "MsrofTypeNo", "MsroforAsl"),
        ("آجار", 1, None, 1),
    )
    insert(
        "bank",
        ("BaankName", "FirstRasid", "BankRasid", "Rasid", "BankNo", "BankTypeNo"),
        ("الخزينة الرئيسية", 0, 500, 0, 1, 1),
    )
    insert(
        "kamkrt",
        (
            "GroupNo", "SenfNo", "Barcode", "SenfDisc", "Unit", "Obowwa",
            "FirstPrice", "NawPrice", "LastPrice", "FirstRasid", "NawRasid",
            "PuyKetaey", "PuyJomla1", "PuyJomla2", "LessRasid", "CompanyNo",
            "ExpiryDate", "Used", "ShowInPanel",
        ),
        # NawPrice is the cost, PuyKetaey the selling price — the pair these
        # tests exist to keep the right way round.
        (1, 10, "1001", "لصقة", "قطعة", 1, 5, 5, 5, 0, 20, 15, 10, 0, 3, 1, None, 2, 1),
        (1, 11, "1002", "كابل شحن", "قطعة", 1, 12, 12, 12, 0, 3, 30, 0, 0, 0, 1, None, 2, 1),
        (1, 12, "1003", "سماعة", "قطعة", 1, 8, 8, 8, 0, 4, 20, 0, 0, 0, 1, None, 2, 1),
        # An item card the shop has not held since 2014 and never deleted. Every
        # catalogue of this age is full of them, and whether they come across is
        # a decision the owner gets to make (``only_stocked_products``).
        (1, 13, "1004", "شاحن قديم", "قطعة", 1, 6, 6, 6, 0, 0, 14, 0, 0, 0, 1, None, 2, 1),
    )
    insert(
        "amilkrt",
        (
            "AmilName", "AmilNo", "NawRasid", "FirstRasid", "PuyType", "Notes",
            "KassOrAam", "AmilPuy", "AmilSell", "CityNo", "Mobile", "Phone",
            "Emial", "MaxRasid", "EnteredDate", "HesabType",
        ),
        ("مبيعات نقدية", 1, 0, 0, 1, None, 1, 1, 1, 1, None, None, None, 0, "2025-01-01", 1),
        ("أحمد علي", 2, -70, -50, 1, None, 1, 1, 1, 1, "0910000000", None, None, 0, "2025-01-01", 1),
        ("شركة التوريد", 3, 130, 100, 1, None, 1, 1, 1, 1, None, None, None, 0, "2025-01-01", 1),
        # A balance and not one document: without an opening balance this
        # customer's debt disappears on import.
        ("سالم", 4, -40, -40, 1, None, 1, 1, 1, 1, None, None, None, 0, "2025-01-01", 1),
        ("خالد", 5, -60, 0, 1, None, 1, 1, 1, 1, None, None, None, 0, "2025-01-01", 1),
        # A customer the shop owes: 25 in credit from before the file, and a
        # purchase paid at the counter since. An invoice cannot carry that.
        ("منى", 6, 25, 25, 1, None, 1, 1, 1, 1, None, None, None, 0, "2025-01-01", 1),
        # A supplier who owed the shop 35 — an advance — and has since
        # delivered 20 of it.
        ("مؤسسة الأمل", 7, -15, -35, 1, None, 1, 1, 1, 1, None, None, None, 0, "2025-01-01", 1),
    )
    insert(
        "kamhrka",
        (
            "date1", "EthenNoParty", "EthenType", "pc", "EthenNo", "AmilNo",
            "SdadType", "AsnafTotal", "AsnafTotal1", "AsnafTaklofa", "Takfid",
            "Notes", "Locke", "EnteredDate", "UserNo",
        ),
        # Walk-in cash sale: 2 × 15.
        ("2026-02-02", "970000001", 7, 1, "sale-cash", 1, 2, 30, 30, 10, 0,
         None, 0, "2026-02-02 10:15:00", 16),
        # آجل sale to أحمد: 1 × 30, nothing taken at the counter.
        ("2026-02-03", "970000002", 7, 1, "sale-credit", 2, 1, 30, 30, 12, 0,
         None, 0, "2026-02-03 11:00:00", 16),
        # Flagged as settled-now, but its receipt was booked to the walk-in
        # account, so خالد's own ledger never saw it.
        ("2026-02-04", "970000003", 7, 1, "sale-crossparty", 5, 2, 60, 60, 16, 0,
         None, 0, "2026-02-04 12:00:00", 16),
        # Purchase from the supplier.
        ("2026-02-01", "910000001", 1, 1, "buy-1", 3, 1, 50, 50, 50, 0,
         None, 0, "2026-02-01 09:00:00", 16),
        # A blank purchase: opened and abandoned, worth nothing.
        ("2026-02-05", "910000002", 1, 1, "buy-empty", 1, 1, 0, 0, 0, 0,
         None, 0, "2026-02-05 09:00:00", 16),
        # Sales return against the walk-in cash sale: one لصقة back.
        ("2026-02-06", "930000001", 3, 1, "ret-1", 1, 2, 15, 15, 5, 0,
         None, 0, "2026-02-06 13:00:00", 16),
        # A return of something this file never recorded being sold — the sale
        # predates the backup. It must be reported, not quietly dropped.
        ("2026-02-07", "930000002", 3, 1, "ret-orphan", 1, 2, 20, 20, 8, 0,
         None, 0, "2026-02-07 13:00:00", 16),
        # A second walk-in sale, and a return of two against it when it sold
        # one: the surplus belongs to an invoice this file cannot name.
        ("2026-02-08", "970000004", 7, 1, "sale-cash2", 1, 2, 30, 30, 12, 0,
         None, 0, "2026-02-08 10:00:00", 16),
        ("2026-02-09", "930000003", 3, 1, "ret-clamp", 1, 2, 60, 60, 24, 0,
         None, 0, "2026-02-09 13:00:00", 16),
        # منى buys a لصقة and pays for it there and then.
        ("2026-02-05", "970000005", 7, 1, "sale-mona", 6, 2, 15, 15, 5, 0,
         None, 0, "2026-02-05 16:00:00", 16),
        # The advance being worked off: a delivery worth 20.
        ("2026-02-03", "910000003", 1, 1, "buy-2", 7, 1, 20, 20, 20, 0,
         None, 0, "2026-02-03 09:30:00", 16),
    )
    insert(
        "kammwad",
        (
            "EthenDate", "PC", "COUNTER", "EthenNo", "SenfNo", "EthenType",
            "Quilty", "Price", "PriceWithOut", "Taklofa", "Obowwa", "Notes",
            "EnteredDate", "UserNo", "BarCode", "GroupNo", "Unit",
        ),
        # ``Price`` is 0 on every line, exactly as the vendor writes it; the
        # money is in ``PriceWithOut``.
        ("2026-02-02", 1, 1, "sale-cash", 10, 7, 2, 0, 15, 5, 1, None,
         "2026-02-02 10:15:00", 16, "1001", 1, "قطعة"),
        ("2026-02-03", 1, 2, "sale-credit", 11, 7, 1, 0, 30, 12, 1, None,
         "2026-02-03 11:00:00", 16, "1002", 1, "قطعة"),
        ("2026-02-04", 1, 3, "sale-crossparty", 12, 7, 3, 0, 20, 8, 1, None,
         "2026-02-04 12:00:00", 16, "1003", 1, "قطعة"),
        ("2026-02-01", 1, 4, "buy-1", 10, 1, 10, 0, 5, 5, 1, None,
         "2026-02-01 09:00:00", 16, "1001", 1, "قطعة"),
        ("2026-02-06", 1, 5, "ret-1", 10, 3, 1, 0, 15, 5, 1, None,
         "2026-02-06 13:00:00", 16, "1001", 1, "قطعة"),
        # Item 12 at 20 was never sold to the walk-in account in this file.
        ("2026-02-07", 1, 6, "ret-orphan", 12, 3, 1, 0, 20, 8, 1, None,
         "2026-02-07 13:00:00", 16, "1003", 1, "قطعة"),
        ("2026-02-08", 1, 7, "sale-cash2", 11, 7, 1, 0, 30, 12, 1, None,
         "2026-02-08 10:00:00", 16, "1002", 1, "قطعة"),
        ("2026-02-09", 1, 8, "ret-clamp", 11, 3, 2, 0, 30, 12, 1, None,
         "2026-02-09 13:00:00", 16, "1002", 1, "قطعة"),
        ("2026-02-05", 1, 9, "sale-mona", 10, 7, 1, 0, 15, 5, 1, None,
         "2026-02-05 16:00:00", 16, "1001", 1, "قطعة"),
        ("2026-02-03", 1, 10, "buy-2", 12, 1, 2, 0, 10, 10, 1, None,
         "2026-02-03 09:30:00", 16, "1003", 1, "قطعة"),
    )
    insert(
        "edaahrka",
        (
            "SrfOREstlam", "SrfEthenNo", "AmilNo", "Date1", "Price",
            "MoaamlaType", "BankNo", "Notes", "EKey", "FatoraNo", "Locke",
            "EnteredDate", "UserNo", "MasrofNo",
        ),
        # The cash box's opening balance.
        (31, "1", 0, "2026-01-31", 500, 2, 1, "بسم الله ... رصيد أول المدة",
         "k-open", None, 0, "2026-01-31 08:00:00", 16, -1),
        # The walk-in sale's own counter receipt.
        (21, "2", 1, "2026-02-02", 30, 1, None, None, "k-1", "970000001", 0,
         "2026-02-02 10:15:00", 16, -1),
        # خالد's sale, receipted against the walk-in account instead of his.
        (21, "3", 1, "2026-02-04", 60, 1, None, None, "k-2", "970000003", 0,
         "2026-02-04 12:00:00", 16, -1),
        # أحمد pays 10 off his account, naming no invoice.
        (21, "4", 2, "2026-02-10", 10, 1, None, "دفعة", "k-3", None, 0,
         "2026-02-10 09:00:00", 16, -1),
        # Paying the supplier.
        (22, "5", 3, "2026-02-11", 20, 2, 1, None, "k-4", None, 0,
         "2026-02-11 09:00:00", 16, -1),
        # The refund handed back on the return.
        (22, "6", 1, "2026-02-06", 15, 1, None, None, "k-5", "930000001", 0,
         "2026-02-06 13:00:00", 16, -1),
        # Rent.
        (33, "7", 0, "2026-02-12", 25, 2, 1, "شهر 2", "k-6", None, 0,
         "2026-02-12 09:00:00", 16, 1),
        # The daily cash sweep — the same dinars as the day's sales.
        (29, "8", 0, "2026-02-02", 30, 2, 1, None, "k-7", None, 0,
         "2026-02-02 21:00:00", 16, -1),
        # منى's counter receipt, on her own account and naming her invoice.
        (21, "9", 6, "2026-02-05", 15, 1, None, None, "k-8", "970000005", 0,
         "2026-02-05 16:00:00", 16, -1),
    )
    insert(
        "aamldata",
        (
            "AamlName", "AamlNo", "Nation", "StartDate", "Mortb", "Rasid",
            "AmilNo", "HourPrice", "SaaatAlaml", "FirstRasid", "Mobile",
        ),
        ("منير", 1, "ليبي", "2025-06-01", 800, 0, None, 0, 8, 0, "0911111111"),
    )
    insert(
        "mortbat",
        (
            "AamlNo", "HrkaType", "HrkaDate", "HrkaMonth", "HrkaYear", "Mortab",
            "Edafi", "Other", "Kiab", "Other1", "Notes", "Kima", "Safii",
            "EthenType", "Locke",
        ),
        (1, 1, "2026-02-01", 1, 2026, 800, 0, 0, 0, 0, None, 0, 800, None, 0),
        # The same employee accrued twice in one month, which happens.
        (1, 1, "2026-02-01", 1, 2026, 200, 0, 0, 0, 0, None, 0, 200, None, 0),
        # ``HrkaType = 2`` is money handed over, not salary earned: its amount
        # is in ``Kima`` and its salary columns are zero.
        (1, 2, "2026-02-16", 1, 2026, 0, 0, 0, 0, 0, None, 1000, 0, None, 0),
    )
    # A table the backup truncates and never fills: its columns are unknowable,
    # and the converter must say so rather than invent them.
    rows.append("\nTRUNCATE TABLE `aamlsaaat`;")
    return "\r\n".join(rows) + "\r\n"


def _literal(value) -> str:
    if value is None:
        return "NULL"
    if isinstance(value, str):
        return "'" + value.replace("\\", "\\\\").replace("'", "\\'") + "'"
    return str(value)


#: Where every opening in the fixture is dated: the day before the cash box
#: opened, which is the first thing in the file.
OPENED_AT = date(2026, 1, 30)


def _entry_numbers() -> dict:
    """Every balance entry, by number, with whether it is still live."""
    return {
        entry.number: entry.doc_status
        for model in (CustomerBalanceEntry, SupplierBalanceEntry)
        for entry in model.objects.all()
    }


def _balance_numbers_issued() -> int:
    series = DocumentNumberSeries.objects.filter(pk=PARTY_BALANCE_SERIES).first()
    return series.last_value if series else 0


class KassTestBase(MigrationTestBase):
    """Puts a real ``.sql`` dump through the whole preparation pipeline."""

    def setUp(self):
        super().setUp()
        self.dump_path = Path(self._tmpdir.name) / "backup.sql"
        self.dump_path.write_bytes(_dump().encode("cp1256"))

    def prepared_source(self):
        source = MigrationSource.objects.create(
            name="النسيم",
            original_filename="backup.sql",
            upload_state=MigrationSource.UploadState.UPLOADED,
        )
        source.staged_filename = storage.staged_name(source.pk, "mysqldump")
        source.save(update_fields=["staged_filename"])
        storage.adopt(self.dump_path, self.staging / source.staged_filename)
        pipeline.prepare_source(source)
        source.refresh_from_db()
        return source

    def extract(self, entity_type, *, scope=None, basis=None):
        """Extract one entity, optionally under a stated run scope.

        ``scope``/``basis`` exist because some records only have a meaning
        relative to the rest of the run — a party's balance most of all. The
        default (no scope) is what the engine hands a full import.
        """
        source = getattr(self, "_source", None)
        if source is None:
            source = self._source = self.prepared_source()
        connector = get_connector("kass")
        transport = build_transport(
            "sqlite", {"database": str(storage.prepared_path(source))}
        )
        if scope is None and basis is None:
            ctx = getattr(self, "_ctx", None)
            if ctx is None:
                ctx = self._ctx = ExtractContext()
        else:
            ctx = ExtractContext(
                selected_entities=frozenset(scope or ()),
                party_balance_basis=basis or "opening",
            )
        with transport:
            return list(connector.extract(entity_type, transport, ctx))


class DumpConversionTests(TestCase):
    """The SQL-dump reader, on its own."""

    def setUp(self):
        self._tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmpdir.cleanup)
        self.root = Path(self._tmpdir.name)

    def test_a_dump_is_identified_from_its_text(self):
        path = self.root / "backup.sql"
        path.write_bytes(_dump().encode("cp1256"))
        self.assertEqual(identification.identify(path), identification.MYSQLDUMP)

    def test_a_database_is_still_read_as_a_database(self):
        """A binary file whose bytes spell SQL is not a dump."""
        path = self.root / "db.sqlite"
        path.write_bytes(b"SQLite format 3\x00" + b"INSERT INTO x" + b"\x00" * 64)
        self.assertEqual(identification.identify(path), identification.SQLITE)

    def test_the_declared_encoding_does_not_decide(self):
        """The header says utf8; the bytes are Windows-1256, and win."""
        path = self.root / "backup.sql"
        path.write_bytes(_dump().encode("cp1256"))
        encoding, declared = mysqldump.detect_encoding(path)
        self.assertEqual(declared, "utf8")
        self.assertEqual(encoding, "cp1256")

    def test_a_utf8_dump_is_read_as_utf8(self):
        path = self.root / "backup.sql"
        path.write_bytes(_dump().encode("utf-8"))
        encoding, _declared = mysqldump.detect_encoding(path)
        self.assertEqual(encoding, "utf-8")

    def test_arabic_survives_the_conversion(self):
        path = self.root / "backup.sql"
        path.write_bytes(_dump().encode("cp1256"))
        destination = self.root / "out.sqlite"
        stats = mysqldump.convert(path, destination)
        self.assertEqual(stats["encoding"], "cp1256")
        transport = build_transport("sqlite", {"database": str(destination)})
        with transport:
            names = {
                row["SenfDisc"] for row in transport.iter_records("kamkrt", fields=["SenfDisc"])
            }
        self.assertIn("لصقة", names)
        self.assertIn("كابل شحن", names)

    def test_money_keeps_its_exact_value(self):
        """Stored as text, so a balance is never handed to a float."""
        path = self.root / "backup.sql"
        path.write_bytes(
            "INSERT INTO `t`(`a`) VALUES ('x');\n"
            "INSERT INTO `amilkrt`(`AmilNo`, `NawRasid`) VALUES (1,1258.175);\n".encode("cp1256")
        )
        destination = self.root / "out.sqlite"
        mysqldump.convert(path, destination)
        transport = build_transport("sqlite", {"database": str(destination)})
        with transport:
            rows = list(transport.iter_records("amilkrt"))
        self.assertEqual(Decimal(str(rows[0]["NawRasid"])), Decimal("1258.175"))

    def test_quotes_semicolons_and_newlines_inside_text(self):
        """Statement splitting tracks quotes; a note containing ``;`` is one row."""
        path = self.root / "backup.sql"
        path.write_bytes(
            (
                "INSERT INTO `n`(`a`, `b`) VALUES ('a;b', 'line1\\nline2');\n"
                "INSERT INTO `n`(`a`, `b`) VALUES ('it\\'s', 'quote''d');\n"
                "-- a comment with a ; in it\n"
                "/*!40101 SET NAMES utf8 */;\n"
            ).encode("cp1256")
        )
        destination = self.root / "out.sqlite"
        mysqldump.convert(path, destination)
        transport = build_transport("sqlite", {"database": str(destination)})
        with transport:
            rows = list(transport.iter_records("n"))
        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[0]["a"], "a;b")
        self.assertEqual(rows[0]["b"], "line1\nline2")
        self.assertEqual(rows[1]["a"], "it's")
        self.assertEqual(rows[1]["b"], "quote'd")

    def test_multi_row_inserts_and_a_create_table(self):
        path = self.root / "backup.sql"
        path.write_bytes(
            (
                "CREATE TABLE `t` (\n"
                "  `id` int(11) NOT NULL,\n"
                "  `name` varchar(50) DEFAULT NULL,\n"
                "  PRIMARY KEY (`id`),\n"
                "  KEY `ix` (`name`)\n"
                ") ENGINE=MyISAM;\n"
                "INSERT INTO `t` VALUES (1,'a'),(2,'b'),(3,NULL);\n"
            ).encode("cp1256")
        )
        destination = self.root / "out.sqlite"
        stats = mysqldump.convert(path, destination)
        self.assertEqual(stats["rows"], 3)
        transport = build_transport("sqlite", {"database": str(destination)})
        with transport:
            self.assertEqual(
                [column.name for column in transport.describe_table("t").columns],
                ["id", "name"],
            )
            rows = list(transport.iter_records("t"))
        self.assertEqual(rows[2]["name"], None)

    def test_a_table_with_no_rows_is_reported_not_invented(self):
        path = self.root / "backup.sql"
        path.write_bytes(_dump().encode("cp1256"))
        destination = self.root / "out.sqlite"
        stats = mysqldump.convert(path, destination)
        self.assertIn("aamlsaaat", stats["empty_tables"])
        transport = build_transport("sqlite", {"database": str(destination)})
        with transport:
            self.assertNotIn("aamlsaaat", set(transport.list_tables()))

    def test_a_file_with_no_tables_is_refused(self):
        path = self.root / "notes.sql"
        path.write_bytes(b"-- just a comment\nSET NAMES utf8;\n")
        with self.assertRaises(mysqldump.DumpConversionError):
            mysqldump.convert(path, self.root / "out.sqlite")


class KassDetectionTests(KassTestBase):
    def test_the_pipeline_recognises_a_kass_backup(self):
        source = self.prepared_source()
        self.assertEqual(source.upload_state, MigrationSource.UploadState.READY)
        self.assertEqual(source.system_key, "kass")
        self.assertEqual(source.detected_version, "kass-delphi-mysql")
        # The raw upload is the big file and is dropped once converted.
        self.assertEqual(source.staged_filename, "")
        self.assertTrue(storage.prepared_path(source).exists())

    def test_the_owner_is_told_what_is_inside(self):
        source = self.prepared_source()
        entities = source.analysis["entities"]
        self.assertEqual(entities["product"]["count"], 4)
        self.assertEqual(entities["customer"]["count"], 7)
        self.assertEqual(source.analysis["conversion"]["encoding"], "cp1256")


class KassCatalogueTests(KassTestBase):
    def test_the_selling_price_is_puyketaey_and_the_cost_is_nawprice(self):
        """The pair that reads backwards. ``Puy`` is not the purchase price."""
        products = {record.name: record for record in self.extract("product")}
        self.assertEqual(products["لصقة"].unit_price, Decimal("15"))
        stock = {record.source_key: record for record in self.extract("stock")}
        self.assertEqual(stock["item:10"].unit_cost, Decimal("5"))
        self.assertEqual(stock["item:10"].quantity_on_hand, Decimal("20"))

    def test_both_classification_axes_become_categories(self):
        categories = {record.source_key: record.name for record in self.extract("category")}
        self.assertEqual(categories["group:1"], "اكسسوارات")
        self.assertEqual(categories["company:1"], "نقالات")

    def test_the_item_code_is_carried_as_the_barcode(self):
        products = {record.name: record for record in self.extract("product")}
        self.assertEqual(products["لصقة"].barcode, "1001")
        self.assertEqual(products["لصقة"].sku, "1001")

    def test_the_catalogue_is_only_the_item_cards(self):
        """No placeholder item to hang balances on: they are entries now."""
        names = [record.name for record in self.extract("product")]
        self.assertEqual(len(names), 4)
        self.assertNotIn(LEGACY_OPENING_ITEM_NAME, names)


class KassSalesTests(KassTestBase):
    def test_the_line_price_comes_from_pricewithout(self):
        """``Price`` is zero on every line in the source; reading it imports a
        shop's entire history at nothing, and nothing errors."""
        sales = {record.source_key: record for record in self.extract("sale")}
        line = sales["sale-cash"].lines[0]
        self.assertEqual(line.unit_price, Decimal("15"))
        self.assertEqual(line.unit_cost, Decimal("5"))
        self.assertEqual(line.quantity, Decimal("2"))

    def test_a_walk_in_sale_has_no_customer_and_is_paid(self):
        sales = {record.source_key: record for record in self.extract("sale")}
        cash = sales["sale-cash"]
        self.assertIsNone(cash.customer_source_key)
        self.assertEqual(cash.sale_type, "standard")
        self.assertIsNone(cash.amount_paid)

    def test_an_aajil_sale_is_credit_and_unpaid(self):
        sales = {record.source_key: record for record in self.extract("sale")}
        credit = sales["sale-credit"]
        self.assertEqual(credit.customer_source_key, "party:2")
        self.assertEqual(credit.sale_type, "credit")
        self.assertEqual(credit.amount_paid, Decimal("0"))

    def test_a_receipt_booked_to_another_account_does_not_settle_the_sale(self):
        """The case that decides whether the shop is owed 60 dinars.

        The invoice is flagged settled-now, but its receipt credits the walk-in
        account. From the customer's own ledger nothing was paid — which is
        what the source's stored balance for them says too.
        """
        sales = {record.source_key: record for record in self.extract("sale")}
        cross = sales["sale-crossparty"]
        self.assertEqual(cross.customer_source_key, "party:5")
        self.assertEqual(cross.sale_type, "credit")
        self.assertEqual(cross.amount_paid, Decimal("0"))

    def test_the_source_invoice_number_is_kept(self):
        sales = {record.source_key: record for record in self.extract("sale")}
        self.assertEqual(sales["sale-cash"].receipt_number, "970000001")

    def test_the_business_date_wins_over_the_entry_clock(self):
        sales = {record.source_key: record for record in self.extract("sale")}
        occurred = sales["sale-cash"].occurred_at
        self.assertEqual(occurred.date().isoformat(), "2026-02-02")
        self.assertEqual(occurred.hour, 10)

    def test_customers_who_only_have_a_balance_get_an_opening_balance(self):
        balances = {
            record.source_key: record
            for record in self.extract("party_balance")
            if record.party_kind == "customer"
        }
        opening = balances["opening:party:4"]
        self.assertEqual(opening.amount, Decimal("40.00"))
        # Dated before the history, not on the day of the import.
        self.assertLess(opening.as_of.date().isoformat(), "2026-02-01")

    def test_a_customer_the_shop_owes_comes_across_as_credit(self):
        """KASS's sign says the shop owes منى 25. The record reads it from the
        customer's side, where owing the shop is positive — so it is negative,
        and not dropped, which is what the invoice-based design had to do."""
        balances = {
            record.source_key: record
            for record in self.extract("party_balance")
            if record.party_kind == "customer"
        }
        self.assertEqual(balances["opening:party:6"].amount, Decimal("-25.00"))

    def test_openings_never_ride_the_sale_stream(self):
        """Whatever the scope. An opening debt is not a sale, and emitting it as
        one put every inherited debt into the import day's revenue."""
        for scope in (None, (SALE, CUSTOMER)):
            openings = [
                record
                for record in self.extract("sale", scope=scope)
                if record.source_key.startswith("opening:")
            ]
            self.assertEqual(openings, [], msg=f"scope={scope}")

    def test_only_the_kinds_of_party_in_the_run_get_a_balance(self):
        """A run with the sales history and no suppliers still opens its
        customers (``scopes.with_party_balances``), and writes nothing for a
        supplier it has nowhere to put."""
        kinds = {
            record.party_kind
            for record in self.extract(
                "party_balance", scope=(SALE, CUSTOMER, PARTY_BALANCE)
            )
        }
        self.assertEqual(kinds, {"customer"})

    def test_a_return_is_matched_to_the_sale_it_came_off(self):
        matched = {
            record.sale_source_key: record
            for record in self.extract("sale_return")
            if record.sale_source_key
        }
        self.assertEqual(set(matched), {"sale-cash", "sale-cash2"})
        self.assertEqual(matched["sale-cash"].lines[0].quantity, Decimal("1"))

    def test_a_return_with_no_sale_to_come_off_is_still_reported(self):
        """Dropping it would lose the goods and the refund with nothing said."""
        orphans = [
            record
            for record in self.extract("sale_return")
            if not record.sale_source_key
        ]
        self.assertEqual(len(orphans), 1)
        self.assertEqual(orphans[0].lines[0].unit_price, Decimal("20"))


class KassMoneyTests(KassTestBase):
    def test_a_sale_receipt_is_not_imported_again_as_an_account_payment(self):
        """Every cash sale writes a receipt; importing both pays it twice."""
        payments = self.extract("payment")
        self.assertEqual(len(payments), 1)
        self.assertEqual(payments[0].customer_source_key, "party:2")
        self.assertEqual(payments[0].amount, Decimal("10"))

    def test_the_refund_on_a_return_is_not_a_supplier_payment(self):
        payments = self.extract("supplier_payment")
        self.assertEqual([record.amount for record in payments], [Decimal("20")])
        self.assertEqual(payments[0].supplier_source_key, "party:3")

    def test_the_cash_box_opens_at_the_sources_own_figure(self):
        accounts = self.extract("money_account")
        self.assertEqual(len(accounts), 1)
        self.assertEqual(accounts[0].opening_balance, Decimal("500.00"))
        self.assertEqual(accounts[0].opening_at.isoformat(), "2026-01-31")

    def test_the_daily_cash_sweep_is_not_imported(self):
        """Those dinars are the day's sales, which the money position already
        counts; posting the sweep too would state the shop's cash twice."""
        accounts = self.extract("money_account")
        # 500 is the opening entry alone — the 30 sweep is not added to it.
        self.assertEqual(accounts[0].opening_balance, Decimal("500.00"))

    def test_expenses_carry_their_category(self):
        expenses = self.extract("expense")
        self.assertEqual(len(expenses), 1)
        self.assertEqual(expenses[0].category_name, "آجار")
        self.assertEqual(expenses[0].amount, Decimal("25"))

    def test_a_blank_purchase_document_is_skipped(self):
        orders = {record.source_key: record for record in self.extract("purchase_order")}
        self.assertNotIn("buy-empty", orders)
        self.assertIn("buy-1", orders)

    def test_suppliers_owed_from_before_get_an_opening_balance(self):
        balances = {
            record.source_key: record
            for record in self.extract("party_balance")
            if record.party_kind == "supplier"
        }
        self.assertEqual(balances["opening:party:3"].amount, Decimal("100.00"))

    def test_a_supplier_who_owes_the_shop_comes_across_as_credit(self):
        balances = {
            record.source_key: record
            for record in self.extract("party_balance")
            if record.party_kind == "supplier"
        }
        self.assertEqual(balances["opening:party:7"].amount, Decimal("-35.00"))


class KassPeopleTests(KassTestBase):
    def test_an_employee_carries_their_salary(self):
        employees = self.extract("employee")
        self.assertEqual(len(employees), 1)
        self.assertEqual(employees[0].full_name, "منير")
        self.assertEqual(employees[0].pay_amount, Decimal("800"))

    def test_payroll_is_filed_under_the_month_it_pays(self):
        runs = self.extract("payroll_run")
        self.assertEqual(len(runs), 1)
        self.assertEqual(runs[0].period_start.isoformat(), "2026-01-01")
        self.assertEqual(runs[0].period_end.isoformat(), "2026-01-31")

    def test_one_employee_accrued_twice_in_a_month_is_one_line(self):
        """Pointy allows an employee one line per run; the source does not.

        Summed rather than picked between — 800 and 200 in the same month is
        1,000 earned, and a payment row (``HrkaType = 2``) is not salary at all.
        """
        runs = self.extract("payroll_run")
        self.assertEqual(len(runs[0].lines), 1)
        self.assertEqual(runs[0].lines[0].net_amount, Decimal("1000"))


@override_settings(CELERY_TASK_ALWAYS_EAGER=True)
class KassImportTests(KassTestBase):
    """The whole thing, written into the database."""

    def setUp(self):
        super().setUp()
        self.source = self.prepared_source()
        # keep_file: a clean import deletes the uploaded database, and the
        # re-run test below needs it to still be there.
        self.run = self.run_sync(self.source, IMPORT, options={"keep_file": True})

    def test_the_run_reports_the_one_thing_it_could_not_place(self):
        """Everything lands except the orphan return, which is a warning — the
        run is honest about it rather than silently short."""
        self.assertEqual(
            self.run.status,
            MigrationRun.Status.SUCCEEDED,
            msg=f"{self.run.error_message} {self.run.summary}",
        )
        codes = set(
            MigrationIssue.objects.filter(run=self.run).values_list("code", flat=True)
        )
        self.assertIn("return_without_sale", codes)

    def test_the_catalogue_lands(self):
        self.assertCreated(Product, 4)
        self.assertCreated(ProductVariant, 4)
        self.assertCreated(ProductCategory, 2)

    def test_stock_arrives_with_a_cost_behind_it(self):
        """Quantity without cost books the whole selling price as profit."""
        variant = ProductVariant.objects.get(barcode="1001")
        self.assertEqual(
            StockItem.objects.get(variant=variant).quantity_on_hand, Decimal("20.000")
        )
        bin_ = StockValuationBin.objects.get(variant=variant)
        self.assertEqual(bin_.valuation_rate, Decimal("5.000000"))
        self.assertEqual(bin_.stock_value, Decimal("100.000000"))
        entry = StockLedgerEntry.objects.get(
            variant=variant, voucher_type=StockLedgerEntry.VoucherType.OPENING
        )
        self.assertEqual(entry.balance_value, Decimal("100.000000"))

    def test_the_walk_in_account_is_not_a_customer(self):
        names = set(Customer.objects.values_list("full_name", flat=True))
        self.assertNotIn("مبيعات نقدية", names)
        self.assertIn("أحمد علي", names)

    def test_a_cash_sale_is_paid_and_keeps_its_number(self):
        order = Order.objects.get(receipt_number="970000001")
        self.assertEqual(order.status, Order.Status.PAID)
        self.assertEqual(order.sale_type, Order.SaleType.STANDARD)
        self.assertIsNone(order.customer_id)
        self.assertEqual(order.total, Decimal("30.00"))

    def test_an_aajil_sale_is_an_open_debt(self):
        order = Order.objects.get(receipt_number="970000002")
        self.assertEqual(order.status, Order.Status.OPEN)
        self.assertEqual(order.sale_type, Order.SaleType.CREDIT)
        self.assertEqual(order.balance_due, Decimal("30.00"))

    def test_an_aajil_sale_is_issued_while_it_is_still_owed(self):
        """Issued the day the old system wrote it, not left a draft until it is
        paid in full. A draft's payments cannot be cancelled, and its last
        collection has to submit it into that backdated month, which a closed
        period refuses."""
        for number, written in (("970000002", "2026-02-03"), ("970000003", "2026-02-04")):
            with self.subTest(number):
                order = Order.objects.get(receipt_number=number)
                self.assertEqual(order.status, Order.Status.OPEN)
                self.assertEqual(order.doc_status, DocumentStatus.SUBMITTED)
                self.assertEqual(order.submitted_at, order.created_at)
                self.assertEqual(
                    timezone.localtime(order.submitted_at).date().isoformat(), written
                )
        # Nothing else is left half-issued either, the opening-balance invoices
        # included.
        self.assertFalse(Order.objects.filter(doc_status=DocumentStatus.DRAFT).exists())

    def test_a_receipt_that_squares_an_aajil_sale_leaves_it_paid_and_issued(self):
        """``PaymentLoader._settle`` closes an invoice with a bare status write,
        which is whole only because the invoice was issued on import. Closed as
        a draft, it was a paid sale whose void would give nothing back."""
        resolver = IdentityResolver(self.source, self.run, dry_run=False)
        PaymentLoader().load(
            canonical.CanonicalPayment(
                source_key="k-settle", sale_source_key="sale-credit", amount=Decimal("30")
            ),
            resolver,
            dry_run=False,
        )
        order = Order.objects.get(receipt_number="970000002")
        self.assertEqual(order.status, Order.Status.PAID)
        self.assertEqual(order.doc_status, DocumentStatus.SUBMITTED)

    def test_a_draft_an_older_import_left_is_issued_on_upgrade(self):
        """And its balance can then be collected though its month is closed.
        Left a draft, the last collection had to submit it dated to that month,
        which a cashier cannot override, so the whole collection rolled back."""
        order = Order.objects.get(receipt_number="970000003")
        customer = order.customer
        # What the older importer left behind.
        Order.objects.filter(pk=order.pk).update(
            doc_status=DocumentStatus.DRAFT, submitted_at=None
        )
        settings_row = ShopSettings.load()
        settings_row.books_locked_through = timezone.localtime(order.created_at).date()
        settings_row.save(update_fields=["books_locked_through"])
        cashier = self.cashier_at_the_till()

        def collect_the_rest():
            # خالد owes this invoice and nothing else.
            return cashier.post(
                reverse("customer-record-payment", args=[customer.pk]),
                {"method": "cash", "amount": "60.00"},
                format="json",
            )

        self.assertEqual(collect_the_rest().status_code, status.HTTP_403_FORBIDDEN)
        self.assertEqual(outstanding_balance(customer), Decimal("60.00"))

        reconcile_lifecycles()

        order.refresh_from_db()
        self.assertEqual(order.doc_status, DocumentStatus.SUBMITTED)
        self.assertEqual(order.submitted_at, order.created_at)
        self.assertEqual(reconcile_lifecycles(), 0)
        collected = collect_the_rest()
        self.assertEqual(collected.status_code, status.HTTP_200_OK, collected.data)
        order.refresh_from_db()
        self.assertEqual(order.status, Order.Status.PAID)
        self.assertEqual(outstanding_balance(customer), Decimal("0.00"))

    def cashier_at_the_till(self):
        """A cashier with a drawer open, and no power to override a closed
        period."""
        ensure_role_groups()
        user = get_user_model().objects.create_user(username="kass-cashier", password="pass")
        user.groups.add(Group.objects.get(name=CASHIER_GROUP))
        RegisterSession.objects.create(
            owner=user, owner_key=f"user:{user.pk}", status=RegisterSession.Status.OPEN
        )
        client = APIClient()
        client.force_authenticate(user=user)
        return client

    def test_what_each_customer_owes_matches_the_old_system(self):
        """The number the shop will be looking for on day one.

        ``amilkrt.NawRasid`` is the old system's own stored balance; a negative
        one is money owed to the shop. Every one of these has to come out of a
        different part of the import — an opening document, an آجل invoice, an
        account receipt, a cross-party receipt — and they all have to agree.
        """
        expected = {
            "أحمد علي": Decimal("70.00"),  # 50 opening + 30 invoice − 10 paid
            "شركة التوريد": Decimal("0.00"),  # a supplier; owes the shop nothing
            "سالم": Decimal("40.00"),  # balance only, no invoices at all
            "خالد": Decimal("60.00"),  # the receipt that went to the wrong account
        }
        for name, owed in expected.items():
            customer = Customer.objects.filter(full_name=name).first()
            actual = outstanding_balance(customer) if customer else Decimal("0.00")
            self.assertEqual(actual, owed, msg=f"{name} owes {actual}, expected {owed}")

    def test_what_the_shop_owes_a_customer_matches_the_old_system(self):
        """منى's 25 in credit is the shop's debt to her, and her paid purchase
        does not touch it."""
        balance = customer_balance(Customer.objects.get(full_name="منى"))
        self.assertEqual(balance.owed_to_customer, Decimal("25.00"))
        self.assertEqual(balance.owed_by_customer, Decimal("0.00"))

    def test_what_the_shop_owes_its_supplier_matches_the_old_system(self):
        supplier = Supplier.objects.get(name="شركة التوريد")
        # 100 opening + 50 order − 20 paid = 130, the supplier's stored balance.
        self.assertEqual(supplier.payable_balance, Decimal("130.00"))

    def test_what_a_supplier_owes_the_shop_matches_the_old_system(self):
        supplier = Supplier.objects.get(name="مؤسسة الأمل")
        # Owed 35 before the file; a delivery of 20 since leaves 15 owed.
        self.assertEqual(supplier.payable_balance, Decimal("20.00"))
        self.assertEqual(supplier.credit_balance, Decimal("35.00"))
        self.assertEqual(supplier.net_balance, Decimal("-15.00"))

    def test_each_opening_is_a_balance_entry(self):
        """Five parties opened before the file, each as an entry on their
        account, on the side the balance runs."""
        customers = {
            entry.customer.full_name: (entry.direction, entry.amount)
            for entry in CustomerBalanceEntry.objects.live().select_related("customer")
        }
        self.assertEqual(
            customers,
            {
                "أحمد علي": (BalanceEntry.Direction.THEY_OWE_US, Decimal("50.00")),
                "سالم": (BalanceEntry.Direction.THEY_OWE_US, Decimal("40.00")),
                "منى": (BalanceEntry.Direction.WE_OWE_THEM, Decimal("25.00")),
            },
        )
        suppliers = {
            entry.supplier.name: (entry.direction, entry.amount)
            for entry in SupplierBalanceEntry.objects.live().select_related("supplier")
        }
        self.assertEqual(
            suppliers,
            {
                "شركة التوريد": (BalanceEntry.Direction.WE_OWE_THEM, Decimal("100.00")),
                "مؤسسة الأمل": (BalanceEntry.Direction.THEY_OWE_US, Decimal("35.00")),
            },
        )
        entries = [*CustomerBalanceEntry.objects.all(), *SupplierBalanceEntry.objects.all()]
        for entry in entries:
            self.assertEqual(entry.kind, BalanceEntry.Kind.OPENING)
            # The day before the cash box opened, the first thing in the file.
            self.assertEqual(entry.effective_date, OPENED_AT)
            self.assertEqual(entry.note, IMPORT_NOTE)

    def test_an_inherited_debt_is_not_revenue(self):
        """The bug this design exists to fix: the old opening invoices were
        آجل sales, so every inherited debt was the import day's revenue."""
        sold = set(
            Order.objects.committed_sales().values_list("receipt_number", flat=True)
        )
        self.assertEqual(
            sold, {"970000001", "970000002", "970000003", "970000004", "970000005"}
        )
        carriers = Order.objects.filter(sale_type=Order.SaleType.ACCOUNT_ENTRY)
        self.assertEqual(carriers.count(), 2)  # أحمد's and سالم's debts
        self.assertFalse(Order.objects.transactional().filter(pk__in=carriers).exists())
        self.assertFalse(Product.objects.filter(name=LEGACY_OPENING_ITEM_NAME).exists())

    def test_an_inherited_debt_is_not_a_purchase(self):
        bought = set(PurchaseOrder.objects.values_list("supplier_invoice_number", flat=True))
        self.assertEqual(bought, {"910000001", "910000003"})

    def test_the_account_receipt_settles_the_opening_debt_first(self):
        """أحمد paid 10 on account, naming no invoice. Oldest first, which is
        what a shop means by "the account", puts it on what he owed before any
        invoice in this file — and the history only adds up if it can."""
        carrier = CustomerBalanceEntry.objects.get(customer__full_name="أحمد علي").order
        self.assertEqual(carrier.balance_due, Decimal("40.00"))
        invoice = Order.objects.get(receipt_number="970000002")
        self.assertEqual(invoice.balance_due, Decimal("30.00"))

    def test_the_return_comes_off_the_sale_it_belonged_to(self):
        order = Order.objects.get(receipt_number="970000001")
        adjustment = OrderAdjustment.objects.get(order=order)
        self.assertEqual(adjustment.adjustment_type, OrderAdjustment.AdjustmentType.RETURN)
        self.assertEqual(adjustment.amount, Decimal("15.00"))
        # Written as a negative payment, the way a live refund is.
        self.assertEqual(order.payments.filter(amount__lt=0).count(), 1)

    def test_the_refund_is_dated_with_its_return(self):
        """Not with the day of the import. A report as of any day in between
        saw the goods come back and not the money go out, and read the
        customer as owing their own refund."""
        order = Order.objects.get(receipt_number="970000001")
        adjustment = OrderAdjustment.objects.get(order=order)
        refund = order.payments.get(amount__lt=0)
        self.assertEqual(refund.paid_at, adjustment.created_at)
        self.assertEqual(refund.paid_at.year, 2026)
        self.assertEqual((refund.paid_at.month, refund.paid_at.day), (2, 6))

    def test_a_return_bigger_than_its_invoice_is_capped_and_reported(self):
        """Crediting two against an invoice that sold one would refund money
        that invoice never took."""
        order = Order.objects.get(receipt_number="970000004")
        adjustment = OrderAdjustment.objects.get(order=order)
        self.assertEqual(adjustment.amount, Decimal("30.00"))
        codes = set(
            MigrationIssue.objects.filter(run=self.run).values_list("code", flat=True)
        )
        self.assertIn("return_exceeds_invoice", codes)

    def test_the_return_does_not_move_stock_a_second_time(self):
        """On-hand came from the source's closing figure, which already has the
        returned goods back on the shelf."""
        variant = ProductVariant.objects.get(barcode="1001")
        self.assertEqual(
            StockItem.objects.get(variant=variant).quantity_on_hand, Decimal("20.000")
        )

    def test_the_cash_box_is_open_for_business(self):
        account = MoneyAccount.objects.get(kind=MoneyAccount.Kind.CASH, name="الخزينة الرئيسية")
        self.assertEqual(account.opening_balance, Decimal("500.00"))

    def test_expenses_and_payroll_land(self):
        self.assertEqual(Expense.objects.filter(amount=Decimal("25.00")).count(), 1)
        employee = Employee.objects.get(full_name="منير")
        self.assertEqual(
            CompensationPlan.objects.get(employee=employee).amount, Decimal("800.00")
        )
        run = PayrollRun.objects.get(period_start="2026-01-01")
        self.assertEqual(run.status, PayrollRun.Status.PAID)
        self.assertEqual(run.net_total, Decimal("1000.00"))

    def test_running_it_again_changes_nothing(self):
        """A re-import replays the same rows; it must not pay an invoice twice
        or hand the same refund back again."""
        before = {
            "orders": Order.objects.count(),
            "payments": Payment.objects.count(),
            "adjustments": OrderAdjustment.objects.count(),
            "purchases": PurchaseOrder.objects.count(),
            "products": Product.objects.count(),
            "owed": outstanding_balance(Customer.objects.get(full_name="أحمد علي")),
            "entries": _entry_numbers(),
            "numbered": _balance_numbers_issued(),
        }
        second = self.run_sync(self.source, IMPORT)
        self.assertEqual(second.status, MigrationRun.Status.SUCCEEDED)
        self.assertEqual(Order.objects.count(), before["orders"])
        self.assertEqual(Payment.objects.count(), before["payments"])
        self.assertEqual(OrderAdjustment.objects.count(), before["adjustments"])
        self.assertEqual(PurchaseOrder.objects.count(), before["purchases"])
        self.assertEqual(Product.objects.count(), before["products"])
        self.assertEqual(
            outstanding_balance(Customer.objects.get(full_name="أحمد علي")),
            before["owed"],
        )
        # The same entries, not equal ones: nothing cancelled, nothing re-issued.
        self.assertEqual(_entry_numbers(), before["entries"])
        self.assertEqual(_balance_numbers_issued(), before["numbered"])
        carrier = CustomerBalanceEntry.objects.get(customer__full_name="أحمد علي").order
        self.assertEqual(carrier.balance_due, Decimal("40.00"))


class KassDryRunTests(KassTestBase):
    def test_a_dry_run_writes_nothing(self):
        source = self.prepared_source()
        before = Product.objects.count()
        numbered = _balance_numbers_issued()
        run = self.run_sync(source, DRY_RUN)
        self.assertEqual(run.status, MigrationRun.Status.SUCCEEDED)
        self.assertEqual(Product.objects.count(), before)
        self.assertTrue(run.summary)
        # The entries were written, checked and rolled back — numbers and all,
        # so the series a real import numbers from has no hole in it.
        self.assertEqual(run.summary[PARTY_BALANCE]["created"], 5)
        self.assertFalse(CustomerBalanceEntry.objects.exists())
        self.assertFalse(SupplierBalanceEntry.objects.exists())
        self.assertEqual(_balance_numbers_issued(), numbered)


@override_settings(CELERY_TASK_ALWAYS_EAGER=True)
class KassBalanceEntryTests(KassTestBase):
    """What a re-run may change on an account an import opened, and what it
    must refuse to.

    The shop is opened on today's balances; each test then hands the loader
    the record a later run would, the way the engine does — inside a savepoint,
    so a refusal takes back whatever the record had written.
    """

    def setUp(self):
        super().setUp()
        self.source = self.prepared_source()
        self.run = self.run_sync(
            self.source,
            IMPORT,
            scope=scopes.OPENING_POSITION,
            options={"keep_file": True},
        )

    def load(self, amount, *, party=4, kind="customer", name="سالم"):
        resolver = IdentityResolver(self.source, self.run, dry_run=False)
        record = canonical.CanonicalPartyBalance(
            source_key=f"opening:party:{party}",
            party_kind=kind,
            party_source_key=f"party:{party}",
            amount=Decimal(amount),
            as_of=OPENED_AT,
            party_name=name,
        )
        with transaction.atomic():
            return PartyBalanceLoader().load(record, resolver, dry_run=False)

    @staticmethod
    def live(model=CustomerBalanceEntry, **party):
        return model.objects.live().get(**party)

    def test_the_run_succeeds(self):
        self.assertEqual(
            self.run.status,
            MigrationRun.Status.SUCCEEDED,
            msg=f"{self.run.error_message} {self.run.summary}",
        )

    def test_the_same_figure_leaves_the_entry_alone(self):
        entry = self.live(customer__full_name="سالم")
        numbered = _balance_numbers_issued()

        outcome = self.load("40.00")

        self.assertEqual(outcome.target_pk, entry.pk)
        self.assertEqual(outcome.issues, [])
        self.assertEqual(_balance_numbers_issued(), numbered)

    def test_a_different_figure_replaces_the_entry(self):
        old = self.live(customer__full_name="سالم")

        outcome = self.load("55.00")

        old.refresh_from_db()
        self.assertEqual(old.doc_status, DocumentStatus.CANCELLED)
        self.assertIsNone(old.cancelled_by)
        # Its carrier goes with it, so the old debt stops being collectable.
        self.assertEqual(Order.objects.get(pk=old.order_id).status, Order.Status.VOID)
        new = self.live(customer__full_name="سالم")
        self.assertEqual(new.amount, Decimal("55.00"))
        self.assertEqual(outcome.target_pk, new.pk)
        self.assertEqual(
            [issue.code for issue in outcome.issues], ["opening_balance_replaced"]
        )
        self.assertEqual(outstanding_balance(new.customer), Decimal("55.00"))

    def test_a_debt_that_has_been_collected_from_is_never_rewritten(self):
        """The earlier design deleted the payments on an opening invoice when a
        re-import rewrote it. Money a cashier took stays taken."""
        entry = self.live(customer__full_name="سالم")
        Payment.objects.create(order=entry.order, method="cash", amount=Decimal("10.00"))

        with self.assertRaises(LoaderError) as caught:
            self.load("55.00")

        self.assertEqual(caught.exception.code, "opening_balance_in_use")
        entry.refresh_from_db()
        self.assertEqual(entry.doc_status, DocumentStatus.SUBMITTED)
        self.assertEqual(entry.order.payments.count(), 1)
        self.assertEqual(
            CustomerBalanceEntry.objects.filter(customer=entry.customer).count(), 1
        )

    def test_credit_that_has_been_spent_is_never_withdrawn(self):
        mona = Customer.objects.get(full_name="منى")
        create_customer_entry(
            customer=mona,
            kind=BalanceEntry.Kind.ADJUSTMENT,
            direction=BalanceEntry.Direction.THEY_OWE_US,
            amount=Decimal("10.00"),
            note="إصلاح شاشة",
        )
        credit = self.live(customer=mona, kind=BalanceEntry.Kind.OPENING)
        self.assertTrue(credit.applications.exists())

        with self.assertRaises(LoaderError) as caught:
            self.load("0", party=6, name="منى")

        self.assertEqual(caught.exception.code, "opening_balance_in_use")
        credit.refresh_from_db()
        self.assertEqual(credit.doc_status, DocumentStatus.SUBMITTED)

    def test_an_entry_a_person_cancelled_stays_cancelled(self):
        owner = get_user_model().objects.create_superuser("owner", "o@x.ly", "pw12")
        entry = self.live(customer__full_name="سالم")
        documents.cancel(entry, reason="سُدّد قبل النقل", actor=owner)

        outcome = self.load("40.00")

        self.assertEqual(
            [issue.code for issue in outcome.issues], ["opening_balance_retracted"]
        )
        self.assertFalse(
            CustomerBalanceEntry.objects.live().filter(customer=entry.customer).exists()
        )

    def test_an_opening_typed_by_hand_is_not_doubled(self):
        """The source said square, so the import withdrew its entry; the owner
        then typed the figure they trust. A later run does not add its own."""
        self.load("0")
        salem = Customer.objects.get(full_name="سالم")
        typed = create_customer_entry(
            customer=salem,
            kind=BalanceEntry.Kind.OPENING,
            direction=BalanceEntry.Direction.THEY_OWE_US,
            amount=Decimal("45.00"),
        )

        with self.assertRaises(LoaderError) as caught:
            self.load("40.00")

        self.assertEqual(caught.exception.code, "opening_balance_exists")
        self.assertEqual(caught.exception.detail["number"], typed.number)
        self.assertEqual(
            list(CustomerBalanceEntry.objects.live().filter(customer=salem)), [typed]
        )

    def test_a_supplier_who_falls_square_loses_their_entry(self):
        supplier = Supplier.objects.get(name="شركة التوريد")
        entry = self.live(SupplierBalanceEntry, supplier=supplier)

        outcome = self.load("0", party=3, kind="supplier", name="شركة التوريد")

        entry.refresh_from_db()
        self.assertEqual(entry.doc_status, DocumentStatus.CANCELLED)
        self.assertEqual(
            [issue.code for issue in outcome.issues], ["opening_balance_withdrawn"]
        )
        self.assertEqual(
            Supplier.objects.get(pk=supplier.pk).payable_balance, Decimal("0.00")
        )

    def test_a_supplier_credit_is_withdrawn_while_unspent(self):
        supplier = Supplier.objects.get(name="مؤسسة الأمل")
        self.assertEqual(supplier.credit_balance, Decimal("15.00"))

        self.load("0", party=7, kind="supplier", name="مؤسسة الأمل")

        self.assertFalse(SupplierCredit.objects.filter(supplier=supplier).exists())
        self.assertEqual(
            Supplier.objects.get(pk=supplier.pk).credit_balance, Decimal("0.00")
        )

    def test_a_closed_period_refuses_the_change(self):
        settings_row = ShopSettings.load()
        settings_row.books_locked_through = date(2026, 3, 31)
        settings_row.save(update_fields=["books_locked_through"])

        with self.assertRaises(LoaderError) as caught:
            self.load("55.00")

        self.assertEqual(caught.exception.code, "period_locked")
        self.assertEqual(
            self.live(customer__full_name="سالم").amount, Decimal("40.00")
        )

    def test_a_replayed_receipt_settles_the_opening_debt_again(self):
        """A re-run replays each receipt: its rows are deleted and allocated
        again. An invoice is rewritten by the sale pass first, but an opening
        debt's carrier is not — closed by this receipt last time, it has to be
        reopened when the payment goes, or the replay finds nothing to pay."""
        resolver = IdentityResolver(self.source, self.run, dry_run=False)
        receipt = canonical.CanonicalPayment(
            source_key="receipt:salem",
            customer_source_key="party:4",
            amount=Decimal("40.00"),
            reference="test:receipt:salem",
        )
        carrier = self.live(customer__full_name="سالم").order

        for _ in range(2):
            with transaction.atomic():
                outcome = PaymentLoader().load(receipt, resolver, dry_run=False)
            self.assertEqual(outcome.issues, [])

        carrier.refresh_from_db()
        self.assertEqual(carrier.status, Order.Status.PAID)
        self.assertEqual(
            list(carrier.payments.values_list("amount", flat=True)), [Decimal("40.00")]
        )


def _old_design_invoice(resolver, *, party, amount):
    """An opening balance the way the importer used to write one: an unpaid
    آجل invoice for one «رصيد افتتاحي»."""
    _old_design_item(resolver)
    outcome = SaleLoader().load(
        canonical.CanonicalSale(
            source_key=f"opening:party:{party}",
            customer_source_key=f"party:{party}",
            status="open",
            sale_type="credit",
            amount_paid=Decimal("0"),
            occurred_at=datetime(2026, 1, 30),
            lines=[
                canonical.CanonicalSaleLine(
                    variant_source_key=LEGACY_OPENING_ITEM_KEY,
                    unit_price=Decimal(amount),
                )
            ],
        ),
        resolver,
        dry_run=False,
    )
    return Order.objects.get(pk=outcome.target_pk)


def _old_design_purchase(resolver, *, party, amount):
    """…and a supplier's: a received order the shop never paid."""
    _old_design_item(resolver)
    outcome = PurchaseOrderLoader().load(
        canonical.CanonicalPurchaseOrder(
            source_key=f"opening:party:{party}",
            supplier_source_key=f"party:{party}",
            status="received",
            supplier_invoice_number=LEGACY_OPENING_ITEM_NAME,
            occurred_at=datetime(2026, 1, 30),
            lines=[
                canonical.CanonicalPurchaseLine(
                    variant_source_key=LEGACY_OPENING_ITEM_KEY,
                    unit_cost=Decimal(amount),
                )
            ],
        ),
        resolver,
        dry_run=False,
    )
    return PurchaseOrder.objects.get(pk=outcome.target_pk)


def _old_design_item(resolver):
    """The service item those documents hung off, registered as it was."""
    if resolver.resolve(VARIANT, LEGACY_OPENING_ITEM_KEY) is not None:
        return
    product = Product.objects.filter(name=LEGACY_OPENING_ITEM_NAME).first()
    if product is None:
        product = Product.objects.create(
            name=LEGACY_OPENING_ITEM_NAME, is_service=True, is_active=True
        )
    variant = product.ensure_default_variant(
        name="", sku="", barcode="", unit_price=Decimal("0"), is_active=True
    )
    resolver.remember(PRODUCT, LEGACY_OPENING_ITEM_KEY, product)
    resolver.remember(VARIANT, LEGACY_OPENING_ITEM_KEY, variant)


@override_settings(CELERY_TASK_ALWAYS_EAGER=True)
class KassOldDesignOpeningTests(KassTestBase):
    """A shop imported before balances were entries, imported again.

    Its openings are an آجل invoice and a received order against «رصيد
    افتتاحي». Nothing converts them in bulk; a re-import of the same source
    converts each one it can show is untouched, and leaves anything a person
    has since used or retracted exactly where it is.
    """

    def setUp(self):
        super().setUp()
        self.source = self.prepared_source()
        self.parties_run = self.run_sync(
            self.source,
            IMPORT,
            entities=[CUSTOMER, SUPPLIER],
            options={"keep_file": True},
        )
        resolver = IdentityResolver(self.source, self.parties_run, dry_run=False)
        self.invoice = _old_design_invoice(resolver, party=4, amount="40.00")
        self.order = _old_design_purchase(resolver, party=3, amount="130.00")

    def reimport(self, source=None):
        return self.run_sync(
            source or self.source,
            IMPORT,
            scope=scopes.OPENING_POSITION,
            options={"keep_file": True},
        )

    def test_an_untouched_opening_invoice_and_order_become_entries(self):
        run = self.reimport()

        self.assertEqual(
            run.status,
            MigrationRun.Status.SUCCEEDED,
            msg=f"{run.error_message} {list(run.issues.values_list('code', 'message'))}",
        )
        self.assertFalse(Order.objects.filter(pk=self.invoice.pk).exists())
        self.assertFalse(PurchaseOrder.objects.filter(pk=self.order.pk).exists())
        salem = Customer.objects.get(full_name="سالم")
        entry = CustomerBalanceEntry.objects.live().get(customer=salem)
        self.assertEqual(entry.amount, Decimal("40.00"))
        self.assertEqual(outstanding_balance(salem), Decimal("40.00"))
        self.assertEqual(
            Supplier.objects.get(name="شركة التوريد").payable_balance, Decimal("130.00")
        )
        converted = run.issues.filter(code="opening_balance_converted")
        self.assertEqual(
            sorted(converted.values_list("source_key", flat=True)),
            ["opening:party:3", "opening:party:4"],
        )
        self.assertFalse(Order.objects.committed_sales().exists())

    def test_an_old_opening_position_can_still_take_the_history(self):
        """Annaseem's path: opened the old way on today's balances, then the
        whole file. Each old opening becomes the opening entry the history walks
        forward from — or goes, for خالد, who opened on nothing."""
        resolver = IdentityResolver(self.source, self.parties_run, dry_run=False)
        invoices = [
            self.invoice,
            _old_design_invoice(resolver, party=2, amount="70.00"),
            _old_design_invoice(resolver, party=5, amount="60.00"),
        ]

        run = self.run_sync(self.source, IMPORT, options={"keep_file": True})

        self.assertEqual(
            run.status,
            MigrationRun.Status.SUCCEEDED,
            msg=f"{run.error_message} {list(run.issues.values_list('code', 'message'))}",
        )
        self.assertFalse(
            Order.objects.filter(pk__in=[invoice.pk for invoice in invoices]).exists()
        )
        self.assertFalse(PurchaseOrder.objects.filter(pk=self.order.pk).exists())
        codes = dict(
            run.issues.filter(code__startswith="opening_balance").values_list(
                "source_key", "code"
            )
        )
        self.assertEqual(codes["opening:party:5"], "opening_balance_withdrawn")
        self.assertEqual(codes["opening:party:2"], "opening_balance_converted")
        for name, owed in (("أحمد علي", "70.00"), ("سالم", "40.00"), ("خالد", "60.00")):
            self.assertEqual(
                outstanding_balance(Customer.objects.get(full_name=name)),
                Decimal(owed),
                msg=name,
            )
        self.assertEqual(
            customer_balance(Customer.objects.get(full_name="منى")).owed_to_customer,
            Decimal("25.00"),
        )
        self.assertEqual(
            Supplier.objects.get(name="شركة التوريد").net_balance, Decimal("130.00")
        )
        self.assertEqual(
            Supplier.objects.get(name="مؤسسة الأمل").net_balance, Decimal("-15.00")
        )

    def test_an_opening_invoice_that_was_collected_from_is_left_alone(self):
        Payment.objects.create(order=self.invoice, method="cash", amount=Decimal("15.00"))

        run = self.reimport()

        self.assertEqual(run.status, MigrationRun.Status.PARTIAL)
        issue = run.issues.get(source_key="opening:party:4")
        self.assertEqual(issue.code, "opening_balance_in_use")
        self.assertTrue(Order.objects.filter(pk=self.invoice.pk).exists())
        self.assertEqual(self.invoice.payments.count(), 1)
        salem = Customer.objects.get(full_name="سالم")
        self.assertFalse(CustomerBalanceEntry.objects.filter(customer=salem).exists())
        # Still owed through the invoice it always was: 40 less the 15 taken.
        self.assertEqual(outstanding_balance(salem), Decimal("25.00"))

    def test_an_opening_invoice_a_person_voided_stays_voided(self):
        Order.objects.filter(pk=self.invoice.pk).update(
            doc_status=DocumentStatus.CANCELLED, status=Order.Status.VOID
        )

        run = self.reimport()

        issue = run.issues.get(source_key="opening:party:4")
        self.assertEqual(issue.code, "opening_balance_retracted")
        salem = Customer.objects.get(full_name="سالم")
        self.assertFalse(CustomerBalanceEntry.objects.filter(customer=salem).exists())
        self.assertEqual(outstanding_balance(salem), Decimal("0.00"))

    def test_an_opening_from_an_earlier_upload_is_not_opened_twice(self):
        """A fresh upload of the same file is a new source, blind to the old
        one's documents. It finds أحمد (by phone) and the supplier (by name) —
        and both already carry an opening from the first import."""
        resolver = IdentityResolver(self.source, self.parties_run, dry_run=False)
        ahmad_invoice = _old_design_invoice(resolver, party=2, amount="70.00")

        run = self.reimport(self.prepared_source())

        errors = dict(
            run.issues.filter(severity="error").values_list("source_key", "code")
        )
        self.assertEqual(errors.get("opening:party:2"), "legacy_opening_exists")
        self.assertEqual(errors.get("opening:party:3"), "legacy_opening_exists")
        ahmad = Customer.objects.get(phone="0910000000")
        self.assertFalse(CustomerBalanceEntry.objects.filter(customer=ahmad).exists())
        self.assertEqual(outstanding_balance(ahmad), Decimal("70.00"))
        self.assertEqual(
            Supplier.objects.get(name="شركة التوريد").payable_balance, Decimal("130.00")
        )
        # This upload cannot show those documents are its own, so it leaves them.
        self.assertTrue(Order.objects.filter(pk=ahmad_invoice.pk).exists())
        self.assertTrue(PurchaseOrder.objects.filter(pk=self.order.pk).exists())
