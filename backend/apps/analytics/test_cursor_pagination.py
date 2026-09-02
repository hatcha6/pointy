"""The event log pages by cursor, not by page number.

Field data (v0.4.2): ``analytics-event-list`` took 10 to 16 s per page on 2
queries — the page-number paginator's exact ``COUNT(*)`` over the filtered set,
a full scan of a table holding a month of telemetry, run again for every page.
A page number is also an OFFSET into a log that is appended to every second.
The cursor paginator serves no count and anchors each page to the last row.
"""

from datetime import timedelta

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.urls import reverse
from django.utils import timezone
from rest_framework.test import APIClient

from apps.core.roles import MANAGER_GROUP, ensure_role_groups

from .models import AnalyticsEvent


class AnalyticsEventCursorPaginationTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.client = APIClient()
        user = get_user_model().objects.create_user(username="m", password="p")
        user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client.force_authenticate(user)
        now = timezone.now()
        AnalyticsEvent.objects.bulk_create(
            [
                AnalyticsEvent(
                    entity_type="order",
                    entity_id=f"evt-{index}",
                    event_type=AnalyticsEvent.EventType.AUDIT,
                    name="sales.checkout.completed",
                    severity=AnalyticsEvent.Severity.INFO,
                    source=AnalyticsEvent.Source.BACKEND,
                    occurred_at=now - timedelta(seconds=index),
                    received_by=user,
                )
                for index in range(60)
            ]
        )

    def test_pages_by_cursor_without_a_count(self):
        first = self.client.get(
            reverse("analytics-event-list"), {"ordering": "-occurred_at", "activity_scope": "all"}
        )
        self.assertEqual(first.status_code, 200, first.data)
        self.assertNotIn("count", first.data)
        self.assertEqual(len(first.data["results"]), 50)
        self.assertIn("cursor=", first.data["next"])
        self.assertEqual(first.data["results"][0]["entity_id"], "evt-0")

        second = self.client.get(first.data["next"])
        self.assertEqual(second.status_code, 200, second.data)
        self.assertEqual(len(second.data["results"]), 10)
        self.assertIsNone(second.data["next"])
        seen = {row["entity_id"] for row in first.data["results"]} | {
            row["entity_id"] for row in second.data["results"]
        }
        self.assertEqual(len(seen), 60)

    def test_a_row_written_between_pages_is_neither_skipped_nor_repeated(self):
        first = self.client.get(
            reverse("analytics-event-list"), {"ordering": "-occurred_at", "activity_scope": "all"}
        )
        # Lands at the head of the log after page one was read.
        AnalyticsEvent.objects.create(
            entity_type="order",
            entity_id="evt-new",
            event_type=AnalyticsEvent.EventType.AUDIT,
            name="sales.checkout.completed",
            severity=AnalyticsEvent.Severity.INFO,
            source=AnalyticsEvent.Source.BACKEND,
            occurred_at=timezone.now() + timedelta(seconds=5),
        )
        second = self.client.get(first.data["next"])
        ids = [row["entity_id"] for row in second.data["results"]]
        self.assertEqual(ids, [f"evt-{index}" for index in range(50, 60)])
