"""Quiet hours must silence marketing without silencing the shop.

Two behaviours nothing else pins:

* the window a shop actually configures — ``22:00 → 08:00`` — spans midnight,
  while the only existing quiet-hours test uses a same-day ``00:00 → 23:59``
  window that never exercises the wrap-around branch;
* a held marketing campaign must not starve the transactional messages queued
  behind it. Invoice, debt-reminder and OTP messages are exempt from quiet hours
  by design, and an OTP that waits until 08:00 has already expired.
"""

from __future__ import annotations

from datetime import datetime, time
from datetime import timezone as dt_timezone

from django.core.cache import cache
from django.test import TestCase, override_settings

from .models import MessagingGateway, OutboundMessage
from .quiet_hours import in_quiet_hours
from .services import enqueue_message
from .tasks import _DISPATCH_BATCH, dispatch_outbound_task
from .transports import fake

_LOCMEM = {"default": {"BACKEND": "django.core.cache.backends.locmem.LocMemCache"}}


def _utc(hour: int, minute: int = 0) -> datetime:
    """An instant on 2026-03-05, given in UTC. Tripoli is UTC+2 year-round."""
    return datetime(2026, 3, 5, hour, minute, tzinfo=dt_timezone.utc)


class QuietHoursWindowTests(TestCase):
    """``in_quiet_hours`` against the window a shop actually configures."""

    def setUp(self):
        # Unsaved: the helper only reads the two time fields.
        self.gateway = MessagingGateway(
            quiet_hours_start=time(22, 0), quiet_hours_end=time(8, 0)
        )

    def test_late_evening_is_quiet(self):
        # 21:00 UTC == 23:00 Tripoli, after the window opens.
        self.assertTrue(in_quiet_hours(self.gateway, _utc(21, 0)))

    def test_after_midnight_is_still_quiet(self):
        # 01:00 UTC == 03:00 Tripoli, the far side of the wrap-around.
        self.assertTrue(in_quiet_hours(self.gateway, _utc(1, 0)))

    def test_the_window_opens_at_start_and_is_over_at_end(self):
        self.assertTrue(in_quiet_hours(self.gateway, _utc(20, 0)))  # 22:00 local
        self.assertFalse(in_quiet_hours(self.gateway, _utc(6, 0)))  # 08:00 local

    def test_midday_is_not_quiet(self):
        self.assertFalse(in_quiet_hours(self.gateway, _utc(10, 0)))  # 12:00 local

    def test_an_unset_or_empty_window_is_never_quiet(self):
        self.assertFalse(in_quiet_hours(MessagingGateway(), _utc(1, 0)))
        self.assertFalse(
            in_quiet_hours(
                MessagingGateway(
                    quiet_hours_start=time(22, 0), quiet_hours_end=time(22, 0)
                ),
                _utc(20, 0),
            )
        )


@override_settings(CACHES=_LOCMEM)
class QuietHoursStarvationTests(TestCase):
    """A held campaign must not block the messages that are exempt from the hold."""

    def setUp(self):
        fake.reset()
        cache.clear()
        # A window covering all 24h, so every tick in this test is "quiet".
        self.gateway = MessagingGateway.objects.create(
            name="Shop phone",
            provider=MessagingGateway.Provider.FAKE,
            is_default=True,
            quiet_hours_start=time(0, 0),
            quiet_hours_end=time(23, 59),
        )

    def _enqueue_campaign(self, count: int) -> None:
        for i in range(count):
            enqueue_message(
                to="+21891%07d" % i,
                body="promo",
                consent_class=OutboundMessage.ConsentClass.MARKETING,
            )

    def test_a_full_batch_of_held_marketing_does_not_starve_an_invoice(self):
        # An evening campaign that fills a dispatch batch, then a receipt.
        self._enqueue_campaign(_DISPATCH_BATCH)
        invoice = enqueue_message(
            to="+218927654321",
            body="فاتورتك",
            consent_class=OutboundMessage.ConsentClass.TRANSACTIONAL,
        )

        dispatch_outbound_task()

        invoice.refresh_from_db()
        self.assertEqual(invoice.status, OutboundMessage.Status.SENT)
        # ...and the campaign is still held, exactly as quiet hours requires.
        self.assertEqual(
            OutboundMessage.objects.filter(
                consent_class=OutboundMessage.ConsentClass.MARKETING,
                status=OutboundMessage.Status.SENT,
            ).count(),
            0,
        )

    def test_the_held_campaign_goes_out_once_the_window_closes(self):
        self._enqueue_campaign(3)
        MessagingGateway.objects.filter(pk=self.gateway.pk).update(
            quiet_hours_start=None, quiet_hours_end=None
        )

        dispatch_outbound_task()

        self.assertEqual(
            OutboundMessage.objects.filter(status=OutboundMessage.Status.SENT).count(), 3
        )
