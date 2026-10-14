"""Who may read exchange rates: the till roles, for the calculator's converter.

The floating calculator's Convert mode reads ``exchange-rates/current/`` and
``currencies/``. Cashiers and supervisors run the counter, where "how much is
that in dollars?" is asked, so they read rates — read only. Typing a rate,
syncing the feed and repricing stay with the people who maintain them.
"""

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from rest_framework.test import APIClient

from apps.core.roles import (
    CASHIER_GROUP,
    SUPERVISOR_GROUP,
    ensure_role_groups,
    role_permission_codes,
)


class TillRolesReadRatesTests(TestCase):
    def test_till_roles_read_rates_but_never_write_them(self):
        for role in (CASHIER_GROUP, SUPERVISOR_GROUP):
            codes = role_permission_codes(role)
            with self.subTest(role=role):
                self.assertIn("fx.view_exchangerate", codes)
                self.assertIn("fx.view_currency", codes)
                self.assertNotIn("fx.add_exchangerate", codes)
                self.assertNotIn("fx.change_currency", codes)

    def test_a_cashier_gets_current_rates_and_currencies(self):
        ensure_role_groups()
        cashier = get_user_model().objects.create_user(
            username="till", password="pass1234"
        )
        cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))
        client = APIClient()
        client.force_authenticate(cashier)

        self.assertEqual(client.get("/api/exchange-rates/current/").status_code, 200)
        self.assertEqual(client.get("/api/currencies/").status_code, 200)
        # …but cannot type a rate or trigger a sync.
        self.assertEqual(
            client.post(
                "/api/exchange-rates/manual/",
                {"from_code": "USD", "rate": "7.1"},
                format="json",
            ).status_code,
            403,
        )
        self.assertEqual(
            client.post("/api/exchange-rates/sync/").status_code, 403
        )
