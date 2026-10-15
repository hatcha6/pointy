import datetime
import http.server
import ipaddress
import json
import socket
import ssl
import tempfile
import threading
import zipfile
from io import BytesIO
from pathlib import Path
from unittest import mock
from urllib import error, request

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID
from django.core.cache import cache
from django.test import SimpleTestCase, TestCase, override_settings
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient

from . import relay_transport
from .models import RelayInstallation
from .relay_transport import (
    create_connection_with_fallback,
    last_good_addresses,
    relay_urlopen,
    remember_address,
    resolver_snapshot,
)

LOOKUP_FAILED = socket.gaierror(-3, "Temporary failure in name resolution")


class LastGoodAddressTests(SimpleTestCase):
    def setUp(self):
        cache.clear()
        self.addCleanup(cache.clear)

    def test_remembers_newest_first_without_duplicates_and_caps_the_list(self):
        for address in ["10.0.0.1", "10.0.0.2", "10.0.0.1", "10.0.0.3", "10.0.0.4", "10.0.0.5"]:
            remember_address("my.dftr.ly", address)

        self.assertEqual(
            last_good_addresses("MY.dftr.ly"),
            ["10.0.0.5", "10.0.0.4", "10.0.0.3", "10.0.0.1"],
        )

    def test_a_working_lookup_never_touches_the_remembered_addresses(self):
        remember_address("my.dftr.ly", "203.0.113.9")
        sock = object()
        with mock.patch.object(relay_transport.socket, "create_connection", return_value=sock) as connect:
            self.assertIs(create_connection_with_fallback(("my.dftr.ly", 443), 5), sock)
        connect.assert_called_once_with(("my.dftr.ly", 443), 5, None)
        self.assertEqual(relay_transport.fallback_stats()["count"], 0)

    def test_failed_lookup_with_nothing_remembered_still_fails(self):
        with mock.patch.object(relay_transport.socket, "create_connection", side_effect=LOOKUP_FAILED):
            with self.assertRaises(socket.gaierror):
                create_connection_with_fallback(("my.dftr.ly", 443), 5)

    def test_failed_lookup_connects_to_the_next_remembered_address_that_answers(self):
        remember_address("my.dftr.ly", "203.0.113.2")
        remember_address("my.dftr.ly", "203.0.113.1")
        sock = object()

        def connect(address, timeout, source_address):
            if address[0] == "my.dftr.ly":
                raise LOOKUP_FAILED
            if address[0] == "203.0.113.1":
                raise ConnectionRefusedError("gone")
            return sock

        with mock.patch.object(relay_transport.socket, "create_connection", side_effect=connect) as calls:
            self.assertIs(create_connection_with_fallback(("my.dftr.ly", 443), 5), sock)

        self.assertEqual(
            [call.args[0] for call in calls.call_args_list],
            [("my.dftr.ly", 443), ("203.0.113.1", 443), ("203.0.113.2", 443)],
        )
        stats = relay_transport.fallback_stats()
        self.assertEqual(stats["count"], 1)
        self.assertEqual(stats["address"], "203.0.113.2")

    def test_every_remembered_address_failing_raises_an_os_error(self):
        remember_address("my.dftr.ly", "203.0.113.1")

        def connect(address, timeout, source_address):
            if address[0] == "my.dftr.ly":
                raise LOOKUP_FAILED
            raise ConnectionRefusedError("gone")

        with mock.patch.object(relay_transport.socket, "create_connection", side_effect=connect):
            with self.assertRaises(ConnectionRefusedError):
                create_connection_with_fallback(("my.dftr.ly", 443), 5)


def _self_signed(host_name):
    key = ec.generate_private_key(ec.SECP256R1())
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, host_name)])
    now = datetime.datetime.now(datetime.timezone.utc)
    certificate = (
        x509.CertificateBuilder()
        .subject_name(name)
        .issuer_name(name)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - datetime.timedelta(days=1))
        .not_valid_after(now + datetime.timedelta(days=1))
        .add_extension(x509.SubjectAlternativeName([x509.DNSName(host_name)]), critical=False)
        .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
        .sign(key, hashes.SHA256())
    )
    cert_pem = certificate.public_bytes(serialization.Encoding.PEM)
    key_pem = key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    )
    return cert_pem, key_pem


class _Ok(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = json.dumps({"host": self.headers.get("Host")}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


class RelayUrlopenOverTlsTests(SimpleTestCase):
    """A real TLS server on 127.0.0.1 serving a certificate for a name that
    does not resolve: proves the fallback keeps verifying the host name."""

    def _serve(self, cert_host):
        cert_pem, key_pem = _self_signed(cert_host)
        folder = Path(tempfile.mkdtemp())
        (folder / "cert.pem").write_bytes(cert_pem)
        (folder / "key.pem").write_bytes(key_pem)
        server_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        server_context.load_cert_chain(folder / "cert.pem", folder / "key.pem")
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _Ok)
        server.socket = server_context.wrap_socket(server.socket, server_side=True)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        client_context = ssl.create_default_context(cadata=cert_pem.decode())
        return server.server_address[1], client_context

    def setUp(self):
        cache.clear()
        self.addCleanup(cache.clear)
        real_create_connection = socket.create_connection

        def offline_dns(address, *args, **kwargs):
            try:
                ipaddress.ip_address(address[0])
            except ValueError:
                raise LOOKUP_FAILED from None
            return real_create_connection(address, *args, **kwargs)

        patcher = mock.patch.object(relay_transport.socket, "create_connection", side_effect=offline_dns)
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_falls_back_to_the_remembered_address_and_keeps_the_host_name(self):
        port, context = self._serve("relay.test")
        remember_address("relay.test", "127.0.0.1")

        with relay_urlopen(
            request.Request(f"https://relay.test:{port}/v1/ping"), timeout=5, context=context
        ) as response:
            payload = json.loads(response.read())

        self.assertEqual(payload["host"], f"relay.test:{port}")
        self.assertEqual(relay_transport.fallback_stats()["count"], 1)

    def test_a_remembered_address_serving_another_name_fails_verification(self):
        port, context = self._serve("someone-else.test")
        remember_address("relay.test", "127.0.0.1")

        with self.assertRaises(error.URLError) as raised:
            relay_urlopen(
                request.Request(f"https://relay.test:{port}/v1/ping"), timeout=5, context=context
            )
        self.assertIsInstance(raised.exception.reason, ssl.SSLCertVerificationError)

    def test_nothing_remembered_reports_the_lookup_failure(self):
        port, context = self._serve("relay.test")

        with self.assertRaises(error.URLError) as raised:
            relay_urlopen(
                request.Request(f"https://relay.test:{port}/v1/ping"), timeout=5, context=context
            )
        self.assertIsInstance(raised.exception.reason, socket.gaierror)

    def test_a_verified_handshake_records_the_peer_address(self):
        port, context = self._serve("relay.test")
        offline_dns = relay_transport.socket.create_connection.side_effect

        def resolves_locally(address, *args, **kwargs):
            if address[0] == "relay.test":
                address = ("127.0.0.1", address[1])
            return offline_dns(address, *args, **kwargs)

        with mock.patch.object(
            relay_transport.socket, "create_connection", side_effect=resolves_locally
        ):
            with relay_urlopen(
                request.Request(f"https://relay.test:{port}/"), timeout=5, context=context
            ) as response:
                response.read()

        self.assertEqual(last_good_addresses("relay.test"), ["127.0.0.1"])
        self.assertEqual(relay_transport.fallback_stats()["count"], 0)


@override_settings(POINTY_RELAY_CONTROL_URL="https://my.dftr.ly")
class ResolverSnapshotTests(SimpleTestCase):
    def setUp(self):
        cache.clear()
        self.addCleanup(cache.clear)

    def test_snapshot_reports_resolv_conf_lookups_and_remembered_addresses(self):
        remember_address("my.dftr.ly", "102.213.182.141")
        resolv = Path(tempfile.mkdtemp()) / "resolv.conf"
        resolv.write_text("# generated\nnameserver 127.0.0.11\noptions ndots:0\nfoo bar\n")
        outcomes = [
            LOOKUP_FAILED,
            [(socket.AF_INET, socket.SOCK_STREAM, 6, "", ("102.213.182.142", 443))],
        ]
        with mock.patch.object(relay_transport.socket, "getaddrinfo", side_effect=outcomes):
            snapshot = resolver_snapshot(probes=2, resolv_conf_path=resolv)

        self.assertEqual(snapshot["relay_host"], "my.dftr.ly")
        self.assertEqual(
            snapshot["resolv_conf"], {"lines": ["nameserver 127.0.0.11", "options ndots:0"]}
        )
        self.assertEqual(snapshot["last_good_addresses"], ["102.213.182.141"])
        self.assertFalse(snapshot["lookups"][0]["ok"])
        self.assertIn("gaierror", snapshot["lookups"][0]["error"])
        self.assertEqual(snapshot["lookups"][1]["addresses"], ["102.213.182.142"])


class DiagnosticsExportNetworkFileTests(TestCase):
    def setUp(self):
        cache.clear()
        self.addCleanup(cache.clear)

    def test_support_pull_carries_network_json(self):
        RelayInstallation.objects.create(
            installation_id="installation-net",
            shop_name="لمسة",
            relay_public_api_url="https://relay.example",
            relay_connector_address="relay.example:443",
            connector_token="ptc1.installation-net.connector-secret",
            access_token="ptr1.installation-net.access-secret",
        )
        snapshot = {"relay_host": "my.dftr.ly", "lookups": [{"ok": False}]}
        with mock.patch("apps.core.relay_views.resolver_snapshot", return_value=snapshot):
            response = APIClient().get(
                reverse("relay-diagnostics-analytics-export"),
                HTTP_X_POINTY_CONNECTOR_TOKEN="ptc1.installation-net.connector-secret",
            )
            body = b"".join(response.streaming_content)

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        with zipfile.ZipFile(BytesIO(body)) as archive:
            manifest = json.loads(archive.read("manifest.json"))
            network = json.loads(archive.read("network.json"))
        self.assertIn("network.json", manifest["files"])
        self.assertEqual(network, snapshot)

    def test_a_failing_snapshot_does_not_sink_the_export(self):
        RelayInstallation.objects.create(
            installation_id="installation-net-2",
            shop_name="لمسة",
            relay_public_api_url="https://relay.example",
            relay_connector_address="relay.example:443",
            connector_token="ptc1.installation-net-2.connector-secret",
            access_token="ptr1.installation-net-2.access-secret",
        )
        with mock.patch(
            "apps.core.relay_views.resolver_snapshot", side_effect=RuntimeError("boom")
        ):
            response = APIClient().get(
                reverse("relay-diagnostics-analytics-export"),
                HTTP_X_POINTY_CONNECTOR_TOKEN="ptc1.installation-net-2.connector-secret",
            )
            body = b"".join(response.streaming_content)

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        with zipfile.ZipFile(BytesIO(body)) as archive:
            self.assertEqual(
                json.loads(archive.read("network.json")), {"error": "RuntimeError: boom"}
            )
