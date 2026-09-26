"""A supplier return can only credit back the goods that actually arrived.

``purchase_adjustment_line_amount`` decides what the supplier owes when stock
goes back. Its "these are the last units" branch used to hand back
``net_line_total`` — the discounted value of the whole **ordered** line — while
the units it is allowed to send back (``adjustable_quantity``) are only the
**accepted** ones. On a line ordered 10 and received 4, returning those 4
claimed the full ten units' worth: a 100.00 supplier credit for 40.00 of goods.

The invariant asserted here: every credit this line can ever produce adds up to
the value of the units that arrived, never the value of the units ordered.
"""

from decimal import Decimal

from django.test import TestCase

from apps.catalog.testing import create_product_with_default_variant

from .models import (
    PurchaseOrder,
    PurchaseOrderAdjustment,
    Supplier,
    SupplierCredit,
)
from .services import (
    adjust_purchase_order_items,
    purchase_adjustment_line_amount,
    purchase_adjustment_line_unit_cost,
    receive_purchase_order,
    submit_purchase_order,
)

UNIT_COST = Decimal("10.00")


class AdjustmentReturnableBasisTests(TestCase):
    def setUp(self):
        self.supplier = Supplier.objects.create(name="مورد")

    def _received_line(
        self,
        *,
        sku,
        ordered,
        accepted,
        damaged=0,
        cancelled=0,
        over_receipt=0,
        extra_discount=Decimal("0.00"),
        unit_cost=UNIT_COST,
    ):
        product = create_product_with_default_variant(
            sku=sku, barcode="", name=f"صنف {sku}", unit_price=Decimal("25.00")
        )
        order = PurchaseOrder.objects.create(
            supplier=self.supplier, extra_discount_amount=extra_discount
        )
        order.lines.create(
            variant=product.default_variant, quantity=ordered, unit_cost=unit_cost
        )
        order.recalculate()
        order.save()
        submit_purchase_order(order)
        order.refresh_from_db()
        return self._receive(
            order,
            accepted=accepted,
            damaged=damaged,
            cancelled=cancelled,
            over_receipt=over_receipt,
        )

    def _receive(self, order, *, accepted, damaged=0, cancelled=0, over_receipt=0):
        receive_purchase_order(
            order,
            lines_data=[
                {
                    "line": order.lines.first(),
                    "accepted_quantity": accepted,
                    "damaged_quantity": damaged,
                    "cancelled_quantity": cancelled,
                    "allowed_over_receipt_quantity": over_receipt,
                }
            ],
        )
        order.refresh_from_db()
        return order, order.lines.first()

    def _return_all(self, order, line, *, settlement=""):
        return adjust_purchase_order_items(
            purchase_order=order,
            adjustment_type=PurchaseOrderAdjustment.AdjustmentType.RETURN,
            lines=[(line, line.adjustable_quantity)],
            reason="تالف",
            settlement_method=settlement,
        )

    def test_partially_received_line_credits_only_what_arrived(self):
        order, line = self._received_line(sku="PARTIAL", ordered=10, accepted=4)

        self.assertEqual(order.status, PurchaseOrder.Status.PARTIALLY_RECEIVED)
        self.assertEqual(line.adjustable_quantity, Decimal("4"))
        self.assertEqual(
            purchase_adjustment_line_amount(line, Decimal("4")), Decimal("40.00")
        )
        self.assertEqual(
            purchase_adjustment_line_unit_cost(line, Decimal("4")), UNIT_COST
        )

    def test_short_shipment_closed_by_cancellation_credits_only_what_arrived(self):
        order, line = self._received_line(
            sku="CANCEL", ordered=10, accepted=4, cancelled=6
        )

        self.assertEqual(order.status, PurchaseOrder.Status.RECEIVED)
        self.assertEqual(
            purchase_adjustment_line_amount(line, Decimal("4")), Decimal("40.00")
        )

    def test_damaged_units_are_not_returnable_and_not_creditable(self):
        # Damaged goods never became sellable stock, so they are outside
        # ``adjustable_quantity`` — and outside the credit ceiling with it.
        order, line = self._received_line(
            sku="DAMAGED", ordered=10, accepted=4, damaged=3, cancelled=3
        )

        self.assertEqual(line.adjustable_quantity, Decimal("4"))
        self.assertEqual(
            purchase_adjustment_line_amount(line, Decimal("4")), Decimal("40.00")
        )

    def test_fully_received_line_is_unchanged(self):
        order, line = self._received_line(sku="FULL", ordered=10, accepted=10)

        self.assertEqual(
            purchase_adjustment_line_amount(line, Decimal("10")), line.net_line_total
        )
        self.assertEqual(
            purchase_adjustment_line_amount(line, Decimal("10")), Decimal("100.00")
        )

    def test_over_receipt_stays_capped_at_the_ordered_line_value(self):
        # The order never billed for the surplus units, so it must not credit
        # for them either.
        order, line = self._received_line(
            sku="OVER", ordered=10, accepted=12, over_receipt=2
        )

        self.assertEqual(line.adjustable_quantity, Decimal("12"))
        self.assertEqual(
            purchase_adjustment_line_amount(line, Decimal("12")), Decimal("100.00")
        )

    def test_repeated_partial_returns_add_up_to_the_arrived_value(self):
        # 3 ordered at 10.00 with 1.00 knocked off the order => 29.00 net;
        # 2 arrived => 19.33 is everything the supplier can ever owe back.
        order, line = self._received_line(
            sku="SPLIT",
            ordered=3,
            accepted=2,
            cancelled=1,
            extra_discount=Decimal("1.00"),
        )
        self.assertEqual(line.net_line_total, Decimal("29.00"))
        arrived_value = Decimal("19.33")

        first = purchase_adjustment_line_amount(line, Decimal("1"))
        self.assertEqual(first, Decimal("9.67"))
        adjust_purchase_order_items(
            purchase_order=order,
            adjustment_type=PurchaseOrderAdjustment.AdjustmentType.RETURN,
            lines=[(line, Decimal("1"))],
            reason="تالف",
        )

        line.refresh_from_db()
        second = purchase_adjustment_line_amount(line, Decimal("1"))
        self.assertEqual(first + second, arrived_value)

    def test_supplier_credit_matches_the_goods_that_went_back(self):
        order, line = self._received_line(
            sku="CREDIT", ordered=10, accepted=4, cancelled=6
        )
        self._return_all(
            order,
            line,
            settlement=PurchaseOrderAdjustment.SettlementMethod.SUPPLIER_CREDIT,
        )

        credit = SupplierCredit.objects.get(purchase_order=order)
        self.assertEqual(credit.amount, Decimal("40.00"))
        self.assertEqual(credit.remaining_amount, Decimal("40.00"))
        self.supplier.refresh_from_db()
        self.assertEqual(self.supplier.credit_balance, Decimal("40.00"))

    def test_adjustment_line_unit_cost_is_the_real_cost(self):
        # An exchange with no explicit replacement prices values the incoming
        # replacements at this unit cost, so an inflated credit also walked
        # inflated stock back into the warehouse.
        order, line = self._received_line(
            sku="EXCHANGE", ordered=10, accepted=4, cancelled=6
        )
        adjustment = self._return_all(order, line)

        self.assertEqual(adjustment.outbound_amount, Decimal("40.00"))
        self.assertEqual(adjustment.lines.get().unit_cost, UNIT_COST)

    # -- over-shipments -------------------------------------------------
    #
    # ``purchase_adjustable_line_value`` caps an over-received line's
    # returnable value at what the order billed — the surplus units were never
    # paid for. But the *partial* return branch spread ``net_line_total`` over
    # the **ordered** count while charging it against the **arrived** count, so
    # each arrived unit was priced above its share and a partial return sailed
    # straight past the cap. Ordering 10 at 10.00, taking 12, and sending 11
    # back credited 110.00 against a line the shop was billed 100.00 for.
    #
    # The invariant: no return may credit more than the line's returnable
    # value, and every return added together must land on it exactly.

    def _over_received(self, sku):
        # Ordered 10 at 10.00 = 100.00 billed; the supplier shipped 12.
        return self._received_line(sku=sku, ordered=10, accepted=12, over_receipt=2)

    def test_partial_return_of_an_over_shipment_stays_within_what_was_billed(self):
        order, line = self._over_received("OVERPART")

        self.assertEqual(line.adjustable_quantity, Decimal("12"))
        amount = purchase_adjustment_line_amount(line, Decimal("11"))

        self.assertLessEqual(amount, Decimal("100.00"))
        # 100.00 spread over the twelve units that actually arrived.
        self.assertEqual(amount, Decimal("91.67"))
        self.assertEqual(
            purchase_adjustment_line_unit_cost(line, Decimal("11")), Decimal("8.33")
        )

    def test_returns_of_an_over_shipment_add_up_to_the_billed_value(self):
        order, line = self._over_received("OVERSUM")

        adjust_purchase_order_items(
            purchase_order=order,
            adjustment_type=PurchaseOrderAdjustment.AdjustmentType.RETURN,
            lines=[(line, Decimal("11"))],
            reason="تالف",
            settlement_method=PurchaseOrderAdjustment.SettlementMethod.SUPPLIER_CREDIT,
        )
        line.refresh_from_db()

        # The twelfth unit is still returnable, and for a positive amount --
        # the old arithmetic had already over-claimed by 10.00, leaving -10.00
        # here, which the service rejects outright as a non-positive adjustment.
        self.assertEqual(line.adjustable_quantity, Decimal("1"))
        last = purchase_adjustment_line_amount(line, Decimal("1"))
        self.assertEqual(last, Decimal("8.33"))

        adjust_purchase_order_items(
            purchase_order=order,
            adjustment_type=PurchaseOrderAdjustment.AdjustmentType.RETURN,
            lines=[(line, Decimal("1"))],
            reason="تالف",
            settlement_method=PurchaseOrderAdjustment.SettlementMethod.SUPPLIER_CREDIT,
        )

        self.supplier.refresh_from_db()
        self.assertEqual(self.supplier.credit_balance, Decimal("100.00"))

    def test_whole_over_shipment_returned_at_once_is_unchanged(self):
        # The ceiling branch was already right; this pins that the fix to the
        # proportional branch left it alone.
        order, line = self._over_received("OVERWHOLE")

        self.assertEqual(
            purchase_adjustment_line_amount(line, Decimal("12")), Decimal("100.00")
        )

    def test_short_shipment_still_credits_per_ordered_unit(self):
        # No over-receipt: the span stays the ordered count, so each of the ten
        # units is worth a tenth of the line whether it arrived or not.
        order, line = self._received_line(sku="UNDER", ordered=10, accepted=4)

        self.assertEqual(
            purchase_adjustment_line_amount(line, Decimal("3")), Decimal("30.00")
        )

    # -- returns either side of an over-shipment -------------------------
    #
    # The fix above read the larger count at the moment of each return, and one
    # line can be short first and over-shipped later. Units sent back while it
    # was short went at a tenth of the line apiece; once the surplus landed the
    # rest were priced at a twelfth, with no look at what had already been
    # credited, so a partial return passed the ceiling again. The
    # business-simulation oracle found it: ordered 34, the 29 that arrived went
    # back, 7 more came (2 of them surplus), and returning 6 of those put
    # 108.40 of credit on a line billed 106.31.

    def _return(self, order, quantity):
        return adjust_purchase_order_items(
            purchase_order=order,
            adjustment_type=PurchaseOrderAdjustment.AdjustmentType.RETURN,
            lines=[(order.lines.get(), Decimal(quantity))],
            reason="تالف",
            settlement_method=PurchaseOrderAdjustment.SettlementMethod.SUPPLIER_CREDIT,
        )

    def test_return_made_before_an_over_shipment_stays_within_what_was_billed(self):
        # Ordered 10 at 10.00 = 100.00 billed. 8 arrive, and all 8 go back.
        order, _ = self._received_line(sku="EARLY", ordered=10, accepted=8)
        credited = self._return(order, 8).outbound_amount
        self.assertEqual(credited, Decimal("80.00"))

        # The last 2 ordered arrive with 2 the order never asked for: 4 are on
        # hand, and 20.00 is all the supplier can still owe for them.
        order, line = self._receive(order, accepted=4, over_receipt=2)
        self.assertEqual(line.adjustable_quantity, Decimal("4"))

        # A twelfth of the line apiece is 25.00 for three of them: 105.00 in all.
        credited += self._return(order, 3).outbound_amount
        self.assertLessEqual(credited, Decimal("100.00"))

        # The fourth still goes back for a positive amount — past the ceiling
        # it was priced below zero and refused — and the returns settle at
        # exactly what the order billed.
        credited += self._return(order, 1).outbound_amount
        self.assertEqual(credited, Decimal("100.00"))
        self.supplier.refresh_from_db()
        self.assertEqual(self.supplier.credit_balance, Decimal("100.00"))

    def test_short_then_over_shipped_line_credits_exactly_what_it_billed(self):
        # The oracle's line: 34 ordered at 3.13 less 0.11 off the order, 106.31.
        order, line = self._received_line(
            sku="SHORTOVER",
            ordered=34,
            accepted=24,
            unit_cost=Decimal("3.13"),
            extra_discount=Decimal("0.11"),
        )
        self.assertEqual(line.net_line_total, Decimal("106.31"))
        order, _ = self._receive(order, accepted=5)
        self.assertEqual(self._return(order, 29).outbound_amount, Decimal("90.68"))
        order, _ = self._receive(order, accepted=7, over_receipt=2)

        # What is left, 15.63, shared by the 7 still on hand. A thirty-sixth of
        # the line apiece was 17.72 here.
        partial = self._return(order, 6).outbound_amount
        self.assertEqual(partial, Decimal("13.40"))
        last = self._return(order, 1).outbound_amount
        self.assertEqual(last, Decimal("2.23"))
        self.assertEqual(Decimal("90.68") + partial + last, Decimal("106.31"))
