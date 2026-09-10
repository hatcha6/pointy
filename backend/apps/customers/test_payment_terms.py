"""The terms resolution itself: dates in, a due date out.

Kept away from the database where it can be — ``PaymentTerms.due_date_for`` is
arithmetic, and arithmetic deserves cases rather than fixtures. The month-end
cases are ported from the ones ERPNext exercises in
``get_due_date_from_template``, plus the boundaries its own tests do not cover.
"""

from datetime import date

from django.test import TestCase

from apps.core.models import ShopSettings
from apps.customers.models import Customer
from apps.customers.payment_terms import (
    MAX_CREDIT_DAYS,
    PaymentTerms,
    PaymentTermsBasis,
    resolve_due_date,
    resolve_payment_terms,
)


def terms(days, basis=PaymentTermsBasis.NET_DAYS):
    return PaymentTerms(basis=basis, days=days, source="shop")


class DueDateArithmeticTests(TestCase):
    def test_net_days_adds_days(self):
        self.assertEqual(terms(30).due_date_for(date(2026, 9, 10)), date(2026, 10, 10))

    def test_net_zero_is_the_invoice_day(self):
        issued = date(2026, 9, 10)
        self.assertEqual(terms(0).due_date_for(issued), issued)
        self.assertTrue(terms(0).is_immediate)

    def test_net_days_crosses_a_month_boundary(self):
        self.assertEqual(terms(30).due_date_for(date(2026, 1, 20)), date(2026, 2, 19))

    def test_net_days_crosses_a_year_boundary(self):
        self.assertEqual(terms(45).due_date_for(date(2026, 12, 1)), date(2027, 1, 15))

    def test_end_of_month_lands_on_the_last_day(self):
        eom = terms(0, PaymentTermsBasis.END_OF_MONTH)
        self.assertEqual(eom.due_date_for(date(2026, 9, 3)), date(2026, 9, 30))
        self.assertFalse(eom.is_immediate)

    def test_end_of_month_plus_days(self):
        eom = terms(10, PaymentTermsBasis.END_OF_MONTH)
        self.assertEqual(eom.due_date_for(date(2026, 9, 3)), date(2026, 10, 10))

    def test_end_of_month_handles_february_in_a_leap_year(self):
        eom = terms(0, PaymentTermsBasis.END_OF_MONTH)
        self.assertEqual(eom.due_date_for(date(2028, 2, 5)), date(2028, 2, 29))
        self.assertEqual(eom.due_date_for(date(2026, 2, 5)), date(2026, 2, 28))

    def test_end_of_month_on_the_last_day_of_the_month_does_not_go_backwards(self):
        # The floor earns its keep here: the month end IS the invoice date, and
        # nothing may push the result before it.
        issued = date(2026, 9, 30)
        self.assertEqual(
            terms(0, PaymentTermsBasis.END_OF_MONTH).due_date_for(issued), issued
        )

    def test_a_due_date_is_never_before_the_invoice(self):
        issued = date(2026, 9, 10)
        self.assertEqual(terms(0).due_date_for(issued), issued)


class TermsResolutionTests(TestCase):
    def setUp(self):
        self.settings = ShopSettings.load()
        self.settings.default_payment_terms_days = 14
        self.settings.default_payment_terms_basis = PaymentTermsBasis.NET_DAYS
        self.settings.save()

    def test_no_customer_falls_back_to_the_shop(self):
        resolved = resolve_payment_terms(None, settings=self.settings)
        self.assertEqual(resolved.days, 14)
        self.assertEqual(resolved.source, "shop")

    def test_shop_default_policy_follows_the_shop(self):
        customer = Customer.objects.create(full_name="افتراضي")
        resolved = resolve_payment_terms(customer, settings=self.settings)
        self.assertEqual(resolved.days, 14)
        self.assertEqual(resolved.source, "shop")

    def test_immediate_policy_overrides_a_generous_shop_default(self):
        customer = Customer.objects.create(
            full_name="نقدًا",
            payment_terms_policy=Customer.PaymentTermsPolicy.IMMEDIATE,
        )
        resolved = resolve_payment_terms(customer, settings=self.settings)
        self.assertTrue(resolved.is_immediate)
        self.assertEqual(resolved.source, "customer")

    def test_custom_policy_carries_its_own_terms(self):
        customer = Customer.objects.create(
            full_name="جملة",
            payment_terms_policy=Customer.PaymentTermsPolicy.CUSTOM,
            payment_terms_days=60,
            payment_terms_basis=PaymentTermsBasis.END_OF_MONTH,
        )
        resolved = resolve_payment_terms(customer, settings=self.settings)
        self.assertEqual(resolved.days, 60)
        self.assertEqual(resolved.basis, PaymentTermsBasis.END_OF_MONTH)
        self.assertEqual(resolved.source, "customer")

    def test_custom_policy_with_no_days_falls_back_rather_than_meaning_zero(self):
        # Only reachable on a row that predates the validation; reading it as
        # "due immediately" would silently tighten a customer's terms.
        customer = Customer.objects.create(full_name="ناقص")
        Customer.objects.filter(pk=customer.pk).update(
            payment_terms_policy=Customer.PaymentTermsPolicy.CUSTOM,
            payment_terms_days=None,
        )
        customer.refresh_from_db()
        resolved = resolve_payment_terms(customer, settings=self.settings)
        self.assertEqual(resolved.days, 14)
        self.assertEqual(resolved.source, "shop")

    def test_resolve_due_date_always_returns_a_date(self):
        self.settings.default_payment_terms_days = 0
        self.settings.save()
        issued = date(2026, 9, 10)
        self.assertEqual(resolve_due_date(None, issued, settings=self.settings), issued)


class TermsValidationTests(TestCase):
    def test_custom_policy_requires_a_day_count(self):
        with self.assertRaises(Exception) as caught:
            Customer.objects.create(
                full_name="ناقص",
                payment_terms_policy=Customer.PaymentTermsPolicy.CUSTOM,
            )
        self.assertIn("payment_terms_days", str(caught.exception))

    def test_a_basis_is_cleared_when_the_policy_stops_being_custom(self):
        customer = Customer.objects.create(
            full_name="جملة",
            payment_terms_policy=Customer.PaymentTermsPolicy.CUSTOM,
            payment_terms_days=30,
            payment_terms_basis=PaymentTermsBasis.END_OF_MONTH,
        )
        customer.payment_terms_policy = Customer.PaymentTermsPolicy.SHOP_DEFAULT
        customer.save()
        customer.refresh_from_db()
        self.assertEqual(customer.payment_terms_basis, "")

    def test_absurd_day_counts_are_refused(self):
        with self.assertRaises(Exception):
            Customer.objects.create(
                full_name="طويل",
                payment_terms_policy=Customer.PaymentTermsPolicy.CUSTOM,
                payment_terms_days=MAX_CREDIT_DAYS + 1,
            )
