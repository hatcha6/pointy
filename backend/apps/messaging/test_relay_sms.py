"""SMS through the company relay: templates, the relay driver, the settings
status, delivery polling, and the session flag."""

from __future__ import annotations

import json
import re
from datetime import timedelta
from unittest import mock

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.core.cache import cache
from django.test import TestCase, override_settings
from django.utils import timezone
from rest_framework.test import APIClient

from apps.core.models import RelayInstallation
from apps.core.relay import RelayControlError, note_relay_transport_failure
from apps.core.roles import CASHIER_GROUP, MANAGER_GROUP, ensure_role_groups

from .models import MessagingGateway, OutboundMessage
from .services import (
    NoGatewayConfigured,
    deliver_message,
    enqueue_message,
    sync_delivery_statuses,
)
from .sms_templates import (
    EMPTY_VALUE,
    MAX_VALUE_LENGTH,
    SMS_TEMPLATE_SPECS,
    SMS_TEMPLATES,
    SmsValueTooLong,
    UnknownSmsTemplate,
    render_text,
    sms_template,
)
from .transports import fake

_LOCMEM = {"default": {"BACKEND": "django.core.cache.backends.locmem.LocMemCache"}}
_DRIVER = "apps.messaging.transports.relay.scoped_relay_client"


def entitle(*, sms=True, active=True, ends_at=None):
    return RelayInstallation.objects.create(
        installation_id="inst-1",
        relay_public_api_url="https://relay.example",
        connector_token="c",
        access_token="access-token",
        subscription_active=active,
        sms_enabled=sms,
        subscription_ends_at=ends_at,
    )


def relay_gateway(**kwargs):
    defaults = dict(
        name="رسائل دفتر", provider=MessagingGateway.Provider.RELAY, is_default=True
    )
    defaults.update(kwargs)
    return MessagingGateway.objects.create(**defaults)


def relay_refusal(status, code="", **extra):
    body = json.dumps({"error": code or "refused", "code": code, **extra}) if code else "<html>"
    return RelayControlError(f"relay {status}", status_code=status, body=body)


class SmsTemplateCatalogTests(TestCase):
    def test_every_sample_fills_every_slot(self):
        for spec in SMS_TEMPLATE_SPECS:
            with self.subTest(kind=spec.kind):
                self.assertEqual(len(spec.sample), len(spec.variables))
                self.assertNotIn("$", spec.example)

    def test_slots_are_numbered_one_to_n_with_none_missing(self):
        # The relay sends values as $1..$n; a gap would leave a slot unfilled.
        for spec in SMS_TEMPLATE_SPECS:
            with self.subTest(kind=spec.kind):
                used = {int(token) for token in re.findall(r"\$(\d+)", spec.text)}
                self.assertEqual(used, set(range(1, len(spec.variables) + 1)))

    def test_every_template_names_the_shop(self):
        # The SMS arrives from the company's sender id, so the text must say who.
        for spec in SMS_TEMPLATE_SPECS:
            with self.subTest(kind=spec.kind):
                self.assertIn("اسم المحل", spec.variables)

    def test_only_marketing_is_marketing(self):
        marketing = {s.kind for s in SMS_TEMPLATE_SPECS if s.consent_class == "marketing"}
        self.assertEqual(marketing, {"marketing"})

    def test_values_are_one_line_and_never_empty(self):
        template = sms_template("batch_recall", "محل\nالنور", "دواء", "L-1", "  ")
        self.assertEqual(template.values[0], "محل النور")
        self.assertEqual(template.values[3], EMPTY_VALUE)

    def test_a_value_is_not_rescanned_for_slots(self):
        self.assertEqual(render_text("$1 / $2", ["$2", "b"]), "$2 / b")

    def test_wrong_value_count_and_unknown_kind_are_refused(self):
        with self.assertRaises(ValueError):
            sms_template("invoice", "only one")
        with self.assertRaises(UnknownSmsTemplate):
            sms_template("nope", "x")

    def test_a_value_the_provider_refuses_is_refused_here(self):
        with self.assertRaises(SmsValueTooLong):
            sms_template("direct", "محل", "ش" * (MAX_VALUE_LENGTH + 1))


@override_settings(CACHES=_LOCMEM, POINTY_SMS_TEST_MODE=False)
class RelayDriverTests(TestCase):
    def setUp(self):
        cache.clear()
        entitle()
        self.gateway = relay_gateway()
        self.client_mock = mock.Mock()
        patcher = mock.patch(_DRIVER, return_value=self.client_mock)
        patcher.start()
        self.addCleanup(patcher.stop)

    def _queue(self, **kwargs):
        return enqueue_message(
            to="0912345678",
            template=sms_template("invoice", "محل النور", "000123", "125.00 د.ل"),
            **kwargs,
        )

    def test_sends_the_template_kind_and_values_with_an_idempotency_key(self):
        self.client_mock.send_sms.return_value = {
            "id": "ledger-1",
            "status": "sent",
            "content": "شكرًا لتسوقك من محل النور. فاتورتك رقم 000123 بقيمة 125.00 د.ل.",
        }
        message = self._queue()
        deliver_message(message)
        message.refresh_from_db()

        kwargs = self.client_mock.send_sms.call_args.kwargs
        self.assertEqual(kwargs["kind"], "invoice")
        self.assertEqual(kwargs["variables"], ["محل النور", "000123", "125.00 د.ل"])
        self.assertEqual(kwargs["to"], "+218912345678")
        self.assertEqual(kwargs["access_token"], "access-token")
        self.assertEqual(kwargs["consent_class"], "transactional")
        self.assertFalse(kwargs["test"])
        self.assertEqual(kwargs["idempotency_key"], message.relay_idempotency_key)
        self.assertTrue(kwargs["idempotency_key"].startswith(f"{message.pk}-"))
        self.assertEqual(message.status, OutboundMessage.Status.SENT)
        self.assertEqual(message.provider_message_id, "ledger-1")

    @override_settings(POINTY_SMS_TEST_MODE=True)
    def test_a_development_machine_asks_for_test_mode(self):
        self.client_mock.send_sms.return_value = {"id": "x", "status": "sent"}
        deliver_message(self._queue())
        self.assertTrue(self.client_mock.send_sms.call_args.kwargs["test"])

    def test_the_log_shows_the_text_the_provider_actually_sent(self):
        approved = "نص معتمد بصياغة مختلفة قليلًا"
        self.client_mock.send_sms.return_value = {"id": "x", "status": "sent", "content": approved}
        message = self._queue()
        deliver_message(message)
        message.refresh_from_db()
        self.assertEqual(message.body, approved)

    def test_an_unreachable_relay_waits_without_spending_an_attempt(self):
        self.client_mock.send_sms.side_effect = RelayControlError("relay down")
        message = self._queue(max_attempts=1)
        deliver_message(message)
        message.refresh_from_db()
        self.assertEqual(message.status, OutboundMessage.Status.QUEUED)
        self.assertEqual(message.attempts, 0)
        self.assertEqual(message.error_code, "relay_unreachable")
        self.assertGreater(message.next_attempt_at, timezone.now() + timedelta(minutes=4))

    def test_a_relay_known_to_be_down_is_not_called_again(self):
        note_relay_transport_failure()
        message = self._queue()
        deliver_message(message)
        message.refresh_from_db()
        self.client_mock.send_sms.assert_not_called()
        self.assertEqual(message.status, OutboundMessage.Status.QUEUED)

    def test_a_message_waiting_a_whole_day_is_given_up(self):
        self.client_mock.send_sms.side_effect = RelayControlError("relay down")
        message = self._queue()
        OutboundMessage.objects.filter(pk=message.pk).update(
            created_at=timezone.now() - timedelta(hours=25)
        )
        message.refresh_from_db()
        deliver_message(message)
        message.refresh_from_db()
        self.assertEqual(message.status, OutboundMessage.Status.FAILED)
        self.assertEqual(message.error_code, "relay_unreachable")

    def test_a_load_balancer_error_page_is_an_outage_not_an_answer(self):
        self.client_mock.send_sms.side_effect = relay_refusal(502)
        message = self._queue()
        deliver_message(message)
        message.refresh_from_db()
        self.assertEqual(message.status, OutboundMessage.Status.QUEUED)
        self.assertEqual(message.error_code, "relay_unreachable")

    def test_the_relays_answers_are_final(self):
        for status, code, expected in (
            (402, "not_entitled", "not_entitled"),
            (429, "monthly_limit", "monthly_limit"),
            (422, "template_not_configured", "template_not_configured"),
            (422, "unknown_kind", "template_not_configured"),
            (422, "invalid_phone", "invalid_phone"),
            (502, "provider_credit", "provider_credit"),
            (502, "provider_error", "provider_error"),
            (502, "outcome_unknown", "outcome_unknown"),
        ):
            with self.subTest(code=code):
                self.client_mock.send_sms.side_effect = relay_refusal(status, code)
                message = self._queue()
                deliver_message(message)
                message.refresh_from_db()
                self.assertEqual(message.status, OutboundMessage.Status.FAILED)
                self.assertEqual(message.error_code, expected)
                self.assertEqual(message.attempts, 1)

    def test_busy_answers_wait_their_turn(self):
        for status, code in ((429, "rate_limited"), (409, "in_flight"), (500, "internal_error")):
            with self.subTest(code=code):
                self.client_mock.send_sms.side_effect = relay_refusal(status, code)
                message = self._queue()
                deliver_message(message)
                message.refresh_from_db()
                self.assertEqual(message.status, OutboundMessage.Status.QUEUED)
                self.assertEqual(message.attempts, 0)

    def test_free_text_cannot_leave_through_a_template_only_provider(self):
        message = enqueue_message(to="0912345678", body="نص حر")
        self.assertEqual(message.status, OutboundMessage.Status.FAILED)
        self.assertEqual(message.error_code, "template_required")
        deliver_message(message)
        self.client_mock.send_sms.assert_not_called()

    def test_consent_class_comes_from_the_template(self):
        message = enqueue_message(
            to="0912345678", template=sms_template("marketing", "محل", "عرض")
        )
        self.assertEqual(message.consent_class, OutboundMessage.ConsentClass.MARKETING)
        self.assertEqual(message.template_kind, "marketing")
        self.assertEqual(message.body, SMS_TEMPLATES["marketing"].render(("محل", "عرض")))


@override_settings(CACHES=_LOCMEM)
class RelayEntitlementTests(TestCase):
    def setUp(self):
        cache.clear()

    def test_a_shop_without_sms_in_its_plan_queues_nothing(self):
        entitle(sms=False)
        relay_gateway()
        with self.assertRaises(NoGatewayConfigured) as caught:
            enqueue_message(to="0912345678", template=sms_template("test", "محل"))
        self.assertEqual(caught.exception.code, "not_entitled")
        self.assertFalse(OutboundMessage.objects.exists())

    def test_an_expired_subscription_is_not_entitled(self):
        entitle(ends_at=timezone.now() - timedelta(days=1))
        relay_gateway()
        with self.assertRaises(NoGatewayConfigured):
            enqueue_message(to="0912345678", template=sms_template("test", "محل"))

    def test_the_relay_gateway_provisions_itself(self):
        entitle()
        message = enqueue_message(to="0912345678", template=sms_template("test", "محل"))
        self.assertEqual(message.gateway.provider, MessagingGateway.Provider.RELAY)
        self.assertTrue(message.gateway.is_default)


@override_settings(CACHES=_LOCMEM)
class DeliveryStatusSyncTests(TestCase):
    def setUp(self):
        cache.clear()
        fake.reset()

    def test_polled_statuses_advance_sent_messages(self):
        gateway = MessagingGateway.objects.create(
            name="fake", provider=MessagingGateway.Provider.FAKE, is_default=True
        )
        delivered = enqueue_message(to="0912345671", template=sms_template("test", "م"))
        lost = enqueue_message(to="0912345672", template=sms_template("test", "م"))
        silent = enqueue_message(to="0912345673", template=sms_template("test", "م"))
        for message in (delivered, lost, silent):
            deliver_message(message)
            message.refresh_from_db()
        gateway.config = {
            "delivery": {
                delivered.provider_message_id: "delivered",
                lost.provider_message_id: "undelivered",
            }
        }
        gateway.save(update_fields=["config"])

        self.assertEqual(sync_delivery_statuses(gateway), 2)

        delivered.refresh_from_db()
        lost.refresh_from_db()
        silent.refresh_from_db()
        self.assertEqual(delivered.status, OutboundMessage.Status.DELIVERED)
        self.assertEqual(lost.status, OutboundMessage.Status.FAILED)
        self.assertEqual(lost.error_code, "delivery_failed")
        self.assertEqual(silent.status, OutboundMessage.Status.SENT)

    def test_the_relay_driver_asks_by_ledger_id(self):
        entitle()
        gateway = relay_gateway()
        client = mock.Mock()
        client.send_sms.return_value = {"id": "L-1", "status": "sent"}
        client.get_sms_statuses.return_value = {
            "messages": [{"id": "L-1", "status": "delivered"}, {"id": "other", "status": "delivered"}]
        }
        with mock.patch(_DRIVER, return_value=client):
            message = enqueue_message(to="0912345678", template=sms_template("test", "م"))
            deliver_message(message)
            applied = sync_delivery_statuses(gateway)

        self.assertEqual(applied, 1)
        self.assertEqual(client.get_sms_statuses.call_args.kwargs["ids"], ["L-1"])
        message.refresh_from_db()
        self.assertEqual(message.status, OutboundMessage.Status.DELIVERED)


@override_settings(CACHES=_LOCMEM, POINTY_SMS_TEST_MODE=False)
class MessagingStatusApiTests(TestCase):
    url = "/api/messaging/status/"

    def setUp(self):
        cache.clear()
        ensure_role_groups()
        User = get_user_model()
        self.manager = User.objects.create_user(username="mgr", password="x")
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.cashier = User.objects.create_user(username="csh", password="x")
        self.cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.client = APIClient()

    def test_a_shop_without_sms_sees_why_and_what_it_would_send(self):
        self.client.force_authenticate(self.manager)
        resp = self.client.get(self.url)
        self.assertEqual(resp.status_code, 200, resp.content)
        self.assertFalse(resp.data["entitled"])
        self.assertFalse(resp.data["available"])
        self.assertIsNone(resp.data["usage"])
        self.assertEqual(resp.data["usage_error"], "not_entitled")
        self.assertEqual(resp.data["gateway"]["provider"], "relay")
        kinds = [row["kind"] for row in resp.data["templates"]]
        self.assertEqual(kinds, [spec.kind for spec in SMS_TEMPLATE_SPECS])
        self.assertTrue(all(row["configured"] is None for row in resp.data["templates"]))
        invoice = next(row for row in resp.data["templates"] if row["kind"] == "invoice")
        self.assertIn("$1", invoice["text"])
        self.assertNotIn("$", invoice["example"])

    def test_an_entitled_shop_sees_this_months_usage(self):
        entitle()
        client = mock.Mock()
        client.get_sms_usage.return_value = {
            "entitled": True,
            "configured": True,
            "test_mode": True,
            "used": 12,
            "limit": 500,
            "remaining": 488,
            "period_start": "2026-09-01T00:00:00+02:00",
            "resets_at": "2026-10-01T00:00:00+02:00",
            "kinds": ["invoice", "test"],
        }
        self.client.force_authenticate(self.manager)
        with mock.patch("apps.messaging.status.scoped_relay_client", return_value=client):
            resp = self.client.get(self.url)
        self.assertEqual(resp.status_code, 200, resp.content)
        self.assertTrue(resp.data["available"])
        self.assertTrue(resp.data["test_mode"])
        self.assertEqual(resp.data["usage"]["used"], 12)
        self.assertEqual(resp.data["usage"]["limit"], 500)
        self.assertEqual(resp.data["usage_error"], "")
        configured = {row["kind"]: row["configured"] for row in resp.data["templates"]}
        self.assertTrue(configured["invoice"])
        self.assertFalse(configured["marketing"])

    def test_an_unreachable_relay_is_reported_not_raised(self):
        entitle()
        client = mock.Mock()
        client.get_sms_usage.side_effect = RelayControlError("down")
        self.client.force_authenticate(self.manager)
        with mock.patch("apps.messaging.status.scoped_relay_client", return_value=client):
            resp = self.client.get(self.url)
        self.assertEqual(resp.status_code, 200)
        self.assertIsNone(resp.data["usage"])
        self.assertEqual(resp.data["usage_error"], "relay_unreachable")
        self.assertTrue(all(row["configured"] is None for row in resp.data["templates"]))

    def test_a_switched_off_service_is_entitled_but_unavailable(self):
        entitle()
        relay_gateway(is_active=False)
        client = mock.Mock()
        client.get_sms_usage.return_value = {"configured": True, "used": 0, "limit": 0}
        self.client.force_authenticate(self.manager)
        with mock.patch("apps.messaging.status.scoped_relay_client", return_value=client):
            resp = self.client.get(self.url)
        self.assertTrue(resp.data["entitled"])
        self.assertFalse(resp.data["available"])
        self.assertFalse(resp.data["gateway"]["is_active"])

    def test_cashiers_cannot_read_it(self):
        self.client.force_authenticate(self.cashier)
        self.assertEqual(self.client.get(self.url).status_code, 403)


@override_settings(CACHES=_LOCMEM)
class SessionSmsFlagTests(TestCase):
    def setUp(self):
        cache.clear()
        ensure_role_groups()
        self.user = get_user_model().objects.create_user(username="mgr", password="x")
        self.user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client = APIClient()
        self.client.force_authenticate(self.user)

    def test_sms_available_follows_the_subscription_and_the_shops_switch(self):
        self.assertFalse(self.client.get("/api/auth/me/").data["sms_available"])
        entitle()
        self.assertTrue(self.client.get("/api/auth/me/").data["sms_available"])
        relay_gateway(is_active=False)
        self.assertFalse(self.client.get("/api/auth/me/").data["sms_available"])


class RelayClientContractTests(TestCase):
    """What Django puts on the wire must be what the relay's /v1/sms routes read."""

    def _client(self):
        from apps.core import relay as relay_module

        return relay_module.RelayControlClient(
            config=relay_module.RelayControlConfig(
                control_url="https://relay-control.example",
                public_api_url="https://relay.example",
                connector_address="relay.example:443",
                admin_token="",
                access_token="ptr1.installation-1.access-secret",
                installation_id="installation-1",
                connector_token="",
                enrollment_token="",
                timeout_seconds=5,
                ai_timeout_seconds=120,
                image_search_timeout_seconds=15,
                allow_insecure_control=False,
                ca_file="",
                client_cert_file="",
                client_key_file="",
            )
        )

    def _capture(self, payload=b"{}"):
        seen = {}

        class _Response:
            def __enter__(self):
                return self

            def __exit__(self, *exc):
                return False

            def read(self):
                return payload

        def _urlopen(http_request, timeout=None, context=None):
            seen["url"] = http_request.full_url
            seen["method"] = http_request.get_method()
            seen["headers"] = {k.lower(): v for k, v in http_request.header_items()}
            seen["body"] = json.loads(http_request.data) if http_request.data else None
            seen["timeout"] = timeout
            return _Response()

        return seen, mock.patch("apps.core.relay.request.urlopen", side_effect=_urlopen)

    def test_send_posts_the_kind_values_and_key_with_the_installation_token(self):
        seen, patch = self._capture(b'{"id":"L-1","status":"sent"}')
        with patch:
            result = self._client().send_sms(
                access_token="access-token",
                kind="invoice",
                to="+218912345678",
                variables=("محل", "1", "5.00 د.ل"),
                idempotency_key="7-20260927",
                consent_class="transactional",
                test=True,
                timeout=20,
            )
        self.assertEqual(result["id"], "L-1")
        self.assertEqual(seen["method"], "POST")
        self.assertEqual(seen["url"], "https://relay-control.example/v1/sms/send")
        self.assertEqual(seen["headers"]["x-pointy-relay-token"], "access-token")
        self.assertEqual(seen["timeout"], 20)
        self.assertEqual(
            seen["body"],
            {
                "kind": "invoice",
                "to": "+218912345678",
                "variables": ["محل", "1", "5.00 د.ل"],
                "idempotency_key": "7-20260927",
                "consent_class": "transactional",
                "test": True,
            },
        )

    def test_live_sends_do_not_carry_a_test_flag(self):
        seen, patch = self._capture()
        with patch:
            self._client().send_sms(
                access_token="t", kind="test", to="0912345678", variables=["م"],
                idempotency_key="k", consent_class="transactional",
            )
        self.assertNotIn("test", seen["body"])

    def test_usage_and_status_reads(self):
        seen, patch = self._capture(b'{"messages": []}')
        with patch:
            self._client().get_sms_statuses(access_token="t", ids=["a", "b-2"])
        self.assertEqual(seen["method"], "GET")
        self.assertEqual(
            seen["url"], "https://relay-control.example/v1/sms/status?ids=a,b-2"
        )
        with patch:
            self._client().get_sms_usage(access_token="t")
        self.assertEqual(seen["url"], "https://relay-control.example/v1/sms/usage/self")


@override_settings(CACHES=_LOCMEM)
class SmsAvailabilityPropagationTests(TestCase):
    """Devices learn sms_available from the session, so a change must move the
    permissions version they revalidate on — or they keep it until sign-in."""

    def setUp(self):
        cache.clear()
        ensure_role_groups()
        self.user = get_user_model().objects.create_user(username="mgr", password="x")
        self.user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client = APIClient()
        self.client.force_authenticate(self.user)

    def test_switching_the_service_off_moves_the_permissions_version(self):
        gateway = relay_gateway()
        with mock.patch("apps.core.caching.bump_perm_version") as bump:
            with self.captureOnCommitCallbacks(execute=True):
                self.client.patch(
                    f"/api/messaging/gateways/{gateway.pk}/", {"is_active": False}, format="json"
                )
            bump.assert_called_once()
            bump.reset_mock()
            with self.captureOnCommitCallbacks(execute=True):
                self.client.patch(
                    f"/api/messaging/gateways/{gateway.pk}/", {"daily_cap": 5}, format="json"
                )
            bump.assert_not_called()

    def test_a_sync_that_changes_an_entitlement_moves_it_and_one_that_does_not_does_not(self):
        from apps.core.relay import sync_relay_installation

        installation = entitle(sms=False)
        relay = mock.Mock()
        relay.config = mock.Mock(public_api_url="", connector_address="")
        relay.get_installation.return_value = {
            "shop_name": "",
            "relay_enabled": False,
            "subscription_active": True,
            "ai_enabled": False,
            "sms_enabled": True,
        }
        with mock.patch("apps.core.caching.bump_perm_version") as bump:
            sync_relay_installation(installation, client=relay, push_shop_name=False)
            bump.assert_called_once()
            installation.refresh_from_db()
            self.assertTrue(installation.sms_enabled)
            bump.reset_mock()
            sync_relay_installation(installation, client=relay, push_shop_name=False)
            bump.assert_not_called()
