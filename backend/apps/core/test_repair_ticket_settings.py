"""The repair counter's shop-wide choices: the diagnosis fee a declined repair
suggests, and the conditions printed on the intake receipt.

The conditions are a list, in the order they print, and edited as one — the
settings screen adds, removes and reorders them. Null is a shop that has not
written its own (the app prints its defaults); an empty list is a shop that
prints none, which is a different answer and must survive the round trip.
"""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient

from apps.core.models import ShopSettings
from apps.core.roles import MANAGER_GROUP, ensure_role_groups


class RepairTicketSettingsTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        manager = get_user_model().objects.create_user(
            username="manager", password="pass"
        )
        manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client = APIClient()
        self.client.force_authenticate(user=manager)

    def patch(self, **payload):
        return self.client.patch(reverse("shop-settings"), payload, format="json")

    def test_a_new_shop_has_no_fee_and_prints_the_default_conditions(self):
        data = self.client.get(reverse("shop-settings")).data

        self.assertIsNone(data["repair_diagnosis_fee"])
        self.assertIsNone(data["repair_ticket_terms"])

    def test_the_conditions_are_kept_in_order_and_tidied(self):
        response = self.patch(
            repair_ticket_terms=[
                "  يسلم الجهاز لحامل الإيصال.  ",
                "",
                "المحل غير مسؤول\nعن البيانات.",
            ],
            repair_diagnosis_fee="10.00",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        settings = ShopSettings.load()
        self.assertEqual(
            settings.repair_ticket_terms,
            ["يسلم الجهاز لحامل الإيصال.", "المحل غير مسؤول عن البيانات."],
        )
        self.assertEqual(settings.repair_diagnosis_fee, Decimal("10.00"))

    def test_none_and_empty_are_different_answers(self):
        self.patch(repair_ticket_terms=[])
        self.assertEqual(ShopSettings.load().repair_ticket_terms, [])

        self.patch(repair_ticket_terms=None)
        self.assertIsNone(ShopSettings.load().repair_ticket_terms)

    def test_the_conditions_must_be_a_short_list_of_text(self):
        for bad in (
            "one long string",
            [1, 2],
            ["ب" * 301],
            [f"شرط {index}" for index in range(21)],
        ):
            with self.subTest(bad=str(bad)[:30]):
                response = self.patch(repair_ticket_terms=bad)
                self.assertEqual(
                    response.status_code, status.HTTP_400_BAD_REQUEST
                )
                self.assertIn("repair_ticket_terms", response.data)
