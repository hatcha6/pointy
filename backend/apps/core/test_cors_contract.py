"""Every header the client sends must be one the browser is allowed to send.

This is a static guard, like the money-definition tests, and for the same
reason: the failure it prevents is somebody adding a header in Dart and not
in Django, and no runtime test sees it because the two halves live in
different languages and different processes.

The bug it guards against is unusually nasty. A header missing from
``CORS_ALLOW_HEADERS`` does not produce an error anywhere. The preflight
answers **200**; the browser compares the returned list against what it asked
for, finds a gap, and silently declines to send the real request. The server
log shows a run of ``OPTIONS`` with no ``POST`` after them, the client shows a
generic failure, and nothing on either side says why.

It only bites when the app and the API are on different origins — which is
every ``flutter run -d web-server`` session and any split-origin deployment,
and never the nginx-served production build. So it is exactly the kind of
thing that ships.
"""

from pathlib import Path
import re

from django.conf import settings
from django.test import SimpleTestCase

# backend/apps/core/ → repo root → frontend/…
API_SESSION = (
    Path(__file__).resolve().parents[3]
    / "frontend"
    / "lib"
    / "src"
    / "data"
    / "services"
    / "api_session.dart"
)

#: Headers the browser sets itself and refuses to let script name. They never
#: appear in a preflight request-headers list, so they need no entry.
BROWSER_CONTROLLED = {"cookie", "content-type"}


def _client_request_headers() -> set[str]:
    """Header names the Dart client puts on outgoing requests."""
    source = API_SESSION.read_text(encoding="utf-8")
    # Only the request-header builders: a map literal entry like
    #   'X-Request-ID': traceId,
    # Response-header *reads* are lowercase string lookups and are excluded by
    # requiring the quote-colon shape of a map key.
    return {
        name.lower()
        for name in re.findall(r"'((?:X|x)-[A-Za-z-]+)':", source)
    }


class CorsRequestHeaderContractTests(SimpleTestCase):
    def test_every_client_header_is_allowed_cross_origin(self):
        if not API_SESSION.exists():  # backend-only checkout
            self.skipTest("frontend sources not present")

        allowed = {name.lower() for name in settings.CORS_ALLOW_HEADERS}
        sent = _client_request_headers() - BROWSER_CONTROLLED
        missing = sorted(sent - allowed)

        self.assertEqual(
            missing,
            [],
            "PosApiSession sends these headers and CORS_ALLOW_HEADERS does not "
            "permit them, so a browser will silently refuse every cross-origin "
            f"request: {missing}. Add them in pointy/settings.py.",
        )

    def test_the_guard_can_actually_see_the_headers(self):
        # A regex that quietly matched nothing would make the test above pass
        # forever. Pin a couple of headers that must always be found.
        if not API_SESSION.exists():
            self.skipTest("frontend sources not present")
        sent = _client_request_headers()
        self.assertIn("x-request-id", sent)
        self.assertIn("x-pointy-device-id", sent)
