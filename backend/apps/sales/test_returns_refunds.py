"""Returns, voids, exchanges and refund-correctness tests.

These exercise the service layer (apps.sales.services) directly so the focus is
on the money/stock invariants of returns and voids rather than on HTTP plumbing
(which apps/sales/tests.py already covers). New scenarios here:

* partial / full / double returns and the returnable-quantity accounting,
* over-return rejection on a first (non-stale) request,
* void-after-partial-return remaining-quantity refunds,
* double-void rejection,
* discount proportioning rounding across piecemeal returns,
* unit-factor (box) restock math,
* the split-tender refund regression (per-tender negative payments +
  ``cash_amount``), single-tender backward compatibility,
* an exchange modelled as a return + a fresh sale (non-atomic).
"""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from rest_framework import serializers

from apps.catalog.models import UnitOfMeasure
from apps.catalog.testing import create_product_with_default_variant
from apps.core.models import ShopSettings
from apps.core.roles import MANAGER_GROUP, ensure_role_groups
from apps.discounts.models import DiscountRule
from apps.inventory.models import StockItem, StockMovement
from apps.payments.models import Payment

from .models import Order, OrderAdjustment, OrderAdjustmentLine
from .services import checkout_order, return_order_items, void_order


class ReturnsRefundsTestCase(TestCase):
    """Shared fixtures: a manager (bypasses cashier-window checks), an open
    register session, and a single stocked product."""

    def setUp(self):
        ensure_role_groups()
        User = get_user_model()
        self.user = User.objects.create_user(username="returns-user", password="pass")
        self.user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        # Default shop settings; loss-prevention default would block a sale below
        # cost, so we keep unit_cost at 0 (no purchase history) throughout.
        ShopSettings.load()

        self.product = create_product_with_default_variant(
            name="Coffee",
            sku="COFFEE",
            unit_price="3.50",
            barcode="",
        )
        self.variant = self.product.default_variant
        self.stock = StockItem.objects.create(
            variant=self.variant,
            quantity_on_hand=Decimal("10"),
        )
        self.session = self._open_session()

    def _open_session(self):
        from .models import RegisterSession

        return RegisterSession.objects.create(
            owner=self.user,
            owner_key=f"user:{self.user.pk}",
        )

    def _checkout(self, *, quantity="2", payments=None, unit_factor=None, coupon=None):
        line = {"variant": self.variant, "quantity": Decimal(quantity)}
        if unit_factor is not None:
            line["unit_factor"] = Decimal(unit_factor)
            line["unit"] = "box"
        if payments is None:
            # Pay exactly the order total in cash. Price is per transacted unit
            # (a box's price is the variant price, 3.50); unit_factor only scales
            # stock and cost, not the line price.
            unit_price = Decimal("3.50")
            total = (unit_price * Decimal(quantity)).quantize(Decimal("0.01"))
            payments = [{"method": Payment.Method.CASH, "amount": total}]
        return checkout_order(
            register_session=self.session,
            lines_data=[line],
            payments_data=payments,
            coupon_codes=tuple(coupon or ()),
        )

    def _stock_qty(self):
        self.stock.refresh_from_db()
        return self.stock.quantity_on_hand

    # ------------------------------------------------------------------
    # 1. Partial return
    # ------------------------------------------------------------------
    def test_partial_return_refunds_unit_price_restocks_and_stays_paid(self):
        order = self._checkout(quantity="3")
        self.assertEqual(self._stock_qty(), Decimal("7"))
        line = order.lines.get()

        adjustment = return_order_items(
            order=order,
            lines=[(line, 1)],
            reason="One cup spilled",
        )

        order.refresh_from_db()
        line.refresh_from_db()
        self.assertEqual(order.status, Order.Status.PAID)
        self.assertEqual(adjustment.adjustment_type, OrderAdjustment.AdjustmentType.RETURN)
        # Refund is unit_price * returned qty = 3.50 * 1.
        self.assertEqual(adjustment.amount, Decimal("3.50"))
        self.assertEqual(line.returned_quantity, 1)
        self.assertEqual(line.returnable_quantity, 2)
        # Exactly the returned base quantity is restocked: 7 + 1 = 8.
        self.assertEqual(self._stock_qty(), Decimal("8"))

        increase = StockMovement.objects.get(movement_type=StockMovement.Type.INCREASE)
        self.assertEqual(increase.quantity, Decimal("1"))
        self.assertEqual(increase.variant, self.variant)

    # ------------------------------------------------------------------
    # 2. Full return of all lines flips order to VOID
    # ------------------------------------------------------------------
    def test_full_return_of_all_lines_marks_order_void(self):
        order = self._checkout(quantity="2")
        line = order.lines.get()

        return_order_items(order=order, lines=[(line, 2)], reason="All returned")

        order.refresh_from_db()
        line.refresh_from_db()
        self.assertEqual(order.status, Order.Status.VOID)
        self.assertEqual(line.returnable_quantity, 0)
        self.assertEqual(self._stock_qty(), Decimal("10"))
        # The full refund came back out: one negative cash payment of -7.00.
        negative = Payment.objects.filter(order=order, amount__lt=0).get()
        self.assertEqual(negative.amount, Decimal("-7.00"))

    # ------------------------------------------------------------------
    # 3. Over-return rejection on a FIRST request
    # ------------------------------------------------------------------
    def test_over_return_more_than_purchased_is_rejected_no_side_effects(self):
        order = self._checkout(quantity="2")
        line = order.lines.get()
        self.assertEqual(self._stock_qty(), Decimal("8"))

        with self.assertRaises(serializers.ValidationError):
            return_order_items(order=order, lines=[(line, 3)], reason="Too many")

        order.refresh_from_db()
        line.refresh_from_db()
        # Nothing recorded: no adjustment, no restock, order still PAID & full.
        self.assertEqual(OrderAdjustment.objects.count(), 0)
        self.assertEqual(line.returned_quantity, 0)
        self.assertEqual(self._stock_qty(), Decimal("8"))
        self.assertEqual(order.status, Order.Status.PAID)
        self.assertFalse(
            StockMovement.objects.filter(
                movement_type=StockMovement.Type.INCREASE
            ).exists()
        )
        self.assertFalse(Payment.objects.filter(amount__lt=0).exists())

    # ------------------------------------------------------------------
    # 4. Two partial returns cannot exceed total purchased
    # ------------------------------------------------------------------
    def test_two_partial_returns_cannot_exceed_total_purchased(self):
        order = self._checkout(quantity="3")
        line = order.lines.get()

        return_order_items(order=order, lines=[(line, 2)], reason="First two")
        self.assertEqual(self._stock_qty(), Decimal("9"))

        # Only 1 remains returnable; asking for 2 must fail.
        with self.assertRaises(serializers.ValidationError):
            return_order_items(order=order, lines=[(line, 2)], reason="Greedy second")

        # The legitimate remaining return still works.
        return_order_items(order=order, lines=[(line, 1)], reason="Last one")

        order.refresh_from_db()
        line.refresh_from_db()
        self.assertEqual(line.returned_quantity, 3)
        self.assertEqual(line.returnable_quantity, 0)
        self.assertEqual(self._stock_qty(), Decimal("10"))
        # Two successful adjustments (the failed one rolled back).
        self.assertEqual(
            OrderAdjustment.objects.filter(order=order).count(),
            2,
        )
        # Total refunded across both returns equals the order total.
        refunded = sum(
            adj.amount for adj in OrderAdjustment.objects.filter(order=order)
        )
        self.assertEqual(refunded, Decimal("10.50"))

    # ------------------------------------------------------------------
    # 5. Return line from a different order is rejected
    # ------------------------------------------------------------------
    def test_return_line_from_a_different_order_is_rejected(self):
        order_a = self._checkout(quantity="2")
        order_b = self._checkout(quantity="2")
        foreign_line = order_b.lines.get()

        with self.assertRaises(serializers.ValidationError):
            return_order_items(
                order=order_a,
                lines=[(foreign_line, 1)],
                reason="Wrong order line",
            )

        self.assertEqual(OrderAdjustment.objects.count(), 0)
        order_a.refresh_from_db()
        order_b.refresh_from_db()
        self.assertEqual(order_a.status, Order.Status.PAID)
        self.assertEqual(order_b.status, Order.Status.PAID)

    # ------------------------------------------------------------------
    # 6. Void after a partial return refunds only the remainder
    # ------------------------------------------------------------------
    def test_void_after_partial_return_refunds_only_remaining(self):
        order = self._checkout(quantity="3")  # total 10.50, stock -> 7
        line = order.lines.get()

        return_adj = return_order_items(
            order=order, lines=[(line, 1)], reason="Return one"
        )
        self.assertEqual(return_adj.amount, Decimal("3.50"))
        self.assertEqual(self._stock_qty(), Decimal("8"))

        void_adj = void_order(order=order, reason="Void the rest")

        order.refresh_from_db()
        line.refresh_from_db()
        self.assertEqual(order.status, Order.Status.VOID)
        self.assertEqual(void_adj.adjustment_type, OrderAdjustment.AdjustmentType.VOID)
        # Void refunds only the 2 remaining units = 7.00, and restocks only 2.
        self.assertEqual(void_adj.amount, Decimal("7.00"))
        self.assertEqual(line.returnable_quantity, 0)
        self.assertEqual(self._stock_qty(), Decimal("10"))
        # Return + void together refund exactly the original total.
        total_refunded = return_adj.amount + void_adj.amount
        self.assertEqual(total_refunded, Decimal("10.50"))
        # Two negative cash payments summing to -10.50.
        negatives = list(
            Payment.objects.filter(order=order, amount__lt=0).values_list(
                "amount", flat=True
            )
        )
        self.assertEqual(sum(negatives), Decimal("-10.50"))

    # ------------------------------------------------------------------
    # 7. Double void / void of an already-VOID order is rejected
    # ------------------------------------------------------------------
    def test_void_of_already_void_order_is_rejected(self):
        order = self._checkout(quantity="2")
        void_order(order=order, reason="First void")
        order.refresh_from_db()
        self.assertEqual(order.status, Order.Status.VOID)

        with self.assertRaises(serializers.ValidationError):
            void_order(order=order, reason="Second void")

        # Still exactly one adjustment and one negative payment.
        self.assertEqual(OrderAdjustment.objects.filter(order=order).count(), 1)
        self.assertEqual(
            Payment.objects.filter(order=order, amount__lt=0).count(),
            1,
        )
        self.assertEqual(self._stock_qty(), Decimal("10"))

    def test_void_after_full_return_is_rejected(self):
        # Fully returning flips the order to VOID; a subsequent void must fail
        # because there is nothing left to refund.
        order = self._checkout(quantity="2")
        line = order.lines.get()
        return_order_items(order=order, lines=[(line, 2)], reason="Full return")
        order.refresh_from_db()
        self.assertEqual(order.status, Order.Status.VOID)

        with self.assertRaises(serializers.ValidationError):
            void_order(order=order, reason="Void after full return")

        self.assertEqual(OrderAdjustment.objects.filter(order=order).count(), 1)

    # ------------------------------------------------------------------
    # 8. Discount proportioning rounding across piecemeal returns
    # ------------------------------------------------------------------
    def test_discount_refund_sums_exactly_across_piecemeal_returns(self):
        """A 1.00 fixed-amount discount on a qty-3 line does not divide evenly
        (1.00 / 3 = 0.333...). Returning the units one at a time must refund a
        discount sum equal to the line's full discount_total to the cent, with
        no lost or extra penny. Guards line_refund_discount rounding."""
        DiscountRule.objects.create(
            name="One dinar off",
            channel=DiscountRule.Channel.SALES,
            scope=DiscountRule.Scope.DOCUMENT,
            value_type=DiscountRule.ValueType.FIXED_AMOUNT,
            value=Decimal("1.00"),
        )
        # 3 * 3.50 = 10.50 subtotal, minus 1.00 discount = 9.50 total.
        order = self._checkout(
            quantity="3",
            payments=[{"method": Payment.Method.CASH, "amount": Decimal("9.50")}],
        )
        line = order.lines.get()
        self.assertEqual(line.discount_total, Decimal("1.00"))

        # Return 1 + 1 + 1.
        return_order_items(order=order, lines=[(line, 1)], reason="r1")
        return_order_items(order=order, lines=[(line, 1)], reason="r2")
        return_order_items(order=order, lines=[(line, 1)], reason="r3")

        line.refresh_from_db()
        # Every base unit went back to stock.
        self.assertEqual(self._stock_qty(), Decimal("10"))
        # Sum of the per-return adjustment-line discounts == line discount_total.
        refunded_discount = sum(
            adj_line.discount_total
            for adj_line in OrderAdjustmentLine.objects.filter(order_line=line)
        )
        self.assertEqual(refunded_discount, Decimal("1.00"))
        # And the total money refunded equals the line's net total (9.50).
        total_refunded = sum(
            adj.amount for adj in OrderAdjustment.objects.filter(order=order)
        )
        self.assertEqual(total_refunded, Decimal("9.50"))

    def test_discount_refund_three_returns_individual_amounts(self):
        # Pin the per-return discount split for the same rounding case to make
        # the largest-remainder behaviour explicit: 0.33 + 0.33 + 0.34 = 1.00.
        DiscountRule.objects.create(
            name="One dinar off again",
            channel=DiscountRule.Channel.SALES,
            scope=DiscountRule.Scope.DOCUMENT,
            value_type=DiscountRule.ValueType.FIXED_AMOUNT,
            value=Decimal("1.00"),
        )
        order = self._checkout(
            quantity="3",
            payments=[{"method": Payment.Method.CASH, "amount": Decimal("9.50")}],
        )
        line = order.lines.get()

        amounts = []
        for _ in range(3):
            adj = return_order_items(order=order, lines=[(line, 1)], reason="piece")
            amounts.append(adj.lines.get().discount_total)

        self.assertEqual(amounts, [Decimal("0.33"), Decimal("0.33"), Decimal("0.34")])
        self.assertEqual(sum(amounts), Decimal("1.00"))

    # ------------------------------------------------------------------
    # 9. Unit-factor return restocks quantity * unit_factor base units
    # ------------------------------------------------------------------
    def test_unit_factor_return_restocks_base_units(self):
        # Confirm the seeded "box" unit exists (do not create it).
        UnitOfMeasure.objects.get(code="box")
        # Sell 2 boxes of 12 = 24 base units; stock 10 - 24 = -14 (oversell ok).
        ShopSettings.objects.filter(pk=1).update(allow_overselling=True)
        order = self._checkout(quantity="2", unit_factor="12")
        self.assertEqual(self._stock_qty(), Decimal("-14"))
        line = order.lines.get()
        self.assertEqual(line.unit_factor, Decimal("12"))

        adjustment = return_order_items(
            order=order, lines=[(line, 1)], reason="One box back"
        )

        # One box back = 12 base units restocked: -14 + 12 = -2.
        self.assertEqual(self._stock_qty(), Decimal("-2"))
        increase = StockMovement.objects.get(movement_type=StockMovement.Type.INCREASE)
        self.assertEqual(increase.quantity, Decimal("12"))
        # Refund is unit_price (per box, = 3.50) * 1 box = 3.50.
        self.assertEqual(adjustment.amount, Decimal("3.50"))
        line.refresh_from_db()
        self.assertEqual(line.returnable_quantity, 1)

    # ------------------------------------------------------------------
    # 10. Split-tender refund regression
    # ------------------------------------------------------------------
    def test_split_tender_full_return_refunds_each_tender_once(self):
        """Recently fixed: a 4.00 cash + 3.00 card sale fully returned must
        produce ONE adjustment whose amount is 7.00 and cash_amount is 4.00,
        plus exactly two negative payments (-4.00 cash, -3.00 card). No
        fraud-count inflation (a single adjustment row)."""
        order = self._checkout(
            quantity="2",  # total 7.00
            payments=[
                {"method": Payment.Method.CASH, "amount": Decimal("4.00")},
                {"method": Payment.Method.CARD, "amount": Decimal("3.00")},
            ],
        )
        line = order.lines.get()

        adjustment = return_order_items(
            order=order, lines=[(line, 2)], reason="Full split return"
        )

        # Exactly ONE adjustment row exists.
        self.assertEqual(OrderAdjustment.objects.filter(order=order).count(), 1)
        self.assertEqual(adjustment.amount, Decimal("7.00"))
        # Only the cash share reduced the drawer.
        self.assertEqual(adjustment.cash_amount, Decimal("4.00"))

        # Two negative payments, one per original tender.
        negatives = {
            (p.method, p.amount)
            for p in Payment.objects.filter(order=order, amount__lt=0)
        }
        self.assertEqual(
            negatives,
            {
                (Payment.Method.CASH, Decimal("-4.00")),
                (Payment.Method.CARD, Decimal("-3.00")),
            },
        )
        # Both negative refunds reference this one adjustment.
        refs = set(
            Payment.objects.filter(order=order, amount__lt=0).values_list(
                "external_reference", flat=True
            )
        )
        self.assertEqual(refs, {f"return:{adjustment.pk}"})

    def test_card_only_full_return_has_zero_cash_amount(self):
        order = self._checkout(
            quantity="2",
            payments=[{"method": Payment.Method.CARD, "amount": Decimal("7.00")}],
        )
        line = order.lines.get()

        adjustment = return_order_items(
            order=order, lines=[(line, 2)], reason="Card refund"
        )

        # A card-only refund never touches the cash drawer.
        self.assertEqual(adjustment.amount, Decimal("7.00"))
        self.assertEqual(adjustment.cash_amount, Decimal("0.00"))
        self.assertEqual(adjustment.refund_method, Payment.Method.CARD)
        negative = Payment.objects.filter(order=order, amount__lt=0).get()
        self.assertEqual(negative.method, Payment.Method.CARD)
        self.assertEqual(negative.amount, Decimal("-7.00"))

    def test_split_tender_partial_return_splits_proportionally(self):
        # A 4.00 cash + 3.00 card sale (total 7.00 over 2 units). Returning a
        # single unit refunds 3.50, split across both tenders proportionally and
        # summing back to exactly 3.50.
        order = self._checkout(
            quantity="2",
            payments=[
                {"method": Payment.Method.CASH, "amount": Decimal("4.00")},
                {"method": Payment.Method.CARD, "amount": Decimal("3.00")},
            ],
        )
        line = order.lines.get()

        adjustment = return_order_items(
            order=order, lines=[(line, 1)], reason="Partial split"
        )

        self.assertEqual(adjustment.amount, Decimal("3.50"))
        negatives = list(
            Payment.objects.filter(order=order, amount__lt=0).values_list(
                "amount", flat=True
            )
        )
        # Per-tender amounts sum to exactly the refunded amount.
        self.assertEqual(sum(negatives), Decimal("-3.50"))
        # cash_amount equals the cash share that left the drawer.
        cash_share = -sum(
            p.amount
            for p in Payment.objects.filter(
                order=order, amount__lt=0, method=Payment.Method.CASH
            )
        )
        self.assertEqual(adjustment.cash_amount, cash_share)

    # ------------------------------------------------------------------
    # 11. Single-tender backward compatibility
    # ------------------------------------------------------------------
    def test_single_tender_cash_return_backward_compat(self):
        order = self._checkout(quantity="2")  # cash 7.00
        line = order.lines.get()

        adjustment = return_order_items(
            order=order, lines=[(line, 2)], reason="Cash refund"
        )

        self.assertEqual(adjustment.amount, Decimal("7.00"))
        # cash_amount mirrors amount for a cash-only sale.
        self.assertEqual(adjustment.cash_amount, Decimal("7.00"))
        self.assertEqual(adjustment.refund_method, Payment.Method.CASH)
        negatives = Payment.objects.filter(order=order, amount__lt=0)
        self.assertEqual(negatives.count(), 1)
        self.assertEqual(negatives.get().amount, Decimal("-7.00"))
        self.assertEqual(negatives.get().method, Payment.Method.CASH)

    # ------------------------------------------------------------------
    # 12. Exchange = return + new sale (non-atomic)
    # ------------------------------------------------------------------
    def test_exchange_is_return_plus_new_sale(self):
        """There is no atomic exchange endpoint. An exchange is modelled as a
        RETURN of the original item followed by a fresh SALE of the replacement.
        These are two independent transactions; this test asserts stock and
        money net out correctly across both."""
        replacement = create_product_with_default_variant(
            name="Tea",
            sku="TEA",
            unit_price="5.00",
            barcode="",
        )
        replacement_variant = replacement.default_variant
        replacement_stock = StockItem.objects.create(
            variant=replacement_variant,
            quantity_on_hand=Decimal("4"),
        )

        # Original sale: 1 coffee at 3.50.
        order = self._checkout(
            quantity="1",
            payments=[{"method": Payment.Method.CASH, "amount": Decimal("3.50")}],
        )
        self.assertEqual(self._stock_qty(), Decimal("9"))
        original_line = order.lines.get()

        # Step 1: return the coffee.
        refund = return_order_items(
            order=order, lines=[(original_line, 1)], reason="Exchange: return coffee"
        )
        order.refresh_from_db()
        self.assertEqual(order.status, Order.Status.VOID)  # fully returned
        self.assertEqual(refund.amount, Decimal("3.50"))
        self.assertEqual(self._stock_qty(), Decimal("10"))  # coffee restocked

        # Step 2: sell the replacement tea (a brand-new, separate order).
        new_order = checkout_order(
            register_session=self.session,
            lines_data=[{"variant": replacement_variant, "quantity": Decimal("1")}],
            payments_data=[{"method": Payment.Method.CASH, "amount": Decimal("5.00")}],
        )

        self.assertEqual(new_order.status, Order.Status.PAID)
        self.assertNotEqual(new_order.pk, order.pk)  # non-atomic: distinct orders
        replacement_stock.refresh_from_db()
        self.assertEqual(replacement_stock.quantity_on_hand, Decimal("3"))  # decremented

        # Money nets out: 3.50 refunded out, 5.00 collected in.
        refund_payment = Payment.objects.filter(order=order, amount__lt=0).get()
        self.assertEqual(refund_payment.amount, Decimal("-3.50"))
        new_payment = Payment.objects.filter(order=new_order, amount__gt=0).get()
        self.assertEqual(new_payment.amount, Decimal("5.00"))
