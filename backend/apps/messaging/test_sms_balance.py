"""SMS paid from the shop's SMS balance: the gate before a message is queued,
what a send's answer does to the shop's copy of the balance, and the settings
page's view of it."""

from __future__ import annotations

from decimal import Decimal
from unittest import mock

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.core.cache import cache
from django.test import TestCase, override_settings
from rest_framework.test import APIClient

from apps.core.models import RelayInstallation
from apps.core.roles import MANAGER_GROUP, ensure_role_groups

from .models import OutboundMessage
from .services import NoGatewayConfigured, deliver_message, enqueue_message, unavailable_message
from .sms_templates import sms_template
from .test_relay_sms import _DRIVER, _LOCMEM, relay_gateway, relay_refusal


def prepaid(balance="15.000", price="0.150"):
    return RelayInstallation.objects.create(
        installation_id="inst-1",
        relay_public_api_url="https://relay.example",
        connector_token="c",
        access_token="access-token",
        sms_balance=Decimal(balance),
        sms_price=Decimal(price),
    )


def invoice_message():
    return sms_template("invoice", "محل النور", "000123", "125.00 د.ل")


def long_invoice_message():
    # A long shop name takes the invoice past one SMS (70 Arabic letters).
    return sms_template("invoice", "مؤسسة النور للمواد الغذائية والمنظفات", "000123", "125.00 د.ل")


@override_settings(CACHES=_LOCMEM)
class SmsBalanceSendTests(TestCase):
    def setUp(self):
        cache.clear()
        self.gateway = relay_gateway()
        self.relay = mock.Mock()
        patcher = mock.patch(_DRIVER, return_value=self.relay)
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_an_empty_balance_queues_nothing_and_says_how_to_fill_it(self):
        prepaid(balance="0.100")
        with self.assertRaises(NoGatewayConfigured) as raised:
            enqueue_message(to="0912345678", template=invoice_message())
        self.assertEqual(raised.exception.code, "insufficient_balance")
        self.assertIn("رصيد الرسائل", unavailable_message(raised.exception))
        self.assertFalse(OutboundMessage.objects.exists())

    def test_a_send_keeps_the_shops_copy_of_the_balance(self):
        prepaid(balance="0.150")
        message = enqueue_message(to="0912345678", template=invoice_message())
        self.relay.send_sms.return_value = {
            "id": "ledger-1", "status": "sent", "content": "نص", "balance": "0.000",
        }
        with mock.patch("apps.core.caching.bump_perm_version") as bump:
            deliver_message(message)
        message.refresh_from_db()
        self.assertEqual(message.status, OutboundMessage.Status.SENT)
        installation = RelayInstallation.objects.get()
        self.assertEqual(installation.sms_balance, Decimal("0"))
        bump.assert_called_once()  # the last message: devices stop offering SMS

    def test_a_long_message_needs_the_price_of_every_part(self):
        # One part's worth sends a short invoice but not a two-part one: the
        # relay charges per SMS part and would refuse it after queueing.
        prepaid(balance="0.150")
        with self.assertRaises(NoGatewayConfigured) as raised:
            enqueue_message(to="0912345678", template=long_invoice_message())
        self.assertEqual(raised.exception.code, "insufficient_balance")
        self.assertIn("لهذه الرسالة", unavailable_message(raised.exception))
        self.assertFalse(OutboundMessage.objects.exists())
        message = enqueue_message(to="0912345678", template=invoice_message())
        self.assertEqual(message.segments, 1)
        RelayInstallation.objects.update(sms_balance=Decimal("0.300"))
        self.assertEqual(enqueue_message(to="0912345679", template=long_invoice_message()).segments, 2)

    def test_the_parts_the_relay_charged_are_what_the_message_cost(self):
        prepaid(balance="15.000")
        message = enqueue_message(to="0912345678", template=invoice_message())
        self.assertEqual(message.segments, 1)
        # Resala sent it as two SMS (an approved text longer than ours): the
        # relay charged two parts, and the log says so.
        self.relay.send_sms.return_value = {
            "id": "ledger-1", "status": "sent", "content": message.body,
            "parts": 2, "charged": "0.300", "balance": "14.700",
        }
        deliver_message(message)
        message.refresh_from_db()
        self.assertEqual(message.status, OutboundMessage.Status.SENT)
        self.assertEqual(message.segments, 2)
        self.assertEqual(RelayInstallation.objects.get().sms_balance, Decimal("14.700"))

    def test_an_older_relay_that_reports_no_parts_keeps_our_count(self):
        prepaid(balance="15.000")
        message = enqueue_message(to="0912345678", template=long_invoice_message())
        self.relay.send_sms.return_value = {"id": "ledger-1", "status": "sent", "content": message.body, "parts": "x"}
        deliver_message(message)
        message.refresh_from_db()
        self.assertEqual(message.segments, 2)

    def test_a_refusal_for_money_is_final_and_turns_sms_off_here(self):
        prepaid(balance="15.000")
        message = enqueue_message(to="0912345678", template=invoice_message())
        self.relay.send_sms.side_effect = relay_refusal(402, "insufficient_balance", balance="0.000", price="0.150")
        deliver_message(message)
        message.refresh_from_db()
        self.assertEqual(message.status, OutboundMessage.Status.FAILED)
        self.assertEqual(message.error_code, "insufficient_balance")
        self.assertEqual(RelayInstallation.objects.get().sms_balance, Decimal("0"))
        with self.assertRaises(NoGatewayConfigured):
            enqueue_message(to="0912345678", template=invoice_message())


@override_settings(CACHES=_LOCMEM)
class SmsBalanceStatusTests(TestCase):
    def setUp(self):
        cache.clear()
        ensure_role_groups()
        user = get_user_model().objects.create_user(username="mgr", password="x")
        user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.api = APIClient()
        self.api.force_authenticate(user)
        relay_gateway()
        self.relay = mock.Mock()
        patcher = mock.patch("apps.messaging.status.scoped_relay_client", return_value=self.relay)
        patcher.start()
        self.addCleanup(patcher.stop)

    def usage(self, **overrides):
        usage = {
            "used": 3, "limit": 0, "remaining": -1,
            "period_start": "2026-10-01T00:00:00+02:00", "resets_at": "2026-11-01T00:00:00+02:00",
            "balance": "0.000", "price": "0.150", "messages_left": 0, "available": False,
            "entitled": False, "configured": True, "test_mode": False, "kinds": ["invoice"],
        }
        usage.update(overrides)
        return usage

    def test_an_empty_balance_is_shown_not_hidden(self):
        prepaid(balance="1.500")
        self.relay.get_sms_usage.return_value = self.usage()
        resp = self.api.get("/api/messaging/status/")
        self.assertEqual(resp.status_code, 200, resp.content)
        self.assertFalse(resp.data["entitled"])
        self.assertEqual(resp.data["usage_error"], "")
        self.assertEqual(resp.data["sms_wallet"], {"balance": "0.000", "price": "0.150", "messages_left": 0})
        self.assertEqual(resp.data["usage"]["used"], 3)
        # The relay's answer is fresher than the shop's copy, which follows it.
        self.assertEqual(RelayInstallation.objects.get().sms_balance, Decimal("0"))

    def test_a_funded_shop_sees_how_many_messages_it_has_left(self):
        prepaid(balance="0")
        self.relay.get_sms_usage.return_value = self.usage(balance="4.500", messages_left=30, available=True, entitled=True)
        resp = self.api.get("/api/messaging/status/")
        self.assertTrue(resp.data["entitled"])
        self.assertTrue(resp.data["available"])
        self.assertEqual(resp.data["sms_wallet"]["messages_left"], 30)
