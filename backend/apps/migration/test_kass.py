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
* two parties carrying a balance from before the file's history begins
* a daily cash sweep, which must not be imported
"""

import tempfile
from decimal import Decimal
from pathlib import Path

from django.test import TestCase, override_settings

from apps.catalog.models import Product, ProductCategory, ProductVariant
from apps.customers.models import Customer
from apps.customers.receivables import outstanding_balance
from apps.employees.models import CompensationPlan, Employee, PayrollRun
from apps.expenses.models import Expense
from apps.inventory.models import StockItem, StockLedgerEntry, StockValuationBin
from apps.payments.models import Payment
from apps.purchasing.models import PurchaseOrder, Supplier
from apps.sales.models import Order, OrderAdjustment
from apps.treasury.models import MoneyAccount

from . import storage
from .connectors import get_connector
from .connectors.base import ExtractContext
from .connectors.kass import OPENING_PRODUCT_NAME
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
        # A balance and not one document: without an opening-balance document
        # this customer's debt disappears on import.
        ("سالم", 4, -40, -40, 1, None, 1, 1, 1, 1, None, None, None, 0, "2025-01-01", 1),
        ("خالد", 5, -60, 0, 1, None, 1, 1, 1, 1, None, None, None, 0, "2025-01-01", 1),
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

    def extract(self, entity_type):
        source = getattr(self, "_source", None)
        if source is None:
            source = self._source = self.prepared_source()
        connector = get_connector("kass")
        transport = build_transport(
            "sqlite", {"database": str(storage.prepared_path(source))}
        )
        ctx = getattr(self, "_ctx", None)
        if ctx is None:
            ctx = self._ctx = ExtractContext()
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
        self.assertEqual(entities["product"]["count"], 3)
        self.assertEqual(entities["customer"]["count"], 5)
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

    def test_the_opening_balance_item_keeps_no_stock(self):
        opening = [
            record for record in self.extract("product") if record.name == OPENING_PRODUCT_NAME
        ]
        self.assertEqual(len(opening), 1)
        self.assertTrue(opening[0].is_service)


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

    def test_customers_who_only_have_a_balance_get_an_opening_invoice(self):
        sales = {record.source_key: record for record in self.extract("sale")}
        opening = sales["opening:party:4"]
        self.assertEqual(opening.sale_type, "credit")
        self.assertEqual(opening.lines[0].unit_price, Decimal("40.00"))
        # Dated before the history, not on the day of the import.
        self.assertLess(opening.occurred_at.date().isoformat(), "2026-02-01")

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

    def test_suppliers_owed_from_before_get_an_opening_order(self):
        orders = {record.source_key: record for record in self.extract("purchase_order")}
        opening = orders["opening:party:3"]
        self.assertEqual(opening.lines[0].unit_cost, Decimal("100.00"))


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
        self.assertCreated(Product, 4)  # three items + the opening-balance item
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

    def test_what_the_shop_owes_its_supplier_matches_the_old_system(self):
        supplier = Supplier.objects.get(name="شركة التوريد")
        # 100 opening + 50 order − 20 paid = 130, the supplier's stored balance.
        self.assertEqual(supplier.payable_balance, Decimal("130.00"))

    def test_the_return_comes_off_the_sale_it_belonged_to(self):
        order = Order.objects.get(receipt_number="970000001")
        adjustment = OrderAdjustment.objects.get(order=order)
        self.assertEqual(adjustment.adjustment_type, OrderAdjustment.AdjustmentType.RETURN)
        self.assertEqual(adjustment.amount, Decimal("15.00"))
        # Written as a negative payment, the way a live refund is.
        self.assertEqual(order.payments.filter(amount__lt=0).count(), 1)

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


class KassDryRunTests(KassTestBase):
    def test_a_dry_run_writes_nothing(self):
        source = self.prepared_source()
        before = Product.objects.count()
        run = self.run_sync(source, DRY_RUN)
        self.assertEqual(run.status, MigrationRun.Status.SUCCEEDED)
        self.assertEqual(Product.objects.count(), before)
        self.assertTrue(run.summary)
