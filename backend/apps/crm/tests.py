from __future__ import annotations

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase, override_settings
from rest_framework.test import APIClient

from apps.core.roles import CASHIER_GROUP, MANAGER_GROUP, ensure_role_groups
from apps.customers.models import Customer
from apps.messaging.models import InboundMessage, MessagingGateway, OutboundMessage
from apps.messaging.services import deliver_message, enqueue_message
from apps.messaging.transports import fake

from .models import Conversation, ConversationMessage
from .services import thread_inbound
from .tasks import route_inbound_task

_EAGER = dict(CELERY_TASK_ALWAYS_EAGER=True, CELERY_TASK_EAGER_PROPAGATES=True)


def make_fake_gateway(**kwargs):
    defaults = dict(
        name="Shop phone",
        provider=MessagingGateway.Provider.FAKE,
        is_default=True,
        is_active=True,
    )
    defaults.update(kwargs)
    return MessagingGateway.objects.create(**defaults)


def make_inbound(gateway, *, phone="+218912345678", body="مرحبا", provider_id="m1"):
    return InboundMessage.objects.create(
        gateway=gateway,
        from_phone=phone,
        from_phone_raw=phone,
        body=body,
        provider_message_id=provider_id,
    )


class RoutingTests(TestCase):
    def setUp(self):
        fake.reset()
        self.gateway = make_fake_gateway()

    def test_threads_new_number_and_mints_placeholder(self):
        inbound = make_inbound(self.gateway)
        route_inbound_task(inbound.id)
        conversation = Conversation.objects.get(phone="+218912345678")
        self.assertEqual(conversation.unread_count, 1)
        self.assertEqual(conversation.messages.count(), 1)
        self.assertIsNotNone(conversation.customer)
        self.assertTrue(conversation.customer.is_auto_created)
        inbound.refresh_from_db()
        self.assertTrue(inbound.handled)
        self.assertEqual(inbound.handled_as, InboundMessage.HandledAs.CONVERSATION)

    def test_matches_existing_customer_by_phone(self):
        customer = Customer.objects.create(full_name="علي", phone="0912345678")
        inbound = make_inbound(self.gateway)
        route_inbound_task(inbound.id)
        conversation = Conversation.objects.get(phone="+218912345678")
        self.assertEqual(conversation.customer_id, customer.id)
        self.assertFalse(Customer.objects.get(pk=customer.pk).is_auto_created)

    def test_second_inbound_reuses_open_thread(self):
        route_inbound_task(make_inbound(self.gateway, provider_id="m1").id)
        route_inbound_task(make_inbound(self.gateway, provider_id="m2", body="ثانية").id)
        self.assertEqual(Conversation.objects.count(), 1)
        conversation = Conversation.objects.get()
        self.assertEqual(conversation.unread_count, 2)
        self.assertEqual(conversation.messages.count(), 2)

    def test_already_handled_is_skipped(self):
        inbound = make_inbound(self.gateway)
        route_inbound_task(inbound.id)
        result = route_inbound_task(inbound.id)
        self.assertEqual(result, "skip")
        self.assertEqual(Conversation.objects.count(), 1)


@override_settings(**_EAGER)
class InboundWebhookTests(TestCase):
    def setUp(self):
        fake.reset()
        self.gateway = make_fake_gateway()
        self.client = APIClient()

    def _url(self, gateway=None):
        return f"/api/messaging/inbound/{(gateway or self.gateway).id}/"

    def test_webhook_records_and_routes(self):
        resp = self.client.post(
            self._url(),
            {"from": "+218912345678", "body": "hi", "id": "abc"},
            format="json",
        )
        self.assertEqual(resp.status_code, 200, resp.content)
        self.assertTrue(resp.data["created"])
        self.assertEqual(InboundMessage.objects.count(), 1)
        self.assertEqual(Conversation.objects.count(), 1)

    def test_webhook_is_idempotent_on_provider_id(self):
        body = {"from": "+218912345678", "body": "hi", "id": "dup"}
        self.client.post(self._url(), body, format="json")
        resp = self.client.post(self._url(), body, format="json")
        self.assertFalse(resp.data["created"])
        self.assertEqual(InboundMessage.objects.count(), 1)
        self.assertEqual(Conversation.objects.get().unread_count, 1)

    def test_unsigned_sms_gate_webhook_is_rejected(self):
        # A real provider with no webhook signing key fails HMAC verification.
        gateway = make_fake_gateway(
            name="real",
            is_default=False,
            provider=MessagingGateway.Provider.SMS_GATE,
            config={"base_url": "http://x"},
        )
        resp = self.client.post(
            self._url(gateway),
            {"from": "+218912345678", "body": "hi", "id": "x"},
            format="json",
        )
        self.assertEqual(resp.status_code, 403)


class ReplyAndReceiptApiTests(TestCase):
    def setUp(self):
        fake.reset()
        self.gateway = make_fake_gateway()
        ensure_role_groups()
        User = get_user_model()
        self.manager = User.objects.create_user(username="mgr", password="x")
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.cashier = User.objects.create_user(username="csh", password="x")
        self.cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.outsider = User.objects.create_user(username="out", password="x")
        self.client = APIClient()
        # Seed an open conversation.
        inbound = make_inbound(self.gateway)
        self.conversation, _ = thread_inbound(inbound)

    def test_manager_reply_queues_outbound_message(self):
        self.client.force_authenticate(self.manager)
        resp = self.client.post(
            f"/api/crm/conversations/{self.conversation.id}/reply/",
            {"body": "شكرًا لتواصلك"},
            format="json",
        )
        self.assertEqual(resp.status_code, 201, resp.content)
        self.assertEqual(resp.data["direction"], "out")
        out = self.conversation.messages.filter(direction="out").first()
        self.assertIsNotNone(out.outbound)
        self.assertEqual(out.outbound.status, OutboundMessage.Status.QUEUED)
        self.assertEqual(out.outbound.consent_class, OutboundMessage.ConsentClass.TRANSACTIONAL)

    def test_reply_without_gateway_is_400(self):
        MessagingGateway.objects.all().delete()
        self.client.force_authenticate(self.manager)
        resp = self.client.post(
            f"/api/crm/conversations/{self.conversation.id}/reply/",
            {"body": "hi"},
            format="json",
        )
        self.assertEqual(resp.status_code, 400)

    def test_mark_read_zeroes_unread(self):
        self.client.force_authenticate(self.manager)
        resp = self.client.post(
            f"/api/crm/conversations/{self.conversation.id}/mark_read/"
        )
        self.assertEqual(resp.status_code, 200)
        self.conversation.refresh_from_db()
        self.assertEqual(self.conversation.unread_count, 0)

    def test_cashier_can_view_but_outsider_cannot(self):
        self.client.force_authenticate(self.cashier)
        self.assertEqual(self.client.get("/api/crm/conversations/").status_code, 200)
        self.client.force_authenticate(self.outsider)
        self.assertEqual(self.client.get("/api/crm/conversations/").status_code, 403)

    def test_delivery_receipt_marks_message_delivered(self):
        message = enqueue_message(to="+218912345678", body="hi", gateway=self.gateway)
        deliver_message(message)
        message.refresh_from_db()
        self.assertEqual(message.status, OutboundMessage.Status.SENT)

        resp = self.client.post(
            f"/api/messaging/receipts/{self.gateway.id}/",
            {"id": message.provider_message_id, "status": "delivered"},
            format="json",
        )
        self.assertEqual(resp.status_code, 200, resp.content)
        message.refresh_from_db()
        self.assertEqual(message.status, OutboundMessage.Status.DELIVERED)
        self.assertIsNotNone(message.delivered_at)


class StartConversationApiTests(TestCase):
    def setUp(self):
        fake.reset()
        self.gateway = make_fake_gateway()
        ensure_role_groups()
        User = get_user_model()
        self.manager = User.objects.create_user(username="mgr", password="x")
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.outsider = User.objects.create_user(username="out", password="x")
        self.client = APIClient()

    def _start(self, customer_id):
        return self.client.post(
            "/api/crm/conversations/start/",
            {"customer": customer_id},
            format="json",
        )

    def test_manager_starts_conversation_with_customer(self):
        customer = Customer.objects.create(full_name="علي", phone="0912345678")
        self.client.force_authenticate(self.manager)
        resp = self._start(customer.id)
        self.assertEqual(resp.status_code, 201, resp.content)
        self.assertEqual(resp.data["customer"], customer.id)
        # The thread is keyed on the E.164-normalized number.
        self.assertEqual(resp.data["phone"], "+218912345678")
        self.assertEqual(resp.data["status"], "open")
        self.assertEqual(Conversation.objects.count(), 1)

    def test_start_is_idempotent_for_an_open_thread(self):
        customer = Customer.objects.create(full_name="علي", phone="0912345678")
        self.client.force_authenticate(self.manager)
        first = self._start(customer.id)
        second = self._start(customer.id)
        self.assertEqual(first.status_code, 201)
        # An already-open thread is resumed, not duplicated.
        self.assertEqual(second.status_code, 200)
        self.assertEqual(first.data["id"], second.data["id"])
        self.assertEqual(Conversation.objects.count(), 1)

    def test_start_adopts_an_unclaimed_open_thread(self):
        # A thread with no linked customer (e.g. an unclaimed inbound) is adopted
        # by the named customer the user picked.
        Conversation.objects.create(
            phone="+218912345678",
            phone_raw="+218912345678",
            status=Conversation.Status.OPEN,
        )
        customer = Customer.objects.create(full_name="علي", phone="0912345678")
        self.client.force_authenticate(self.manager)
        resp = self._start(customer.id)
        self.assertEqual(resp.status_code, 200, resp.content)
        self.assertEqual(resp.data["customer"], customer.id)
        self.assertEqual(Conversation.objects.count(), 1)

    def test_start_requires_a_valid_phone(self):
        customer = Customer.objects.create(full_name="بلا هاتف", phone="")
        self.client.force_authenticate(self.manager)
        resp = self._start(customer.id)
        self.assertEqual(resp.status_code, 400)
        self.assertEqual(Conversation.objects.count(), 0)

    def test_start_with_missing_or_unknown_customer(self):
        self.client.force_authenticate(self.manager)
        self.assertEqual(self._start("").status_code, 400)
        self.assertEqual(self._start(999999).status_code, 404)

    def test_outsider_cannot_start(self):
        customer = Customer.objects.create(full_name="علي", phone="0912345678")
        self.client.force_authenticate(self.outsider)
        self.assertEqual(self._start(customer.id).status_code, 403)
        self.assertEqual(Conversation.objects.count(), 0)
