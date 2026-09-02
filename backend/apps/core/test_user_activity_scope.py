"""The users screen's activity tile counts a person's actions, cheaply.

Field data: ``users/<id>/activity`` took 57 s (47 queries, all database time).
The tile counted every analytics row received under the user — and a busy till
writes millions of request-timing rows a month under its cashier's name. The
count now covers reviewable events only, and above a planner-estimated size it
serves the estimate rather than scanning the person's whole history.
"""

from unittest import mock

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.urls import reverse
from django.utils import timezone
from rest_framework.test import APIClient

from apps.analytics.models import AnalyticsEvent
from apps.core.roles import CASHIER_GROUP, MANAGER_GROUP, ensure_role_groups


class UserActivityScopeTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        User = get_user_model()
        self.manager = User.objects.create_user(username="manager", password="p")
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.cashier = User.objects.create_user(username="cashier", password="p")
        self.cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.client = APIClient()
        self.client.force_authenticate(self.manager)
        now = timezone.now()
        AnalyticsEvent.objects.bulk_create(
            [
                AnalyticsEvent(
                    event_type=AnalyticsEvent.EventType.PERFORMANCE,
                    name="backend.request",
                    severity=AnalyticsEvent.Severity.INFO,
                    source=AnalyticsEvent.Source.BACKEND,
                    occurred_at=now,
                    received_by=self.cashier,
                )
                for index in range(20)
            ]
            + [
                AnalyticsEvent(
                    event_type=AnalyticsEvent.EventType.USAGE,
                    name="frontend.interaction",
                    severity=AnalyticsEvent.Severity.DEBUG,
                    source=AnalyticsEvent.Source.FRONTEND,
                    occurred_at=now,
                    received_by=self.cashier,
                ),
                AnalyticsEvent(
                    event_type=AnalyticsEvent.EventType.AUDIT,
                    name="sales.checkout.completed",
                    severity=AnalyticsEvent.Severity.INFO,
                    source=AnalyticsEvent.Source.BACKEND,
                    occurred_at=now,
                    received_by=self.cashier,
                ),
            ]
        )

    def _activity(self):
        response = self.client.get(reverse("pos-user-activity", args=[self.cashier.pk]))
        self.assertEqual(response.status_code, 200, response.data)
        return response.data

    def test_counts_actions_not_telemetry(self):
        data = self._activity()
        self.assertEqual(data["summary"]["activity"]["event_count"], 1)
        self.assertFalse(data["summary"]["activity"]["event_count_is_estimate"])
        self.assertEqual(
            [event["name"] for event in data["recent_activity"]],
            ["sales.checkout.completed"],
        )

    def test_a_large_history_is_estimated_rather_than_scanned(self):
        with mock.patch(
            "apps.core.user_activity.estimate_export_rows", return_value=123456
        ):
            data = self._activity()
        self.assertEqual(data["summary"]["activity"]["event_count"], 123456)
        self.assertTrue(data["summary"]["activity"]["event_count_is_estimate"])

    def test_without_an_estimate_the_count_is_exact(self):
        with mock.patch("apps.core.user_activity.estimate_export_rows", return_value=None):
            data = self._activity()
        self.assertEqual(data["summary"]["activity"]["event_count"], 1)
        self.assertFalse(data["summary"]["activity"]["event_count_is_estimate"])
