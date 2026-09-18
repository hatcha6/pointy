"""A write names the place it touched, or it does not compile.

Three defects with one shape: an argument that identifies *where* stock moved
carried a default, callers took the default, and the resulting write landed on
the wrong shelf without saying so. The arguments are required now, and these are
the behaviours that proves.
"""

from decimal import Decimal

from django.test import TestCase
from apps.catalog.models import Product
from apps.inventory.identity import normalize_identifier
from apps.inventory.models import StockBatch, StockBatchBalance, Warehouse
from apps.inventory.oversell import may_oversell, may_oversell_document
from apps.inventory.services import consume_expiring_stock_batches
from apps.inventory.tracked_testing import tracked_product


def _expiry_product(sku):
    product = tracked_product(
        name="حليب", sku=sku, mode=Product.TrackingMode.QUANTITY, unit_price="5.00"
    )
    product.tracks_expiry = True
    product.save(update_fields=["tracks_expiry", "updated_at"])
    return product


class ConsumeStaysInItsWarehouse(TestCase):
    """A shrink in Branch #2 may not be taken out of the main store's lot."""

    def setUp(self):
        self.product = _expiry_product("MILK")
        self.variant = self.product.default_variant
        self.branch = Warehouse.objects.create(name="فرع", code="BR2")
        self.lot = StockBatch.objects.create(
            variant=self.variant, code="L-1", code_normalized="L-1"
        )
        self.main_balance = StockBatchBalance.objects.create(
            batch=self.lot,
            warehouse_id=Warehouse.default_id(),
            variant=self.variant,
            received_quantity=Decimal("10"),
            remaining_quantity=Decimal("10"),
        )
        self.branch_balance = StockBatchBalance.objects.create(
            batch=self.lot,
            warehouse=self.branch,
            variant=self.variant,
            received_quantity=Decimal("10"),
            remaining_quantity=Decimal("10"),
        )

    def test_a_branch_shrink_draws_only_on_the_branch(self):
        consume_expiring_stock_batches(
            variant=self.variant, quantity=Decimal("4"), warehouse=self.branch.pk
        )

        self.main_balance.refresh_from_db()
        self.branch_balance.refresh_from_db()
        self.assertEqual(self.main_balance.remaining_quantity, Decimal("10.000"))
        self.assertEqual(self.branch_balance.remaining_quantity, Decimal("6.000"))

    def test_the_warehouse_cannot_be_left_out(self):
        """The default is what let four of five callers get this wrong."""
        with self.assertRaises(TypeError):
            consume_expiring_stock_batches(
                variant=self.variant, quantity=Decimal("4")
            )


class OversellRefusesWholeDocumentsHoldingIdentifiedStock(TestCase):
    """One identified line forbids going negative for all of it."""

    def setUp(self):
        self.settings_row = None
        self.plain = tracked_product(
            name="كولا", sku="COLA", mode=Product.TrackingMode.QUANTITY
        )
        self.serial = tracked_product(
            name="آيفون", sku="IPH", mode=Product.TrackingMode.SERIAL
        )

    def test_a_document_of_plain_goods_follows_the_shop(self):
        from apps.core.models import ShopSettings

        settings = ShopSettings.load()
        settings.allow_overselling = True
        settings.save(update_fields=["allow_overselling", "updated_at"])
        self.assertTrue(
            may_oversell_document(
                Warehouse.default_id(),
                variants=[self.plain.default_variant],
                settings=settings,
            )
        )

    def test_one_tracked_line_refuses_the_whole_document(self):
        from apps.core.models import ShopSettings

        settings = ShopSettings.load()
        settings.allow_overselling = True
        settings.save(update_fields=["allow_overselling", "updated_at"])
        self.assertFalse(
            may_oversell_document(
                Warehouse.default_id(),
                variants=[self.plain.default_variant, self.serial.default_variant],
                settings=settings,
            )
        )

    def test_the_variant_cannot_be_left_out(self):
        with self.assertRaises(TypeError):
            may_oversell(Warehouse.default_id())


class IdentifiersFoldTheirDigits(TestCase):
    """An IMEI typed on an Arabic keyboard is the same IMEI."""

    def test_arabic_indic_digits_collide_with_ascii(self):
        typed = "٣٥١٢٣٤٥٦٧٨٩٠١١٦"
        scanned = "351234567890116"
        self.assertEqual(
            normalize_identifier(typed), normalize_identifier(scanned)
        )

    def test_persian_digits_too(self):
        self.assertEqual(
            normalize_identifier("۳۵۱۲۳۴۵۶۷۸۹۰۱۱۶"),
            normalize_identifier("351234567890116"),
        )

    def test_arabic_letters_are_left_alone(self):
        """Folding digits must not touch a lot code written in Arabic."""
        self.assertEqual(normalize_identifier("دفعة-٣"), "دفعة3")

    def test_the_validator_no_longer_passes_a_typed_imei_as_its_own_number(self):
        """Before the fold, Luhn accepted Arabic-Indic digits and said fine."""
        from apps.inventory.identity import check_identifier

        typed = "٣٥١٢٣٤٥٦٧٨٩٠١١٦"
        self.assertEqual(
            check_identifier(normalize_identifier(typed), kind="imei"),
            check_identifier("351234567890116", kind="imei"),
        )


class DiscardStaysInItsWarehouse(TestCase):
    """Cancelling a receipt in one branch leaves the other branch alone."""

    def setUp(self):
        self.product = _expiry_product("MILK2")
        self.variant = self.product.default_variant
        self.branch = Warehouse.objects.create(name="فرع", code="BR3")

    def test_only_the_receipts_own_shelf_is_taken_back(self):
        from apps.inventory.services import discard_expiring_stock_batches, receipt_line_lot_code
        from apps.purchasing.models import (
            PurchaseOrder,
            PurchaseReceipt,
            PurchaseReceiptLine,
            Supplier,
        )

        order = PurchaseOrder.objects.create(
            supplier=Supplier.objects.create(name="مورد")
        )
        line = order.lines.create(
            variant=self.variant, quantity=Decimal("10"), unit_cost=Decimal("1")
        )
        receipt = PurchaseReceipt.objects.create(purchase_order=order)
        receipt_line = PurchaseReceiptLine.objects.create(
            receipt=receipt,
            purchase_line=line,
            variant=self.variant,
            ordered_quantity=Decimal("10"),
            outstanding_before=Decimal("10"),
            accepted_quantity=Decimal("10"),
        )
        code = receipt_line_lot_code(receipt_line)
        lot = StockBatch.objects.create(
            variant=self.variant,
            code=code,
            code_normalized=normalize_identifier(code),
            code_is_generated=True,
        )
        main = StockBatchBalance.objects.create(
            batch=lot, warehouse_id=Warehouse.default_id(), variant=self.variant,
            received_quantity=Decimal("10"), remaining_quantity=Decimal("10"),
        )
        branch = StockBatchBalance.objects.create(
            batch=lot, warehouse=self.branch, variant=self.variant,
            received_quantity=Decimal("4"), remaining_quantity=Decimal("4"),
        )

        discard_expiring_stock_batches(
            receipt_lines=[receipt_line], warehouse=Warehouse.default_id()
        )

        main.refresh_from_db()
        branch.refresh_from_db()
        self.assertEqual(main.remaining_quantity, Decimal("0.000"))
        self.assertEqual(branch.remaining_quantity, Decimal("4.000"))
        # The lot survives, because a branch still holds some of it.
        self.assertTrue(StockBatch.objects.filter(pk=lot.pk).exists())


class IntegrityCommandRuns(TestCase):
    """The invariants must be reachable without a Django shell.

    They existed from Phase A and nothing ran them, so every defect they would
    have caught was found by hand months later.
    """

    def test_a_clean_shop_reports_clean(self):
        from io import StringIO

        from django.core.management import call_command

        out = StringIO()
        call_command("check_stock_integrity", stdout=out)
        self.assertIn("all invariants hold", out.getvalue())

    def test_a_broken_shop_exits_non_zero_and_names_the_invariant(self):
        from io import StringIO

        from django.core.management import call_command

        from apps.catalog.models import Product
        from apps.inventory.models import StockItem
        from apps.inventory.tracked_testing import tracked_product

        product = tracked_product(
            name="آيفون", sku="BROKEN", mode=Product.TrackingMode.SERIAL
        )
        # A bin that claims stock no article accounts for — invariant 1.
        item = StockItem.objects.get(variant=product.default_variant)
        item.quantity_on_hand = Decimal("3")
        item.save(update_fields=["quantity_on_hand", "updated_at"])

        err = StringIO()
        with self.assertRaises(SystemExit):
            call_command("check_stock_integrity", stderr=err)
        self.assertIn("on hand is 3.000", err.getvalue())
