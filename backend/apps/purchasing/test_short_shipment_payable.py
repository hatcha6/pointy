"""A short shipment must stop billing for the goods that never arrived.

A receipt can close ordered units as ``cancelled_quantity`` — the supplier
could not supply them, or the shop rejected them at the door. Those units will
never arrive, and they can never be returned either (a supplier return credits
``adjustable_quantity``, which counts *accepted* units only), so an order that
keeps billing for them leaves a payable that no payment, credit or adjustment
can ever clear.

These tests pin every place the shop is told what it owes: the order itself,
the supplier's accounts payable in both of its implementations, the payables
list on the purchases screen, and the dashboard's due total. The last class
pins the other half of a receipt's promise — that it lands whole or not at
all — since the same function is where both live.
"""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.urls import reverse
from rest_framework import serializers as drf_serializers
from rest_framework.test import APIClient

from apps.catalog.testing import create_product_with_default_variant
from apps.core.roles import MANAGER_GROUP, ensure_role_groups
from apps.inventory.models import StockItem
from apps.purchasing.models import PurchaseOrder, Supplier, prime_supplier_balances
from apps.purchasing.services import (
    create_supplier_payment,
    receive_purchase_order,
    submit_purchase_order,
)


class ShortShipmentPayableTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.user = get_user_model().objects.create_user(
            username="buyer", password="pw", is_staff=True
        )
        self.user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client = APIClient()
        self.client.force_authenticate(self.user)
        self.supplier = Supplier.objects.create(name="Short Shipper")
        product = create_product_with_default_variant(
            name="Crate", sku="CRATE-1", unit_price=Decimal("25.00")
        )
        self.variant = product.variants.first()
        StockItem.objects.create(variant=self.variant, quantity_on_hand=0)

    def _received_short_order(self, *, ordered=10, accepted=4, unit_cost="10.00"):
        """Order ``ordered`` crates, take ``accepted``, cancel the rest."""
        order = PurchaseOrder.objects.create(supplier=self.supplier)
        line = order.lines.create(
            variant=self.variant,
            quantity=ordered,
            unit_cost=Decimal(unit_cost),
        )
        order.recalculate()
        order.save(update_fields=["subtotal", "discount_total", "total", "updated_at"])
        submit_purchase_order(order)
        receive_purchase_order(
            order,
            lines_data=[
                {
                    "line": line,
                    "accepted_quantity": accepted,
                    "damaged_quantity": 0,
                    "cancelled_quantity": ordered - accepted,
                }
            ],
        )
        order.refresh_from_db()
        return order, line

    def test_order_bills_only_for_the_goods_that_arrived(self):
        order, _line = self._received_short_order()

        # The document still records what was ordered...
        self.assertEqual(order.status, PurchaseOrder.Status.RECEIVED)
        self.assertEqual(order.total, Decimal("100.00"))
        # ...but only the four crates that turned up are billable.
        self.assertEqual(order.cancelled_total, Decimal("60.00"))
        self.assertEqual(order.billable_total, Decimal("40.00"))
        self.assertEqual(order.balance_due, Decimal("40.00"))

    def test_paying_for_what_arrived_settles_the_order(self):
        order, _line = self._received_short_order()

        create_supplier_payment(
            created_by=self.user,
            supplier=self.supplier,
            amount=Decimal("40.00"),
            method="cash",
            purchase_order=order,
        )
        order.refresh_from_db()

        self.assertEqual(order.balance_due, Decimal("0.00"))
        self.assertEqual(order.payment_status, "paid")
        # And the order cannot be made to swallow the phantom 60.00 on top.
        with self.assertRaises(drf_serializers.ValidationError):
            create_supplier_payment(
                created_by=self.user,
                supplier=self.supplier,
                amount=Decimal("60.00"),
                method="cash",
                purchase_order=order,
            )

    def test_supplier_payable_matches_in_both_implementations(self):
        self._received_short_order()

        cold = Supplier.objects.get(pk=self.supplier.pk)
        self.assertEqual(cold.payable_balance, Decimal("40.00"))
        # The bulk path that serializes supplier lists and reports is a second
        # port of the same number and has to agree with it.
        primed = prime_supplier_balances([Supplier.objects.get(pk=self.supplier.pk)])[0]
        self.assertEqual(primed.payable_balance, Decimal("40.00"))

    def test_settled_short_order_leaves_the_payables_list(self):
        order, _line = self._received_short_order()

        url = reverse("purchaseorder-outstanding-received-not-paid")
        listed = self.client.get(url).data["results"]
        self.assertEqual([row["id"] for row in listed], [order.pk])
        self.assertEqual(listed[0]["balance_due"], "40.00")

        create_supplier_payment(
            created_by=self.user,
            supplier=self.supplier,
            amount=Decimal("40.00"),
            method="cash",
            purchase_order=order,
        )

        # Previously this row was unclearable: the SQL filter compared the
        # ordered total against payments, so a fully settled short shipment sat
        # on the purchases screen forever.
        self.assertEqual(self.client.get(url).data["results"], [])

    def test_dashboard_due_total_agrees_with_the_order(self):
        from apps.core.dashboard.helpers import (
            _purchase_order_balance_due,
            _purchase_order_balance_rows,
        )

        order, _line = self._received_short_order()

        rows = list(_purchase_order_balance_rows(PurchaseOrder.objects.all()))
        self.assertEqual(len(rows), 1)
        self.assertEqual(_purchase_order_balance_due(rows[0]), order.balance_due)

    def test_a_wholly_cancelled_order_owes_nothing(self):
        order, _line = self._received_short_order(ordered=3, accepted=0)

        self.assertEqual(order.cancelled_total, order.total)
        self.assertEqual(order.balance_due, Decimal("0.00"))
        self.assertEqual(
            Supplier.objects.get(pk=self.supplier.pk).payable_balance,
            Decimal("0.00"),
        )

    def test_indivisible_line_value_is_credited_whole(self):
        """7.00 over 3 crates does not divide; cancelling all three must still
        take exactly 7.00 off, not 3 x 2.33."""
        order, _line = self._received_short_order(
            ordered=3, accepted=0, unit_cost="2.3333"
        )

        self.assertEqual(order.cancelled_total, order.total)
        self.assertEqual(order.balance_due, Decimal("0.00"))

    def test_partial_receipts_do_not_double_count_cancellations(self):
        order = PurchaseOrder.objects.create(supplier=self.supplier)
        line = order.lines.create(
            variant=self.variant, quantity=10, unit_cost=Decimal("10.00")
        )
        order.recalculate()
        order.save(update_fields=["subtotal", "discount_total", "total", "updated_at"])
        submit_purchase_order(order)

        for accepted, cancelled in ((2, 1), (3, 4)):
            receive_purchase_order(
                order,
                lines_data=[
                    {
                        "line": line,
                        "accepted_quantity": accepted,
                        "damaged_quantity": 0,
                        "cancelled_quantity": cancelled,
                    }
                ],
            )
        order.refresh_from_db()

        # 5 cancelled across two receipts, recomputed each time rather than
        # accumulated: 50.00, not 10.00 + 50.00.
        self.assertEqual(order.status, PurchaseOrder.Status.RECEIVED)
        self.assertEqual(order.cancelled_total, Decimal("50.00"))
        self.assertEqual(order.balance_due, Decimal("50.00"))


class ReceiptAtomicityTests(TestCase):
    """A receipt is one write or none of it.

    ``receive_purchase_order`` moves stock, writes receipt lines, retires the
    expected quantities and flips the order's status. Half of that is worse
    than none of it — stock that arrived with no receipt behind it, or an order
    that says ``received`` for goods it never recorded. Nothing in the suite
    forced a mid-receipt failure before, so the decorator that guarantees this
    could go missing without a single test noticing.
    """

    def setUp(self):
        self.supplier = Supplier.objects.create(name="Atomic")
        product = create_product_with_default_variant(
            name="Crate", sku="CRATE-2", unit_price=Decimal("25.00")
        )
        self.variant = product.variants.first()
        StockItem.objects.create(variant=self.variant, quantity_on_hand=0)

    def test_a_failure_part_way_through_leaves_nothing_behind(self):
        from unittest import mock

        from apps.inventory.models import StockMovement
        from apps.purchasing.models import PurchaseReceipt

        order = PurchaseOrder.objects.create(supplier=self.supplier)
        line = order.lines.create(
            variant=self.variant, quantity=6, unit_cost=Decimal("10.00")
        )
        order.recalculate()
        order.save(update_fields=["subtotal", "discount_total", "total", "updated_at"])
        submit_purchase_order(order)
        # Submitting already booked the expected-stock movement; only what the
        # *receipt* would write must disappear.
        movements_before = StockMovement.objects.filter(variant=self.variant).count()

        # The audit event is the last write of the receipt, so failing there
        # leaves every earlier write already made.
        with mock.patch(
            "apps.purchasing.services.record_purchase_order_audit_event",
            side_effect=RuntimeError("boom"),
        ):
            with self.assertRaises(RuntimeError):
                receive_purchase_order(
                    order,
                    lines_data=[
                        {
                            "line": line,
                            "accepted_quantity": 4,
                            "damaged_quantity": 0,
                            "cancelled_quantity": 2,
                        }
                    ],
                )

        order.refresh_from_db()
        self.assertEqual(order.status, PurchaseOrder.Status.SUBMITTED)
        self.assertEqual(order.cancelled_total, Decimal("0.00"))
        self.assertFalse(PurchaseReceipt.objects.filter(purchase_order=order).exists())
        self.assertEqual(
            StockMovement.objects.filter(variant=self.variant).count(),
            movements_before,
        )
        self.assertEqual(
            StockItem.objects.get(variant=self.variant).quantity_on_hand, 0
        )
