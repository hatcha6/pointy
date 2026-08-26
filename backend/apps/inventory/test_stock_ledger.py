"""The valuation ledger, end to end.

``test_valuation`` proves the arithmetic in isolation. These prove the wiring:
that a receipt records what it paid, that a sale is costed from what is
actually on the shelf rather than from the last invoice, that a return puts
stock back at the cost it left at, and that the cached bin can always be
rebuilt from the ledger.

The scenario throughout is the one that exposes the old behaviour: buy the same
product twice at different prices, then sell it. Under the last-cost rule the
cost of that sale was whichever invoice happened to be newest. It should now be
what the goods actually cost.
"""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.test import TestCase

from apps.catalog.models import Product, ProductVariant
from apps.core.models import ShopSettings
from apps.inventory.models import (
    StockItem,
    StockLedgerEntry,
    StockMovement,
    StockValuationBin,
    Warehouse,
)
from apps.inventory.services import (
    create_stock_movement,
    lock_stock_item,
    stock_snapshot,
)
from apps.inventory.valuation import load_state
from apps.inventory.valuation_service import (
    repost_variant,
    valuation_unit_costs,
)


def D(value):
    return Decimal(str(value))


class LedgerTestCase(TestCase):
    def setUp(self):
        self.user = get_user_model().objects.create_user(
            username="keeper", password="pass"
        )
        self.product = Product.objects.create(name="Rice")
        self.variant = ProductVariant.objects.create(
            product=self.product,
            name="1kg",
            sku="RICE-1",
            unit_price=D("10.00"),
        )
        StockItem.objects.create(variant=self.variant, quantity_on_hand=D("0"))

    def set_method(self, method):
        settings = ShopSettings.load()
        settings.inventory_valuation_method = method
        settings.save()
        # The settings singleton is cached; reload so the service sees it.
        ShopSettings.load()

    def move(self, movement_type, quantity, *, unit_cost=None, voucher_type=None):
        stock_item = lock_stock_item(variant=self.variant)
        before = stock_snapshot(stock_item)
        if movement_type in (
            StockMovement.Type.INCREASE,
            StockMovement.Type.RECEIVE_EXPECTED,
        ):
            stock_item.quantity_on_hand += quantity
        else:
            stock_item.quantity_on_hand -= quantity
        stock_item.save()
        return create_stock_movement(
            variant=self.variant,
            stock_item=stock_item,
            movement_type=movement_type,
            quantity=quantity,
            note="",
            created_by=self.user,
            before=before,
            unit_cost=unit_cost,
            voucher_type=voucher_type or StockLedgerEntry.VoucherType.ADJUSTMENT,
        )

    def receive(self, quantity, unit_cost):
        return self.move(
            StockMovement.Type.INCREASE,
            D(quantity),
            unit_cost=D(unit_cost),
            voucher_type=StockLedgerEntry.VoucherType.PURCHASE_RECEIPT,
        )

    def issue(self, quantity):
        return self.move(
            StockMovement.Type.DECREASE,
            D(quantity),
            voucher_type=StockLedgerEntry.VoucherType.SALE,
        )

    def bin(self):
        return StockValuationBin.objects.get(variant=self.variant)

    def entries(self):
        return list(
            StockLedgerEntry.objects.filter(variant=self.variant).order_by("id")
        )


class ReceiptValuationTests(LedgerTestCase):
    def test_a_receipt_records_what_it_paid(self):
        self.receive(10, "3.00")
        entry = self.entries()[-1]
        self.assertEqual(entry.quantity_change, D("10.000"))
        self.assertEqual(entry.valuation_rate, D("3.000000"))
        self.assertEqual(entry.value_change, D("30.000000"))
        self.assertEqual(entry.balance_quantity, D("10.000"))
        self.assertEqual(entry.balance_value, D("30.000000"))

    def test_a_second_receipt_at_a_new_price_re_averages(self):
        self.receive(10, "3.00")
        self.receive(10, "5.00")
        self.assertEqual(self.bin().valuation_rate, D("4.000000"))
        self.assertEqual(self.bin().stock_value, D("80.000000"))

    def test_expected_stock_is_not_a_valuation_event(self):
        """A purchase order promises stock; it does not put any on the shelf,
        and it must not move the value of what is there."""
        self.receive(10, "3.00")
        stock_item = lock_stock_item(variant=self.variant)
        before = stock_snapshot(stock_item)
        stock_item.quantity_expected += D("50")
        stock_item.save()
        create_stock_movement(
            variant=self.variant,
            stock_item=stock_item,
            movement_type=StockMovement.Type.EXPECTED,
            quantity=D("50"),
            note="",
            created_by=self.user,
            before=before,
        )
        self.assertEqual(len(self.entries()), 1)
        self.assertEqual(self.bin().valuation_rate, D("3.000000"))


class SaleCostingTests(LedgerTestCase):
    def test_moving_average_costs_a_sale_at_the_blended_rate(self):
        self.set_method(ShopSettings.ValuationMethod.MOVING_AVERAGE)
        self.receive(10, "3.00")
        self.receive(10, "5.00")
        movement = self.issue(5)
        self.assertEqual(movement.valuation_rate_applied, D("4"))
        entry = self.entries()[-1]
        self.assertEqual(entry.value_change, D("-20.000000"))

    def test_fifo_costs_a_sale_at_the_oldest_price(self):
        self.set_method(ShopSettings.ValuationMethod.FIFO)
        self.receive(10, "3.00")
        self.receive(10, "5.00")
        movement = self.issue(5)
        self.assertEqual(movement.valuation_rate_applied, D("3"))
        self.assertEqual(self.bin().stock_value, D("65.000000"))

    def test_lifo_costs_a_sale_at_the_newest_price(self):
        self.set_method(ShopSettings.ValuationMethod.LIFO)
        self.receive(10, "3.00")
        self.receive(10, "5.00")
        movement = self.issue(5)
        self.assertEqual(movement.valuation_rate_applied, D("5"))
        self.assertEqual(self.bin().stock_value, D("55.000000"))

    def test_a_sale_straddling_two_prices_blends_them(self):
        self.set_method(ShopSettings.ValuationMethod.FIFO)
        self.receive(10, "3.00")
        self.receive(10, "5.00")
        movement = self.issue(15)
        # 10 at 3 plus 5 at 5 = 55 for 15 units.
        self.assertEqual(movement.valuation_rate_applied * 15, D("55"))

    def test_the_three_methods_disagree_on_the_same_history(self):
        """The point of the setting. If these ever agree, the method is being
        ignored somewhere between the shop settings and the ledger."""
        costs = {}
        for method in (
            ShopSettings.ValuationMethod.MOVING_AVERAGE,
            ShopSettings.ValuationMethod.FIFO,
            ShopSettings.ValuationMethod.LIFO,
        ):
            StockLedgerEntry.objects.all().delete()
            StockValuationBin.objects.all().delete()
            StockItem.objects.filter(variant=self.variant).update(
                quantity_on_hand=D("0")
            )
            self.set_method(method)
            self.receive(10, "3.00")
            self.receive(10, "5.00")
            costs[method] = self.issue(5).valuation_rate_applied
        self.assertEqual(costs[ShopSettings.ValuationMethod.FIFO], D("3"))
        self.assertEqual(costs[ShopSettings.ValuationMethod.MOVING_AVERAGE], D("4"))
        self.assertEqual(costs[ShopSettings.ValuationMethod.LIFO], D("5"))

    def test_an_unvalued_variant_falls_back_to_the_last_purchase_cost(self):
        """A product that has never been received through the ledger — the
        state every shop is in on the day this ships — still costs sensibly."""
        from apps.purchasing.models import PurchaseLine, PurchaseOrder, Supplier

        supplier = Supplier.objects.create(name="S")
        order = PurchaseOrder.objects.create(supplier=supplier)
        PurchaseLine.objects.create(
            purchase_order=order,
            variant=self.variant,
            quantity=D("5"),
            unit_cost=D("7.00"),
            unit_factor=D("1"),
        )
        costs = valuation_unit_costs([self.variant.pk])
        self.assertEqual(costs[self.variant.pk], D("7.00"))


class ReturnValuationTests(LedgerTestCase):
    def test_a_return_re_enters_at_the_cost_it_left_at(self):
        """Valuing a return at today's rate would book a profit or a loss on a
        sale that was simply undone."""
        self.set_method(ShopSettings.ValuationMethod.MOVING_AVERAGE)
        self.receive(10, "3.00")
        self.issue(10)
        self.receive(10, "9.00")
        self.move(
            StockMovement.Type.INCREASE,
            D("2"),
            unit_cost=D("3.00"),
            voucher_type=StockLedgerEntry.VoucherType.SALE_RETURN,
        )
        entry = self.entries()[-1]
        self.assertEqual(entry.voucher_type, StockLedgerEntry.VoucherType.SALE_RETURN)
        self.assertEqual(entry.valuation_rate, D("3.000000"))
        # 10 at 9 plus 2 at 3 = 96 across 12 units.
        self.assertEqual(self.bin().stock_value, D("96.000000"))


class LedgerIntegrityTests(LedgerTestCase):
    def test_the_bin_always_matches_the_last_entry(self):
        self.receive(10, "3.00")
        self.receive(6, "5.00")
        self.issue(4)
        self.receive(2, "7.00")
        self.issue(9)
        last = self.entries()[-1]
        self.assertEqual(self.bin().quantity, last.balance_quantity)
        self.assertEqual(self.bin().stock_value, last.balance_value)

    def test_the_ledger_balance_matches_stock_on_hand(self):
        """The ledger and the operational stock row are two accounts of the
        same shelf. If they disagree, one of them is lying."""
        self.receive(10, "3.00")
        self.receive(6, "5.00")
        self.issue(4)
        stock_item = StockItem.objects.get(variant=self.variant)
        self.assertEqual(self.bin().quantity, stock_item.quantity_on_hand)

    def test_value_is_conserved_across_the_whole_ledger(self):
        self.receive(10, "3.00")
        self.receive(6, "5.00")
        self.issue(4)
        self.issue(2)
        received = sum(
            e.value_change for e in self.entries() if e.quantity_change > 0
        )
        issued = sum(
            -e.value_change for e in self.entries() if e.quantity_change < 0
        )
        self.assertEqual(received - issued, self.bin().stock_value)

    def test_reposting_reproduces_the_same_state(self):
        self.receive(10, "3.00")
        self.receive(6, "5.00")
        self.issue(4)
        before = self.bin()
        quantity, rate, value, state = (
            before.quantity,
            before.valuation_rate,
            before.stock_value,
            load_state(before.state),
        )

        repost_variant(self.variant.pk)

        after = self.bin()
        self.assertEqual(after.quantity, quantity)
        self.assertEqual(after.valuation_rate, rate)
        self.assertEqual(after.stock_value, value)
        # Compared as numbers, not as the strings they are stored in: a repost
        # replays from the ledger's rate column, which is held to six decimals,
        # so it can spell an identical number differently from the live path.
        self.assertEqual(load_state(after.state), state)

    def test_reposting_is_idempotent(self):
        """Reposting twice must not drift: if replaying its own output changed
        the answer, every repost would move the numbers a little."""
        self.receive(10, "3.00")
        self.receive(7, "5.50")
        self.issue(4)
        repost_variant(self.variant.pk)
        once = self.bin()
        first = (once.quantity, once.valuation_rate, once.stock_value)
        repost_variant(self.variant.pk)
        twice = self.bin()
        self.assertEqual(
            (twice.quantity, twice.valuation_rate, twice.stock_value), first
        )

    def test_reposting_repairs_a_corrupted_bin(self):
        """The bin is a cache. Losing it must cost nothing but a repost."""
        self.receive(10, "3.00")
        self.receive(6, "5.00")
        self.issue(4)
        expected = self.bin().stock_value

        StockValuationBin.objects.filter(variant=self.variant).update(
            quantity=D("0"),
            valuation_rate=D("0"),
            stock_value=D("0"),
            state=[],
        )
        repost_variant(self.variant.pk)

        self.assertEqual(self.bin().stock_value, expected)

    def test_reposting_under_a_different_method_re_costs_history(self):
        """What the guarded settings change is actually guarding against."""
        self.set_method(ShopSettings.ValuationMethod.FIFO)
        self.receive(10, "3.00")
        self.receive(10, "5.00")
        self.issue(10)
        self.assertEqual(self.bin().stock_value, D("50.000000"))

        repost_variant(self.variant.pk, method=ShopSettings.ValuationMethod.LIFO)

        # Same history, same quantities, a different account of what was sold.
        self.assertEqual(self.bin().stock_value, D("30.000000"))

    def test_every_entry_lands_in_the_default_warehouse(self):
        """Multi-location is a later phase, but the column is carried from the
        first migration so that phase never has to re-migrate history."""
        self.receive(10, "3.00")
        self.issue(2)
        warehouse_id = Warehouse.default_id()
        for entry in self.entries():
            self.assertEqual(entry.warehouse_id, warehouse_id)


class NegativeStockTests(LedgerTestCase):
    def test_selling_into_negative_stock_keeps_the_last_known_cost(self):
        self.set_method(ShopSettings.ValuationMethod.MOVING_AVERAGE)
        self.receive(5, "4.00")
        self.issue(8)
        self.assertEqual(self.bin().quantity, D("-3.000"))
        self.assertEqual(self.bin().valuation_rate, D("4.000000"))

    def test_a_receipt_covering_the_shortfall_adopts_the_new_cost(self):
        self.set_method(ShopSettings.ValuationMethod.MOVING_AVERAGE)
        self.receive(5, "4.00")
        self.issue(8)
        self.receive(10, "6.00")
        self.assertEqual(self.bin().quantity, D("7.000"))
        self.assertEqual(self.bin().valuation_rate, D("6.000000"))
