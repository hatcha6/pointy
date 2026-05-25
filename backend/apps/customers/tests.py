from datetime import timedelta
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.urls import reverse
from django.utils import timezone
from rest_framework import status
from rest_framework.test import APITestCase

from apps.catalog.testing import create_product_with_default_variant
from apps.core.roles import ensure_role_groups
from apps.customers.models import Customer
from apps.inventory.models import StockItem


class CustomerApiTests(APITestCase):
    def setUp(self):
        groups = ensure_role_groups()
        self.user = get_user_model().objects.create_user(
            username="manager",
            password="password",
        )
        self.user.groups.add(groups["manager"])
        self.client.force_authenticate(self.user)

    def test_create_customer_with_optional_profile_fields(self):
        response = self.client.post(
            reverse("customer-list"),
            {
                "full_name": "Layla Ahmed",
                "phone": "+218911234567",
                "email": "layla@example.com",
                "gender": Customer.Gender.FEMALE,
                "birthday": "1995-05-12",
                "marketing_consent": True,
                "notes": "Prefers SMS campaigns.",
                "is_active": True,
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        customer = Customer.objects.get()
        self.assertTrue(customer.customer_number.startswith("C"))
        self.assertEqual(customer.phone, "+218911234567")
        self.assertEqual(customer.gender, Customer.Gender.FEMALE)
        self.assertTrue(customer.marketing_consent)

    def test_customer_phone_and_birthday_are_optional(self):
        response = self.client.post(
            reverse("customer-list"),
            {"full_name": "Walk-in loyalty lead"},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        customer = Customer.objects.get()
        self.assertEqual(customer.phone, "")
        self.assertIsNone(customer.birthday)

    def test_customer_birthday_cannot_be_in_future(self):
        future_date = timezone.localdate() + timedelta(days=1)
        response = self.client.post(
            reverse("customer-list"),
            {
                "full_name": "Future Customer",
                "birthday": future_date.isoformat(),
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("birthday", response.data)

    def test_customer_list_can_search_by_phone(self):
        Customer.objects.create(full_name="Nadia Saleh", phone="091777888")
        Customer.objects.create(full_name="Omar Saleh", phone="092111222")

        response = self.client.get(reverse("customer-list"), {"search": "091777"})

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["count"], 1)
        self.assertEqual(response.data["results"][0]["full_name"], "Nadia Saleh")

    def test_customer_sales_summary_includes_invoices_and_adjustments(self):
        customer = Customer.objects.create(full_name="Layla Ahmed")
        order_response = self._checkout_customer_order(customer)
        line_id = order_response.data["lines"][0]["id"]
        return_response = self.client.post(
            reverse("order-return-items", args=[order_response.data["id"]]),
            {
                "reason": "Customer changed item",
                "lines": [{"line": line_id, "quantity": 1}],
            },
            format="json",
        )

        response = self.client.get(
            reverse("customer-sales-summary", args=[customer.pk]),
        )

        self.assertEqual(return_response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["invoice_count"], 1)
        self.assertEqual(response.data["paid_invoice_count"], 1)
        self.assertEqual(response.data["return_count"], 1)
        self.assertEqual(response.data["refund_count"], 1)
        self.assertEqual(response.data["exchange_count"], 0)
        self.assertEqual(response.data["total_invoiced"], "7.00")
        self.assertEqual(response.data["return_total"], "3.50")
        self.assertEqual(response.data["refund_total"], "3.50")
        self.assertEqual(response.data["net_sales"], "3.50")
        self.assertIsNotNone(response.data["last_invoice_at"])

    def test_customer_orders_returns_only_selected_customer_orders(self):
        first_customer = Customer.objects.create(full_name="First customer")
        second_customer = Customer.objects.create(full_name="Second customer")
        first_response = self._checkout_customer_order(first_customer)
        second_response = self._checkout_customer_order(second_customer)

        response = self.client.get(reverse("customer-orders", args=[first_customer.pk]))

        self.assertEqual(first_response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(second_response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(len(response.data["results"]), 1)
        self.assertEqual(response.data["results"][0]["id"], first_response.data["id"])
        self.assertEqual(response.data["results"][0]["customer"], first_customer.pk)

    def test_customer_adjustments_returns_return_line_details(self):
        customer = Customer.objects.create(full_name="Return customer")
        order_response = self._checkout_customer_order(customer)
        line_id = order_response.data["lines"][0]["id"]
        self.client.post(
            reverse("order-return-items", args=[order_response.data["id"]]),
            {
                "reason": "Damaged item",
                "lines": [{"line": line_id, "quantity": 1}],
            },
            format="json",
        )

        response = self.client.get(
            reverse("customer-adjustments", args=[customer.pk]),
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(len(response.data["results"]), 1)
        adjustment = response.data["results"][0]
        self.assertEqual(
            adjustment["receipt_number"],
            order_response.data["receipt_number"],
        )
        self.assertEqual(adjustment["adjustment_type"], "return")
        self.assertEqual(adjustment["amount"], "3.50")
        self.assertEqual(adjustment["reason"], "Damaged item")
        self.assertEqual(adjustment["lines"][0]["product_name"], "Coffee")
        self.assertEqual(adjustment["lines"][0]["quantity"], 1)

    def _checkout_customer_order(self, customer):
        variant = self._variant()
        self.client.post(
            reverse("register-session-start"),
            {"opening_cash": "0.00"},
            format="json",
        )
        return self.client.post(
            reverse("order-checkout"),
            {
                "lines": [{"variant": variant.pk, "quantity": 2}],
                "customer": customer.pk,
                "payment_method": "cash",
                "amount_received": "7.00",
            },
            format="json",
        )

    def _variant(self):
        product = create_product_with_default_variant(
            sku=f"COFFEE-{StockItem.objects.count() + 1}",
            barcode="",
            name="Coffee",
            unit_price=Decimal("3.50"),
        )
        variant = product.default_variant
        StockItem.objects.create(variant=variant, quantity_on_hand=10)
        return variant
