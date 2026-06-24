"""Per-session register summary endpoint (``register-session-summary``).

Covers the all-payment-methods breakdown, the sales-by-category grouping (and
its single-primary-category dedup), refund attribution, the issued-vs-collected
split, empty sessions, and owner scoping. Disjoint from
``test_register_reconciliation`` (cash drawer math) — here we assert the
aggregate payload the manager view and the Z-Report render.
"""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient

from apps.catalog.models import ProductCategory
from apps.catalog.testing import create_product_with_default_variant
from apps.core.roles import CASHIER_GROUP, MANAGER_GROUP, ensure_role_groups
from apps.inventory.models import StockItem

from .models import Order, RegisterSession
from .services import checkout_order, return_order_items


def _open_session(owner):
    return RegisterSession.objects.create(
        owner=owner,
        owner_key=f"user:{owner.pk}",
        opening_cash=Decimal("0.00"),
    )


def _product(*, sku, price, qty="100", categories=()):
    product = create_product_with_default_variant(
        name=f"Item {sku}",
        sku=sku,
        barcode="",
        unit_price=Decimal(price),
    )
    StockItem.objects.create(
        variant=product.default_variant,
        quantity_on_hand=Decimal(qty),
    )
    if categories:
        product.categories.add(*categories)
    return product.default_variant


class RegisterSummaryEndpointTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.user = get_user_model().objects.create_user(
            username="summary-cashier",
            password="pass",
        )
        self.user.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.client = APIClient()
        self.client.force_authenticate(user=self.user)

    def _summary(self, session_id):
        return self.client.get(reverse("register-session-summary", args=[session_id]))

    def _methods(self, payload):
        return {row["method"]: row for row in payload["payment_methods"]}

    # 1. Every payment method is summarised, not just cash.
    def test_all_payment_methods_are_summarised(self):
        session = _open_session(self.user)
        variant = _product(sku="SUM-1", price="10.00")
        checkout_order(
            register_session=session,
            lines_data=[{"variant": variant, "quantity": Decimal("1")}],
            payments_data=[{"method": "cash", "amount": Decimal("10.00")}],
        )
        checkout_order(
            register_session=session,
            lines_data=[{"variant": variant, "quantity": Decimal("2")}],
            payments_data=[{"method": "card", "amount": Decimal("20.00")}],
        )
        checkout_order(
            register_session=session,
            lines_data=[{"variant": variant, "quantity": Decimal("3")}],
            payments_data=[{"method": "transfer", "amount": Decimal("30.00")}],
        )

        response = self._summary(session.pk)
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        methods = self._methods(response.data)

        self.assertEqual(methods["cash"]["gross"], "10.00")
        self.assertEqual(methods["cash"]["count"], 1)
        self.assertEqual(methods["card"]["gross"], "20.00")
        self.assertEqual(methods["card"]["count"], 1)
        self.assertEqual(methods["transfer"]["gross"], "30.00")
        self.assertEqual(methods["transfer"]["count"], 1)
        self.assertEqual(response.data["payment_totals"]["gross"], "60.00")
        self.assertEqual(response.data["payment_totals"]["count"], 3)
        self.assertEqual(response.data["sales"]["gross_sales"], "60.00")
        self.assertEqual(response.data["sales"]["net_sales"], "60.00")
        self.assertEqual(response.data["sales"]["order_count"], 3)

    # 2. A product in several categories is counted once, under its primary.
    def test_category_breakdown_dedupes_multi_category_product(self):
        session = _open_session(self.user)
        primary = ProductCategory.objects.create(name="Drinks", display_order=0)
        secondary = ProductCategory.objects.create(name="Promos", display_order=5)
        food = ProductCategory.objects.create(name="Food", display_order=1)

        drink = _product(
            sku="CAT-1",
            price="10.00",
            categories=(secondary, primary),  # primary wins on display_order
        )
        snack = _product(sku="CAT-2", price="4.00", categories=(food,))

        checkout_order(
            register_session=session,
            lines_data=[{"variant": drink, "quantity": Decimal("2")}],  # 20.00
            payments_data=[{"method": "cash", "amount": Decimal("20.00")}],
        )
        checkout_order(
            register_session=session,
            lines_data=[{"variant": snack, "quantity": Decimal("3")}],  # 12.00
            payments_data=[{"method": "cash", "amount": Decimal("12.00")}],
        )

        response = self._summary(session.pk)
        categories = {row["category"]: row for row in response.data["categories"]}

        # Counted once, under the lower-display-order category — not in "Promos".
        self.assertIn("Drinks", categories)
        self.assertNotIn("Promos", categories)
        self.assertEqual(categories["Drinks"]["net"], "20.00")
        self.assertEqual(categories["Drinks"]["quantity"], "2")
        self.assertEqual(categories["Food"]["net"], "12.00")

        # Σ category net reconciles with net sales.
        total = sum(Decimal(row["net"]) for row in response.data["categories"])
        self.assertEqual(total, Decimal(response.data["sales"]["net_sales"]))

    # 3. Uncategorized products fall into their own bucket (category=None).
    def test_uncategorized_products_bucket(self):
        session = _open_session(self.user)
        variant = _product(sku="UNCAT-1", price="7.00")
        checkout_order(
            register_session=session,
            lines_data=[{"variant": variant, "quantity": Decimal("1")}],
            payments_data=[{"method": "cash", "amount": Decimal("7.00")}],
        )
        response = self._summary(session.pk)
        categories = response.data["categories"]
        self.assertEqual(len(categories), 1)
        self.assertIsNone(categories[0]["category"])
        self.assertEqual(categories[0]["net"], "7.00")

    # 4. A refund reduces the method net and the refund totals; the cash drawer
    #    refund is the exact cash share.
    def test_refund_reduces_method_net_and_totals(self):
        session = _open_session(self.user)
        variant = _product(sku="REF-1", price="10.00")
        order = checkout_order(
            register_session=session,
            lines_data=[{"variant": variant, "quantity": Decimal("2")}],
            payments_data=[{"method": "cash", "amount": Decimal("20.00")}],
        )
        line = order.lines.get()
        return_order_items(
            order=order,
            lines=[(line, 1)],  # refund 10.00 cash
            reason="Damaged",
            register_session=session,
        )

        response = self._summary(session.pk)
        methods = self._methods(response.data)
        self.assertEqual(methods["cash"]["gross"], "20.00")
        self.assertEqual(methods["cash"]["refund"], "10.00")
        self.assertEqual(methods["cash"]["net"], "10.00")
        self.assertEqual(response.data["refunds"]["refund_total"], "10.00")
        self.assertEqual(response.data["refunds"]["cash_refund_total"], "10.00")
        self.assertEqual(response.data["refunds"]["return_count"], 1)
        # Net sales drop by the refund: gross 20.00 - refund 10.00.
        self.assertEqual(response.data["sales"]["net_sales"], "10.00")

    # 5. A fully-returned (VOID) order leaves sales/categories but its collected
    #    cash still shows under the method gross — the issued-vs-collected split.
    def test_void_excluded_from_sales_but_payment_still_collected(self):
        session = _open_session(self.user)
        variant = _product(sku="VOID-1", price="5.00")
        order = checkout_order(
            register_session=session,
            lines_data=[{"variant": variant, "quantity": Decimal("1")}],
            payments_data=[{"method": "cash", "amount": Decimal("5.00")}],
        )
        line = order.lines.get()
        return_order_items(
            order=order,
            lines=[(line, 1)],  # full single-line return -> order VOID
            reason="All back",
            register_session=session,
        )
        order.refresh_from_db()
        self.assertEqual(order.status, Order.Status.VOID)

        response = self._summary(session.pk)
        # Sales exclude the void; void_count records it; no category rows remain.
        self.assertEqual(response.data["sales"]["order_count"], 0)
        self.assertEqual(response.data["sales"]["void_count"], 1)
        self.assertEqual(response.data["sales"]["gross_sales"], "0.00")
        self.assertEqual(response.data["categories"], [])
        # The cash collected (and refunded) is still visible per method.
        methods = self._methods(response.data)
        self.assertEqual(methods["cash"]["gross"], "5.00")
        self.assertEqual(methods["cash"]["refund"], "5.00")
        self.assertEqual(methods["cash"]["net"], "0.00")

    # 6. An empty session returns zeroed totals and no category rows.
    def test_empty_session_returns_zeroes(self):
        session = _open_session(self.user)
        response = self._summary(session.pk)
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["sales"]["gross_sales"], "0.00")
        self.assertEqual(response.data["sales"]["net_sales"], "0.00")
        self.assertEqual(response.data["sales"]["order_count"], 0)
        self.assertEqual(response.data["categories"], [])
        self.assertEqual(response.data["payment_totals"]["gross"], "0.00")
        methods = self._methods(response.data)
        self.assertEqual(set(methods), {"cash", "card", "transfer"})
        self.assertEqual(methods["card"]["gross"], "0.00")

    # 7. Cash reconciliation block carries the drawer figures.
    def test_cash_reconciliation_block(self):
        session = _open_session(self.user)
        session.opening_cash = Decimal("50.00")
        session.save(update_fields=["opening_cash"])
        variant = _product(sku="CASH-1", price="10.00")
        checkout_order(
            register_session=session,
            lines_data=[{"variant": variant, "quantity": Decimal("1")}],
            payments_data=[{"method": "cash", "amount": Decimal("10.00")}],
        )
        response = self._summary(session.pk)
        cash = response.data["cash"]
        self.assertEqual(cash["opening_cash"], "50.00")
        self.assertEqual(cash["cash_sales_total"], "10.00")
        self.assertEqual(cash["expected_cash"], "60.00")
        self.assertIsNone(cash["closing_cash"])
        self.assertIsNone(cash["cash_variance"])
        self.assertEqual(len(cash["denominations"]), 4)


class RegisterSummaryAccessTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.User = get_user_model()

    def _cashier(self, username):
        user = self.User.objects.create_user(username=username, password="pass")
        user.groups.add(Group.objects.get(name=CASHIER_GROUP))
        client = APIClient()
        client.force_authenticate(user=user)
        return user, client

    def _manager(self, username):
        user = self.User.objects.create_user(username=username, password="pass")
        user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        client = APIClient()
        client.force_authenticate(user=user)
        return user, client

    def test_cashier_can_read_own_session_summary(self):
        user, client = self._cashier("own-cashier")
        session = _open_session(user)
        response = client.get(reverse("register-session-summary", args=[session.pk]))
        self.assertEqual(response.status_code, status.HTTP_200_OK)

    def test_cashier_blocked_from_other_owner_session(self):
        owner, _ = self._cashier("owner-cashier")
        session = _open_session(owner)
        _, other_client = self._cashier("intruder-cashier")
        response = other_client.get(
            reverse("register-session-summary", args=[session.pk])
        )
        # Owner scoping in get_queryset hides it -> 404, never another's totals.
        self.assertEqual(response.status_code, status.HTTP_404_NOT_FOUND)

    def test_manager_can_read_any_session_summary(self):
        owner, _ = self._cashier("managed-cashier")
        session = _open_session(owner)
        _, manager_client = self._manager("summary-manager")
        response = manager_client.get(
            reverse("register-session-summary", args=[session.pk])
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK)
