"""A recorded 4xx must carry the reason it was refused.

5xx has carried ``error_type`` and a traceback since the exception-capture work;
4xx carried nothing but the status family, and the September 2026 field export
showed what that costs. One shop met a 400 on ``PATCH /api/purchase-orders/``
**41 times** across two orders and a 403 on a single attachment **63 times**, and
neither the screen nor the telemetry could say why — so from the data the shop
looked like it would not do its bookkeeping, when the app was refusing it.

A refusal we cannot explain is indistinguishable from neglect.
"""

from django.test import TestCase, override_settings
from django.urls import path
from rest_framework import status
from rest_framework.decorators import api_view, permission_classes
from rest_framework.permissions import AllowAny
from rest_framework.response import Response

from apps.analytics.models import AnalyticsEvent


@api_view(["GET"])
@permission_classes([AllowAny])
def already_closed_view(request):
    return Response(
        {
            "detail": "Register session is already closed.",
            "code": "register_session_already_closed",
        },
        status=status.HTTP_400_BAD_REQUEST,
    )


@api_view(["GET"])
@permission_classes([AllowAny])
def field_errors_view(request):
    return Response(
        {
            "quantity": ["Quantity must be positive."],
            "lines": [{"unit_cost": ["Unit cost cannot be negative."]}, {}],
        },
        status=status.HTTP_400_BAD_REQUEST,
    )


@api_view(["GET"])
@permission_classes([AllowAny])
def bare_403_view(request):
    return Response({"detail": "Nope."}, status=status.HTTP_403_FORBIDDEN)


@api_view(["GET"])
@permission_classes([AllowAny])
def long_detail_view(request):
    return Response({"detail": "x" * 900}, status=status.HTTP_400_BAD_REQUEST)


@api_view(["GET"])
@permission_classes([AllowAny])
def ok_view(request):
    return Response({"ok": True})


urlpatterns = [
    path("api/closed/", already_closed_view),
    path("api/fields/", field_errors_view),
    path("api/forbidden/", bare_403_view),
    path("api/long/", long_detail_view),
    path("api/ok/", ok_view),
]


@override_settings(ROOT_URLCONF=__name__, DEBUG=False)
class ClientErrorCaptureTests(TestCase):
    def _attributes(self):
        return AnalyticsEvent.objects.get(name="backend.request").attributes

    def test_a_machine_code_is_recorded(self):
        """The field an export groups by, and a client branches on."""
        self.client.get("/api/closed/")

        attributes = self._attributes()
        self.assertEqual(attributes["status_family"], "4xx")
        self.assertEqual(attributes["error_code"], "register_session_already_closed")
        self.assertEqual(
            attributes["error_detail"], "Register session is already closed."
        )

    def test_field_errors_are_flattened_into_a_readable_reason(self):
        self.client.get("/api/fields/")

        attributes = self._attributes()
        self.assertIn("Quantity must be positive.", attributes["error_detail"])
        self.assertIn("Unit cost cannot be negative.", attributes["error_detail"])
        # The field names too: "which field" is the first question asked of a
        # 400, and it groups where free text does not.
        self.assertEqual(sorted(attributes["error_fields"]), ["lines", "quantity"])

    def test_a_detail_only_body_records_no_field_list(self):
        self.client.get("/api/forbidden/")

        attributes = self._attributes()
        self.assertEqual(attributes["error_detail"], "Nope.")
        self.assertNotIn("error_fields", attributes)
        self.assertNotIn("error_code", attributes)

    def test_the_reason_is_capped(self):
        """Serializer messages can interpolate input; none of it survives this."""
        self.client.get("/api/long/")

        self.assertLessEqual(len(self._attributes()["error_detail"]), 200)

    def test_successful_requests_carry_no_error_fields(self):
        self.client.get("/api/ok/")

        attributes = self._attributes()
        for field in ("error_code", "error_detail", "error_fields"):
            self.assertNotIn(field, attributes)
