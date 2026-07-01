from __future__ import annotations

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.utils import timezone
from rest_framework.test import APIClient

from apps.core.roles import CASHIER_GROUP, MANAGER_GROUP, ensure_role_groups
from apps.customers.models import Customer
from apps.messaging.models import InboundMessage, MessagingGateway, OutboundMessage
from apps.messaging.transports import fake

from .consent import can_send, parse_consent_command
from .models import ConsentEvent, Conversation
from .tasks import route_inbound_task

_MARKETING = OutboundMessage.ConsentClass.MARKETING
_TRANSACTIONAL = OutboundMessage.ConsentClass.TRANSACTIONAL


def make_gateway():
    return MessagingGateway.objects.create(
        name="phone", provider=MessagingGateway.Provider.FAKE, is_default=True
    )


def make_inbound(gateway, *, body, phone="+218912345678", pid="m1"):
    return InboundMessage.objects.create(
        gateway=gateway,
        from_phone=phone,
        from_phone_raw=phone,
        body=body,
        provider_message_id=pid,
    )


class ParseConsentTests(TestCase):
    def test_opt_out_keywords(self):
        for msg in ["STOP", "stop please", "إيقاف الرسائل", "الغاء", "توقف"]:
            self.assertEqual(
                parse_consent_command(msg), ConsentEvent.Action.OPT_OUT, msg
            )

    def test_opt_in_keywords(self):
        for msg in ["START", "subscribe", "اشتراك", "ابدأ"]:
            self.assertEqual(
                parse_consent_command(msg), ConsentEvent.Action.OPT_IN, msg
            )

    def test_normal_messages_are_not_commands(self):
        for msg in ["مرحبا هل الطلب جاهز", "لا شكرا", "thanks", "نعم من فضلك", ""]:
            self.assertIsNone(parse_consent_command(msg), msg)


class CanSendTests(TestCase):
    def setUp(self):
        self.customer = Customer.objects.create(full_name="علي", phone="+218912345678")

    def test_transactional_always_allowed_even_when_opted_out(self):
        self.customer.marketing_opted_out_at = timezone.now()
        self.customer.do_not_contact = True
        self.customer.save()
        ok, _ = can_send(self.customer, _TRANSACTIONAL)
        self.assertTrue(ok)

    def test_marketing_allowed_by_default(self):
        ok, _ = can_send(self.customer, _MARKETING)
        self.assertTrue(ok)

    def test_marketing_blocked_when_opted_out(self):
        self.customer.marketing_opted_out_at = timezone.now()
        self.customer.save()
        ok, reason = can_send(self.customer, _MARKETING)
        self.assertFalse(ok)
        self.assertEqual(reason, "opted_out")

    def test_marketing_blocked_do_not_contact(self):
        self.customer.do_not_contact = True
        self.customer.save()
        ok, reason = can_send(self.customer, _MARKETING)
        self.assertFalse(ok)
        self.assertEqual(reason, "do_not_contact")

    def test_marketing_blocked_without_phone(self):
        customer = Customer.objects.create(full_name="بلا هاتف", phone="")
        ok, reason = can_send(customer, _MARKETING)
        self.assertFalse(ok)
        self.assertEqual(reason, "no_phone")

    def test_no_customer(self):
        ok, reason = can_send(None, _MARKETING)
        self.assertFalse(ok)
        self.assertEqual(reason, "no_customer")


class ConsentRoutingTests(TestCase):
    def setUp(self):
        fake.reset()
        self.gateway = make_gateway()

    def test_stop_opts_out_confirms_and_does_not_thread(self):
        inbound = make_inbound(self.gateway, body="STOP")
        result = route_inbound_task(inbound.id)
        self.assertEqual(result, "consent")

        customer = Customer.objects.get()
        self.assertIsNotNone(customer.marketing_opted_out_at)
        self.assertTrue(
            ConsentEvent.objects.filter(
                customer=customer, action="opt_out", source="sms_command"
            ).exists()
        )
        # A transactional confirmation is queued (reaches even an opted-out number).
        self.assertTrue(
            OutboundMessage.objects.filter(
                consent_class=_TRANSACTIONAL, source_type="consent_confirmation"
            ).exists()
        )
        # Consent wins: the STOP is not swallowed into a conversation.
        self.assertEqual(Conversation.objects.count(), 0)
        inbound.refresh_from_db()
        self.assertEqual(inbound.handled_as, InboundMessage.HandledAs.CONSENT_COMMAND)

    def test_start_opts_in_existing_customer(self):
        customer = Customer.objects.create(
            full_name="علي", phone="0912345678", marketing_opted_out_at=timezone.now()
        )
        route_inbound_task(make_inbound(self.gateway, body="START").id)
        customer.refresh_from_db()
        self.assertIsNone(customer.marketing_opted_out_at)
        self.assertTrue(
            ConsentEvent.objects.filter(customer=customer, action="opt_in").exists()
        )

    def test_arabic_stop_matches_existing_customer(self):
        customer = Customer.objects.create(full_name="علي", phone="0912345678")
        route_inbound_task(make_inbound(self.gateway, body="ايقاف").id)
        customer.refresh_from_db()
        self.assertIsNotNone(customer.marketing_opted_out_at)

    def test_normal_message_still_threads(self):
        route_inbound_task(make_inbound(self.gateway, body="مرحبا").id)
        self.assertEqual(Conversation.objects.count(), 1)
        self.assertEqual(ConsentEvent.objects.count(), 0)


class ConsentApiTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        User = get_user_model()
        self.manager = User.objects.create_user(username="mgr", password="x")
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.cashier = User.objects.create_user(username="csh", password="x")
        self.cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.customer = Customer.objects.create(full_name="علي", phone="+218912345678")
        self.client = APIClient()

    def _url(self):
        return f"/api/crm/customers/{self.customer.id}/consent/"

    def test_manager_sets_opt_out_and_records_event(self):
        self.client.force_authenticate(self.manager)
        resp = self.client.post(
            self._url(), {"marketing_opted_out": True}, format="json"
        )
        self.assertEqual(resp.status_code, 200, resp.content)
        self.assertTrue(resp.data["marketing_opted_out"])
        self.customer.refresh_from_db()
        self.assertIsNotNone(self.customer.marketing_opted_out_at)
        self.assertTrue(
            ConsentEvent.objects.filter(
                customer=self.customer, action="opt_out", source="admin_ui"
            ).exists()
        )

    def test_manager_sets_do_not_contact(self):
        self.client.force_authenticate(self.manager)
        resp = self.client.post(self._url(), {"do_not_contact": True}, format="json")
        self.assertEqual(resp.status_code, 200)
        self.assertTrue(resp.data["do_not_contact"])
        self.assertFalse(resp.data["can_market"])

    def test_get_returns_state(self):
        self.client.force_authenticate(self.manager)
        resp = self.client.get(self._url())
        self.assertEqual(resp.status_code, 200)
        self.assertIn("can_market", resp.data)

    def test_cashier_forbidden(self):
        self.client.force_authenticate(self.cashier)
        self.assertEqual(self.client.get(self._url()).status_code, 403)
