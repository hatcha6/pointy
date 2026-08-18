"""The supplier accounting balances must not scale with the number of rows.

Serializing a supplier reads ``payable_balance``, ``credit_balance`` and
``net_balance``; before ``prime_supplier_balances`` each row cost 6 queries
(129 for 20 suppliers). These tests pin the batched cost flat AND assert the
batched arithmetic still matches the per-instance properties.
"""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.db import connection
from django.test import TestCase
from django.test.utils import CaptureQueriesContext
from django.urls import reverse
from rest_framework.test import APIClient

from apps.core.roles import MANAGER_GROUP, ensure_role_groups
from .models import (
    PurchaseOrder,
    PurchaseOrderAdjustment,
    Supplier,
    SupplierCredit,
    SupplierPayment,
)


class SupplierBalanceQueryScalingTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.client = APIClient()
        self.user = get_user_model().objects.create_user(
            username="supplier-manager",
            password="pass",
        )
        self.user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client.force_authenticate(user=self.user)

    def _seed_supplier(self, index):
        supplier = Supplier.objects.create(name=f"Supplier {index:03d}")
        order = PurchaseOrder.objects.create(
            supplier=supplier,
            status=PurchaseOrder.Status.RECEIVED,
            subtotal=Decimal("10.00"),
            total=Decimal("10.00"),
        )
        SupplierPayment.objects.create(
            supplier=supplier,
            purchase_order=order,
            amount=Decimal("3.00"),
            method=SupplierPayment.Method.CASH,
        )
        SupplierPayment.objects.create(
            supplier=supplier,
            amount=Decimal("1.00"),
            method=SupplierPayment.Method.CASH,
        )
        adjustment = PurchaseOrderAdjustment.objects.create(
            purchase_order=order,
            adjustment_type=PurchaseOrderAdjustment.AdjustmentType.RETURN,
            amount=Decimal("2.00"),
            settlement_method=PurchaseOrderAdjustment.SettlementMethod.SUPPLIER_CREDIT,
            reason="Returned units",
        )
        SupplierCredit.objects.create(
            supplier=supplier,
            purchase_order=order,
            adjustment=adjustment,
            amount=Decimal("2.00"),
            remaining_amount=Decimal("2.00"),
            reason="Returned units",
        )
        return supplier

    def _list_query_count(self, url):
        with CaptureQueriesContext(connection) as queries:
            response = self.client.get(url)
        self.assertEqual(response.status_code, 200)
        return len(queries)

    def test_supplier_list_query_count_does_not_grow_with_rows(self):
        url = reverse("supplier-list")
        baseline_rows = Supplier.objects.count()
        for index in range(2):
            self._seed_supplier(index)
        self.client.get(url)  # warm permission/settings caches
        small = self._list_query_count(url)

        for index in range(2, 12):
            self._seed_supplier(index)
        large = self._list_query_count(url)

        self.assertEqual(Supplier.objects.count(), baseline_rows + 12)
        self.assertEqual(
            large,
            small,
            f"supplier-list scaled with rows: {small} queries for 2, {large} for 12",
        )

    def test_batched_balances_match_the_per_instance_properties(self):
        expected = {}
        for index in range(3):
            supplier = self._seed_supplier(index)
            # Cold instance: the properties compute from the database.
            expected[supplier.pk] = (
                supplier.payable_balance,
                supplier.credit_balance,
                supplier.net_balance,
            )

        response = self.client.get(reverse("supplier-list"))

        self.assertEqual(response.status_code, 200)
        rows = [row for row in response.data["results"] if row["id"] in expected]
        self.assertEqual(len(rows), 3)
        for row in rows:
            payable, credit, net = expected[row["id"]]
            self.assertEqual(row["payable_balance"], str(payable))
            self.assertEqual(row["credit_balance"], str(credit))
            self.assertEqual(row["net_balance"], str(net))
