from django.http import HttpResponse
from django.test import RequestFactory, SimpleTestCase, override_settings

from .host_validation import PrivateNetworkHostMiddleware, host_is_allowed


ALLOWED_NAMES = {"localhost", "127.0.0.1", "backend"}


class HostIsAllowedTests(SimpleTestCase):
    def test_private_ipv4_hosts_allowed(self):
        for host in [
            "192.168.1.50:8000",
            "192.168.1.50",
            "10.0.0.5:8000",
            "172.16.5.5",
            "172.31.255.255",
        ]:
            self.assertTrue(host_is_allowed(host, ALLOWED_NAMES), host)

    def test_loopback_and_link_local_allowed(self):
        for host in ["127.0.0.1", "127.0.0.1:8000", "169.254.10.10", "[::1]:8000", "[::1]"]:
            self.assertTrue(host_is_allowed(host, ALLOWED_NAMES), host)

    def test_allow_listed_names_allowed(self):
        for host in ["backend", "backend:8000", "localhost:8000"]:
            self.assertTrue(host_is_allowed(host, ALLOWED_NAMES), host)

    def test_public_addresses_and_names_rejected(self):
        # Genuinely globally-routable IPs and public names. (Note: Python's
        # is_private also covers reserved/doc ranges like 203.0.113.0/24, which is
        # fine to accept on a LAN — they are never globally reachable.)
        for host in [
            "8.8.8.8",
            "8.8.8.8:8000",
            "1.1.1.1",
            "172.32.0.1",  # just outside the private 172.16/12 block
            "evil.example.com",
            "pointy.local",  # an mDNS name not explicitly allow-listed
            "",
        ]:
            self.assertFalse(host_is_allowed(host, ALLOWED_NAMES), host)


@override_settings(
    ALLOWED_HOSTS=["*"],
    POINTY_LAN_ALLOWED_HOST_NAMES=sorted(ALLOWED_NAMES),
)
class PrivateNetworkHostMiddlewareTests(SimpleTestCase):
    def setUp(self):
        self.factory = RequestFactory()
        self.middleware = PrivateNetworkHostMiddleware(lambda request: HttpResponse("ok"))

    def test_private_host_passes_through(self):
        request = self.factory.get("/", HTTP_HOST="192.168.1.77:8000")
        response = self.middleware(request)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.content, b"ok")

    def test_public_host_rejected(self):
        request = self.factory.get("/", HTTP_HOST="evil.example.com")
        response = self.middleware(request)
        self.assertEqual(response.status_code, 400)
