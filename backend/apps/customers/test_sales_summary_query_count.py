"""``customer-sales-summary`` folds its counts and sums into one pass per table.

The endpoint answers the customer screen's header and is the *response* of every
debt collection (``record_payment`` returns this payload), so its cost is paid at
the till. It used to ask thirteen separate questions of two tables — seven
``.count()``/``.aggregate()`` calls on ``sales_order`` and six on
``sales_orderadjustment`` — none of which grows with row count but all of which
is a round trip through PgBouncer.

Both tests must fail before the conditional-aggregation change: the count test on
the query total, the value test only if the folded filters disagree with the
querysets they replaced (it passes on ``main``, and is here so a future edit to
``transactional_sale_q`` cannot silently redefine what counts as a sale).
"""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.db import connection
from django.test.utils import CaptureQueriesContext
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APITestCase

from apps.catalog.testing import create_product_with_default_variant
from apps.core.roles import ensure_role_groups
from apps.customers.models import Customer
from apps.sales.models import (
    Order,
    OrderAdjustment,
    OrderLine,
    RegisterSession,
)


class CustomerSalesSummaryQueryCountTests(APITestCase):
    def setUp(self):
        groups = ensure_role_groups()
        self.user = get_user_model().objects.create_user(
            username="summary-manager",
            password="password",
        )
        self.user.groups.add(groups["manager"])
        self.client.force_authenticate(self.user)
        self.session = RegisterSession.objects.create(
            owner_key=f"user:{self.user.pk}",
            opening_cash=Decimal("0.00"),
        )
        self.customer = Customer.objects.create(full_name="Summary customer")
        product = create_product_with_default_variant(
            name="Summary product",
            sku="SUMMARY-1",
            unit_price="10.00",
        )
        self.variant = product.variants.get()
        self.url = reverse("customer-sales-summary", args=[self.customer.pk])

    def _order(self, *, status_value, sale_type, total):
        order = Order.objects.create(
            register_session=self.session,
            customer=self.customer,
            status=status_value,
            sale_type=sale_type,
            subtotal=Decimal(total),
            total=Decimal(total),
        )
        OrderLine.objects.create(
            order=order,
            variant=self.variant,
            quantity=Decimal("1"),
            unit_price=Decimal(total),
        )
        return order

    def _adjustment(self, order, *, adjustment_type, amount):
        return OrderAdjustment.objects.create(
            order=order,
            register_session=self.session,
            adjustment_type=adjustment_type,
            amount=Decimal(amount),
            created_by=self.user,
        )

    def _seed_every_order_shape(self):
        """One of each row the summary discriminates between.

        A summary built from a single conditional aggregate is only equivalent to
        the old per-filter queries if every branch is populated, so seed all of
        them: recognized sales, a void, an open debt invoice (which counts from
        issue), and a quotation (which never counts as a sale).
        """
        paid = self._order(
            status_value=Order.Status.PAID,
            sale_type=Order.SaleType.STANDARD,
            total="10.00",
        )
        voided = self._order(
            status_value=Order.Status.VOID,
            sale_type=Order.SaleType.STANDARD,
            total="4.00",
        )
        self._order(
            status_value=Order.Status.OPEN,
            sale_type=Order.SaleType.CREDIT,
            total="6.00",
        )
        self._order(
            status_value=Order.Status.OPEN,
            sale_type=Order.SaleType.QUOTATION,
            total="99.00",
        )
        self._adjustment(
            paid,
            adjustment_type=OrderAdjustment.AdjustmentType.RETURN,
            amount="2.50",
        )
        self._adjustment(
            voided,
            adjustment_type=OrderAdjustment.AdjustmentType.VOID,
            amount="4.00",
        )

    def _measure(self):
        # The first request warms the per-request caches (permissions, shop
        # settings); only the second reports the payload's own cost.
        self.client.get(self.url)
        with CaptureQueriesContext(connection) as context:
            response = self.client.get(self.url)
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        return len(context.captured_queries), response

    def _table_hits(self, table):
        """Statements whose *own* table is ``table``.

        Matched on ``FROM "<table>"`` rather than a bare substring: the
        adjustments aggregate joins ``sales_order`` to scope by customer, and
        counting that as a read of the orders table would hide the very
        difference this test exists to see.
        """
        with CaptureQueriesContext(connection) as context:
            self.client.get(self.url)
        return len(
            [q for q in context.captured_queries if f'FROM "{table}"' in q["sql"]]
        )

    def test_summary_reads_each_table_once(self):
        self._seed_every_order_shape()
        self.client.get(self.url)

        # Two reads of sales_order: the folded aggregate, plus the separate
        # open-debt pass whose balance is summed in Python (``Order.balance_due``
        # stays the single implementation of that arithmetic).
        self.assertEqual(self._table_hits("sales_order"), 2)
        self.assertEqual(self._table_hits("sales_orderadjustment"), 1)

    def test_summary_query_count_stays_flat_as_history_grows(self):
        self._seed_every_order_shape()
        small_count, _ = self._measure()
        for _ in range(5):
            self._seed_every_order_shape()
        large_count, _ = self._measure()

        self.assertEqual(small_count, large_count)
        # Was 18 before the aggregates were folded (13 of them counts and sums
        # over two tables); a regression here means a per-filter query came back.
        self.assertLessEqual(large_count, 8)

    def test_summary_values_cover_every_order_and_adjustment_shape(self):
        self._seed_every_order_shape()

        response = self.client.get(self.url)

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        data = response.data
        # paid + void + open credit are transactional; the quotation is not.
        self.assertEqual(data["invoice_count"], 3)
        self.assertEqual(data["paid_invoice_count"], 1)
        self.assertEqual(data["void_invoice_count"], 1)
        self.assertEqual(data["quotation_count"], 1)
        self.assertEqual(data["return_count"], 1)
        self.assertEqual(data["void_count"], 1)
        self.assertEqual(data["refund_count"], 2)
        self.assertEqual(data["total_invoiced"], "20.00")
        self.assertEqual(data["return_total"], "2.50")
        self.assertEqual(data["void_total"], "4.00")
        self.assertEqual(data["refund_total"], "6.50")
        self.assertEqual(data["net_sales"], "13.50")
        self.assertEqual(data["outstanding_balance"], "6.00")
        self.assertIsNotNone(data["last_invoice_at"])

    def test_summary_ignores_another_customer_history(self):
        self._seed_every_order_shape()
        other = Customer.objects.create(full_name="Other customer")
        Order.objects.create(
            register_session=self.session,
            customer=other,
            status=Order.Status.PAID,
            sale_type=Order.SaleType.STANDARD,
            subtotal=Decimal("50.00"),
            total=Decimal("50.00"),
        )

        response = self.client.get(self.url)

        self.assertEqual(response.data["invoice_count"], 3)
        self.assertEqual(response.data["total_invoiced"], "20.00")
