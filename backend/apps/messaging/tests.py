from __future__ import annotations

from datetime import time

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.core.cache import cache
from django.test import TestCase, override_settings
from django.utils import timezone
from rest_framework.test import APIClient

from apps.core.roles import CASHIER_GROUP, MANAGER_GROUP, ensure_role_groups

from .models import MessagingGateway, OutboundMessage
from .phone import normalize_phone
from .secrets import decrypt_secrets, encrypt_secrets
from .segments import count_segments
from .services import NoGatewayConfigured, deliver_message, enqueue_message
from .tasks import dispatch_outbound_task
from .transports import fake

_LOCMEM = {"default": {"BACKEND": "django.core.cache.backends.locmem.LocMemCache"}}


def make_gateway(**kwargs):
    defaults = dict(name="Shop phone", provider=MessagingGateway.Provider.FAKE, is_default=True)
    defaults.update(kwargs)
    return MessagingGateway.objects.create(**defaults)


class SecretStorageTests(TestCase):
    def test_roundtrip_and_ciphertext_hides_plaintext(self):
        token = encrypt_secrets({"password": "s3cr3t", "webhook_signing_key": "k"})
        self.assertNotIn("s3cr3t", token)
        self.assertEqual(decrypt_secrets(token), {"password": "s3cr3t", "webhook_signing_key": "k"})

    def test_corrupt_token_yields_empty(self):
        self.assertEqual(decrypt_secrets("not-a-real-token"), {})
        self.assertEqual(decrypt_secrets(""), {})

    def test_gateway_secret_helpers(self):
        gateway = make_gateway()
        gateway.set_secret("password", "hunter2")
        gateway.save()
        gateway.refresh_from_db()
        self.assertEqual(gateway.get_secret("password"), "hunter2")
        self.assertTrue(gateway.has_secret("password"))
        self.assertNotIn("hunter2", gateway.secrets_encrypted)
        gateway.set_secret("password", "")
        self.assertFalse(gateway.has_secret("password"))


class PhoneNormalizationTests(TestCase):
    def test_libya_formats_resolve_to_one_key(self):
        expected = "+218912345678"
        for raw in ("+218912345678", "00218912345678", "0912345678", "091 234 5678"):
            self.assertEqual(normalize_phone(raw), expected, raw)

    def test_unparseable_returns_empty(self):
        self.assertEqual(normalize_phone(""), "")
        self.assertEqual(normalize_phone("abc"), "")


class SegmentCountingTests(TestCase):
    def test_gsm7_within_one_segment(self):
        self.assertEqual(count_segments("Hello, your order is ready."), 1)
        self.assertEqual(count_segments("A" * 160), 1)
        self.assertEqual(count_segments("A" * 161), 2)

    def test_arabic_is_ucs2_70_per_segment(self):
        # 70 Arabic chars still one segment; 71 tips into a second.
        self.assertEqual(count_segments("ش" * 70), 1)
        self.assertEqual(count_segments("ش" * 71), 2)

    def test_emoji_counts_as_two_ucs2_units(self):
        # 35 astral emoji = 70 UTF-16 units = one segment; 36 tips over.
        self.assertEqual(count_segments("😀" * 35), 1)
        self.assertEqual(count_segments("😀" * 36), 2)


class EnqueueTests(TestCase):
    def setUp(self):
        fake.reset()
        self.gateway = make_gateway()

    def test_requires_a_gateway(self):
        MessagingGateway.objects.all().delete()
        with self.assertRaises(NoGatewayConfigured):
            enqueue_message(to="+218912345678", body="hi")

    def test_normalizes_and_counts_segments(self):
        msg = enqueue_message(to="0912345678", body="ش" * 71)
        self.assertEqual(msg.to_phone, "+218912345678")
        self.assertEqual(msg.to_phone_raw, "0912345678")
        self.assertEqual(msg.segments, 2)
        self.assertEqual(msg.status, OutboundMessage.Status.QUEUED)

    def test_bad_number_is_terminally_failed(self):
        msg = enqueue_message(to="garbage", body="hi")
        self.assertEqual(msg.status, OutboundMessage.Status.FAILED)
        self.assertEqual(msg.error_code, "bad_number")

    def test_dedup_key_is_idempotent(self):
        a = enqueue_message(to="+218912345678", body="one", dedup_key="invoice:5")
        b = enqueue_message(to="+218912345678", body="two", dedup_key="invoice:5")
        self.assertEqual(a.pk, b.pk)
        self.assertEqual(OutboundMessage.objects.count(), 1)
        self.assertEqual(b.body, "one")  # second call did not overwrite

    def test_scheduled_when_not_before_set(self):
        later = timezone.now() + timezone.timedelta(hours=1)
        msg = enqueue_message(to="+218912345678", body="hi", not_before=later)
        self.assertEqual(msg.status, OutboundMessage.Status.SCHEDULED)


class DeliverTests(TestCase):
    def setUp(self):
        fake.reset()
        self.gateway = make_gateway()

    def test_queued_message_is_sent(self):
        msg = enqueue_message(to="+218912345678", body="hi")
        deliver_message(msg)
        msg.refresh_from_db()
        self.assertEqual(msg.status, OutboundMessage.Status.SENT)
        self.assertTrue(msg.provider_message_id)
        self.assertEqual(len(fake.SENT_MESSAGES), 1)

    def test_retryable_failure_requeues(self):
        gw = make_gateway(name="flaky", is_default=False, config={"fail_with": "unreachable"})
        msg = enqueue_message(to="+218912345678", body="hi", gateway=gw)
        deliver_message(msg)
        msg.refresh_from_db()
        self.assertEqual(msg.status, OutboundMessage.Status.QUEUED)
        self.assertEqual(msg.attempts, 1)
        self.assertIsNotNone(msg.next_attempt_at)

    def test_permanent_failure_is_terminal(self):
        gw = make_gateway(name="badauth", is_default=False, config={"fail_with": "unauthorized"})
        msg = enqueue_message(to="+218912345678", body="hi", gateway=gw)
        deliver_message(msg)
        msg.refresh_from_db()
        self.assertEqual(msg.status, OutboundMessage.Status.FAILED)
        self.assertEqual(msg.error_code, "unauthorized")

    def test_exhausts_attempts(self):
        gw = make_gateway(name="flaky", is_default=False, config={"fail_with": "unreachable"})
        msg = enqueue_message(to="+218912345678", body="hi", gateway=gw, max_attempts=2)
        deliver_message(msg)  # attempt 1 -> requeue
        msg.refresh_from_db()
        msg.next_attempt_at = None
        msg.save(update_fields=["next_attempt_at"])
        deliver_message(msg)  # attempt 2 -> failed
        msg.refresh_from_db()
        self.assertEqual(msg.status, OutboundMessage.Status.FAILED)
        self.assertEqual(msg.attempts, 2)


@override_settings(CACHES=_LOCMEM)
class DispatchPacingTests(TestCase):
    def setUp(self):
        fake.reset()
        cache.clear()

    def test_dispatch_sends_queued(self):
        make_gateway()
        for i in range(3):
            enqueue_message(to="+21891234567%d" % i, body="hi")
        result = dispatch_outbound_task()
        self.assertEqual(result["sent"], 3)
        self.assertEqual(OutboundMessage.objects.filter(status="sent").count(), 3)

    def test_per_minute_throttle_caps_a_tick(self):
        make_gateway(max_messages_per_minute=2)
        for i in range(5):
            enqueue_message(to="+2189123456%02d" % i, body="hi")
        dispatch_outbound_task()
        self.assertEqual(OutboundMessage.objects.filter(status="sent").count(), 2)
        self.assertEqual(OutboundMessage.objects.filter(status="queued").count(), 3)

    def test_quiet_hours_holds_marketing_but_not_transactional(self):
        # A window covering all 24h so "now" is always inside it.
        make_gateway(quiet_hours_start=time(0, 0), quiet_hours_end=time(23, 59))
        enqueue_message(to="+218912345670", body="promo", consent_class=OutboundMessage.ConsentClass.MARKETING)
        enqueue_message(to="+218912345671", body="receipt", consent_class=OutboundMessage.ConsentClass.TRANSACTIONAL)
        dispatch_outbound_task()
        marketing = OutboundMessage.objects.get(to_phone="+218912345670")
        transactional = OutboundMessage.objects.get(to_phone="+218912345671")
        self.assertEqual(marketing.status, OutboundMessage.Status.QUEUED)
        self.assertEqual(transactional.status, OutboundMessage.Status.SENT)

    def test_daily_cap_stops_sending(self):
        make_gateway(daily_cap=1)
        for i in range(3):
            enqueue_message(to="+21891234560%d" % i, body="hi")
        dispatch_outbound_task()
        self.assertEqual(OutboundMessage.objects.filter(status="sent").count(), 1)


class GatewayApiTests(TestCase):
    def setUp(self):
        fake.reset()
        ensure_role_groups()
        User = get_user_model()
        self.manager = User.objects.create_user(username="mgr", password="x")
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.cashier = User.objects.create_user(username="csh", password="x")
        self.cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.client = APIClient()

    def test_manager_can_create_gateway_and_secret_is_write_only(self):
        self.client.force_authenticate(self.manager)
        resp = self.client.post(
            "/api/messaging/gateways/",
            {
                "name": "Front desk",
                "provider": "fake",
                "config": {},
                "password": "hunter2",
                "is_default": True,
            },
            format="json",
        )
        self.assertEqual(resp.status_code, 201, resp.content)
        self.assertNotIn("password", resp.data)
        self.assertTrue(resp.data["has_password"])
        gateway = MessagingGateway.objects.get(pk=resp.data["id"])
        self.assertEqual(gateway.get_secret("password"), "hunter2")

    def test_test_send_delivers_immediately(self):
        gateway = make_gateway()
        self.client.force_authenticate(self.manager)
        resp = self.client.post(
            f"/api/messaging/gateways/{gateway.pk}/test_send/",
            {"to": "+218912345678", "body": "ping"},
            format="json",
        )
        self.assertEqual(resp.status_code, 200, resp.content)
        self.assertEqual(resp.data["status"], "sent")
        self.assertEqual(len(fake.SENT_MESSAGES), 1)

    def test_cashier_cannot_manage_gateways(self):
        self.client.force_authenticate(self.cashier)
        resp = self.client.get("/api/messaging/gateways/")
        self.assertEqual(resp.status_code, 403)


class GatewayActivationTests(TestCase):
    def setUp(self):
        fake.reset()
        ensure_role_groups()
        User = get_user_model()
        self.manager = User.objects.create_user(username="mgr", password="x")
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.gateway = make_gateway()
        self.client = APIClient()

    def test_activate_provisions_token_registers_webhooks_and_activates(self):
        self.client.force_authenticate(self.manager)
        resp = self.client.post(
            f"/api/messaging/gateways/{self.gateway.id}/activate/"
        )
        self.assertEqual(resp.status_code, 200, resp.content)
        self.assertTrue(resp.data["ok"])
        self.assertEqual(len(fake.REGISTERED_WEBHOOKS), 1)
        self.gateway.refresh_from_db()
        self.assertTrue(self.gateway.is_active)
        self.assertTrue(self.gateway.is_default)
        self.assertTrue(self.gateway.has_secret("webhook_token"))
        registered = fake.REGISTERED_WEBHOOKS[0]
        self.assertIn(f"/inbound/{self.gateway.id}/", registered["inbound"])
        self.assertIn("token=", registered["inbound"])


@override_settings(**_LOCMEM, CELERY_TASK_ALWAYS_EAGER=True, CELERY_TASK_EAGER_PROPAGATES=True)
class TokenInboundAuthTests(TestCase):
    def setUp(self):
        fake.reset()
        self.gateway = make_gateway()
        self.token = "secret-webhook-token-xyz"
        self.gateway.set_secret("webhook_token", self.token)
        self.gateway.save()
        self.client = APIClient()

    def _url(self, token=None):
        base = f"/api/messaging/inbound/{self.gateway.id}/"
        return f"{base}?token={token}" if token else base

    def test_correct_token_accepted(self):
        resp = self.client.post(
            self._url(self.token),
            {"from": "+218912345678", "body": "hi", "id": "t1"},
            format="json",
        )
        self.assertEqual(resp.status_code, 200, resp.content)

    def test_missing_token_rejected(self):
        resp = self.client.post(self._url(), {"id": "t2"}, format="json")
        self.assertEqual(resp.status_code, 403)

    def test_wrong_token_rejected(self):
        resp = self.client.post(self._url("nope"), {"id": "t3"}, format="json")
        self.assertEqual(resp.status_code, 403)
