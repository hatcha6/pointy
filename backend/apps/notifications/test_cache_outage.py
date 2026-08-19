"""The bell keeps ringing when Redis does not.

``maybe_sync_business_notifications`` claims a throttle slot in the cache before
handing a recompute to Celery. That ``cache.add`` sits on the request path of
the bell/badge poll every signed-in device runs, so an unreachable Redis used to
propagate straight out of the viewset as a 500 — and once the socket timeouts
landed (see ``apps.core.test_redis_timeouts``) it would do so reliably rather
than by hanging.

The defined outcome is to skip the top-up: falling back to the inline recompute
is not an option here because Redis is also the Celery broker, so a cache outage
would put a ~1300-query whole-catalog scan on every poll from every device and
convert it into a database outage. The feed goes stale, not blank.
"""

from unittest import mock

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase, override_settings
from django.urls import reverse
from redis.exceptions import TimeoutError as RedisTimeoutError
from rest_framework import status
from rest_framework.test import APIClient

from apps.core.roles import MANAGER_GROUP
from apps.notifications import services


@override_settings(POINTY_NOTIFICATION_INLINE_SYNC_THROTTLE_SECONDS=300)
class NotificationsSurviveACacheOutageTests(TestCase):
    def setUp(self):
        user = get_user_model().objects.create_user(username="manager", password="x")
        user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.api = APIClient()
        self.api.force_authenticate(user=user)

    def test_feed_still_lists_when_the_cache_is_unreachable(self):
        with mock.patch.object(
            services.cache,
            "add",
            side_effect=RedisTimeoutError("Timeout reading from socket"),
        ) as add:
            response = self.api.get(reverse("business-notification-list"))

        add.assert_called_once()
        self.assertEqual(response.status_code, status.HTTP_200_OK)

    def test_an_unreachable_cache_does_not_trigger_the_inline_recompute(self):
        """The expensive fallback is for a dead *broker*, not a dead cache."""
        with (
            mock.patch.object(services.cache, "add", side_effect=RedisTimeoutError("boom")),
            mock.patch.object(services, "sync_business_notifications") as recompute,
        ):
            result = services.maybe_sync_business_notifications()

        self.assertIsNone(result)
        recompute.assert_not_called()

    def test_a_dead_broker_still_falls_back_to_the_inline_recompute(self):
        """Guard the guard: the pre-existing broker fallback is untouched."""
        with (
            mock.patch.object(services.cache, "add", return_value=True),
            mock.patch(
                "apps.notifications.tasks.sync_business_notifications_task.apply_async",
                side_effect=OSError("broker unreachable"),
            ),
            mock.patch.object(
                services, "sync_business_notifications", return_value={"created": 0}
            ) as recompute,
        ):
            result = services.maybe_sync_business_notifications()

        self.assertEqual(result, {"created": 0})
        recompute.assert_called_once()
