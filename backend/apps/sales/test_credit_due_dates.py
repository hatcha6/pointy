"""Due dates on آجل invoices: where they come from, what refuses them, and
what happens to the ones an older backend wrote in the wrong column.

The cash path is asserted on as hard as the credit path. Most sales in this
shop are neither credit nor quotations, and the whole design of this feature
rests on those never acquiring a due date, a terms lookup, or a settings read.
"""

from datetime import timedelta
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient

from apps.catalog.tests import create_product_with_default_variant
from apps.core.models import ShopSettings
from apps.core.roles import CASHIER_GROUP, MANAGER_GROUP, ensure_role_groups
from apps.core.timeutils import business_local_date
from apps.customers.models import Customer
from apps.customers.payment_terms import MAX_CREDIT_DAYS, PaymentTermsBasis
from apps.inventory.models import StockItem
from apps.sales.models import Order
from apps.sales.reconciliation import reconcile_credit_due_dates


class CreditDueDateCheckoutTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.client = APIClient()
        self.user = get_user_model().objects.create_user(
            username="terms-cashier", password="pass"
        )
        self.user.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.client.force_authenticate(user=self.user)
        self.product = create_product_with_default_variant(
            sku="WIDGET", barcode="", name="Widget", unit_price=Decimal("3.50")
        )
        self.variant = self.product.default_variant
        StockItem.objects.create(variant=self.variant, quantity_on_hand=50)
        self.customer = Customer.objects.create(full_name="عميل آجل")
        self.client.post(
            reverse("register-session-start"), {"opening_cash": "0.00"}, format="json"
        )
        self.settings = ShopSettings.load()
        self.settings.default_payment_terms_days = 30
        self.settings.save()
        self.today = business_local_date()

    def _checkout(self, **overrides):
        payload = {"lines": [{"variant": self.variant.pk, "quantity": 2}]}
        payload.update(overrides)
        return self.client.post(reverse("order-checkout"), payload, format="json")

    def _credit(self, **overrides):
        overrides.setdefault("sale_type", "credit")
        overrides.setdefault("customer", self.customer.pk)
        overrides.setdefault("payments", [])
        return self._checkout(**overrides)

    # -- where the date comes from -----------------------------------------

    def test_credit_sale_takes_the_shop_terms_when_none_is_sent(self):
        response = self._credit()
        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        order = Order.objects.get(pk=response.data["id"])
        self.assertEqual(order.due_date, self.today + timedelta(days=30))

    def test_a_sent_date_beats_the_terms(self):
        chosen = self.today + timedelta(days=3)
        order = Order.objects.get(
            pk=self._credit(due_date=chosen.isoformat()).data["id"]
        )
        self.assertEqual(order.due_date, chosen)

    def test_an_explicit_null_leaves_the_tab_open(self):
        # Distinct from omitting the key: this customer HAS terms, and the
        # cashier is deliberately declining to apply them.
        order = Order.objects.get(pk=self._credit(due_date=None).data["id"])
        self.assertIsNone(order.due_date)

    def test_customer_terms_beat_the_shop_default(self):
        self.customer.payment_terms_policy = Customer.PaymentTermsPolicy.CUSTOM
        self.customer.payment_terms_days = 0
        self.customer.payment_terms_basis = PaymentTermsBasis.END_OF_MONTH
        self.customer.save()
        order = Order.objects.get(pk=self._credit().data["id"])
        self.assertEqual(order.due_date.month, self.today.month)
        self.assertGreaterEqual(order.due_date, self.today)

    def test_a_walk_in_credit_sale_still_gets_the_shop_terms(self):
        self.settings.require_customer_for_credit = False
        self.settings.save()
        order = Order.objects.get(pk=self._credit(customer=None).data["id"])
        self.assertEqual(order.due_date, self.today + timedelta(days=30))

    # -- the cash path stays untouched -------------------------------------

    def test_a_cash_sale_never_gets_a_due_date(self):
        response = self._checkout(payment_method="cash", amount_received="7.00")
        order = Order.objects.get(pk=response.data["id"])
        self.assertIsNone(order.due_date)
        self.assertFalse(order.is_overdue)

    def test_a_due_date_on_a_cash_sale_is_refused_not_ignored(self):
        response = self._checkout(
            payment_method="cash",
            amount_received="7.00",
            due_date=(self.today + timedelta(days=5)).isoformat(),
        )
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("due_date", response.data)

    def test_a_quotation_keeps_valid_until_and_refuses_a_due_date(self):
        response = self._checkout(
            sale_type="quotation",
            customer=self.customer.pk,
            payments=[],
            due_date=(self.today + timedelta(days=5)).isoformat(),
        )
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

        offer = self.today + timedelta(days=5)
        ok = self._checkout(
            sale_type="quotation",
            customer=self.customer.pk,
            payments=[],
            valid_until=offer.isoformat(),
        )
        order = Order.objects.get(pk=ok.data["id"])
        self.assertEqual(order.valid_until, offer)
        self.assertIsNone(order.due_date)

    # -- refusals -----------------------------------------------------------

    def test_a_backdated_due_date_is_refused(self):
        response = self._credit(
            due_date=(self.today - timedelta(days=1)).isoformat()
        )
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("due_date", response.data)

    def test_an_absurd_due_date_is_refused(self):
        response = self._credit(
            due_date=(self.today + timedelta(days=MAX_CREDIT_DAYS + 1)).isoformat()
        )
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_todays_due_date_is_accepted(self):
        # The boundary: due today is due, not overdue, and not a backdate.
        order = Order.objects.get(
            pk=self._credit(due_date=self.today.isoformat()).data["id"]
        )
        self.assertEqual(order.due_date, self.today)
        self.assertFalse(order.is_overdue)


class OverdueDerivationTests(TestCase):
    def setUp(self):
        self.customer = Customer.objects.create(full_name="مدين")
        self.today = business_local_date()

    def _order(self, due_date=None, status_=Order.Status.OPEN, total="100"):
        order = Order.objects.create(
            customer=self.customer,
            sale_type=Order.SaleType.CREDIT,
            status=status_,
            due_date=due_date,
        )
        Order.objects.filter(pk=order.pk).update(total=Decimal(total))
        order.refresh_from_db()
        return order

    def test_past_due_with_a_balance_is_overdue(self):
        order = self._order(due_date=self.today - timedelta(days=1))
        self.assertTrue(order.is_overdue)
        self.assertEqual(order.days_overdue, 1)

    def test_due_today_is_not_yet_overdue(self):
        self.assertFalse(self._order(due_date=self.today).is_overdue)

    def test_no_due_date_is_never_overdue(self):
        # "Payable now" and "late" are different claims; only one colours a
        # screen red.
        order = self._order()
        self.assertFalse(order.is_overdue)
        self.assertEqual(order.days_overdue, 0)

    def test_a_settled_invoice_is_not_overdue(self):
        order = self._order(due_date=self.today - timedelta(days=10), total="0")
        self.assertFalse(order.is_overdue)

    def test_the_queryset_agrees_with_the_property(self):
        late = self._order(due_date=self.today - timedelta(days=5))
        self._order(due_date=self.today + timedelta(days=5))
        self._order()
        overdue = list(Order.objects.overdue(self.today))
        self.assertEqual([order.pk for order in overdue], [late.pk])

    def test_due_on_or_before_includes_the_undated(self):
        due = self._order(due_date=self.today)
        undated = self._order()
        self._order(due_date=self.today + timedelta(days=1))
        collectable = set(
            Order.objects.due_on_or_before(self.today).values_list("pk", flat=True)
        )
        self.assertEqual(collectable, {due.pk, undated.pk})


class RescheduleDueDateApiTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.client = APIClient()
        self.manager = get_user_model().objects.create_user(
            username="terms-manager", password="pass"
        )
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client.force_authenticate(user=self.manager)
        self.customer = Customer.objects.create(full_name="مدين")
        self.today = business_local_date()
        self.order = Order.objects.create(
            customer=self.customer,
            sale_type=Order.SaleType.CREDIT,
            status=Order.Status.OPEN,
            due_date=self.today,
        )
        Order.objects.filter(pk=self.order.pk).update(total=Decimal("100"))
        self.order.refresh_from_db()

    def _url(self, order=None):
        return reverse("order-due-date", args=[(order or self.order).pk])

    def _post(self, payload, order=None):
        return self.client.post(self._url(order), payload, format="json")

    def test_manager_can_extend_the_term(self):
        later = self.today + timedelta(days=14)
        response = self._post({"due_date": later.isoformat()})
        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.order.refresh_from_db()
        self.assertEqual(self.order.due_date, later)

    def test_clearing_returns_it_to_an_open_tab(self):
        response = self._post({"due_date": None})
        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.order.refresh_from_db()
        self.assertIsNone(self.order.due_date)

    def test_omitting_the_field_is_not_the_same_as_clearing_it(self):
        response = self._post({})
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.order.refresh_from_db()
        self.assertEqual(self.order.due_date, self.today)

    def test_a_date_in_the_past_is_refused(self):
        response = self._post({"due_date": (self.today - timedelta(days=1)).isoformat()})
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_a_settled_invoice_cannot_be_rescheduled(self):
        Order.objects.filter(pk=self.order.pk).update(status=Order.Status.PAID)
        response = self._post({"due_date": (self.today + timedelta(days=7)).isoformat()})
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_a_cash_sale_has_no_due_date_to_reschedule(self):
        cash = Order.objects.create(sale_type=Order.SaleType.STANDARD)
        response = self._post(
            {"due_date": (self.today + timedelta(days=7)).isoformat()}, order=cash
        )
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_a_cashier_cannot_reschedule(self):
        cashier = get_user_model().objects.create_user(
            username="terms-till", password="pass"
        )
        cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))
        client = APIClient()
        client.force_authenticate(user=cashier)
        response = client.post(
            self._url(),
            {"due_date": (self.today + timedelta(days=7)).isoformat()},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)


class LiveUpdateReconciliationTests(TestCase):
    """The minute during a live update when the old backend is still writing a
    credit invoice's due date into ``valid_until``."""

    def setUp(self):
        self.customer = Customer.objects.create(full_name="مدين")
        self.due = business_local_date() + timedelta(days=30)

    def _legacy_credit_order(self):
        order = Order.objects.create(
            customer=self.customer,
            sale_type=Order.SaleType.CREDIT,
            status=Order.Status.OPEN,
        )
        # Exactly what the old code wrote: the date in the old column.
        Order.objects.filter(pk=order.pk).update(
            valid_until=self.due, due_date=None, total=Decimal("100")
        )
        order.refresh_from_db()
        return order

    def test_a_stranded_due_date_is_promoted_and_the_source_cleared(self):
        order = self._legacy_credit_order()
        self.assertEqual(reconcile_credit_due_dates(), 1)
        order.refresh_from_db()
        self.assertEqual(order.due_date, self.due)
        self.assertIsNone(order.valid_until)

    def test_it_is_idempotent(self):
        self._legacy_credit_order()
        reconcile_credit_due_dates()
        self.assertEqual(reconcile_credit_due_dates(), 0)

    def test_a_deliberately_cleared_due_date_is_not_resurrected(self):
        # The clearing half of the promotion is what makes this true: once the
        # date has moved, there is nothing left in valid_until to come back.
        order = self._legacy_credit_order()
        reconcile_credit_due_dates()
        order.refresh_from_db()
        order.due_date = None
        order.save(update_fields=["due_date"])
        self.assertEqual(reconcile_credit_due_dates(), 0)
        order.refresh_from_db()
        self.assertIsNone(order.due_date)

    def test_a_quotation_keeps_its_expiry(self):
        quote = Order.objects.create(
            customer=self.customer, sale_type=Order.SaleType.QUOTATION
        )
        Order.objects.filter(pk=quote.pk).update(valid_until=self.due)
        reconcile_credit_due_dates()
        quote.refresh_from_db()
        self.assertEqual(quote.valid_until, self.due)
        self.assertIsNone(quote.due_date)
