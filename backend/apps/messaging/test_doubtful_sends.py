"""Sends that failed in doubt: Resala erred or went silent after taking the
message, so the relay keeps its price while it checks Resala's sent log. The
shop keeps the relay's id on the failed message and keeps asking after it; when
the relay finds it went out, the message log says so."""

from __future__ import annotations

from datetime import timedelta
from unittest import mock

from django.core.cache import cache
from django.test import TestCase, override_settings
from django.utils import timezone

from .models import DeliveryReceipt, OutboundMessage
from .services import deliver_message, enqueue_message, sync_delivery_statuses
from .sms_templates import sms_template
from .test_relay_sms import _DRIVER, _LOCMEM, entitle, relay_gateway, relay_refusal


@override_settings(CACHES=_LOCMEM, POINTY_SMS_TEST_MODE=False)
class DoubtfulSendTests(TestCase):
    def setUp(self):
        cache.clear()
        entitle()
        self.gateway = relay_gateway()
        self.relay = mock.Mock()
        patcher = mock.patch(_DRIVER, return_value=self.relay)
        patcher.start()
        self.addCleanup(patcher.stop)

    def failed_in_doubt(self, relay_id="L-9", phone="0912345678"):
        self.relay.send_sms.side_effect = relay_refusal(
            502, "provider_error", id=relay_id, held=True,
            detail="resala did not answer in time; the message may or may not have been sent",
        )
        message = enqueue_message(to=phone, template=sms_template("test", "محل النور"))
        deliver_message(message)
        message.refresh_from_db()
        return message

    def poll(self, *statuses):
        self.relay.get_sms_statuses.return_value = {
            "messages": [{"id": relay_id, "status": status} for relay_id, status in statuses]
        }
        return sync_delivery_statuses(self.gateway)

    def test_a_doubtful_failure_keeps_the_relays_id(self):
        message = self.failed_in_doubt()
        self.assertEqual(message.status, OutboundMessage.Status.FAILED)
        self.assertEqual(message.error_code, "provider_error")
        self.assertEqual(message.provider_message_id, "L-9")
        # A refusal Resala stated is final: nothing to ask after.
        self.relay.send_sms.side_effect = relay_refusal(502, "provider_rejected", id="L-10")
        refused = enqueue_message(to="0912345679", template=sms_template("test", "محل النور"))
        deliver_message(refused)
        refused.refresh_from_db()
        self.assertEqual(refused.error_code, "provider_rejected")
        self.assertEqual(refused.provider_message_id, "")

    def test_the_relay_found_it_went_out(self):
        message = self.failed_in_doubt()
        self.assertEqual(self.poll(("L-9", "sent")), 1)
        message.refresh_from_db()
        self.assertEqual(message.status, OutboundMessage.Status.SENT)
        self.assertEqual(message.error_code, "")
        self.assertIsNotNone(message.sent_at)
        receipt = DeliveryReceipt.objects.get(outbound=message)
        self.assertEqual(receipt.raw.get("recovered"), True)
        self.assertEqual(self.relay.get_sms_statuses.call_args.kwargs["ids"], ["L-9"])
        # From now on it is an ordinary sent message awaiting its report.
        self.assertEqual(self.poll(("L-9", "delivered")), 1)
        message.refresh_from_db()
        self.assertEqual(message.status, OutboundMessage.Status.DELIVERED)

    def test_found_delivered_or_undelivered(self):
        delivered = self.failed_in_doubt(relay_id="L-1", phone="0912345671")
        lost = self.failed_in_doubt(relay_id="L-2", phone="0912345672")
        self.assertEqual(self.poll(("L-1", "delivered"), ("L-2", "undelivered")), 2)
        delivered.refresh_from_db()
        lost.refresh_from_db()
        self.assertEqual(delivered.status, OutboundMessage.Status.DELIVERED)
        self.assertIsNotNone(delivered.delivered_at)
        # It went out — and was paid for — but never reached the phone.
        self.assertEqual(lost.status, OutboundMessage.Status.FAILED)
        self.assertEqual(lost.error_code, "delivery_failed")
        # Both settled: nothing is asked after any more.
        self.relay.get_sms_statuses.reset_mock()
        self.assertEqual(self.poll(), 0)
        self.relay.get_sms_statuses.assert_not_called()

    def test_still_failed_while_the_relay_checks_or_after_it_refunds(self):
        message = self.failed_in_doubt()
        self.assertEqual(self.poll(("L-9", "failed")), 0)
        message.refresh_from_db()
        self.assertEqual(message.status, OutboundMessage.Status.FAILED)
        self.assertEqual(message.error_code, "provider_error")
        self.assertFalse(DeliveryReceipt.objects.filter(outbound=message).exists())

    def test_a_sent_message_still_on_its_way_records_nothing(self):
        self.relay.send_sms.side_effect = None
        self.relay.send_sms.return_value = {"id": "L-5", "status": "sent"}
        message = enqueue_message(to="0912345678", template=sms_template("test", "محل النور"))
        deliver_message(message)
        self.assertEqual(self.poll(("L-5", "sent")), 0)
        self.assertFalse(DeliveryReceipt.objects.exists())

    def test_old_doubts_are_left_alone(self):
        message = self.failed_in_doubt()
        OutboundMessage.objects.filter(pk=message.pk).update(created_at=timezone.now() - timedelta(hours=49))
        self.assertEqual(self.poll(("L-9", "sent")), 0)
        self.relay.get_sms_statuses.assert_not_called()
