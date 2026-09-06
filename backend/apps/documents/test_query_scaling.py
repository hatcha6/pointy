"""What the lifecycle costs, held to a fixed number of queries.

Every regression guarded here has the same shape: a page or a path that is flat
while everything is live, and linear once something has been retracted. That is
the worst shape a performance bug can take, because the shop only meets it on
the day it voids a lot of sales — and a test that only ever looks at healthy
data will never see it.

The guards are written as comparisons rather than as magic numbers wherever the
question is really "does this scale", so they keep meaning something as the
paths around them change.
"""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.db import connection
from django.test import TestCase, override_settings
from django.test.utils import CaptureQueriesContext
from django.urls import reverse
from rest_framework.test import APIClient

from apps.catalog.testing import create_product_with_default_variant
from apps.core.roles import MANAGER_GROUP, ensure_role_groups
from apps.inventory.models import StockItem
from apps.purchasing.models import PurchaseOrder, Supplier
from apps.purchasing.services import cancel_purchase_order, submit_purchase_order
from apps.sales.models import Order, RegisterSession
from apps.sales.services import checkout_order, return_order_items, void_order


class _Request:
    """Enough of a request for the services that only read ``user`` off it."""

    def __init__(self, user):
        self.user = user
        self.query_params = {}
        self.data = {}


@override_settings(
    CACHES={"default": {"BACKEND": "django.core.cache.backends.locmem.LocMemCache"}}
)
class DocumentLifecycleQueryScalingTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.user = get_user_model().objects.create_user(username="m", password="p")
        self.user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.request = _Request(self.user)
        self.client = APIClient()
        self.client.force_authenticate(user=self.user)
        self.variants = []
        for index in range(6):
            product = create_product_with_default_variant(
                name=f"Widget {index}",
                sku=f"W{index}",
                barcode="",
                unit_price=Decimal("5.00"),
            )
            StockItem.objects.create(
                variant=product.default_variant,
                quantity_on_hand=Decimal("10000"),
            )
            self.variants.append(product.default_variant)
        self.session = RegisterSession.objects.create(
            owner=self.user,
            owner_key=f"user:{self.user.pk}",
            opening_cash=Decimal("0.00"),
        )
        self.supplier = Supplier.objects.create(name="Supplier")

    # -- helpers ---------------------------------------------------------

    def _sell(self, lines=1):
        return checkout_order(
            register_session=self.session,
            lines_data=[
                {"variant": self.variants[index], "quantity": Decimal("1")}
                for index in range(lines)
            ],
            payments_data=[{"method": "cash", "amount": Decimal("5.00") * lines}],
        )

    def _get(self, url):
        # Warm permissions / content types / settings singletons first, or the
        # first request's fixed overhead lands on the smaller measurement.
        self.client.get(url)
        with CaptureQueriesContext(connection) as ctx:
            response = self.client.get(url)
        self.assertEqual(response.status_code, 200)
        return len(ctx)

    def _reads_of(self, table, work):
        with CaptureQueriesContext(connection) as ctx:
            work()
        return sum(
            1
            for query in ctx.captured_queries
            if query["sql"].startswith("SELECT") and f'"{table}"' in query["sql"]
        )

    def _submitted_purchase_order(self, lines):
        order = PurchaseOrder.objects.create(supplier=self.supplier)
        for index in range(lines):
            order.lines.create(
                variant=self.variants[index],
                quantity=2,
                unit_cost=Decimal("1.00"),
            )
        order.recalculate()
        order.save(update_fields=["subtotal", "total", "updated_at"])
        submit_purchase_order(order, request=self.request)
        return PurchaseOrder.objects.get(pk=order.pk)

    # -- the lists -------------------------------------------------------

    def test_invoices_list_stays_flat_once_sales_are_voided(self):
        """``cancelled_by_username`` traverses an FK, so a page of voided sales
        cost a query per row until the queryset loaded it."""
        for _ in range(10):
            self._sell()
        url = reverse("order-list")
        live = self._get(url)

        for order in list(Order.objects.filter(status=Order.Status.PAID)):
            void_order(
                order=order,
                reason="wrong customer",
                request=self.request,
                register_session=self.session,
            )
        voided = self._get(url)

        print(f"\n[invoices] 10 live: {live} queries; 10 voided: {voided} queries")
        self.assertEqual(
            live,
            voided,
            "the invoices list scales with the number of voided sales",
        )

    def test_register_session_strip_stays_flat_once_sales_are_voided(self):
        for _ in range(10):
            self._sell()
        url = reverse("register-session-orders", args=[self.session.pk])
        live = self._get(url)

        for order in list(Order.objects.filter(status=Order.Status.PAID)):
            void_order(
                order=order,
                reason="wrong customer",
                request=self.request,
                register_session=self.session,
            )
        voided = self._get(url)

        self.assertEqual(
            live,
            voided,
            "the register-session strip scales with the number of voided sales",
        )

    def test_purchase_order_details_cost_the_same_once_cancelled(self):
        order = self._submitted_purchase_order(lines=3)
        url = reverse("purchaseorder-detail", args=[order.pk])
        live = self._get(url)

        cancel_purchase_order(order, reason="duplicate", request=self.request)
        cancelled = self._get(url)

        self.assertEqual(
            live,
            cancelled,
            "a cancelled purchase order costs an extra query to read",
        )

    # -- the transitions -------------------------------------------------

    def test_voiding_reads_the_adjustment_lines_once(self):
        """``lock_order_lines_for_update`` already reads and locks every
        adjustment line; nothing downstream should read them again per line."""
        one = self._reads_of(
            "sales_orderadjustmentline",
            lambda: void_order(
                order=self._sell(1),
                reason="x",
                request=self.request,
                register_session=self.session,
            ),
        )
        six = self._reads_of(
            "sales_orderadjustmentline",
            lambda: void_order(
                order=self._sell(6),
                reason="x",
                request=self.request,
                register_session=self.session,
            ),
        )

        print(f"\n[void] adjustment-line reads — 1 line: {one}; 6 lines: {six}")
        self.assertEqual(
            one, six, "voiding re-reads a sale's adjustment lines per line"
        )

    def test_returning_recomputes_progress_without_a_query_per_line(self):
        """``progress_status`` asks whether every line has come back, which
        reads ``adjustment_lines`` for each one."""

        def do_return(lines):
            order = self._sell(lines)
            rows = [(line, 1) for line in order.lines.all()[: lines - 1 or 1]]
            return lambda: return_order_items(
                order=order,
                lines=rows,
                reason="x",
                request=self.request,
                register_session=self.session,
            )

        one = self._reads_of("sales_orderadjustmentline", do_return(1))
        six = self._reads_of("sales_orderadjustmentline", do_return(6))

        print(f"\n[return] adjustment-line reads — 1 line: {one}; 6 lines: {six}")
        self.assertEqual(
            one, six, "a return re-reads adjustment lines per line of the sale"
        )

    def test_cancelling_a_purchase_order_is_flat_in_its_lines(self):
        def cancel(lines):
            order = self._submitted_purchase_order(lines)
            with CaptureQueriesContext(connection) as ctx:
                cancel_purchase_order(order, reason="x", request=self.request)
            return len(ctx)

        one, six = cancel(1), cancel(6)
        print(f"\n[po-cancel] 1 line: {one} queries; 6 lines: {six} queries")
        self.assertEqual(
            one, six, "cancelling a purchase order scales with its line count"
        )
