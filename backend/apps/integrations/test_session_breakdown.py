"""Where a register session's provider money went.

Covers ``apps.integrations.session_breakdown`` through the register summary
endpoint the manager view and the Z-Report read: every provider line lands in
exactly one bucket, the headline figures cover only the sales the shop kept,
and a recharge refunded after the provider performed it is called out rather
than quietly netted away.
"""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.db import connection
from django.test import TestCase
from django.test.utils import CaptureQueriesContext
from django.urls import reverse
from rest_framework.test import APIClient

from apps.core.roles import MANAGER_GROUP, ensure_role_groups
from apps.sales.models import Order, RegisterSession
from apps.sales.services import checkout_order, return_order_items, void_order

from . import catalog
from .fulfillment import resolve_line_integration
from .models import IntegrationAccount, IntegrationFulfillment
from .provisioning import service_variant_for
from .session_breakdown import build_integration_breakdown


def _account(provider, **kwargs):
    account = IntegrationAccount.objects.create(
        provider=provider,
        base_url="http://provider.example",
        username="Alnassim",
        **kwargs,
    )
    account.set_secret(catalog.FIELD_PASSWORD, "secret-pw")
    account.save()
    return account


class SessionIntegrationBreakdownTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.user = get_user_model().objects.create_user(username="boss", password="x")
        self.user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client = APIClient()
        self.client.force_authenticate(self.user)
        self.session = self._session("a")
        # HD Box sells at cost + 5, so every margin below is visible arithmetic.
        self.hdbox = _account(
            "hdbox",
            markup_kind=IntegrationAccount.Markup.AMOUNT,
            markup_value=Decimal("5"),
        )
        self.lnet = _account("lnet")

    def _session(self, suffix):
        return RegisterSession.objects.create(
            owner=self.user, owner_key=f"user:{self.user.pk}:{suffix}"
        )

    def _hdbox_line(self, card, cost="25.00", months=1):
        resolved = resolve_line_integration(
            {
                "provider": "hdbox",
                "subscriber_ref": card,
                "option_code": f"renew:{months}",
                "option_label": f"{months} month",
                "months": months,
                "cost": Decimal(cost),
            },
            service_variant_for("hdbox"),
        )
        return self._line("hdbox", resolved)

    def _lnet_line(self, line, amount):
        resolved = resolve_line_integration(
            {
                "provider": "lnet",
                "subscriber_ref": line,
                "option_code": f"topup:{amount}",
                "option_label": f"{amount} LYD",
            },
            service_variant_for("lnet"),
        )
        return self._line("lnet", resolved)

    @staticmethod
    def _line(provider, resolved):
        return {
            "variant": service_variant_for(provider),
            "quantity": Decimal("1"),
            "effective_unit_price": resolved["price"],
            "integration": resolved,
        }

    def _sell(self, *lines, session=None):
        total = sum((line["effective_unit_price"] for line in lines), Decimal("0"))
        return checkout_order(
            register_session=session or self.session,
            lines_data=list(lines),
            payments_data=[{"method": "cash", "amount": total}],
            request=None,
        )

    @staticmethod
    def _mark(order, **fields):
        IntegrationFulfillment.objects.filter(order_line__order=order).update(**fields)

    def _integrations(self, session=None):
        response = self.client.get(
            reverse("register-session-summary", args=[(session or self.session).pk])
        )
        self.assertEqual(response.status_code, 200)
        return response.data["integrations"]

    @staticmethod
    def _by_provider(payload):
        return {row["provider"]: row for row in payload["providers"]}

    def test_a_shift_with_no_provider_sales_reports_none(self):
        payload = self._integrations()

        self.assertEqual(payload["providers"], [])
        self.assertEqual(payload["transactions"], [])
        self.assertEqual(payload["totals"]["count"], 0)
        self.assertEqual(payload["totals"]["sold"], "0.00")

    def test_each_provider_is_split_by_what_the_provider_did(self):
        delivered = self._sell(self._hdbox_line("111"))
        self._mark(
            delivered,
            status=IntegrationFulfillment.Status.CONFIRMED,
            provider_reference="558032",
        )
        # Refused for an empty float and put back: paid for, not received.
        refused = self._sell(self._hdbox_line("222"))
        self._mark(refused, last_error_code="insufficient_float")
        # Sent, never answered.
        unknown = self._sell(self._hdbox_line("333", cost="65.00", months=3))
        self._mark(unknown, status=IntegrationFulfillment.Status.SUBMITTED)
        topup = self._sell(self._lnet_line("basheir", 45))
        self._mark(topup, status=IntegrationFulfillment.Status.CONFIRMED)

        payload = self._integrations()
        providers = self._by_provider(payload)

        # Catalog order, so a provider keeps its place from shift to shift.
        self.assertEqual([row["provider"] for row in payload["providers"]], ["hdbox", "lnet"])

        hdbox = providers["hdbox"]
        self.assertEqual(hdbox["count"], 3)
        self.assertEqual(hdbox["sold"], "130.00")   # 30 + 30 + 70
        self.assertEqual(hdbox["cost"], "115.00")   # 25 + 25 + 65
        self.assertEqual(hdbox["margin"], "15.00")
        self.assertEqual(
            hdbox["delivered"], {"count": 1, "amount": "30.00", "cost": "25.00"}
        )
        self.assertEqual(
            hdbox["awaiting"], {"count": 1, "amount": "30.00", "cost": "25.00"}
        )
        self.assertEqual(
            hdbox["unknown"], {"count": 1, "amount": "70.00", "cost": "65.00"}
        )
        self.assertEqual(hdbox["refunded"]["count"], 0)

        # Stored value: 45 of credit costs the float 42.75 and sells at face.
        lnet = providers["lnet"]
        self.assertEqual(lnet["sold"], "45.00")
        self.assertEqual(lnet["cost"], "42.75")
        self.assertEqual(lnet["margin"], "2.25")
        self.assertEqual(lnet["delivered"]["count"], 1)

        totals = payload["totals"]
        self.assertEqual(totals["count"], 4)
        self.assertEqual(totals["sold"], "175.00")
        self.assertEqual(totals["cost"], "157.75")
        self.assertEqual(totals["margin"], "17.25")
        self.assertEqual(totals["awaiting"]["count"], 1)
        self.assertEqual(totals["unknown"]["count"], 1)

        transactions = payload["transactions"]
        self.assertEqual(
            [row["subscriber_ref"] for row in transactions],
            ["111", "222", "333", "basheir"],
        )
        first = transactions[0]
        self.assertEqual(first["order_id"], delivered.pk)
        self.assertEqual(first["receipt_number"], delivered.receipt_number)
        self.assertEqual(first["kind"], "recharge")
        self.assertEqual(first["bucket"], "delivered")
        self.assertEqual(first["status"], "confirmed")
        self.assertEqual(first["provider_reference"], "558032")
        self.assertEqual(first["price"], "30.00")
        self.assertEqual(first["cost"], "25.00")
        self.assertEqual(first["refunded_amount"], "0.00")
        self.assertEqual(transactions[1]["bucket"], "awaiting")
        # The reason travels with it: an empty float is the one a shop can fix.
        self.assertEqual(transactions[1]["error_code"], "insufficient_float")
        self.assertEqual(transactions[2]["bucket"], "unknown")

    def test_a_recharge_refunded_after_the_provider_performed_it_is_called_out(self):
        performed = self._sell(self._hdbox_line("111"))
        self._mark(performed, status=IntegrationFulfillment.Status.CONFIRMED)
        never_sent = self._sell(self._hdbox_line("222"))
        void_order(order=performed, reason="customer changed mind")
        void_order(order=never_sent, reason="wrong card")

        hdbox = self._by_provider(self._integrations())["hdbox"]

        # Neither sale is the shop's any more, so neither is "sold"…
        self.assertEqual(hdbox["count"], 0)
        self.assertEqual(hdbox["sold"], "0.00")
        self.assertEqual(
            hdbox["refunded"], {"count": 2, "amount": "60.00", "cost": "50.00"}
        )
        # …but one of them had already cost the float 25.00, and a void puts
        # no time back on the provider's side. That is the leak to see.
        self.assertEqual(
            hdbox["refunded_after_delivery"], {"count": 1, "cost": "25.00"}
        )

    def test_a_returned_line_leaves_the_rest_of_its_sale_counted(self):
        order = self._sell(self._hdbox_line("111"), self._hdbox_line("222"))
        self._mark(order, status=IntegrationFulfillment.Status.CONFIRMED)
        returned = order.lines.get(integration_fulfillment__subscriber_ref="222")
        return_order_items(
            order=order,
            lines=[(returned, 1)],
            reason="wrong card",
            register_session=self.session,
        )
        order.refresh_from_db()
        self.assertEqual(order.status, Order.Status.PAID)

        payload = self._integrations()
        hdbox = self._by_provider(payload)["hdbox"]

        self.assertEqual(hdbox["delivered"]["count"], 1)
        self.assertEqual(hdbox["sold"], "30.00")
        self.assertEqual(hdbox["refunded"]["count"], 1)
        self.assertEqual(hdbox["refunded_after_delivery"]["count"], 1)
        by_card = {row["subscriber_ref"]: row for row in payload["transactions"]}
        self.assertEqual(by_card["111"]["bucket"], "delivered")
        self.assertEqual(by_card["222"]["bucket"], "refunded")
        self.assertEqual(by_card["222"]["refunded_amount"], "30.00")

    def test_a_card_off_the_shelf_is_reported_as_a_voucher(self):
        qareeb = IntegrationAccount.objects.create(provider="qareeb", username="0910000000")
        qareeb.set_secret(catalog.FIELD_PASSWORD, "secret-pw")
        qareeb.save()
        resolved = {
            "account": qareeb,
            "provider": "qareeb",
            "subscriber": None,
            # A card belongs to nobody until it is scratched.
            "subscriber_ref": "",
            "option_code": "LIBYANA-10",
            "option_label": "ليبيانا 10 دينار",
            "months": 0,
            "package_id": "30",
            "package_name": "ليبيانا",
            "cost": Decimal("9.70"),
            "price": Decimal("10.00"),
        }
        self._sell(self._line("qareeb", resolved))

        payload = self._integrations()

        self.assertEqual(payload["transactions"][0]["kind"], "voucher")
        self.assertEqual(payload["transactions"][0]["option_label"], "ليبيانا 10 دينار")
        self.assertEqual(self._by_provider(payload)["qareeb"]["margin"], "0.30")

    def test_only_the_sessions_own_sales_are_counted(self):
        self._sell(self._hdbox_line("111"))
        other = self._session("b")
        self._sell(self._hdbox_line("999"), session=other)

        payload = self._integrations()

        self.assertEqual(
            [row["subscriber_ref"] for row in payload["transactions"]], ["111"]
        )
        self.assertEqual(self._by_provider(payload)["hdbox"]["count"], 1)

    def test_the_breakdown_costs_the_same_queries_however_busy_the_shift(self):
        def count_queries():
            orders = Order.objects.transactional().filter(register_session=self.session)
            with CaptureQueriesContext(connection) as ctx:
                build_integration_breakdown(orders)
            return len(ctx)

        for card in ("1", "2"):
            self._sell(self._hdbox_line(card))
        two = count_queries()
        for card in ("3", "4", "5", "6"):
            self._sell(self._hdbox_line(card), self._lnet_line(f"line{card}", 20))
        many = count_queries()

        self.assertEqual(two, many)
        # The lines with their order and fulfillment, then their refund lines.
        self.assertLessEqual(many, 2)
