from datetime import timedelta

from django.contrib.auth import get_user_model
from django.urls import reverse
from django.utils import timezone
from rest_framework import status
from rest_framework.test import APITestCase

from apps.core.roles import ensure_role_groups
from apps.customers.models import Customer


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
