"""The returns desk finds a receipt however its number is typed off the paper.

``orders/lookup/?receipt=`` compared the typed text with ``receipt_number``
exactly, case and all, so «R 20260929 000123», «R٢٠٢٦٠٩٢٩٠٠٠١٢٣» or the digits
without their «R» came back «no invoice» with the customer's receipt in hand.
The lookup still matches exactly — it is how money leaves the drawer — only
now against the form Pointy prints.
"""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group, Permission
from django.test import SimpleTestCase, TestCase
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient

from apps.core.roles import CASHIER_GROUP, ensure_role_groups

from .models import Order, RegisterSession
from .testing import issue
from .views import receipt_lookup_candidates

RECEIPT = "R20260929000123"


class ReceiptLookupCandidatesTests(SimpleTestCase):
    def test_a_receipt_typed_off_the_paper_becomes_the_printed_number(self):
        for typed in (
            RECEIPT,
            " R20260929000123 ",
            "R 20260929 000123",
            "r20260929000123",
            "R٢٠٢٦٠٩٢٩٠٠٠١٢٣",
            "R۲۰۲۶۰۹۲۹۰۰۰۱۲۳",
            "‏R20260929000123‎",  # direction marks copied along with it
            "20260929000123",
            "٢٠٢٦٠٩٢٩ ٠٠٠١٢٣",
        ):
            with self.subTest(typed=typed):
                self.assertIn(RECEIPT, receipt_lookup_candidates(typed))

    def test_what_was_typed_is_tried_first(self):
        self.assertEqual(
            receipt_lookup_candidates("20260929000123"),
            ["20260929000123", RECEIPT],
        )
        self.assertEqual(receipt_lookup_candidates("inv-77"), ["inv-77", "INV-77"])
        self.assertEqual(receipt_lookup_candidates(RECEIPT), [RECEIPT])

    def test_only_the_full_date_and_sequence_gets_its_r_back(self):
        self.assertEqual(receipt_lookup_candidates("2026092900012"), ["2026092900012"])
        # A series past 999999 prints a seven-digit sequence.
        self.assertEqual(
            receipt_lookup_candidates("202609291000123"),
            ["202609291000123", "R202609291000123"],
        )

    def test_nothing_typed_is_nothing_to_look_up(self):
        for typed in (None, "", "   "):
            with self.subTest(typed=typed):
                self.assertEqual(receipt_lookup_candidates(typed), [])


class ReceiptLookupEndpointTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        # The returns desk: a cashier who may reach a sale they did not ring up.
        user = get_user_model().objects.create_user(username="returns-desk", password="p")
        user.groups.add(Group.objects.get(name=CASHIER_GROUP))
        user.user_permissions.add(Permission.objects.get(codename="process_return_lookup"))
        self.client = APIClient()
        self.client.force_authenticate(get_user_model().objects.get(pk=user.pk))
        self.session = RegisterSession.objects.create(
            owner=user, owner_key=f"user:{user.pk}", opening_cash=Decimal("0.00")
        )
        self.order = self._sale(RECEIPT)

    def _sale(self, receipt_number):
        return issue(
            Order.objects.create(
                register_session=self.session,
                receipt_number=receipt_number,
                subtotal=Decimal("5.00"),
                total=Decimal("5.00"),
            )
        )

    def _lookup(self, typed):
        return self.client.get(reverse("order-lookup"), {"receipt": typed})

    def test_the_receipt_is_found_however_it_was_typed(self):
        for typed in (
            RECEIPT,
            "R 2026 0929 000123",
            "r20260929000123",
            "R٢٠٢٦٠٩٢٩٠٠٠١٢٣",
            "20260929000123",
            "٢٠٢٦٠٩٢٩٠٠٠١٢٣",
        ):
            with self.subTest(typed=typed):
                response = self._lookup(typed)
                self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
                self.assertEqual(response.data["id"], self.order.pk)

    def test_it_is_still_an_exact_match(self):
        for typed in ("R2026092900012", "2026092900012", "000123", "R20260929000124"):
            with self.subTest(typed=typed):
                self.assertEqual(self._lookup(typed).status_code, status.HTTP_404_NOT_FOUND)

    def test_an_imported_receipt_keeps_the_number_the_old_system_printed(self):
        legacy = self._sale("inv-77")
        response = self._lookup("inv-77")
        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.assertEqual(response.data["id"], legacy.pk)

    def test_a_number_that_exists_as_typed_is_never_shadowed(self):
        # An imported sale numbered with the same digits as one of Pointy's:
        # typing the digits means the one printed with exactly those digits.
        legacy = self._sale("20260929000123")
        self.assertEqual(self._lookup("20260929000123").data["id"], legacy.pk)
        self.assertEqual(self._lookup(RECEIPT).data["id"], self.order.pk)

    def test_a_blank_receipt_is_still_refused(self):
        self.assertEqual(self._lookup("  ").status_code, status.HTTP_400_BAD_REQUEST)
