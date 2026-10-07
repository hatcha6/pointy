"""The release header is how a till learns its backend was just updated."""

from django.test import TestCase, override_settings
from django.urls import reverse

from .version_header import SERVER_VERSION_HEADER


class ServerVersionHeaderTests(TestCase):
    @override_settings(POINTY_VERSION="0.8.0")
    def test_an_api_response_names_the_backend_release(self):
        response = self.client.get(reverse("setup-status"))

        self.assertEqual(response.headers.get(SERVER_VERSION_HEADER), "0.8.0")

    @override_settings(POINTY_VERSION="0.8.0")
    def test_a_refused_request_still_names_it(self):
        """The idle till's poll is anonymous until it signs in, and a 401 or
        403 must not hide an update it could otherwise have offered."""
        response = self.client.get("/api/state/")

        self.assertGreaterEqual(response.status_code, 400)
        self.assertEqual(response.headers.get(SERVER_VERSION_HEADER), "0.8.0")

    @override_settings(POINTY_VERSION="0.8.0")
    def test_pages_outside_the_api_are_left_alone(self):
        response = self.client.get("/healthz/")

        self.assertNotIn(SERVER_VERSION_HEADER, response.headers)

    @override_settings(POINTY_VERSION="")
    def test_an_unversioned_build_sends_nothing(self):
        response = self.client.get(reverse("setup-status"))

        self.assertNotIn(SERVER_VERSION_HEADER, response.headers)
