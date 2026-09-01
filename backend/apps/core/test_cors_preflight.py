"""Every custom header the client attaches has to survive a CORS preflight.

This file exists because forgetting one does not degrade the web build — it
breaks it completely. ``ApiSession`` attaches the device trio
(``X-Pointy-Device-Id`` / ``-Platform`` / ``-App-Version``) to *every* request,
so a header missing from ``CORS_ALLOW_HEADERS`` means the browser blocks the
login POST itself and the app can only report "wrong username or password". That
is exactly what happened: the trio was added on the client for throttling and
telemetry and never added to the setting, and the web build could not sign in at
all while the credentials were perfectly correct.

Native builds never notice, which is why this needs a test rather than a habit.

The list below is the contract. When ``ApiSession`` starts sending a new header,
this test fails until the setting is updated — which is the point.
"""

from django.test import SimpleTestCase, override_settings
from django.urls import reverse

# Mirrors the non-safelisted headers set in
# ``frontend/lib/src/data/services/api_session.dart``. Safelisted ones (Accept,
# Content-Type, ...) never preflight and are not listed.
CLIENT_REQUEST_HEADERS = [
    "Idempotency-Key",
    "If-None-Match",
    "X-CSRFToken",
    "X-Pointy-App-Version",
    "X-Pointy-Device-Id",
    "X-Pointy-Platform",
    "X-Pointy-Relay-Token",
]

ORIGIN = "http://localhost:8080"


@override_settings(CORS_ALLOWED_ORIGINS=[ORIGIN])
class CorsPreflightTests(SimpleTestCase):
    def _preflight(self, requested):
        return self.client.options(
            reverse("auth-login"),
            HTTP_ORIGIN=ORIGIN,
            HTTP_ACCESS_CONTROL_REQUEST_METHOD="POST",
            HTTP_ACCESS_CONTROL_REQUEST_HEADERS=requested,
        )

    def _allowed(self, response):
        raw = response.headers.get("access-control-allow-headers", "")
        return {part.strip().lower() for part in raw.split(",") if part.strip()}

    def test_every_header_the_client_sends_is_allowed(self):
        response = self._preflight(", ".join(CLIENT_REQUEST_HEADERS))

        self.assertEqual(response.status_code, 200)
        allowed = self._allowed(response)
        missing = sorted(
            header.lower()
            for header in CLIENT_REQUEST_HEADERS
            if header.lower() not in allowed
        )
        self.assertEqual(
            missing,
            [],
            "CORS_ALLOW_HEADERS is missing header(s) the client sends on every "
            "request; the browser will block the call outright, and the web "
            "build cannot even log in.",
        )

    def test_the_device_id_header_alone_is_allowed(self):
        """The specific header that broke the web login, pinned on its own so a
        failure names it instead of the whole set."""
        response = self._preflight("X-Pointy-Device-Id")

        self.assertIn("x-pointy-device-id", self._allowed(response))

    def test_an_unknown_header_is_still_refused(self):
        """The allow-list has to stay a list — proof this suite would notice if
        it were ever widened to everything."""
        response = self._preflight("X-Made-Up-Header")

        self.assertNotIn("x-made-up-header", self._allowed(response))

    def test_the_preflight_allows_credentials(self):
        """Session cookie auth: without this the login response's Set-Cookie is
        dropped and every later request is anonymous."""
        response = self._preflight("X-Pointy-Device-Id")

        self.assertEqual(
            response.headers.get("access-control-allow-credentials"), "true"
        )
