"""The one-off repair of Annaseem's order P20261024000010
(``apps.purchasing.annaseem_po_repair``).

The order was received at 24 lines / 1,146.00, then every save that added the
rest of the invoice was refused because the shelf held fewer «لصقه 21D» than
the delivery. The repair adds the five missing lines and moves the order to
the right supplier — on that installation only, and only while the order is
exactly as he left it.
"""

from decimal import Decimal
from unittest import mock

from django.test import TestCase

from apps.catalog.testing import create_product_with_default_variant
from apps.core.models import RelayInstallation
from apps.documents.guards import system_write
from apps.inventory.models import StockItem
from apps.purchasing import annaseem_po_repair as repair
from apps.purchasing.models import PurchaseOrder, Supplier, SupplierPayment
from apps.purchasing.services import (
    receive_purchase_order,
    save_purchase_order_with_lines,
    submit_purchase_order,
)

STICKER_SKU = "2852"
COOLER_SKU = "2785"


class AnnaseemPurchaseOrderRepairTests(TestCase):
    def setUp(self):
        self.variants = {}
        for _id, sku, _q, _c in repair.SAVED_LINES + repair.ADDED_LINES:
            product = create_product_with_default_variant(
                name=f"منتج {sku}", sku=sku, barcode="", unit_price=Decimal("100")
            )
            self.variants[sku] = product.default_variant
        # The test database hands out its own ids; the fingerprints follow them.
        self.saved_lines = self._with_ids(repair.SAVED_LINES)
        self.added_lines = self._with_ids(repair.ADDED_LINES)
        patches = [
            mock.patch.object(repair, "SAVED_LINES", self.saved_lines),
            mock.patch.object(repair, "ADDED_LINES", self.added_lines),
        ]
        for patcher in patches:
            patcher.start()
            self.addCleanup(patcher.stop)

        self.wrong = Supplier.objects.create(name=repair.WRONG_SUPPLIER)
        self.right = Supplier.objects.create(name="شركة غويلة الدولية")
        # The stickers had been sold into negative before the goods came.
        StockItem.objects.create(
            variant=self.variants[STICKER_SKU], quantity_on_hand=Decimal("-1")
        )
        self.order = self._received_as_he_left_it()
        # And one cooler sold after the receipt.
        cooler = StockItem.objects.get(variant=self.variants[COOLER_SKU])
        cooler.quantity_on_hand -= 1
        cooler.save(update_fields=["quantity_on_hand"])

    def _with_ids(self, rows):
        return tuple((self.variants[sku].pk, sku, q, c) for _id, sku, q, c in rows)

    def _received_as_he_left_it(self):
        order = save_purchase_order_with_lines(
            supplier=self.wrong,
            lines_data=[
                {
                    "variant": self.variants[sku],
                    "quantity": Decimal(q),
                    "unit_cost": Decimal(c),
                }
                for _id, sku, q, c in self.saved_lines
            ],
        )
        order = receive_purchase_order(submit_purchase_order(order))
        with system_write():
            PurchaseOrder.objects.filter(pk=order.pk).update(
                order_number=repair.ORDER_NUMBER
            )
        order.refresh_from_db()
        self.assertEqual(order.total, repair.SAVED_TOTAL)
        return order

    def _annaseem(self, installation_id=repair.ANNASEEM):
        RelayInstallation.objects.create(
            installation_id=installation_id,
            relay_public_api_url="https://relay.example",
            connector_token="x",
            access_token="x",
        )

    def _on_hand(self, sku):
        return StockItem.objects.get(variant=self.variants[sku]).quantity_on_hand

    def test_the_order_matches_the_invoice(self):
        self._annaseem()

        result = repair.repair()

        self.assertTrue(result["repaired"])
        order = PurchaseOrder.objects.get(pk=self.order.pk)
        self.assertEqual(order.total, repair.TARGET_TOTAL)
        self.assertEqual(order.supplier, self.right)
        self.assertEqual(order.status, PurchaseOrder.Status.RECEIVED)
        self.assertEqual(order.lines.count(), 29)
        self.assertEqual(sum(line.quantity for line in order.lines.all()), 63)
        # What was already on the shelf stays exactly where it was ...
        self.assertEqual(self._on_hand(STICKER_SKU), Decimal("9"))
        self.assertEqual(self._on_hand(COOLER_SKU), Decimal("1"))
        # ... and the five lines the invoice adds arrive with it.
        for _id, sku, quantity, _cost in self.added_lines:
            self.assertEqual(self._on_hand(sku), Decimal(quantity))
            self.assertEqual(
                StockItem.objects.get(variant=self.variants[sku]).quantity_expected, 0
            )

    def test_a_second_run_finds_nothing_to_do(self):
        self._annaseem()
        repair.repair()

        self.assertEqual(repair.repair(), {"repaired": False})
        self.assertEqual(self._on_hand(STICKER_SKU), Decimal("9"))

    def test_any_other_shop_is_left_alone(self):
        self._annaseem("00000000-0000-0000-0000-000000000000")

        self.assertEqual(repair.repair(), {})
        self.order.refresh_from_db()
        self.assertEqual(self.order.total, repair.SAVED_TOTAL)
        self.assertEqual(self.order.supplier, self.wrong)

    def test_an_order_he_already_changed_is_left_alone(self):
        self._annaseem()
        self.order.lines.filter(variant=self.variants[STICKER_SKU]).update(
            quantity=Decimal("12")
        )

        self.assertEqual(repair.repair(), {"repaired": False})
        self.assertEqual(self.order.lines.count(), 24)

    def test_an_order_paid_since_is_left_alone(self):
        self._annaseem()
        SupplierPayment.objects.create(
            supplier=self.wrong,
            purchase_order=self.order,
            amount=Decimal("100.00"),
            method=SupplierPayment.Method.CASH,
        )

        self.assertEqual(repair.repair(), {"repaired": False})
        self.order.refresh_from_db()
        self.assertEqual(self.order.supplier, self.wrong)

    def test_without_the_right_supplier_nothing_changes(self):
        self._annaseem()
        self.right.delete()

        self.assertEqual(repair.repair(), {"repaired": False})
        self.order.refresh_from_db()
        self.assertEqual(self.order.total, repair.SAVED_TOTAL)
