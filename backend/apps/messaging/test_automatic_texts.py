"""The switches behind the texts that go out by themselves, and how the SMS
settings page lists every text: under its family, with what its example costs
(SMS are paid per part) and — for an automatic one — whether it is on."""

from __future__ import annotations

from decimal import Decimal
from unittest import mock

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.core.cache import cache
from django.test import TestCase, override_settings
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient

from apps.core.roles import MANAGER_GROUP, ensure_role_groups

from .approvals import kind_unapproved, note_approved_kinds, note_kind_unapproved
from .automation import auto_message_states, auto_sms_enabled, automatic_kinds, send_automatic
from .models import OutboundMessage
from .segments import count_segments
from .services import deliver_message, enqueue_message
from .sms_templates import SMS_TEMPLATE_GROUP_TITLES, SMS_TEMPLATES, sms_template
from .test_relay_sms import _DRIVER, _LOCMEM, entitle, relay_gateway, relay_refusal
from .test_sms_balance import prepaid


class AutomaticSwitchTests(TestCase):
    def setUp(self):
        self.gateway = relay_gateway()

    def test_every_automatic_kind_starts_where_its_template_says(self):
        states = auto_message_states()
        self.assertEqual(set(states), set(automatic_kinds()))
        for kind, enabled in states.items():
            self.assertEqual(enabled, SMS_TEMPLATES[kind].auto_default, kind)
        # A kind sent only from a button has no switch, and is never automatic.
        self.assertFalse(auto_sms_enabled("invoice"))
        self.assertFalse(auto_sms_enabled("job_ready_due"))

    def test_the_owner_flips_a_switch_and_it_holds(self):
        self.gateway.auto_messages = {"job_ready": False, "payroll_paid": True}
        self.gateway.save(update_fields=["auto_messages"])
        self.assertFalse(auto_sms_enabled("job_ready"))
        self.assertTrue(auto_sms_enabled("payroll_paid"))
        # Switched off as a whole, the choices are kept for when it comes back.
        self.gateway.is_active = False
        self.gateway.save(update_fields=["is_active"])
        self.assertFalse(auto_sms_enabled("job_ready"))

    def test_an_automatic_text_waits_for_the_commit(self):
        with self.captureOnCommitCallbacks(execute=False) as callbacks:
            send_automatic(
                "job_ready", "محل النور", "هاتف", to="0912345678",
                dedup_key="k", source_type="t", source_id=1,
            )
        self.assertEqual(OutboundMessage.objects.count(), 0)
        self.assertEqual(len(callbacks), 1)
        # Never: off, no phone, or a customer who asked not to be contacted.
        self.gateway.auto_messages = {"job_ready": False}
        self.gateway.save(update_fields=["auto_messages"])
        with self.captureOnCommitCallbacks(execute=False) as callbacks:
            send_automatic("job_ready", "م", "ه", to="0912345678", dedup_key="k2", source_type="t", source_id=1)
            send_automatic("job_estimate", "م", "ه", "1", to="", dedup_key="k3", source_type="t", source_id=1)
            send_automatic(
                "job_estimate", "م", "ه", "1", to="0912345678", customer=mock.Mock(do_not_contact=True),
                dedup_key="k4", source_type="t", source_id=1,
            )
        self.assertEqual(callbacks, [])


@override_settings(CACHES=_LOCMEM, POINTY_SMS_TEST_MODE=False)
class UnapprovedKindTests(TestCase):
    """A kind the operator has not registered with Resala yet: the relay
    refuses it before charging anything, which is no broken gateway, and
    automatic texts of that kind sit it out instead of failing at every sale or
    job move — while a text sent by hand still goes, to fail in front of its
    sender with the reason."""

    def setUp(self):
        cache.clear()
        self.addCleanup(cache.clear)
        entitle()
        self.gateway = relay_gateway()
        self.relay = mock.Mock()
        self.relay.send_sms.side_effect = relay_refusal(422, "template_not_configured")
        patcher = mock.patch(_DRIVER, return_value=self.relay)
        patcher.start()
        self.addCleanup(patcher.stop)

    def ready(self, key):
        with self.captureOnCommitCallbacks(execute=True):
            send_automatic(
                "job_ready", "محل النور", "هاتف", to="0912345678",
                dedup_key=key, source_type="t", source_id=1,
            )
        return OutboundMessage.objects.filter(dedup_key=key).first()

    def test_a_refused_kind_sits_out_and_the_gateway_is_not_blamed(self):
        first = self.ready("ready-1")
        deliver_message(first)
        first.refresh_from_db()
        self.assertEqual(first.status, OutboundMessage.Status.FAILED)
        self.assertEqual(first.error_code, "template_not_configured")
        self.gateway.refresh_from_db()
        self.assertEqual(self.gateway.last_error, "")
        # The next job that gets ready is not queued only to be refused again…
        self.assertIsNone(self.ready("ready-2"))
        # …but a text sent by hand still goes.
        by_hand = enqueue_message(to="0912345678", template=sms_template("job_ready", "محل النور", "هاتف"))
        self.assertEqual(by_hand.status, OutboundMessage.Status.QUEUED)

    def test_once_the_relay_lists_it_the_kind_goes_out_again(self):
        note_kind_unapproved("job_ready")
        self.assertIsNone(self.ready("ready-3"))
        note_approved_kinds(["job_ready"])
        self.assertIsNotNone(self.ready("ready-4"))

    def test_a_real_gateway_fault_still_shows(self):
        self.relay.send_sms.side_effect = relay_refusal(502, "provider_credit")
        message = self.ready("ready-5")
        deliver_message(message)
        self.gateway.refresh_from_db()
        self.assertTrue(self.gateway.last_error.startswith("provider_credit"))
        self.assertFalse(kind_unapproved("job_ready"))


@override_settings(CACHES=_LOCMEM)
class SettingsPageTests(TestCase):
    def setUp(self):
        cache.clear()
        self.addCleanup(cache.clear)
        ensure_role_groups()
        user = get_user_model().objects.create_user(username="sms-owner", password="x")
        user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.api = APIClient()
        self.api.force_authenticate(user)
        self.gateway = relay_gateway()
        prepaid(balance="15.000", price="0.150")
        patcher = mock.patch("apps.messaging.status.scoped_relay_client")
        relay = patcher.start()
        relay.return_value.get_sms_usage.return_value = {
            "used": 0, "limit": 0, "remaining": -1, "balance": "15.000", "price": "0.150",
            "messages_left": 100, "available": True, "configured": True, "kinds": ["job_ready"],
        }
        self.addCleanup(patcher.stop)

    def test_templates_come_in_families_with_their_cost(self):
        payload = self.api.get(reverse("messaging-status")).data
        groups = [group["key"] for group in payload["template_groups"]]
        self.assertEqual(groups[:3], ["sales", "debts", "jobs"])
        templates = {item["kind"]: item for item in payload["templates"]}
        ready = templates["job_ready"]
        self.assertEqual(ready["group"], "jobs")
        self.assertIn(ready["group"], SMS_TEMPLATE_GROUP_TITLES)
        self.assertTrue(ready["automatic"])
        self.assertTrue(ready["auto_enabled"])
        self.assertTrue(ready["auto_label"])
        self.assertTrue(ready["configured"])
        self.assertEqual(ready["example_parts"], count_segments(ready["example"]))
        self.assertEqual(Decimal(ready["example_price"]), Decimal("0.150") * ready["example_parts"])
        # A two-part example costs two parts.
        credit = templates["credit_invoice"]
        self.assertEqual(credit["example_parts"], 2)
        self.assertEqual(credit["example_price"], "0.300")
        # A text sent from a button has no switch.
        self.assertFalse(templates["invoice"]["automatic"])
        self.assertIsNone(templates["invoice"]["auto_enabled"])

    def test_the_owner_flips_one_switch_and_keeps_the_rest(self):
        url = reverse("messaging-gateway-detail", args=[self.gateway.pk])
        response = self.api.patch(url, {"auto_messages": {"job_received": True}}, format="json")
        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.assertTrue(response.data["auto_messages"]["job_received"])
        response = self.api.patch(url, {"auto_messages": {"job_ready": False}}, format="json")
        self.assertTrue(response.data["auto_messages"]["job_received"], "an earlier switch is kept")
        self.assertFalse(response.data["auto_messages"]["job_ready"])
        self.assertEqual(set(response.data["auto_messages"]), set(automatic_kinds()))
        payload = self.api.get(reverse("messaging-status")).data
        ready = next(item for item in payload["templates"] if item["kind"] == "job_ready")
        self.assertFalse(ready["auto_enabled"])

    def test_reading_the_page_lifts_the_pause_on_approved_kinds(self):
        note_kind_unapproved("job_ready")
        note_kind_unapproved("job_received")
        self.api.get(reverse("messaging-status"))
        self.assertFalse(kind_unapproved("job_ready"), "the relay lists it as approved")
        self.assertTrue(kind_unapproved("job_received"), "still waiting for its template")

    def test_only_automatic_kinds_have_switches(self):
        url = reverse("messaging-gateway-detail", args=[self.gateway.pk])
        for bad in ({"invoice": True}, {"job_ready": "yes"}, ["job_ready"]):
            response = self.api.patch(url, {"auto_messages": bad}, format="json")
            self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST, bad)
