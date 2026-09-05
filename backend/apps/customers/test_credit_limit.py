"""The credit (آجل) ceiling: how it resolves, and where it is enforced.

Two questions are tested apart from each other on purpose. *Resolution* is
"which number applies to this customer" — pure, and where the shop default and
the per-customer policy meet. *Enforcement* is "does a sale that would breach it
get refused" — end-to-end through the till, because a limit that resolves
correctly and is never consulted is not a limit.
"""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient, APITestCase

from apps.catalog.testing import create_product_with_default_variant
from apps.core.models import ShopSettings
from apps.core.roles import CASHIER_GROUP, ensure_role_groups
from apps.customers.models import Customer
from apps.customers.receivables import (
    CreditAssessment,
    assess_credit,
    effective_credit_limit,
    outstanding_balance,
)
from apps.inventory.models import StockItem
from apps.sales.models import Order


def _set_shop_default(limit, enforce=True):
    """Set the shop ceiling. Enforcement is off by default in the product, so
    every test that expects a refusal has to ask for it — which is the point."""
    ShopSettings.objects.filter(pk=1).update(
        default_customer_credit_limit=limit,
        enforce_customer_credit_limits=enforce,
    )


class CreditLimitResolutionTests(TestCase):
    def setUp(self):
        ShopSettings.load()
        self.customer = Customer.objects.create(full_name="Resolution")

    def test_no_shop_default_and_no_policy_means_no_limit(self):
        """The state every shop upgrades into. It must not start blocking."""
        _set_shop_default(None)
        self.assertIsNone(effective_credit_limit(self.customer))

    def test_shop_default_applies_to_an_inheriting_customer(self):
        _set_shop_default(Decimal("500.00"))
        self.assertEqual(effective_credit_limit(self.customer), Decimal("500.00"))

    def test_unlimited_policy_beats_the_shop_default(self):
        _set_shop_default(Decimal("500.00"))
        self.customer.credit_limit_policy = Customer.CreditLimitPolicy.UNLIMITED
        self.customer.save()
        self.assertIsNone(effective_credit_limit(self.customer))

    def test_custom_policy_beats_the_shop_default(self):
        _set_shop_default(Decimal("500.00"))
        self.customer.credit_limit_policy = Customer.CreditLimitPolicy.CUSTOM
        self.customer.credit_limit = Decimal("2000.00")
        self.customer.save()
        self.assertEqual(effective_credit_limit(self.customer), Decimal("2000.00"))

    def test_custom_zero_means_no_credit_not_no_limit(self):
        """The distinction the whole module turns on."""
        _set_shop_default(None)
        self.customer.credit_limit_policy = Customer.CreditLimitPolicy.CUSTOM
        self.customer.credit_limit = Decimal("0.00")
        self.customer.save()
        self.assertEqual(effective_credit_limit(self.customer), Decimal("0.00"))
        self.assertFalse(assess_credit(self.customer, Decimal("0.01")).allowed)

    def test_a_custom_policy_without_an_amount_is_refused(self):
        self.customer.credit_limit_policy = Customer.CreditLimitPolicy.CUSTOM
        self.customer.credit_limit = None
        with self.assertRaises(Exception):
            self.customer.save()

    def test_available_credit_never_goes_negative(self):
        """A limit lowered under a customer who is already past it leaves zero
        head-room, not a negative allowance the next sale could add back."""
        _set_shop_default(Decimal("100.00"))
        assessment = assess_credit(self.customer, Decimal("0.00"))
        self.assertEqual(assessment.available, Decimal("100.00"))

        over = CreditAssessment(
            allowed=False,
            limit=Decimal("100.00"),
            outstanding=Decimal("250.00"),
            new_debt=Decimal("0.00"),
        )
        self.assertEqual(over.available, Decimal("0.00"))


class CreditLimitCheckoutTests(APITestCase):
    """The till refuses the sale that would breach the ceiling — and only that
    sale. Widget is 3.50, every checkout below buys 2 (7.00)."""

    def setUp(self):
        ensure_role_groups()
        ShopSettings.load()
        self.client = APIClient()
        self.user = get_user_model().objects.create_user(
            username="limit-cashier", password="pass"
        )
        self.user.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.client.force_authenticate(user=self.user)
        self.product = create_product_with_default_variant(
            sku="WIDGET", barcode="", name="Widget", unit_price=Decimal("3.50")
        )
        self.variant = self.product.default_variant
        StockItem.objects.create(variant=self.variant, quantity_on_hand=100)
        self.customer = Customer.objects.create(full_name="Debt Customer")
        self.client.post(
            reverse("register-session-start"), {"opening_cash": "0.00"}, format="json"
        )

    def _checkout(self, **overrides):
        payload = {"lines": [{"variant": self.variant.pk, "quantity": 2}]}
        payload.update(overrides)
        return self.client.post(reverse("order-checkout"), payload, format="json")

    def _credit(self, **overrides):
        return self._checkout(
            sale_type="credit", customer=self.customer.pk, payments=[], **overrides
        )

    def test_the_feature_is_off_until_the_owner_turns_it_on(self):
        """The upgrade path. A shop that never asked for credit limits keeps
        selling on آجل exactly as it did, even with a default sitting unused."""
        _set_shop_default(Decimal("1.00"), enforce=False)
        for _ in range(3):
            self.assertEqual(self._credit().status_code, status.HTTP_201_CREATED)

    def test_turning_the_switch_off_again_stops_refusing(self):
        _set_shop_default(Decimal("1.00"))
        self.assertEqual(self._credit().status_code, status.HTTP_400_BAD_REQUEST)

        _set_shop_default(Decimal("1.00"), enforce=False)
        self.assertEqual(self._credit().status_code, status.HTTP_201_CREATED)

    def test_an_anonymous_credit_sale_is_never_refused(self):
        """A shop that allows آجل with no customer named has chosen unbounded
        anonymous debt; there is nobody for a ceiling to belong to. The gate
        must not turn that permission into a refusal."""
        _set_shop_default(Decimal("0.00"))
        ShopSettings.objects.filter(pk=1).update(require_customer_for_credit=False)

        response = self._checkout(sale_type="credit", payments=[])

        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        self.assertIsNone(Order.objects.get(pk=response.data["id"]).customer)

    def test_credit_sale_under_the_shop_default_is_allowed(self):
        _set_shop_default(Decimal("10.00"))
        self.assertEqual(self._credit().status_code, status.HTTP_201_CREATED)

    def test_credit_sale_over_the_shop_default_is_refused(self):
        _set_shop_default(Decimal("10.00"))
        self.assertEqual(self._credit().status_code, status.HTTP_201_CREATED)

        response = self._credit()
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(response.data["code"], "credit_limit_exceeded")
        credit = response.data["credit"]
        self.assertEqual(credit["limit"], "10.00")
        self.assertEqual(credit["outstanding"], "7.00")
        self.assertEqual(credit["available"], "3.00")
        self.assertEqual(credit["new_debt"], "7.00")
        self.assertEqual(credit["projected"], "14.00")
        # Refused, not partially recorded.
        self.assertEqual(Order.objects.filter(sale_type=Order.SaleType.CREDIT).count(), 1)

    def test_a_paid_sale_is_never_judged_against_the_credit_limit(self):
        """The ceiling bounds debt, not trade. A customer at their limit can
        still buy anything they pay for."""
        _set_shop_default(Decimal("0.00"))
        response = self._checkout(customer=self.customer.pk, amount_received="7.00")
        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)

    def test_a_down_payment_that_clears_the_total_leaves_no_new_debt(self):
        """A credit invoice settled in full at the till adds nothing to the
        receivable, so a zero ceiling must not refuse it."""
        _set_shop_default(Decimal("0.00"))
        response = self._checkout(
            sale_type="credit",
            customer=self.customer.pk,
            payment_method="cash",
            amount_received="7.00",
        )
        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)

    def test_only_the_unpaid_part_counts_against_the_limit(self):
        _set_shop_default(Decimal("5.00"))
        response = self._checkout(
            sale_type="credit",
            customer=self.customer.pk,
            payment_method="cash",
            amount_received="3.00",
        )
        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        self.assertEqual(outstanding_balance(self.customer), Decimal("4.00"))

    def test_an_unlimited_customer_ignores_the_shop_default(self):
        _set_shop_default(Decimal("1.00"))
        self.customer.credit_limit_policy = Customer.CreditLimitPolicy.UNLIMITED
        self.customer.save()
        self.assertEqual(self._credit().status_code, status.HTTP_201_CREATED)

    def test_a_custom_limit_overrides_a_generous_shop_default(self):
        _set_shop_default(Decimal("1000.00"))
        self.customer.credit_limit_policy = Customer.CreditLimitPolicy.CUSTOM
        self.customer.credit_limit = Decimal("5.00")
        self.customer.save()
        self.assertEqual(self._credit().status_code, status.HTTP_400_BAD_REQUEST)

    def test_no_limit_anywhere_allows_unbounded_credit(self):
        _set_shop_default(None)
        for _ in range(3):
            self.assertEqual(self._credit().status_code, status.HTTP_201_CREATED)

    def test_a_customer_paying_their_debt_frees_the_ceiling_again(self):
        _set_shop_default(Decimal("10.00"))
        self.assertEqual(self._credit().status_code, status.HTTP_201_CREATED)
        self.assertEqual(self._credit().status_code, status.HTTP_400_BAD_REQUEST)

        self.client.post(
            reverse("customer-record-payment", args=[self.customer.pk]),
            {"method": "cash", "amount": "7.00"},
            format="json",
        )
        self.assertEqual(outstanding_balance(self.customer), Decimal("0.00"))
        self.assertEqual(self._credit().status_code, status.HTTP_201_CREATED)


class CreditLimitApiSurfaceTests(APITestCase):
    """What the screens read: the customer record and the sales summary."""

    def setUp(self):
        groups = ensure_role_groups()
        ShopSettings.load()
        self.user = get_user_model().objects.create_user(
            username="limit-manager", password="pass"
        )
        self.user.groups.add(groups["manager"])
        self.client.force_authenticate(self.user)
        self.customer = Customer.objects.create(full_name="Surface")

    def test_customer_payload_carries_the_policy_and_the_resolved_limit(self):
        _set_shop_default(Decimal("300.00"))
        response = self.client.get(reverse("customer-detail", args=[self.customer.pk]))
        self.assertEqual(response.data["credit_limit_policy"], "shop_default")
        self.assertIsNone(response.data["credit_limit"])
        self.assertEqual(response.data["effective_credit_limit"], "300.00")

    def test_a_custom_limit_can_be_set_from_the_customer_record(self):
        response = self.client.patch(
            reverse("customer-detail", args=[self.customer.pk]),
            {"credit_limit_policy": "custom", "credit_limit": "750.00"},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.assertEqual(response.data["effective_credit_limit"], "750.00")

    def test_a_custom_policy_without_an_amount_is_a_field_error(self):
        response = self.client.patch(
            reverse("customer-detail", args=[self.customer.pk]),
            {"credit_limit_policy": "custom"},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("credit_limit", response.data)

    def test_sales_summary_reports_the_limit_and_the_head_room(self):
        _set_shop_default(Decimal("100.00"))
        response = self.client.get(
            reverse("customer-sales-summary", args=[self.customer.pk])
        )
        self.assertEqual(response.data["credit_limit"], "100.00")
        self.assertEqual(response.data["available_credit"], "100.00")
        self.assertEqual(response.data["outstanding_balance"], "0.00")

    def test_an_unlimited_customer_reports_no_limit_rather_than_zero(self):
        _set_shop_default(Decimal("100.00"))
        self.customer.credit_limit_policy = Customer.CreditLimitPolicy.UNLIMITED
        self.customer.save()
        response = self.client.get(
            reverse("customer-sales-summary", args=[self.customer.pk])
        )
        self.assertIsNone(response.data["credit_limit"])
        self.assertIsNone(response.data["available_credit"])
