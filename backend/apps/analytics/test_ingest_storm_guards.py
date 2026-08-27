"""Guards against telemetry delivery becoming the thing telemetry records.

A first client's database was 10.17M analytics rows, and 5.1M of them were the
backend writing down its own refusal to accept telemetry: a client looping on
rejected ingest calls sent 5,127,075 requests over seven weeks — 85% of every
HTTP request the backend served, and 68% of its request time. Two backend
properties keep that from recurring, whatever the client does.
"""

from django.contrib.auth import get_user_model
from django.test import TestCase, override_settings
from django.urls import reverse
from rest_framework.test import APIClient

from apps.core.roles import MANAGER_GROUP, ensure_role_groups

from .models import AnalyticsEvent


class IngestSelfRecordingTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        from django.contrib.auth.models import Group

        self.user = get_user_model().objects.create_user(
            username="manager", password="pass"
        )
        self.user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client = APIClient()

    def _ingest(self, authenticated):
        if authenticated:
            self.client.force_authenticate(self.user)
        return self.client.post(
            reverse("analytics-event-ingest"),
            {
                "events": [
                    {
                        "name": "pos.checkout.completed",
                        "event_type": "usage",
                        "client_event_id": "11111111-1111-4111-8111-111111111111",
                    }
                ]
            },
            format="json",
        )

    def test_a_rejected_ingest_does_not_write_a_row_about_itself(self):
        """The circular write that made a client bug into half the database."""
        response = self._ingest(authenticated=False)

        self.assertEqual(response.status_code, 401)
        self.assertFalse(
            AnalyticsEvent.objects.filter(name="backend.request").exists(),
            "the endpoint recorded telemetry about the delivery of telemetry",
        )

    def test_an_accepted_ingest_does_not_write_a_row_about_itself_either(self):
        response = self._ingest(authenticated=True)

        self.assertEqual(response.status_code, 202)
        self.assertFalse(
            AnalyticsEvent.objects.filter(
                name="backend.request",
                attributes__view_name="analytics-event-ingest",
            ).exists()
        )

    def test_other_endpoints_are_still_recorded(self):
        """The exclusion is for the ingest path only, not a blanket silence."""
        self.client.force_authenticate(self.user)

        self.client.get(reverse("shop-settings"))

        self.assertTrue(
            AnalyticsEvent.objects.filter(name="backend.request").exists()
        )


class RejectedRequestIdentityTests(TestCase):
    """A request we refuse is exactly the one worth identifying.

    Device and session used to be read from the request's *session*, so the
    5.1M rejected calls carried no ip, no device, no user agent and no session —
    they could be counted precisely and still not traced to a machine.
    """

    def test_an_unauthenticated_request_still_names_its_device(self):
        client = APIClient()

        client.post(
            reverse("analytics-event-ingest"),
            {"events": []},
            format="json",
            headers={
                "X-Pointy-Device-Id": "kiosk-7",
                "X-Pointy-Platform": "flutter-windows",
                "X-Pointy-App-Version": "0.4.2",
                "User-Agent": "pointy-test",
            },
            REMOTE_ADDR="10.0.0.44",
        )

        # Ingest itself is not recorded, so assert on an endpoint that is.
        client.get(
            reverse("shop-settings"),
            headers={
                "X-Pointy-Device-Id": "kiosk-7",
                "X-Pointy-Platform": "flutter-windows",
                "X-Pointy-App-Version": "0.4.2",
                "User-Agent": "pointy-test",
            },
            REMOTE_ADDR="10.0.0.44",
        )
        event = AnalyticsEvent.objects.filter(name="backend.request").first()

        self.assertIsNotNone(event)
        self.assertEqual(event.device_id, "kiosk-7")
        self.assertEqual(event.installation_id, "kiosk-7")
        self.assertEqual(event.platform, "flutter-windows")
        self.assertEqual(event.app_version, "0.4.2")
        self.assertEqual(event.ip_address, "10.0.0.44")
        self.assertEqual(event.user_agent, "pointy-test")
        self.assertFalse(event.attributes["user_authenticated"])

    def test_a_malformed_address_is_dropped_rather_than_poisoning_the_batch(self):
        """These rows go through a bulk buffer: one unsaveable value would take
        a whole batch of unrelated events with it."""
        client = APIClient()

        client.get(reverse("shop-settings"), REMOTE_ADDR="not-an-ip")
        event = AnalyticsEvent.objects.filter(name="backend.request").first()

        self.assertIsNotNone(event, "the event was dropped along with the bad ip")
        self.assertIsNone(event.ip_address)


@override_settings(POINTY_ANONYMOUS_BURST_LIMIT=3, POINTY_ANONYMOUS_BURST_WINDOW_SECONDS=60)
class AnonymousCeilingTests(TestCase):
    """The one class of caller that can loop forever without succeeding was the
    one class nothing was watching.

    It has to be middleware: DRF checks permissions before throttles, so a
    request destined to 401 never reaches a throttle class.
    """

    def setUp(self):
        from django.core.cache import cache

        cache.clear()
        self.addCleanup(cache.clear)

    def _post(self, client, device_id):
        return client.post(
            reverse("analytics-event-ingest"),
            {"events": []},
            format="json",
            headers={"X-Pointy-Device-Id": device_id},
        )

    def test_a_runaway_anonymous_client_is_eventually_refused(self):
        client = APIClient()

        statuses = [self._post(client, "runaway-kiosk").status_code for _ in range(6)]

        self.assertIn(
            429,
            statuses,
            "an unauthenticated loop must meet a ceiling; before this it never did",
        )

    def test_devices_are_counted_apart(self):
        """Tills share one address behind nginx, so one runaway must not lock
        the rest of the shop out."""
        client = APIClient()
        for _ in range(6):
            self._post(client, "runaway-kiosk")

        self.assertNotEqual(self._post(client, "healthy-till").status_code, 429)

    def test_a_signed_in_till_is_untouched(self):
        """The POS is high volume by design; this ceiling is not for it."""
        from django.contrib.auth.models import Group

        ensure_role_groups()
        user = get_user_model().objects.create_user(username="till", password="pass")
        user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        client = APIClient()
        client.login(username="till", password="pass")

        statuses = [
            client.get(reverse("shop-settings")).status_code for _ in range(6)
        ]

        self.assertNotIn(429, statuses)

    def test_signing_in_still_works_during_a_storm(self):
        """The worst outcome would be a runaway kiosk locking the shop out of
        its own POS. Sign-in has its own tighter throttle and is exempt here."""
        client = APIClient()
        for _ in range(6):
            self._post(client, "runaway-kiosk")

        response = client.post(
            reverse("auth-login"),
            {"username": "nobody", "password": "wrong"},
            format="json",
            headers={"X-Pointy-Device-Id": "runaway-kiosk"},
        )

        self.assertNotEqual(
            response.status_code,
            429,
            "a flood on one endpoint must not close the door on sign-in",
        )

    def test_a_caller_offering_credentials_is_left_to_the_other_ceiling(self):
        """Middleware runs before DRF, so it cannot judge a header-based
        credential. Waving those through is the safe direction: throttling a
        working till would be worse than missing an odd runaway."""
        client = APIClient()

        statuses = [
            client.post(
                reverse("analytics-event-ingest"),
                {"events": []},
                format="json",
                headers={
                    "X-Pointy-Device-Id": "relay-till",
                    "X-Pointy-Relay-Token": "tunnel-token",
                },
            ).status_code
            for _ in range(6)
        ]

        self.assertNotIn(429, statuses)
