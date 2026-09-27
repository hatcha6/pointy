"""What a sale made is the owner's number, not the till's.

The invoices list printed a profit under every row, and a cashier's list is
their own sales: every cashier could read, sale by sale, what the shop makes on
what they sell, and the invoice behind the row itemised each line's cost. Cost
and profit now leave the order payload for everyone outside the reporting roles
on every surface that serializes an order — the list, the invoice, a drawer
session's strip, the returns-desk lookup and the checkout response. The clients
render profit only when it is present, the frozen Windows 7/8 till build
included, so taking it out of the payload is what hides it.
"""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group, Permission
from django.db import connection
from django.test import TestCase
from django.test.utils import CaptureQueriesContext
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient

from apps.catalog.testing import create_product_with_default_variant
from apps.core.roles import (
    ACCOUNTANT_GROUP,
    AUDITOR_GROUP,
    CASHIER_GROUP,
    MANAGER_GROUP,
    SUPERVISOR_GROUP,
    ensure_role_groups,
)
from apps.integrations.models import IntegrationAccount, IntegrationFulfillment
from apps.integrations.provisioning import service_variant_for

from .models import Order, OrderLine, RegisterSession
from .serializers import ORDER_LINE_MARGIN_FIELDS, ORDER_MARGIN_FIELDS
from .testing import issue

REPORTING_ROLES = (MANAGER_GROUP, SUPERVISOR_GROUP, ACCOUNTANT_GROUP, AUDITOR_GROUP)


class OrderMarginVisibilityTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.cashier, self.cashier_client = self._user("margin-cashier", CASHIER_GROUP)
        self.session = RegisterSession.objects.create(
            owner=self.cashier,
            owner_key=f"user:{self.cashier.pk}",
            opening_cash=Decimal("0.00"),
        )
        self.variant = create_product_with_default_variant(
            sku="MARGIN-1", name="سلعة", unit_price=Decimal("4.00")
        ).default_variant
        self.order = self._sale()

    def _user(self, username, role, *, extra=()):
        User = get_user_model()
        user = User.objects.create_user(username=username, password="p")
        user.groups.add(Group.objects.get(name=role))
        for codename in extra:
            user.user_permissions.add(Permission.objects.get(codename=codename))
        # Re-read, so has_perm() does not answer from a stale permission cache.
        user = User.objects.get(pk=user.pk)
        client = APIClient()
        client.force_authenticate(user=user)
        return user, client

    def _sale(self, session=None):
        """Two at 4.00 that cost the shop 1.50 each: 3.00 cost, 5.00 profit."""
        order = Order.objects.create(
            register_session=session or self.session,
            subtotal=Decimal("8.00"),
            total=Decimal("8.00"),
        )
        OrderLine.objects.create(
            order=order,
            variant=self.variant,
            quantity=2,
            unit_price=Decimal("4.00"),
            unit_cost=Decimal("1.50"),
        )
        return issue(order)

    def _surfaces(self, client):
        """Every payload the till reads this sale from: (name, order, lines)."""
        detail = client.get(reverse("order-detail", args=[self.order.pk]))
        listed = client.get(reverse("order-list"))
        strip = client.get(reverse("register-session-orders", args=[self.session.pk]))
        for response in (detail, listed, strip):
            self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        return [
            ("invoice", detail.data, detail.data["lines"]),
            ("invoices list", listed.data["results"][0], []),
            ("drawer session strip", strip.data["results"][0], []),
        ]

    def test_a_cashier_reads_no_cost_or_profit_on_their_own_sales(self):
        for name, order, lines in self._surfaces(self.cashier_client):
            with self.subTest(surface=name):
                self.assertEqual(order["id"], self.order.pk)
                self.assertEqual(order["total"], "8.00")
                for field in ORDER_MARGIN_FIELDS:
                    self.assertNotIn(field, order)
                for line in lines:
                    self.assertEqual(line["unit_price"], "4.00")
                    for field in ORDER_LINE_MARGIN_FIELDS:
                        self.assertNotIn(field, line)

    def test_every_reporting_role_reads_them(self):
        for role in REPORTING_ROLES:
            _, client = self._user(f"margin-{role}", role)
            for name, order, lines in self._surfaces(client):
                with self.subTest(role=role, surface=name):
                    self.assertEqual(order["total_cost"], "3.00")
                    self.assertEqual(order["total_profit"], "5.00")
                    for line in lines:
                        self.assertEqual(line["unit_cost"], "1.50")
                        self.assertEqual(line["line_cost"], "3.00")
                        self.assertEqual(line["line_profit"], "5.00")

    def test_the_returns_desk_reaches_another_tills_sale_without_them(self):
        # process_return_lookup is the one grant that shows a cashier a sale
        # they did not ring up. It is for taking goods back, not for pricing
        # the shop's margins.
        _, desk = self._user(
            "margin-desk", CASHIER_GROUP, extra=("process_return_lookup",)
        )

        response = desk.get(
            reverse("order-lookup"), {"receipt": self.order.receipt_number}
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.assertEqual(response.data["id"], self.order.pk)
        self.assertNotIn("total_profit", response.data)
        self.assertNotIn("unit_cost", response.data["lines"][0])

    def test_a_top_up_line_keeps_what_the_provider_charged_to_the_owner(self):
        account = IntegrationAccount.objects.create(
            provider="hdbox", base_url="http://provider.example", username="agent"
        )
        line = OrderLine.objects.create(
            order=self.order,
            variant=service_variant_for("hdbox"),
            quantity=1,
            unit_price=Decimal("30.00"),
            unit_cost=Decimal("25.00"),
        )
        IntegrationFulfillment.objects.create(
            order_line=line,
            account=account,
            provider="hdbox",
            subscriber_ref="7001",
            option_code="renew:1",
            cost=Decimal("25.00"),
        )
        _, manager = self._user("margin-owner", MANAGER_GROUP)

        def top_up(client):
            lines = client.get(reverse("order-detail", args=[self.order.pk])).data[
                "lines"
            ]
            return next(row for row in lines if row["id"] == line.pk)["integration"]

        cashier_view = top_up(self.cashier_client)
        self.assertEqual(cashier_view["subscriber_ref"], "7001")
        self.assertNotIn("cost", cashier_view)
        self.assertEqual(top_up(manager)["cost"], Decimal("25.00"))

    def test_asking_costs_the_same_however_many_sales_are_listed(self):
        # Whether the reader may see margins is a database question; it is
        # asked once per response, not once per row or per line.
        self.cashier_client.get(reverse("order-list"))
        with CaptureQueriesContext(connection) as few:
            self.cashier_client.get(reverse("order-list"))

        for _ in range(4):
            self._sale()
        with CaptureQueriesContext(connection) as more:
            response = self.cashier_client.get(reverse("order-list"))

        self.assertEqual(len(response.data["results"]), 5)
        self.assertEqual(len(few), len(more))
