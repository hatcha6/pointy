"""The payables list must agree with ``balance_due``, row for row.

``outstanding-received-not-paid`` no longer asks each order for the sum of its
own payments — that correlated subquery ran once per received order and was
581ms of database time at the field shop. It now selects the same set the
other way round: every billable received order, minus the ones a grouped pass
over the payments table shows as covered.

Two ways of saying the same thing can drift, and this one decides whether a
shop is told it still owes money. So the endpoint's membership is asserted
against the property that *defines* the answer — ``PurchaseOrder.balance_due``,
evaluated in Python — over the cases where the two formulations could disagree:
nothing paid, part paid, paid to the penny, overpaid, cancelled goods netted
off, and an order billable for nothing at all.

See ``apps/core/money_definitions.py`` for why a money figure gets exactly one
definition.
"""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from apps.core.roles import MANAGER_GROUP, ensure_role_groups
from apps.inventory.models import Warehouse

from .models import PurchaseOrder, Supplier, SupplierPayment


class PayablesMatchBalanceDueTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.client = APIClient()
        self.user = get_user_model().objects.create_user(username="m", password="p")
        self.user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client.force_authenticate(user=self.user)
        self.warehouse = Warehouse.objects.first() or Warehouse.objects.create(
            name="main"
        )
        self.supplier = Supplier.objects.create(name="مورد", phone="0910000000")

    def _order(self, *, total, cancelled="0.00", paid=None, status=None):
        order = PurchaseOrder.objects.create(
            warehouse=self.warehouse,
            supplier=self.supplier,
            status=status or PurchaseOrder.Status.RECEIVED,
            subtotal=Decimal(total),
            total=Decimal(total),
            cancelled_total=Decimal(cancelled),
        )
        for amount in paid or []:
            SupplierPayment.objects.create(
                purchase_order=order,
                supplier=self.supplier,
                amount=Decimal(amount),
                method="cash",
            )
        return order

    def _listed_ids(self):
        response = self.client.get(
            reverse("purchaseorder-outstanding-received-not-paid"),
            {"page_size": 200},
        )
        self.assertEqual(response.status_code, 200)
        return {row["id"] for row in response.data["results"]}

    def test_membership_matches_balance_due_over_every_payment_shape(self):
        cases = {
            "nothing paid": self._order(total="100.00"),
            "part paid": self._order(total="100.00", paid=["40.00"]),
            "part paid twice": self._order(total="100.00", paid=["40.00", "35.00"]),
            "paid to the penny": self._order(total="100.00", paid=["100.00"]),
            "paid in instalments": self._order(
                total="100.00", paid=["60.00", "40.00"]
            ),
            "overpaid": self._order(total="100.00", paid=["120.00"]),
            "short shipment, paid for what arrived": self._order(
                total="100.00", cancelled="30.00", paid=["70.00"]
            ),
            "short shipment, still owing": self._order(
                total="100.00", cancelled="30.00", paid=["50.00"]
            ),
            "wholly cancelled": self._order(total="100.00", cancelled="100.00"),
            "wholly cancelled but paid anyway": self._order(
                total="100.00", cancelled="100.00", paid=["10.00"]
            ),
            "zero-value order": self._order(total="0.00"),
        }
        listed = self._listed_ids()
        for label, order in cases.items():
            with self.subTest(label):
                order.refresh_from_db()
                self.assertEqual(
                    order.pk in listed,
                    order.balance_due > Decimal("0.00"),
                    f"{label}: listed={order.pk in listed} but "
                    f"balance_due={order.balance_due}",
                )

    def test_only_received_orders_are_payable(self):
        draft = self._order(total="100.00", status=PurchaseOrder.Status.DRAFT)
        cancelled = self._order(total="100.00", status=PurchaseOrder.Status.CANCELLED)
        received = self._order(total="100.00")
        listed = self._listed_ids()
        self.assertIn(received.pk, listed)
        self.assertNotIn(draft.pk, listed)
        self.assertNotIn(cancelled.pk, listed)

    def test_a_cancelled_payment_stops_counting_as_paid(self):
        order = self._order(total="100.00", paid=["100.00"])
        self.assertNotIn(order.pk, self._listed_ids())
        payment = order.supplier_payments.get()
        payment.doc_status = "cancelled"
        payment.save(update_fields=["doc_status"])
        order.refresh_from_db()
        self.assertEqual(order.balance_due, Decimal("100.00"))
        self.assertIn(order.pk, self._listed_ids())

    def test_a_supplier_payment_with_no_order_never_settles_one(self):
        order = self._order(total="100.00")
        SupplierPayment.objects.create(
            purchase_order=None,
            supplier=self.supplier,
            amount=Decimal("500.00"),
            method="cash",
        )
        self.assertIn(order.pk, self._listed_ids())


class PayablesPagingTests(TestCase):
    """The page is chosen without a ``COUNT(*)``; ``next`` carries the paging."""

    def setUp(self):
        ensure_role_groups()
        self.client = APIClient()
        user = get_user_model().objects.create_user(username="m", password="p")
        user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client.force_authenticate(user=user)
        warehouse = Warehouse.objects.first() or Warehouse.objects.create(name="main")
        supplier = Supplier.objects.create(name="مورد", phone="0910000000")
        PurchaseOrder.objects.bulk_create(
            [
                PurchaseOrder(
                    warehouse=warehouse,
                    supplier=supplier,
                    order_number=f"PG-{n:04d}",
                    status=PurchaseOrder.Status.RECEIVED,
                    subtotal=Decimal("10.00"),
                    total=Decimal("10.00"),
                )
                for n in range(7)
            ]
        )
        self.url = reverse("purchaseorder-outstanding-received-not-paid")

    def test_pages_walk_every_row_exactly_once(self):
        seen = []
        page = 1
        while True:
            response = self.client.get(self.url, {"page": page, "page_size": 3})
            self.assertEqual(response.status_code, 200)
            self.assertNotIn(
                "count",
                response.data,
                "the payables page must not pay for a total nobody reads",
            )
            seen.extend(row["id"] for row in response.data["results"])
            if response.data["next"] is None:
                break
            page += 1
            self.assertLess(page, 10, "paging did not terminate")
        self.assertEqual(len(seen), 7)
        self.assertEqual(len(set(seen)), 7)
        self.assertEqual(page, 3)

    def test_previous_link_returns_to_the_unnumbered_first_page(self):
        response = self.client.get(self.url, {"page": 2, "page_size": 3})
        self.assertIsNotNone(response.data["previous"])
        self.assertNotIn("page=", response.data["previous"])
        first = self.client.get(self.url, {"page": 1, "page_size": 3})
        self.assertIsNone(first.data["previous"])

    def test_a_page_past_the_end_is_empty_rather_than_an_error(self):
        response = self.client.get(self.url, {"page": 9, "page_size": 3})
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data["results"], [])
        self.assertIsNone(response.data["next"])

    def test_a_nonsense_page_is_rejected(self):
        self.assertEqual(self.client.get(self.url, {"page": "x"}).status_code, 404)
        self.assertEqual(self.client.get(self.url, {"page": 0}).status_code, 404)
