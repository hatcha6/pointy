"""The manual order-level purchase discount must reach the lines.

``PurchaseOrder.extra_discount_amount`` is a one-off discount typed on the
order itself. It has always been folded into ``discount_total`` and ``total``,
so the *money* was right — but it never touched the lines, so every per-line
cost figure derived from ``net_line_total`` kept quoting the pre-discount cost:

* ``net_unit_cost`` / ``effective_unit_cost`` — the cost basis a margin is
  measured against, and what the purchase-history screen charts over time;
* ``purchase_adjustment_line_amount`` — the credit claimed from the supplier
  when goods go back, which would exceed what was actually paid for them.

The load-bearing invariant, asserted below: the lines must add up to the order.
"""

from decimal import Decimal

from django.test import TestCase

from apps.catalog.testing import create_product_with_default_variant
from apps.discounts.models import DiscountRule

from .models import PurchaseOrder, PurchaseOrderLandedCostEntry, Supplier
from .services import (
    purchase_adjustment_line_amount,
    receive_purchase_order,
    submit_purchase_order,
)


class ExtraPurchaseDiscountReachesLinesTests(TestCase):
    def setUp(self):
        self.supplier = Supplier.objects.create(name="مورد")
        self.products = [
            create_product_with_default_variant(
                sku=f"EXTRA-{index}",
                barcode="",
                name=f"صنف {index}",
                unit_price=Decimal("15.00"),
            )
            for index in range(3)
        ]

    def _order(self, *, extra, landed=Decimal("0.00"), lines=None, method=None):
        order = PurchaseOrder.objects.create(
            supplier=self.supplier,
            extra_discount_amount=extra,
            landed_cost_allocation_method=(
                method or PurchaseOrder.LandedCostAllocationMethod.LINE_VALUE
            ),
        )
        if landed > Decimal("0.00"):
            PurchaseOrderLandedCostEntry.objects.create(
                purchase_order=order, name="شحن", amount=landed
            )
        for index, (quantity, unit_cost) in enumerate(
            lines or [(2, "10.00"), (2, "10.00")]
        ):
            order.lines.create(
                variant=self.products[index].default_variant,
                quantity=quantity,
                unit_cost=Decimal(unit_cost),
            )
        order.recalculate()
        order.save(
            update_fields=["subtotal", "discount_total", "total", "updated_at"]
        )
        order.refresh_from_db()
        return order, list(order.lines.order_by("created_at", "id"))

    def _receive_in_full(self, order):
        submit_purchase_order(order)
        order.refresh_from_db()
        receive_purchase_order(order)
        order.refresh_from_db()
        return list(order.lines.order_by("created_at", "id"))

    def assert_lines_add_up_to_order(self, order, lines):
        """sum(effective_line_total) == order.total, always."""
        self.assertEqual(
            sum((line.effective_line_total for line in lines), Decimal("0.00")),
            order.total,
        )
        self.assertEqual(
            sum((line.discount_amount for line in lines), Decimal("0.00")),
            order.discount_total,
        )
        self.assertEqual(
            sum((line.allocated_landed_cost for line in lines), Decimal("0.00")),
            order.landed_cost_total,
        )

    def test_extra_discount_lands_on_the_lines(self):
        order, lines = self._order(extra=Decimal("4.00"))

        self.assertEqual(order.subtotal, Decimal("40.00"))
        self.assertEqual(order.discount_total, Decimal("4.00"))
        self.assertEqual(order.total, Decimal("36.00"))
        # 4.00 split evenly over two equal 20.00 lines.
        self.assertEqual(
            [line.discount_amount for line in lines],
            [Decimal("2.00"), Decimal("2.00")],
        )
        self.assertEqual(
            [line.net_line_total for line in lines],
            [Decimal("18.00"), Decimal("18.00")],
        )
        self.assertEqual(
            [line.effective_unit_cost for line in lines],
            [Decimal("9.00"), Decimal("9.00")],
        )
        self.assert_lines_add_up_to_order(order, lines)

    def test_extra_discount_composes_with_landed_costs(self):
        order, lines = self._order(extra=Decimal("4.00"), landed=Decimal("6.00"))

        self.assertEqual(order.total, Decimal("42.00"))
        # 6.00 freight over two equal post-discount lines of 18.00.
        self.assertEqual(
            [line.allocated_landed_cost for line in lines],
            [Decimal("3.00"), Decimal("3.00")],
        )
        self.assertEqual(
            [line.effective_unit_cost for line in lines],
            [Decimal("10.50"), Decimal("10.50")],
        )
        self.assert_lines_add_up_to_order(order, lines)

    def test_extra_discount_composes_with_an_engine_discount(self):
        DiscountRule.objects.create(
            name="خصم مورد",
            channel=DiscountRule.Channel.PURCHASING,
            application_type=DiscountRule.ApplicationType.AUTOMATIC,
            scope=DiscountRule.Scope.DOCUMENT,
            value_type=DiscountRule.ValueType.PERCENTAGE,
            value=Decimal("10"),
            is_active=True,
        )
        order, lines = self._order(extra=Decimal("5.00"))

        self.assertEqual(order.subtotal, Decimal("40.00"))
        # 4.00 from the engine + the 5.00 manual discount.
        self.assertEqual(order.discount_total, Decimal("9.00"))
        self.assertEqual(order.total, Decimal("31.00"))
        self.assert_lines_add_up_to_order(order, lines)

    def test_indivisible_extra_discount_loses_no_cent(self):
        order, lines = self._order(
            extra=Decimal("0.05"),
            lines=[(1, "1.00"), (1, "1.00"), (1, "1.00")],
            method=PurchaseOrder.LandedCostAllocationMethod.QUANTITY,
        )

        self.assertEqual(order.total, Decimal("2.95"))
        self.assertEqual(
            [line.discount_amount for line in lines],
            [Decimal("0.02"), Decimal("0.02"), Decimal("0.01")],
        )
        self.assert_lines_add_up_to_order(order, lines)

    def test_extra_discount_is_clamped_to_the_subtotal(self):
        order, lines = self._order(extra=Decimal("500.00"))

        self.assertEqual(order.discount_total, Decimal("40.00"))
        self.assertEqual(order.total, Decimal("0.00"))
        self.assertEqual(
            [line.net_line_total for line in lines],
            [Decimal("0.00"), Decimal("0.00")],
        )
        self.assert_lines_add_up_to_order(order, lines)

    def test_supplier_credit_never_exceeds_what_was_paid(self):
        """Returning every unit must credit exactly the order total, not the
        pre-discount subtotal."""
        order, lines = self._order(extra=Decimal("4.00"))
        # Only received goods can be sent back, so the credit basis is only
        # meaningful once the order has actually arrived.
        lines = self._receive_in_full(order)

        credit = sum(
            (
                purchase_adjustment_line_amount(line, line.quantity)
                for line in lines
            ),
            Decimal("0.00"),
        )
        self.assertEqual(credit, order.total)
