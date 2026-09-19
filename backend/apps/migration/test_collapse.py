"""The §12 collapse, from a name to a shelf.

The fixture is the prospect's catalogue in miniature: thirteen products in an
AboGhris-shaped file, of which nine are really nine handsets of three models and
four are not — a charger with no number in its name, an accessory sold five
times, a handset whose IMEI is already on the shelf, and a row carrying two of
itself. The four are the interesting ones: §12.4 says anything unparseable stays
a product, and every one of them is a different way of being unparseable.

What these tests hold, in order: that the parser reads a name the way a shop
writes one; that the builder checks §1.1's premise instead of assuming it; that
nothing is written before approval; and that what the import writes passes the
§5.4 invariants — asserted against ``apps.inventory.integrity`` rather than
against a hand-written expectation, because the failure this feature can
actually have is a bin that disagrees with the articles it counts.
"""

from __future__ import annotations

import sqlite3
import tempfile
from decimal import Decimal
from pathlib import Path
from unittest import mock

from django.contrib.auth import get_user_model
from django.db import connection
from django.test import TestCase, override_settings
from django.test.utils import CaptureQueriesContext
from rest_framework.serializers import ValidationError
from rest_framework.test import APIClient

from apps.catalog.models import Product, ProductVariant
from apps.core.models import ShopSettings
from apps.inventory.identity import luhn_check
from apps.inventory.integrity import tracking_invariant_violations
from apps.inventory.models import (
    StockAllocation,
    StockItem,
    StockLedgerEntry,
    StockUnit,
    StockValuationBin,
)
from apps.sales.models import Order

from . import services, storage
from .collapse import extract as parsing  # the module, not the function
from .collapse.planner import clusters_for
from .models import CollapseCandidate, CollapsePlan, MigrationRun, MigrationSource

IMPORT = MigrationRun.Mode.IMPORT
DRY_RUN = MigrationRun.Mode.DRY_RUN


def imei(prefix14: str) -> str:
    """A Luhn-correct IMEI from a 14-digit prefix.

    Written out rather than pasted as constants: a fixture full of IMEIs that
    fail their own check digit would quietly exercise the low-confidence path
    for every row, and the test would pass while proving the opposite of what it
    claims.
    """
    assert len(prefix14) == 14 and prefix14.isdigit()
    total = 0
    for index, char in enumerate(reversed(prefix14)):
        value = int(char)
        if index % 2 == 0:
            value *= 2
            if value > 9:
                value -= 9
        total += value
    return prefix14 + str((10 - total % 10) % 10)


#: ``(item id, name, cost, list price, sold price or None, on hand)``.
#: Three models, nine handsets, and four rows that must survive untouched.
PHONES = [
    (101, f"iPhone 13 Pro 256GB Blue Battery86 IMEI{imei('35123456789011')}",
     2400, 2900, 2900, 0),
    (102, f"iPhone 13 Pro 256GB Blue Battery92 IMEI{imei('35123456789022')}",
     2500, 3000, 3000, 0),
    (103, f"iPhone 13 Pro 256GB Blue Battery79 IMEI{imei('35123456789033')}",
     2350, 2850, None, 1),
    (104, f"iPhone 13 Pro 128GB Black Battery88 IMEI{imei('35123456789044')}",
     2100, 2600, 2600, 0),
    (105, f"iPhone 13 Pro 128GB Black Battery95 IMEI{imei('35123456789055')}",
     2200, 2700, None, 1),
    (106, f"ايفون 12 64 جيجا ابيض بطارية 90 {imei('35566677788811')}",
     1500, 1900, None, 1),
    (107, f"ايفون 12 64 جيجا ابيض بطارية 84 {imei('35566677788822')}",
     1450, 1850, None, 1),
    (108, "Samsung S21 Ultra 512GB Phantom Black A+ S/N R58N70ABCDE",
     1800, 2300, 2300, 0),
    (109, "Samsung S21 Ultra 512GB Phantom Black Grade B S/N R58N70FGHIJ",
     1600, 2000, None, 1),
]
#: Everything that must come out the other side as an ordinary product.
KEEPERS = [
    # No identifier at all — §12.4's "anything unparseable stays a product".
    (201, "شاحن ايفون اصلي 20 واط", 30, 60, None, 12),
    # Sold five times, so it is not one product per article however its name
    # reads. Its "IMEI" is a coincidence and the premise check catches it.
    (202, f"جراب شفاف IMEI{imei('35999900001111')}", 5, 15, 15, 40),
    # The same handset as 103, still on the shelf. Two live units may not share
    # an identifier (§7), and which of the two is real is not ours to decide.
    (203, f"iPhone 13 Pro 256GB Blue IMEI{imei('35123456789033')}", 2350, 2850, None, 1),
    # Two of itself on hand, so it is a model, not an article.
    (204, f"iPhone 11 64GB Black IMEI{imei('35777788889911')}", 900, 1200, None, 2),
]

SALE_DATE = "2026-03-11 10:15:00"
BUY_DATE = "2026-01-08 09:00:00"

#: Three models the generated fixture cycles through, for the scaling test.
MODELS = [
    ("iPhone 13 Pro", "256GB", "Blue"),
    ("iPhone 12", "64GB", "White"),
    ("Samsung S22", "128GB", "Black"),
]


def generate_phones(count: int, *, seed: int = 0) -> list:
    """``count`` handsets across three models, each bought once and half sold.

    ``seed`` shifts the identifiers, because the scaling guard imports two
    files into one shop and two live articles may not share a number (§7).
    """
    rows = []
    for index in range(count):
        model, storage, colour = MODELS[index % len(MODELS)]
        code = imei(f"351234{seed:04d}{index:04d}")
        sold = 1200 + index if index % 2 == 0 else None
        rows.append(
            (
                300 + seed * 1000 + index,
                f"{model} {storage} {colour} Battery{80 + index % 20} IMEI{code}",
                900 + index,
                1200 + index,
                sold,
                0 if sold is not None else 1,
            )
        )
    return rows


def build_phone_shop_sample(path: Path, items: list | None = None) -> None:
    """The prospect's catalogue, in the AboGhris schema, small enough to read.

    Rebuilds from nothing, because two tests build the same shop twice at
    different sizes. The staged copy an earlier source took is a hard link to
    the old inode and is left alone by construction.
    """
    path.unlink(missing_ok=True)
    db = sqlite3.connect(path)
    try:
        db.executescript(
            """
            CREATE TABLE UNITS (UNIT_ID INTEGER, UNIT_DISC TEXT);
            CREATE TABLE CATEGORY1 (CAT1_ID INTEGER, CAT1_NAME TEXT, CAT1_INVISIBLE INTEGER);
            CREATE TABLE CATEGORY2 (CAT2_ID INTEGER, CAT2_NAME TEXT, CAT2_INVISIBLE INTEGER);
            CREATE TABLE ITEMS (ITEM_ID INTEGER, ITEM_MODEL TEXT, ITEM_NAME TEXT,
                                CAT1_ID INTEGER, CAT2_ID INTEGER, ITEM_INVISIBLE INTEGER);
            CREATE TABLE BARCODE (BAR_ID INTEGER, UNIT_ID INTEGER, ITEM_ID INTEGER,
                                  BARCODE TEXT, PRICE1 REAL, PUBLIC_PRICE REAL, UNIT_QTY REAL);
            CREATE TABLE ITEMS_SUB (ITEM_SUB_ID INTEGER, ITEM_ID INTEGER,
                                    STORE_ID INTEGER, QTY REAL);
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
        db.executemany(
            "INSERT INTO UNITS VALUES (?, ?)", [(0, "N/A"), (92, "قطعة")]
        )
        db.executemany(
            "INSERT INTO CATEGORY1 VALUES (?, ?, ?)", [(0, "N/A", 0), (7, "هواتف", 0)]
        )
        db.executemany(
            "INSERT INTO CATEGORY2 VALUES (?, ?, ?)", [(0, "N/A", 0)]
        )
        rows = items if items is not None else PHONES + KEEPERS
        db.executemany(
            "INSERT INTO ITEMS VALUES (?, ?, ?, ?, ?, ?)",
            [(item, "", name, 7, 0, 0) for item, name, *_rest in rows],
        )
        db.executemany(
            "INSERT INTO BARCODE VALUES (?, ?, ?, ?, ?, ?, ?)",
            [
                (1000 + item, 92, item, f"620000{item}", price, 0, 1)
                for item, _name, _cost, price, _sold, _hand in rows
            ],
        )
        db.executemany(
            "INSERT INTO ITEMS_SUB VALUES (?, ?, ?, ?)",
            [
                (index, item, 1, hand)
                for index, (item, _n, _c, _p, _s, hand) in enumerate(rows, start=1)
            ],
        )
        db.executemany(
            "INSERT INTO CUSTOMERS VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            [
                (0, "N/A", "", "", "", "", 1, 0),
                (1, "زبون نقدي", "0910000001", "", "", "", 0, 0),
                (2, "مورد الهواتف", "", "0912000002", "", "طرابلس", 1, 0),
            ],
        )
        # One purchase invoice: every article, bought once.
        db.executemany(
            "INSERT INTO BUY_INVOICE VALUES (?, ?, ?, ?, ?)",
            [(1, BUY_DATE, 2, "PH-001", 0)],
        )
        db.executemany(
            "INSERT INTO BUY_ITEMS VALUES (?, ?, ?, ?, ?)",
            [
                (index, 1, item, 50 if item in (201, 202) else 1, cost)
                for index, (item, _n, cost, _p, _s, _h) in enumerate(rows, start=1)
            ],
        )
        # Sales: one invoice per sold handset, plus five of the accessory.
        invoices = []
        lines = []
        line_id = 1
        for invoice_id, (item, _name, cost, _price, sold, _hand) in enumerate(
            rows, start=1
        ):
            if sold is None:
                continue
            invoices.append((invoice_id, SALE_DATE, 1, 0, 0))
            quantity = 5 if item == 202 else 1
            lines.append(
                (line_id, invoice_id, item, quantity, sold, sold, sold, cost, cost)
            )
            line_id += 1
        db.executemany(
            "INSERT INTO SALE_INVOICE VALUES (?, ?, ?, ?, ?)", invoices
        )
        db.executemany(
            "INSERT INTO SALE_ITEMS VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)", lines
        )
        db.executemany(
            "INSERT INTO EXPENCES VALUES (?, ?, ?)", [(0, "N/A", 0)]
        )
        db.commit()
    finally:
        db.close()


# --- the parser --------------------------------------------------------------


class NameExtractionTests(TestCase):
    def test_reads_an_english_name_apart(self):
        found = parsing.extract(
            f"iPhone 13 Pro 256GB Blue Battery86 IMEI{imei('35123456789011')}"
        )
        self.assertEqual(found.stem, "iPhone 13 Pro")
        self.assertEqual(found.identifier_kind, "imei")
        self.assertEqual(found.options, {"storage": "256GB", "colour": "blue"})
        self.assertEqual(found.attributes, {"battery_health": 86})
        self.assertEqual(found.reasons, [])
        self.assertEqual(found.confidence, 1.0)

    def test_reads_an_arabic_name_apart(self):
        found = parsing.extract("ايفون 13 برو 128 جيجا الاسود بطاريه ٨٧٪ ايمي ٣٥١٢٣٤٥٦٧٨٩٠١١١")
        self.assertEqual(found.stem, "ايفون 13 برو")
        self.assertEqual(found.options, {"storage": "128GB", "colour": "black"})
        self.assertEqual(found.attributes, {"battery_health": 87})
        # Arabic-Indic digits fold to ASCII before anything reads them.
        self.assertEqual(found.identifier, "351234567890111")

    def test_arabic_and_english_spellings_cluster_together(self):
        one = parsing.extract(f"ايفون ١٣ برو أزرق IMEI{imei('35123456789011')}")
        two = parsing.extract(f"إيفون 13 برو ازرق IMEI{imei('35123456789022')}")
        self.assertEqual(one.stem_key, two.stem_key)

    def test_the_identifier_is_claimed_before_anything_else_reads_the_name(self):
        """An IMEI contains runs that look like storage, a grade and a battery.

        Masking order is the whole reason the parser is written as a sequence
        rather than five independent searches: 512 and 86 both live inside this
        number, and a scan that saw them would report a phone the shop does not
        have.
        """
        found = parsing.extract(f"Nokia {imei('51286451286451')} 64GB")
        self.assertEqual(found.options, {"storage": "64GB"})
        self.assertEqual(found.attributes, {})
        self.assertEqual(found.stem, "Nokia")

    def test_a_compound_colour_leaves_no_word_behind(self):
        found = parsing.extract(
            "Samsung S21 Ultra 512GB Phantom Black S/N R58N70ABCDE"
        )
        self.assertEqual(found.stem, "Samsung S21 Ultra")
        self.assertEqual(found.options["colour"], "black")

    def test_a_failed_check_digit_costs_confidence_but_keeps_the_number(self):
        found = parsing.extract("iPhone 13 Pro IMEI351234567890111")
        self.assertFalse(luhn_check("351234567890111"))
        self.assertIn("imei_check_digit_failed", found.reasons)
        self.assertEqual(found.identifier, "351234567890111")
        self.assertLess(found.confidence, 1.0)

    def test_a_name_with_no_identifier_is_not_collapsible(self):
        found = parsing.extract("شاحن ايفون اصلي 20 واط")
        self.assertFalse(found.collapsible)
        self.assertIn("no_identifier", found.reasons)

    def test_a_name_that_is_only_an_identifier_is_not_collapsible(self):
        found = parsing.extract(imei("35123456789011"))
        self.assertTrue(found.identifier)
        self.assertFalse(found.collapsible)
        self.assertIn("no_stem", found.reasons)

    def test_folding_never_changes_a_name_s_length(self):
        """The property every span in the parser depends on."""
        for name in [name for _id, name, *_rest in PHONES + KEEPERS] + [
            "أبيض ـــ ٨٦٪ آيفون", "Grade A+ / 256 GB", "",
        ]:
            self.assertEqual(len(parsing.fold(name)), len(name), name)

    def test_a_battery_percentage_outside_the_possible_is_not_one(self):
        found = parsing.extract(f"Router 250% boost IMEI{imei('35123456789011')}")
        self.assertNotIn("battery_health", found.attributes)


# --- building the proposal ---------------------------------------------------


class CollapsePlanTestBase(TestCase):
    def setUp(self):
        super().setUp()
        self._tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmpdir.cleanup)
        self.staging = Path(self._tmpdir.name) / "staging"
        self.staging.mkdir()
        override = override_settings(POINTY_MIGRATION_STAGING_ROOT=self.staging)
        override.enable()
        self.addCleanup(override.disable)
        self.db_path = Path(self._tmpdir.name) / "phones.sqlite"
        build_phone_shop_sample(self.db_path)
        self.source = self._make_source()

    def _make_source(self):
        source = MigrationSource.objects.create(
            name="Phone shop",
            original_filename="phones.sqlite",
            system_key="aboghris",
            upload_state=MigrationSource.UploadState.READY,
        )
        source.prepared_filename = storage.prepared_name(source.pk)
        storage.adopt(self.db_path, self.staging / source.prepared_filename)
        source.prepared_size_bytes = storage.file_size(storage.prepared_path(source))
        source.save(
            update_fields=["prepared_filename", "prepared_size_bytes", "updated_at"]
        )
        return source

    def build(self) -> CollapsePlan:
        plan = services.queue_collapse_plan(self.source, user=None, dispatch=False)
        services.build_collapse_plan(plan.pk)
        plan.refresh_from_db()
        return plan

    def approved(self) -> CollapsePlan:
        plan = self.build()
        return services.approve_collapse_plan(plan, user=None)

    def import_with(self, plan, *, mode=IMPORT):
        run = services.queue_migration_run(
            self.source,
            mode=mode,
            entities=None,
            options={"stock_source": "snapshot", "collapse_plan": plan.pk},
            user=None,
            dispatch=False,
        )
        services.run_migration(run.pk)
        run.refresh_from_db()
        return run


class PlanBuildingTests(CollapsePlanTestBase):
    def test_the_headline_counts_what_the_screen_shows(self):
        plan = self.build()
        self.assertEqual(plan.status, CollapsePlan.Status.READY)
        self.assertEqual(
            {
                key: plan.stats[key]
                for key in ("source_products", "products", "variants", "units", "kept")
            },
            {
                "source_products": 13,
                "products": 3,
                "variants": 4,
                "units": 9,
                "kept": 4,
            },
        )
        self.assertEqual(plan.stats["units_in_stock"], 5)
        self.assertEqual(plan.stats["units_sold"], 4)

    def test_clusters_name_the_products_and_their_options(self):
        clusters = {cluster["stem"]: cluster for cluster in clusters_for(self.build())}
        self.assertEqual(
            sorted(clusters), ["Samsung S21 Ultra", "iPhone 13 Pro", "ايفون 12"]
        )
        iphone13 = clusters["iPhone 13 Pro"]
        self.assertEqual(iphone13["units"], 5)
        self.assertEqual(iphone13["variants"], 2)
        self.assertEqual(
            iphone13["option_values"],
            {"storage": ["128GB", "256GB"], "colour": ["black", "blue"]},
        )

    def test_a_row_with_no_identifier_stays_a_product(self):
        plan = self.build()
        charger = plan.candidates.get(source_key="201")
        self.assertEqual(charger.decision, CollapseCandidate.Decision.KEEP)
        self.assertIn("no_identifier", charger.reasons)

    def test_a_row_sold_five_times_is_not_one_product_per_article(self):
        """§1.1's premise is testable, so the builder tests it.

        A product with a fifteen-digit run in its name that left on five
        different lines is an accessory, not a handset — and the only thing that
        can tell the difference is the shop's own documents.
        """
        case = self.build().candidates.get(source_key="202")
        self.assertEqual(case.decision, CollapseCandidate.Decision.KEEP)
        self.assertIn("sold_more_than_once", case.reasons)

    def test_two_of_itself_on_the_shelf_is_a_model_not_an_article(self):
        case = self.build().candidates.get(source_key="204")
        self.assertEqual(case.decision, CollapseCandidate.Decision.KEEP)
        self.assertIn("more_than_one_on_hand", case.reasons)

    def test_a_second_live_row_for_one_identifier_is_left_alone(self):
        plan = self.build()
        self.assertEqual(
            plan.candidates.get(source_key="103").decision,
            CollapseCandidate.Decision.COLLAPSE,
        )
        duplicate = plan.candidates.get(source_key="203")
        self.assertEqual(duplicate.decision, CollapseCandidate.Decision.KEEP)
        self.assertIn("duplicate_identifier", duplicate.reasons)

    def test_cost_price_and_dates_come_from_the_shop_s_own_invoices(self):
        sold = self.build().candidates.get(source_key="101")
        self.assertEqual(sold.unit_cost, Decimal("2400.000000"))
        self.assertEqual(sold.sold_price, Decimal("2900.00"))
        self.assertEqual(sold.list_price, Decimal("2900.00"))
        self.assertEqual(sold.unit_status, CollapseCandidate.UnitStatus.SOLD)
        self.assertEqual(sold.acquired_at.year, 2026)
        self.assertEqual(sold.sold_at.month, 3)

    def test_an_article_the_old_system_still_carries_is_in_stock(self):
        on_hand = self.build().candidates.get(source_key="103")
        self.assertEqual(on_hand.unit_status, CollapseCandidate.UnitStatus.IN_STOCK)
        self.assertIsNone(on_hand.sold_at)

    def test_the_asset_type_is_guessed_from_what_the_identifiers_are(self):
        plan = self.build()
        self.assertIsNotNone(plan.asset_type)
        self.assertTrue(plan.asset_type.tracks_imei)

    def test_rebuilding_supersedes_the_previous_proposal(self):
        first = self.build()
        second = self.build()
        first.refresh_from_db()
        self.assertEqual(first.status, CollapsePlan.Status.SUPERSEDED)
        self.assertEqual(second.status, CollapsePlan.Status.READY)

    def test_an_identifier_the_shop_already_holds_is_left_alone(self):
        """A second file, or a shop that started identifying by hand, can hold a
        handset this file also claims. Which record is real is the owner's
        call."""
        from apps.catalog.models import Product, ProductVariant
        from apps.inventory.models import StockUnit, Warehouse

        product = Product.objects.create(
            name="iPhone 13 Pro", tracking_mode=Product.TrackingMode.SERIAL
        )
        variant = ProductVariant.objects.create(
            product=product, sku="EXISTING-1", unit_price=Decimal("0")
        )
        StockUnit.objects.create(
            variant=variant,
            warehouse_id=Warehouse.default_id(),
            code=imei("35123456789033"),
            status=StockUnit.Status.IN_STOCK,
        )

        clash = self.build().candidates.get(source_key="103")

        self.assertEqual(clash.decision, CollapseCandidate.Decision.KEEP)
        self.assertIn("identifier_already_in_stock", clash.reasons)

    def test_a_failure_leaves_the_plan_failed_rather_than_running(self):
        plan = services.queue_collapse_plan(self.source, user=None, dispatch=False)
        with mock.patch(
            "apps.migration.collapse.build_plan",
            side_effect=RuntimeError("no such table: ITEMS"),
        ):
            services.build_collapse_plan(plan.pk)
        plan.refresh_from_db()
        self.assertEqual(plan.status, CollapsePlan.Status.FAILED)
        self.assertIn("no such table", plan.error_message)


# --- reviewing and approving --------------------------------------------------


class ReviewAndApprovalTests(CollapsePlanTestBase):
    def test_nothing_is_written_to_the_shop_before_approval(self):
        before = Product.objects.count()
        plan = self.build()
        self.assertEqual(Product.objects.count(), before)
        self.assertEqual(StockUnit.objects.count(), 0)
        self.assertEqual(plan.status, CollapsePlan.Status.READY)

    def test_an_approved_plan_can_no_longer_be_edited(self):
        plan = self.approved()
        self.assertFalse(plan.is_editable)
        with self.assertRaises(ValidationError):
            services.rename_collapse_cluster(
                plan, stem_key="iphone 13 pro", stem="iPhone 13 Pro Max"
            )

    def test_a_plan_with_nothing_to_collapse_cannot_be_approved(self):
        plan = self.build()
        plan.candidates.update(decision=CollapseCandidate.Decision.KEEP)
        with self.assertRaises(ValidationError):
            services.approve_collapse_plan(plan, user=None)

    def test_renaming_a_product_is_how_two_of_them_are_merged(self):
        plan = self.build()
        services.rename_collapse_cluster(
            plan, stem_key="ايفون 12", stem="iPhone 13 Pro"
        )
        plan.refresh_from_db()
        self.assertEqual(plan.stats["products"], 2)
        self.assertEqual(plan.stats["units"], 9)
        merged = {cluster["stem"]: cluster["units"] for cluster in clusters_for(plan)}
        self.assertEqual(merged["iPhone 13 Pro"], 7)

    def test_a_run_refuses_a_plan_nobody_approved(self):
        plan = self.build()
        with self.assertRaises(ValidationError):
            services.queue_migration_run(
                self.source,
                mode=IMPORT,
                options={"collapse_plan": plan.pk},
                user=None,
                dispatch=False,
            )

    def test_a_run_refuses_a_plan_belonging_to_another_file(self):
        other = MigrationSource.objects.create(
            name="Another", system_key="aboghris",
            upload_state=MigrationSource.UploadState.READY,
        )
        plan = self.approved()
        with self.assertRaises(ValidationError):
            services.queue_migration_run(
                other, mode=IMPORT, options={"collapse_plan": plan.pk},
                user=None, dispatch=False,
            )


# --- applying ----------------------------------------------------------------


class CollapseImportTests(CollapsePlanTestBase):
    def test_the_catalogue_collapses_and_the_invariants_hold(self):
        plan = self.approved()
        run = self.import_with(plan)

        self.assertIn(
            run.status, (MigrationRun.Status.SUCCEEDED, MigrationRun.Status.PARTIAL)
        )
        self.assertEqual(run.summary["collapse"]["created"], 9)
        # Three collapsed products plus the four that stayed products.
        self.assertEqual(Product.objects.count(), 7)
        tracked = Product.objects.filter(tracking_mode=Product.TrackingMode.SERIAL)
        self.assertEqual(tracked.count(), 3)
        self.assertEqual(StockUnit.objects.count(), 9)
        self.assertEqual(tracking_invariant_violations(), [])

    def test_the_bin_counts_the_articles_and_nothing_else(self):
        self.import_with(self.approved())
        iphone13 = Product.objects.get(name="iPhone 13 Pro")
        by_variant = {
            item.variant_id: item.quantity_on_hand
            for item in StockItem.objects.filter(variant__product=iphone13)
        }
        self.assertEqual(sorted(by_variant.values()), [Decimal("1.000"), Decimal("1.000")])
        # The old system carried one of each of the five; three of them left.
        self.assertEqual(
            StockUnit.objects.filter(
                variant__product=iphone13, status=StockUnit.Status.IN_STOCK
            ).count(),
            2,
        )

    def test_stock_value_is_what_the_articles_cost(self):
        self.import_with(self.approved())
        iphone13 = Product.objects.get(name="iPhone 13 Pro")
        bins = StockValuationBin.objects.filter(variant__product=iphone13)
        self.assertEqual(
            sum(row.stock_value for row in bins), Decimal("2350") + Decimal("2200")
        )

    def test_a_sold_article_names_the_invoice_that_took_it(self):
        self.import_with(self.approved())
        unit = StockUnit.objects.get(code=imei("35123456789011"))
        self.assertEqual(unit.status, StockUnit.Status.SOLD)
        self.assertIsNotNone(unit.sold_order_line)
        self.assertEqual(unit.sold_order_line.order.status, Order.Status.PAID)
        self.assertEqual(unit.sold_price, Decimal("2900.00"))
        self.assertIsNotNone(unit.customer)

    def test_four_years_of_invoices_land_on_the_collapsed_variant(self):
        """The reason the collapse runs inside the import rather than beside it.

        Every sale line names a legacy product key; the identity map points that
        key at the collapsed variant before the sales load, so nothing in the
        sale loader has to know this feature exists.
        """
        self.import_with(self.approved())
        iphone13 = Product.objects.get(name="iPhone 13 Pro")
        lines = [
            line
            for order in Order.objects.prefetch_related("lines__variant__product")
            for line in order.lines.all()
            if line.variant.product_id == iphone13.pk
        ]
        self.assertEqual(len(lines), 3)
        self.assertEqual({line.quantity for line in lines}, {Decimal("1.000")})

    def test_every_article_has_a_history_and_it_balances(self):
        self.import_with(self.approved())
        on_hand = StockUnit.objects.get(code=imei("35123456789033"))
        sold = StockUnit.objects.get(code=imei("35123456789011"))
        self.assertEqual(
            list(
                on_hand.allocations.order_by("posting_at").values_list(
                    "direction", flat=True
                )
            ),
            ["in"],
        )
        self.assertEqual(
            list(
                sold.allocations.order_by("posting_at", "id").values_list(
                    "direction", flat=True
                )
            ),
            ["in", "out"],
        )

    def test_the_opening_entry_accounts_for_exactly_the_articles_on_the_shelf(self):
        self.import_with(self.approved())
        entries = StockLedgerEntry.objects.filter(
            voucher_type=StockLedgerEntry.VoucherType.OPENING
        )
        self.assertEqual(entries.count(), 4)
        for entry in entries:
            self.assertEqual(
                sum(allocation.quantity for allocation in entry.allocations.all()),
                entry.quantity_change,
            )

    def test_a_long_product_name_does_not_collide_its_own_variants(self):
        """The identity-map key is 255 characters; a stem can already fill it.

        A key that silently truncated would make two variants of a long-named
        product the same row — one variant, holding both storages.
        """
        from apps.migration.collapse.apply import _variant_identity
        from apps.migration.models import MigrationIdentityMap

        long_stem = "iphone " * 60
        first = _variant_identity(long_stem, "storage=128GB")
        second = _variant_identity(long_stem, "storage=256GB")
        self.assertNotEqual(first, second)
        for key in (first, second):
            self.assertLessEqual(
                len(key),
                MigrationIdentityMap._meta.get_field("source_key").max_length,
            )

    def test_the_variant_options_the_catalogue_turned_out_to_contain_are_created(self):
        self.import_with(self.approved())
        iphone13 = Product.objects.get(name="iPhone 13 Pro")
        names = sorted(
            variant.name for variant in ProductVariant.objects.filter(product=iphone13)
        )
        self.assertEqual(names, ["128GB / أسود", "256GB / أزرق"])

    def test_the_old_shelf_label_still_resolves_to_the_article(self):
        self.import_with(self.approved())
        unit = StockUnit.objects.get(code=imei("35123456789033"))
        self.assertEqual(unit.secondary_code, "620000103")

    def test_a_barcode_several_handsets_share_is_not_carried_onto_any_of_them(
        self,
    ):
        """A shelf label that names four phones is a product code, not an
        article's, and a till scanning it would resolve ambiguously."""
        shared = [
            (item, name, cost, price, sold, hand)
            for item, name, cost, price, sold, hand in PHONES
        ]
        build_phone_shop_sample(self.db_path, items=shared + KEEPERS)
        # Give three of the handsets one barcode between them.
        db = sqlite3.connect(self.db_path)
        db.execute("UPDATE BARCODE SET BARCODE = 'SHELF-1' WHERE ITEM_ID IN (101,102,103)")
        db.commit()
        db.close()
        self.source = self._make_source()

        self.import_with(self.approved())

        codes = set(
            StockUnit.objects.filter(
                code__in=[
                    imei("35123456789011"),
                    imei("35123456789022"),
                    imei("35123456789033"),
                ]
            ).values_list("secondary_code", flat=True)
        )
        self.assertEqual(codes, {""})
        # A barcode only one handset carries still travels.
        self.assertEqual(
            StockUnit.objects.get(code=imei("35123456789044")).secondary_code,
            "620000104",
        )

    def test_the_unit_carries_the_facts_the_name_was_hiding(self):
        self.import_with(self.approved())
        unit = StockUnit.objects.get(code=imei("35123456789033"))
        # Stored as a JSON number, the way a captured unit stores it.
        self.assertEqual(unit.attributes, {"battery_health": 79.0})
        samsung = StockUnit.objects.get(code="R58N70ABCDE")
        self.assertEqual(samsung.attributes["condition_grade"], "a_plus")

    def test_the_rows_that_stayed_products_are_untouched_ordinary_products(self):
        self.import_with(self.approved())
        charger = Product.objects.get(name="شاحن ايفون اصلي 20 واط")
        self.assertEqual(charger.tracking_mode, Product.TrackingMode.QUANTITY)
        variant = charger.variants.get()
        self.assertEqual(
            StockItem.objects.get(variant=variant).quantity_on_hand, Decimal("12.000")
        )

    def test_applying_a_collapse_turns_the_surfaces_on(self):
        """The flag gates the screens (§10), so a migration that created four
        hundred handsets and left it off would have built a register nobody in
        the shop can open."""
        self.assertFalse(ShopSettings.load().enable_serialized_inventory)
        plan = self.approved()
        self.import_with(plan)
        plan.refresh_from_db()
        self.assertEqual(plan.status, CollapsePlan.Status.APPLIED)
        self.assertTrue(ShopSettings.load().enable_serialized_inventory)

    def test_re_running_the_import_changes_nothing(self):
        plan = self.approved()
        self.import_with(plan)
        counts = (
            Product.objects.count(),
            ProductVariant.objects.count(),
            StockUnit.objects.count(),
            StockAllocation.objects.count(),
            Order.objects.count(),
        )
        self.import_with(plan)
        self.assertEqual(
            (
                Product.objects.count(),
                ProductVariant.objects.count(),
                StockUnit.objects.count(),
                StockAllocation.objects.count(),
                Order.objects.count(),
            ),
            counts,
        )
        self.assertEqual(tracking_invariant_violations(), [])

    def test_a_dry_run_persists_nothing(self):
        plan = self.approved()
        run = self.import_with(plan, mode=DRY_RUN)
        self.assertEqual(run.status, MigrationRun.Status.SUCCEEDED)
        self.assertEqual(run.summary["collapse"]["created"], 9)
        self.assertEqual(StockUnit.objects.count(), 0)
        self.assertEqual(Product.objects.count(), 0)

    def test_a_handset_that_arrived_between_approval_and_import_is_refused(self):
        """One article is a line in the report; the unique index refusing it
        would take the whole phase down with it."""
        from apps.catalog.models import Product, ProductVariant
        from apps.inventory.models import Warehouse

        plan = self.approved()
        product = Product.objects.create(
            name="Held back", tracking_mode=Product.TrackingMode.SERIAL
        )
        variant = ProductVariant.objects.create(
            product=product, sku="HELD-1", unit_price=Decimal("0")
        )
        StockUnit.objects.create(
            variant=variant,
            warehouse_id=Warehouse.default_id(),
            code=imei("35123456789033"),
            status=StockUnit.Status.IN_STOCK,
        )

        run = self.import_with(plan)

        self.assertEqual(run.summary["collapse"]["created"], 8)
        self.assertEqual(run.summary["collapse"]["skipped"], 1)
        self.assertTrue(
            run.issues.filter(code="collapse_identifier_in_stock").exists()
        )
        self.assertEqual(tracking_invariant_violations(), [])

    def test_a_result_that_breaks_the_invariants_is_rolled_back_whole(self):
        """A migration is the one moment a shop cannot check the answer itself.

        Simulated rather than provoked: every way of actually breaking the
        invariants here is a bug we would fix, and the behaviour under test is
        what happens *when* one exists — units rolled back, run reports it.
        """
        plan = self.approved()
        with mock.patch(
            "apps.migration.collapse.apply.tracking_invariant_violations",
            return_value=["[1] SKU: on hand is 3 but units say 2."],
        ):
            run = self.import_with(plan)
        self.assertEqual(StockUnit.objects.count(), 0)
        self.assertEqual(run.status, MigrationRun.Status.PARTIAL)
        self.assertTrue(run.issues.filter(code="collapse_invariants_violated").exists())
        # And nothing claims it was applied: the surfaces stay off and the plan
        # stays approved, so the owner can fix the file and run it again.
        plan.refresh_from_db()
        self.assertEqual(plan.status, CollapsePlan.Status.APPROVED)
        self.assertFalse(ShopSettings.load().enable_serialized_inventory)


class CollapseScalingTests(CollapsePlanTestBase):
    """The unit phase must not cost a query per handset beyond the article itself.

    The shape ``lifecycle-query-scaling`` names: an N+1 in the sale-linking, the
    allocation pass or the "is this identifier already here" check is invisible
    on thirteen rows and is the whole of the wall clock on a shop with thirty
    thousand. Every article genuinely costs its own write; nothing else may cost
    anything per article.

    Measured over ``apply_units`` alone rather than over a whole run — an import
    also walks products, invoices and customers, and those costs would drown the
    one this guard is about.
    """

    #: Writing one article. Anything above this is a lookup that should have
    #: been batched.
    PER_UNIT_BUDGET = 3

    def _queries_for(self, count, *, seed):
        from .collapse.apply import CollapseSession
        from .identity import IdentityResolver

        build_phone_shop_sample(
            self.db_path, items=generate_phones(count, seed=seed)
        )
        self.source = self._make_source()
        plan = self.approved()
        run = self.import_with(plan)
        self.assertEqual(run.summary["collapse"]["created"], count)

        # The same phase again, over the articles it just created. Re-running an
        # import is the ordinary recovery path, so this is a real code path and
        # not a contrivance to make it measurable.
        session = CollapseSession(plan, dry_run=False)
        session.resolver = IdentityResolver(self.source, run, dry_run=False)
        with CaptureQueriesContext(connection) as captured:
            outcome = session.apply_units()
        self.assertEqual(outcome.counts["updated"], count)
        return len(captured)

    def test_the_cost_of_a_handset_is_the_handset(self):
        small = self._queries_for(6, seed=1)
        large = self._queries_for(18, seed=2)
        self.assertLessEqual(
            large - small,
            12 * self.PER_UNIT_BUDGET,
            f"12 more handsets cost {large - small} more queries; the linking, "
            "allocation and identifier passes are meant to be batched.",
        )


# --- the API -----------------------------------------------------------------


class CollapseApiTests(CollapsePlanTestBase):
    def setUp(self):
        super().setUp()
        self.user = get_user_model().objects.create_superuser(
            username="owner", password="owner-pass-1"
        )
        self.client = APIClient()
        self.client.force_authenticate(self.user)

    def test_candidates_are_listed_least_confident_first(self):
        plan = self.build()
        response = self.client.get(
            f"/api/migration/collapse-plans/{plan.pk}/candidates/"
        )
        self.assertEqual(response.status_code, 200)
        rows = response.json()["results"]
        scores = [Decimal(row["confidence"]) for row in rows]
        self.assertEqual(scores, sorted(scores))

    def test_the_review_filter_returns_only_what_needs_a_person(self):
        plan = self.build()
        plan.candidates.filter(source_key="101").update(confidence=Decimal("0.20"))
        response = self.client.get(
            f"/api/migration/collapse-plans/{plan.pk}/candidates/",
            {"needs_review": "1"},
        )
        keys = [row["source_key"] for row in response.json()["results"]]
        self.assertEqual(keys, ["101"])

    def test_editing_a_row_moves_it_and_recounts_the_headline(self):
        plan = self.build()
        candidate = plan.candidates.get(source_key="106")
        response = self.client.patch(
            f"/api/migration/collapse-candidates/{candidate.pk}/",
            {"stem": "iPhone 12"},
            format="json",
        )
        self.assertEqual(response.status_code, 200)
        body = response.json()
        self.assertTrue(body["candidate"]["edited"])
        self.assertEqual(body["candidate"]["stem_key"], "iphone 12")
        # It left its old cluster, so there are now four products.
        self.assertEqual(body["stats"]["products"], 4)

    def test_a_row_cannot_be_collapsed_without_a_name_or_an_identifier(self):
        plan = self.build()
        candidate = plan.candidates.get(source_key="101")
        response = self.client.patch(
            f"/api/migration/collapse-candidates/{candidate.pk}/",
            {"identifier": ""},
            format="json",
        )
        self.assertEqual(response.status_code, 400)

    def test_a_kept_row_can_be_collapsed_by_hand(self):
        plan = self.build()
        candidate = plan.candidates.get(source_key="201")
        response = self.client.patch(
            f"/api/migration/collapse-candidates/{candidate.pk}/",
            {
                "decision": "collapse",
                "stem": "شاحن ايفون",
                "identifier": "CHG-0001",
                "identifier_kind": "serial",
            },
            format="json",
        )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["stats"]["products"], 4)

    def test_an_edited_attribute_goes_through_the_same_coercion_as_a_unit(self):
        """«٨٦٪» typed into the sheet must land on the article as 86.

        The value is written onto ``StockUnit.attributes`` untouched, so it has
        to be the shape the picker, the filters and the label printer expect.
        """
        plan = self.build()
        candidate = plan.candidates.get(source_key="101")
        response = self.client.patch(
            f"/api/migration/collapse-candidates/{candidate.pk}/",
            {"attributes": {"battery_health": "86", "nonsense": "x"}},
            format="json",
        )
        self.assertEqual(response.status_code, 200)
        # A number rather than the string it arrived as, and the key nothing
        # defines is gone.
        self.assertEqual(
            response.json()["candidate"]["attributes"], {"battery_health": 86.0}
        )

    def test_an_impossible_battery_percentage_is_refused(self):
        plan = self.build()
        candidate = plan.candidates.get(source_key="101")
        response = self.client.patch(
            f"/api/migration/collapse-candidates/{candidate.pk}/",
            {"attributes": {"battery_health": 250}},
            format="json",
        )
        self.assertEqual(response.status_code, 400)

    def test_an_identifier_kind_the_register_cannot_render_is_refused(self):
        plan = self.build()
        candidate = plan.candidates.get(source_key="101")
        response = self.client.patch(
            f"/api/migration/collapse-candidates/{candidate.pk}/",
            {"identifier_kind": "telepathy"},
            format="json",
        )
        self.assertEqual(response.status_code, 400)

    def test_approval_freezes_the_rows(self):
        plan = self.build()
        candidate = plan.candidates.get(source_key="101")
        approve = self.client.post(
            f"/api/migration/collapse-plans/{plan.pk}/approve/"
        )
        self.assertEqual(approve.status_code, 200)
        self.assertEqual(approve.json()["status"], "approved")
        response = self.client.patch(
            f"/api/migration/collapse-candidates/{candidate.pk}/",
            {"stem": "iPhone 13"},
            format="json",
        )
        self.assertEqual(response.status_code, 400)

    def test_the_clusters_endpoint_is_the_screen_s_own_payload(self):
        plan = self.build()
        response = self.client.get(
            f"/api/migration/collapse-plans/{plan.pk}/clusters/"
        )
        self.assertEqual(response.status_code, 200)
        biggest = response.json()[0]
        self.assertEqual(biggest["stem"], "iPhone 13 Pro")
        self.assertEqual(biggest["units"], 5)

    def test_reading_and_approving_are_different_permissions(self):
        """A collapse rewrites what a shop's catalogue means. Looking at the
        proposal and agreeing to it are not the same act."""
        from django.contrib.auth.models import Permission

        reader = get_user_model().objects.create_user(
            username="reader", password="reader-pass-1"
        )
        plan = self.build()
        client = APIClient()
        client.force_authenticate(reader)

        self.assertEqual(
            client.get(f"/api/migration/collapse-plans/{plan.pk}/").status_code,
            403,
        )

        reader.user_permissions.add(
            Permission.objects.get(
                codename="view_migrationsource",
                content_type__app_label="migration",
            )
        )
        reader = get_user_model().objects.get(pk=reader.pk)
        client.force_authenticate(reader)

        self.assertEqual(
            client.get(f"/api/migration/collapse-plans/{plan.pk}/").status_code,
            200,
        )
        self.assertEqual(
            client.post(
                f"/api/migration/collapse-plans/{plan.pk}/approve/"
            ).status_code,
            403,
        )

    def test_proposing_from_the_source_queues_a_plan(self):
        with mock.patch("apps.migration.services._dispatch_collapse") as dispatch:
            response = self.client.post(
                f"/api/migration/sources/{self.source.pk}/collapse/"
            )
        self.assertEqual(response.status_code, 202)
        self.assertEqual(response.json()["status"], "queued")
        dispatch.assert_called_once()
