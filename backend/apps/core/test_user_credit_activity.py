"""A cashier's credit (آجل) invoices, read apart from their cash sales.

The profile listed one "recent sales" run, newest first, and a debt invoice
looked exactly like a settled one in it — so answering "what has this person
left on tab?" meant picking آجل rows out of a column of cash sales by eye, then
opening each to see what was still owed.

The two lists are disjoint: an invoice appears under exactly one of them, which
is the whole point of splitting them. The summary carries the totals, because
five rows of a cashier with forty open tabs is a truncation the screen must not
present as the whole answer.
"""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.db import connection
from django.test import TestCase, override_settings
from django.test.utils import CaptureQueriesContext
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient

from apps.core.roles import CASHIER_GROUP, MANAGER_GROUP, ensure_role_groups
from apps.payments.models import Payment
from apps.sales.models import Order, RegisterSession


@override_settings(
    CACHES={"default": {"BACKEND": "django.core.cache.backends.locmem.LocMemCache"}}
)
class UserCreditActivityTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        User = get_user_model()
        self.manager = User.objects.create_user(username="credit-manager", password="p")
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client = APIClient()
        self.client.force_authenticate(user=self.manager)

        self.cashier = User.objects.create_user(username="credit-cashier", password="p")
        self.cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.session = RegisterSession.objects.create(
            owner=self.cashier,
            owner_key=f"user:{self.cashier.pk}",
            status=RegisterSession.Status.CLOSED,
            opening_cash=Decimal("0.00"),
            closed_at=None,
        )

    def _order(self, *, sale_type, order_status, total, paid=Decimal("0.00")):
        order = Order.objects.create(
            register_session=self.session,
            status=order_status,
            sale_type=sale_type,
            subtotal=total,
            total=total,
        )
        if paid:
            Payment.objects.create(
                order=order,
                register_session=self.session,
                method=Payment.Method.CASH,
                amount=paid,
            )
        return order

    def _activity(self):
        response = self.client.get(
            reverse("pos-user-activity", args=[self.cashier.pk])
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        return response.data

    def test_credit_invoices_are_listed_apart_from_cash_sales(self):
        cash = self._order(
            sale_type=Order.SaleType.STANDARD,
            order_status=Order.Status.PAID,
            total=Decimal("25.00"),
            paid=Decimal("25.00"),
        )
        credit = self._order(
            sale_type=Order.SaleType.CREDIT,
            order_status=Order.Status.OPEN,
            total=Decimal("40.00"),
        )

        data = self._activity()

        self.assertEqual([row["id"] for row in data["recent_sales"]], [cash.pk])
        self.assertEqual(
            [row["id"] for row in data["recent_credit_sales"]], [credit.pk]
        )

    def test_a_credit_invoice_is_never_in_both_lists(self):
        # "Separately, instead of inside" — a debt counted twice on one screen
        # is a shop double-counting what it is owed.
        credit = self._order(
            sale_type=Order.SaleType.CREDIT,
            order_status=Order.Status.OPEN,
            total=Decimal("40.00"),
        )

        data = self._activity()

        self.assertNotIn(credit.pk, [row["id"] for row in data["recent_sales"]])

    def test_a_credit_row_says_what_is_still_owed(self):
        self._order(
            sale_type=Order.SaleType.CREDIT,
            order_status=Order.Status.OPEN,
            total=Decimal("40.00"),
            paid=Decimal("15.00"),
        )

        row = self._activity()["recent_credit_sales"][0]

        self.assertEqual(row["sale_type"], Order.SaleType.CREDIT)
        self.assertEqual(row["amount_paid"], "15.00")
        self.assertEqual(row["balance_due"], "25.00")
        self.assertEqual(row["payment_status"], "partial")

    def test_the_summary_totals_the_debt_the_five_rows_cannot_show(self):
        for _ in range(3):
            self._order(
                sale_type=Order.SaleType.CREDIT,
                order_status=Order.Status.OPEN,
                total=Decimal("10.00"),
            )
        # A settled tab is history, not a receivable: it counts toward how many
        # credit invoices this person issued, and toward nothing else.
        self._order(
            sale_type=Order.SaleType.CREDIT,
            order_status=Order.Status.PAID,
            total=Decimal("50.00"),
            paid=Decimal("50.00"),
        )

        sales = self._activity()["summary"]["sales"]

        self.assertEqual(sales["credit_invoice_count"], 4)
        self.assertEqual(sales["credit_outstanding_total"], "30.00")

    def test_the_overview_does_not_cost_a_query_per_invoice(self):
        for _ in range(2):
            self._order(
                sale_type=Order.SaleType.CREDIT,
                order_status=Order.Status.OPEN,
                total=Decimal("10.00"),
                paid=Decimal("1.00"),
            )
        self._activity()
        with CaptureQueriesContext(connection) as few:
            self._activity()

        for _ in range(3):
            self._order(
                sale_type=Order.SaleType.CREDIT,
                order_status=Order.Status.OPEN,
                total=Decimal("10.00"),
                paid=Decimal("1.00"),
            )
        with CaptureQueriesContext(connection) as more:
            self._activity()

        # `amount_paid` reads the payments of every row it renders, so an
        # unprefetched list is one query per invoice — invisible on a new
        # cashier and linear on the one an owner actually opens.
        self.assertEqual(
            len(few),
            len(more),
            "the profile must cost the same however many invoices it summarises",
        )
