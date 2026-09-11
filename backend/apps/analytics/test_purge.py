"""Clearing the shop's event history.

Telemetry is the one table that grows without anybody deciding it should: on
the first client's database it was 86% of a 6.4 GB dump, and the September 2026
export ran to 417,361 rows from a single month. Once an export has been taken
there is no reason to keep carrying it, so there is a button — and because the
button is irreversible and takes the activity log and the AUDIT trail with it,
these pin who may press it, that it really clears everything, and that the one
thing it leaves behind is a record of itself.
"""

from unittest.mock import patch

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase, override_settings
from django.urls import reverse
from django.utils import timezone
from rest_framework import status
from rest_framework.test import APIClient

from apps.core.roles import CASHIER_GROUP, MANAGER_GROUP, ensure_role_groups

from . import buffer
from .models import AnalyticsEvent
from .services import record_event_buffered


class AnalyticsPurgeTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        User = get_user_model()
        self.manager = User.objects.create_user(username="purge-manager", password="pass")
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.cashier = User.objects.create_user(username="purge-cashier", password="pass")
        self.cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.addCleanup(buffer.reset)

    def _client(self, user):
        client = APIClient()
        client.force_authenticate(user=user)
        return client

    def _url(self):
        return reverse("analytics-event-purge")

    def _survivors(self):
        """Everything left except the purge call's own request telemetry.

        The middleware records a ``backend.request`` row for every API call,
        this one included, and writes it on the way out — after the sweep has
        already run. A purged table is therefore never literally empty, and a
        test that pretended otherwise would be asserting the wrong thing.
        """
        return AnalyticsEvent.objects.exclude(name="backend.request")

    def _make_events(self, count, *, name="pos.cart.line.added"):
        now = timezone.now()
        AnalyticsEvent.objects.bulk_create(
            AnalyticsEvent(
                name=name,
                event_type=AnalyticsEvent.EventType.USAGE,
                occurred_at=now,
            )
            for _ in range(count)
        )

    def test_a_manager_clears_the_history_and_is_told_how_much_went(self):
        self._make_events(12)

        response = self._client(self.manager).post(self._url())

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["deleted"], 12)

    def test_a_cashier_cannot_clear_anything(self):
        self._make_events(5)

        response = self._client(self.cashier).post(self._url())

        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)
        self.assertEqual(AnalyticsEvent.objects.filter(name="pos.cart.line.added").count(), 5)

    def test_signing_out_is_not_a_way_in(self):
        self._make_events(3)

        response = APIClient().post(self._url())

        self.assertIn(
            response.status_code,
            {status.HTTP_401_UNAUTHORIZED, status.HTTP_403_FORBIDDEN},
        )
        self.assertEqual(AnalyticsEvent.objects.filter(name="pos.cart.line.added").count(), 3)

    def test_the_audit_trail_goes_too_and_says_so_on_the_way_out(self):
        """The whole table, not just the timing rows — and one row left to tell.

        Erasing an audit trail is itself an auditable act. If the purge were
        silent, the only evidence a month of history had ever existed would be
        its absence.
        """
        self._make_events(4)
        AnalyticsEvent.objects.create(
            name="core.period_lock.overridden",
            event_type=AnalyticsEvent.EventType.AUDIT,
            severity=AnalyticsEvent.Severity.WARNING,
            occurred_at=timezone.now(),
        )

        self._client(self.manager).post(self._url())

        remaining = list(self._survivors())
        self.assertEqual(len(remaining), 1, "only the receipt survives")
        receipt = remaining[0]
        self.assertEqual(receipt.name, "analytics.events.purged")
        self.assertEqual(receipt.event_type, AnalyticsEvent.EventType.AUDIT)
        self.assertEqual(receipt.received_by, self.manager)
        self.assertEqual(receipt.metrics["deleted"], 5)

    def test_clearing_an_empty_history_writes_nothing(self):
        """Nothing was destroyed, so there is nothing to record."""
        response = self._client(self.manager).post(self._url())

        self.assertEqual(response.data["deleted"], 0)
        self.assertFalse(self._survivors().exists())

    @patch("apps.analytics.services.ANALYTICS_PURGE_BATCH_SIZE", 4)
    def test_every_batch_is_swept_not_just_the_first(self):
        """The sweep deletes in slices so the tills keep writing through it.

        A loop that stopped after one slice would look like it worked on a
        test-sized table and leave a shop's real one almost untouched.
        """
        self._make_events(13)

        response = self._client(self.manager).post(self._url())

        self.assertEqual(response.data["deleted"], 13)
        self.assertEqual(self._survivors().exclude(name="analytics.events.purged").count(), 0)

    @override_settings(POINTY_ANALYTICS_BUFFER_SIZE=100)
    def test_rows_still_buffered_do_not_survive_the_purge(self):
        """Otherwise the table refills the moment the buffer drains.

        Telemetry is written through a buffer that holds a tail of rows until it
        fills or ages out. A purge that ignored it would delete what is on disk
        and then watch the pending rows land behind it — the screen says cleared
        and the table is not.
        """
        record_event_buffered(name="pos.cart.line.added", occurred_at=timezone.now())
        self.assertEqual(buffer.buffer_size(), 100)
        self.assertFalse(
            AnalyticsEvent.objects.filter(name="pos.cart.line.added").exists(),
            "precondition: the row is buffered, not yet inserted",
        )

        response = self._client(self.manager).post(self._url())

        self.assertEqual(response.data["deleted"], 1)
        buffer.flush()
        self.assertFalse(AnalyticsEvent.objects.filter(name="pos.cart.line.added").exists())

    def test_a_purge_ignores_whatever_the_export_form_was_set_to(self):
        """The blast radius is never off-screen.

        The button sits on the export page, which carries a filter form. A purge
        that quietly honoured those filters would destroy a different amount
        depending on state the confirmation dialog never mentions.
        """
        old = timezone.now() - timezone.timedelta(days=90)
        AnalyticsEvent.objects.create(name="old.event", occurred_at=old)
        self._make_events(2)

        response = self._client(self.manager).post(
            self._url(),
            {"name": "pos.cart.line.added", "occurred_from": timezone.now().isoformat()},
            format="json",
        )

        self.assertEqual(response.data["deleted"], 3)
        self.assertFalse(AnalyticsEvent.objects.filter(name="old.event").exists())
