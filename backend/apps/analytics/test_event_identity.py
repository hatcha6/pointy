"""Which machine did this, and as part of what.

A field export held 3,845 sales and could not say which of the shop's two tills
rang up any of them. The identity was never unknown — the middleware computes it
for its own rows on every request — it simply had no way of reaching the events
recorded deeper in the stack. Every analysis that wanted to compare registers,
attribute a drawer, or follow one action from tap to row was blocked on that.
"""

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.http import HttpResponse
from django.test import TestCase, override_settings
from django.urls import path
from rest_framework.test import APIClient

from apps.analytics import context, services
from apps.analytics.models import AnalyticsEvent
from apps.core.roles import CASHIER_GROUP, ensure_role_groups

TILL = "till-7f3a"
TRACE = "trace-abc123"
REGISTER = "482"


def domain_event_view(request):
    """A view that records the way the sales, purchasing and auth paths do."""
    services.record_domain_event(
        name="sales.checkout.completed",
        attributes={"receipt_number": "R1"},
    )
    return HttpResponse("ok")


def immediate_event_view(request):
    services.record_event(
        name="sales.order.paid",
        event_type=AnalyticsEvent.EventType.AUDIT,
    )
    return HttpResponse("ok")


def preset_register_view(request):
    """A caller that already knows its register must not be overwritten."""
    services.record_domain_event(
        name="sales.register_session.closed",
        attributes={"register_session_id": "999"},
    )
    return HttpResponse("ok")


urlpatterns = [
    path("api/domain/", domain_event_view),
    path("api/immediate/", immediate_event_view),
    path("api/preset/", preset_register_view),
]


@override_settings(ROOT_URLCONF=__name__, DEBUG=False)
class DomainEventIdentityTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.user = get_user_model().objects.create_user(
            username="identity-cashier", password="pass"
        )
        self.user.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.client = APIClient()
        self.client.force_authenticate(user=self.user)

    def _call(self, url="/api/domain/", **headers):
        # `record_domain_event` defers to `on_commit`, which never fires inside
        # a TestCase's rolled-back transaction. Capturing and executing is how
        # the deferral gets exercised rather than skipped.
        with self.captureOnCommitCallbacks(execute=True):
            return self._get(url, **headers)

    def _get(self, url, **headers):
        return self.client.get(
            url,
            HTTP_X_POINTY_DEVICE_ID=TILL,
            HTTP_X_REQUEST_ID=TRACE,
            HTTP_X_POINTY_PLATFORM="flutter-windows",
            HTTP_X_POINTY_APP_VERSION="0.6.0",
            HTTP_X_POINTY_REGISTER_SESSION=REGISTER,
            **headers,
        )

    def _event(self, name):
        return AnalyticsEvent.objects.get(name=name)

    def test_a_sale_records_which_till_rang_it_up(self):
        self._call()

        event = self._event("sales.checkout.completed")
        self.assertEqual(event.installation_id, TILL)
        self.assertEqual(event.device_id, TILL)
        self.assertEqual(event.platform, "flutter-windows")
        self.assertEqual(event.app_version, "0.6.0")

    def test_a_sale_can_be_followed_back_to_the_request_that_made_it(self):
        self._call()

        self.assertEqual(self._event("sales.checkout.completed").trace_id, TRACE)

    def test_a_sale_records_the_register_session_it_belongs_to(self):
        self._call()

        event = self._event("sales.checkout.completed")
        self.assertEqual(event.attributes["register_session_id"], REGISTER)
        # And keeps what the caller said.
        self.assertEqual(event.attributes["receipt_number"], "R1")

    def test_a_caller_that_knows_its_register_is_not_overwritten(self):
        self._call("/api/preset/")

        event = self._event("sales.register_session.closed")
        self.assertEqual(event.attributes["register_session_id"], "999")

    def test_an_event_written_immediately_gets_it_too(self):
        """Not every path defers to ``on_commit``."""
        self._call("/api/immediate/")

        self.assertEqual(self._event("sales.order.paid").installation_id, TILL)

    def test_identity_survives_the_commit_hook(self):
        """The subtle one, and the reason this is captured rather than read.

        ``record_domain_event`` defers to ``on_commit``, which runs after the
        response has gone and the request's context has been reset. Reading the
        ambient identity in there finds nothing — and the events that most need
        a device are precisely the ones written that way.
        """
        with self.captureOnCommitCallbacks(execute=True) as callbacks:
            with context.request_identity(
                {
                    "installation_id": TILL,
                    "trace_id": TRACE,
                    "register_session_id": REGISTER,
                }
            ):
                services.record_domain_event(name="sales.order.voided")
                # Deferred, so nothing is written yet — and the context is torn
                # down at the end of this block, before the callback runs.
                self.assertFalse(
                    AnalyticsEvent.objects.filter(name="sales.order.voided").exists()
                )

        # Populated on exit, which is also when they run.
        self.assertEqual(len(callbacks), 1, "it really was deferred")
        event = self._event("sales.order.voided")
        self.assertEqual(event.installation_id, TILL)
        self.assertEqual(event.trace_id, TRACE)
        self.assertEqual(event.attributes["register_session_id"], REGISTER)

    def test_outside_a_request_nothing_is_invented(self):
        """A Celery task and a management command have no device. An empty
        field is the honest answer; a borrowed one would be a lie."""
        with self.captureOnCommitCallbacks(execute=True):
            services.record_domain_event(name="reports.run.failed")

        event = self._event("reports.run.failed")
        self.assertEqual(event.installation_id, "")
        self.assertEqual(event.trace_id, "")
        self.assertNotIn("register_session_id", event.attributes)

    def test_a_register_session_id_never_reaches_the_model_constructor(self):
        """It is not a column. Splatting it into ``AnalyticsEvent(**…)`` raises
        a TypeError inside a recorder that swallows its own exceptions, which
        does not fail loudly — it silently stops recording. This happened."""
        identity = {
            "installation_id": TILL,
            "register_session_id": REGISTER,
            "trace_id": TRACE,
        }

        columns = context.identity_columns(identity)

        self.assertNotIn("register_session_id", columns)
        self.assertEqual(columns["installation_id"], TILL)
        # The real guard: it has to survive the constructor.
        AnalyticsEvent(name="x", event_type="usage", occurred_at=None, **columns)
