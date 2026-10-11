"""A cashier closes blind unless granted ``view_own_register_reconciliation``:
then their OWN sessions carry expected cash and the variance, and nobody
else's sessions become visible."""

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group, Permission
from django.test import TestCase
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient

from apps.core.roles import CASHIER_GROUP, ROLE_PERMISSION_CODES, ensure_role_groups

GRANT = "sales.view_own_register_reconciliation"


class RegisterReconciliationGrantTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.cashier = self._cashier("grant-cashier")
        self.client = APIClient()
        self.client.force_authenticate(user=self.cashier)
        response = self.client.post(
            reverse("register-session-start"),
            {"opening_cash": "40.00"},
            format="json",
        )
        self.assertIn(response.status_code, (status.HTTP_200_OK, status.HTTP_201_CREATED))
        self.session_id = response.data["id"]

    def _cashier(self, username):
        user = get_user_model().objects.create_user(username=username, password="pass")
        user.groups.add(Group.objects.get(name=CASHIER_GROUP))
        return user

    def _grant(self, user):
        app_label, codename = GRANT.split(".")
        user.user_permissions.add(
            Permission.objects.get(content_type__app_label=app_label, codename=codename)
        )
        # Drop Django's per-instance permission cache.
        return get_user_model().objects.get(pk=user.pk)

    def _detail(self, user):
        client = APIClient()
        client.force_authenticate(user=user)
        return client.get(reverse("register-session-detail", args=[self.session_id]))

    def test_no_role_holds_it_by_default(self):
        for role, codes in ROLE_PERMISSION_CODES.items():
            self.assertNotIn(GRANT, codes, role)

    def test_cashier_without_the_grant_closes_blind(self):
        response = self._detail(self.cashier)

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertNotIn("expected_cash", response.data)
        self.assertNotIn("cash_variance", response.data)

    def test_granted_cashier_sees_expected_cash_on_own_open_session(self):
        cashier = self._grant(self.cashier)

        response = self._detail(cashier)

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["expected_cash"], "40.00")

    def test_granted_cashier_sees_variance_after_close(self):
        cashier = self._grant(self.cashier)
        client = APIClient()
        client.force_authenticate(user=cashier)

        response = client.post(
            reverse("register-session-close", args=[self.session_id]),
            {
                "closing_cash": "35.00",
                "count_025": 0,
                "count_050": 0,
                "count_075": 0,
                "count_100": 0,
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["cash_variance"], "-5.00")
        self.assertTrue(response.data["has_cash_variance"])
        listed = client.get(reverse("register-session-list"))
        self.assertEqual(listed.data["results"][0]["expected_cash"], "40.00")

    def test_grant_does_not_open_another_cashiers_session(self):
        other = self._grant(self._cashier("other-cashier"))

        response = self._detail(other)
        listed = APIClient()
        listed.force_authenticate(user=other)
        rows = listed.get(reverse("register-session-list")).data["results"]

        self.assertEqual(response.status_code, status.HTTP_404_NOT_FOUND)
        self.assertEqual(rows, [])

    def _summary_cash(self, user):
        client = APIClient()
        client.force_authenticate(user=user)
        response = client.get(
            reverse("register-session-summary", args=[self.session_id])
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        return response.data["cash"]

    def test_summary_keeps_a_blind_cashier_blind(self):
        cash = self._summary_cash(self.cashier)

        for field in (
            "expected_cash",
            "cash_variance",
            "has_cash_variance",
            "cash_sales_total",
            "pay_in_total",
            "pay_out_total",
            "cash_refund_total",
        ):
            self.assertNotIn(field, cash)
        # What they handled themselves stays on their Z-report.
        self.assertEqual(cash["opening_cash"], "40.00")
        self.assertIn("denominations", cash)

    def test_summary_shows_a_granted_cashier_the_reconciliation(self):
        cash = self._summary_cash(self._grant(self.cashier))

        self.assertEqual(cash["expected_cash"], "40.00")
        self.assertIn("cash_variance", cash)

    def test_grant_is_offered_in_the_permission_catalog(self):
        from apps.core.permission_catalog import catalog_codes

        self.assertIn(GRANT, catalog_codes())
