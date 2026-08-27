import asyncio
import socket
from datetime import timedelta
from decimal import Decimal
from unittest.mock import patch

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.contrib.contenttypes.models import ContentType
from django.test import TestCase
from django.urls import reverse
from django.utils import timezone
from rest_framework import status
from rest_framework.test import APIClient

from apps.attachments.models import Attachment, StorageVolume
from apps.catalog.models import Product, ProductVariant
from apps.catalog.testing import create_product_with_default_variant
from apps.core.roles import CASHIER_GROUP, MANAGER_GROUP, ensure_role_groups
from apps.discounts.models import DiscountRule

from . import daemon, discovery, service
from .drivers import (
    GenericTcpDriver,
    ScantechShuttleDriver,
)
from .formatting import (
    DisplayProfile,
    contains_arabic,
    encode_text,
    format_money,
    layout_lines,
    plan_for_support,
    prepare_text,
)
from .models import PriceCheckerDevice, PriceCheckEvent
from .pricing import lookup_price

TCP = PriceCheckerDevice.Transport.TCP
Arabic = PriceCheckerDevice.ArabicSupport
BARCODE = "6001234500001"


def make_product(name="Tee", sku="TEE-1", price="20.00", barcode=BARCODE, **kwargs):
    product = create_product_with_default_variant(
        name=name, sku=sku, unit_price=price, barcode=barcode
    )
    if kwargs:
        for field, value in kwargs.items():
            setattr(product, field, value)
        product.save()
    return product


def add_percentage_discount(product, percent="10", name=None):
    rule = DiscountRule.objects.create(
        name=name or f"{percent}% off",
        channel=DiscountRule.Channel.SALES,
        application_type=DiscountRule.ApplicationType.AUTOMATIC,
        scope=DiscountRule.Scope.LINE,
        value_type=DiscountRule.ValueType.PERCENTAGE,
        value=Decimal(percent),
        is_active=True,
    )
    rule.products.add(product)
    return rule


def attach_product_image(owner, *, filename="img.jpg", primary=True):
    """A minimal ACTIVE product-image attachment row (no real file needed).

    ``image_url`` is built from the row's pk + signed checksum token, so the
    kiosk payload tests don't need bytes on disk.
    """
    volume, _ = StorageVolume.objects.get_or_create(
        name="test-volume", defaults={"path": "/tmp/pointy-test-volume"}
    )
    return Attachment.objects.create(
        owner_content_type=ContentType.objects.get_for_model(owner),
        owner_object_id=owner.pk,
        role=Attachment.Role.PRODUCT_IMAGE,
        storage_volume=volume,
        relative_path=f"products/{owner.pk}/{filename}",
        original_filename=filename,
        content_type="image/jpeg",
        original_size=1024,
        stored_size=1024,
        checksum_sha256="0" * 64,
        is_primary=primary,
        status=Attachment.Status.ACTIVE,
    )


def profile(support=Arabic.UNICODE, *, cols=20, rows=5, encoding="utf-8"):
    return DisplayProfile(
        rows=rows, cols=cols, plan=plan_for_support(support), encoding=encoding
    )


class PricingTests(TestCase):
    def test_found_without_discount(self):
        make_product(price="20.00")
        result = lookup_price(BARCODE)
        self.assertTrue(result.found)
        self.assertEqual(result.original_price, Decimal("20.00"))
        self.assertEqual(result.final_price, Decimal("20.00"))
        self.assertFalse(result.has_discount)
        self.assertEqual(result.discounts, ())

    def test_found_with_percentage_discount(self):
        product = make_product(price="20.00")
        add_percentage_discount(product, "10")
        result = lookup_price(BARCODE)
        self.assertTrue(result.found)
        self.assertEqual(result.original_price, Decimal("20.00"))
        self.assertEqual(result.final_price, Decimal("18.00"))
        self.assertEqual(result.discount_total, Decimal("2.00"))
        self.assertEqual(result.discount_percent, Decimal("10"))
        self.assertTrue(result.has_discount)
        self.assertEqual(len(result.discounts), 1)
        self.assertEqual(result.discounts[0].name, "10% off")

    def test_image_is_resolved_only_when_requested(self):
        product = make_product()
        attachment = attach_product_image(product)
        # Opt-in: socket scans (default) skip the attachment query entirely.
        self.assertIsNone(lookup_price(BARCODE).image_attachment_id)
        with_image = lookup_price(BARCODE, with_image=True)
        self.assertEqual(with_image.image_attachment_id, attachment.pk)
        self.assertTrue(with_image.image_token)

    def test_image_absent_leaves_fields_empty(self):
        make_product()
        result = lookup_price(BARCODE, with_image=True)
        self.assertIsNone(result.image_attachment_id)
        self.assertEqual(result.image_token, "")

    def test_unknown_and_blank_barcode(self):
        self.assertFalse(lookup_price("does-not-exist").found)
        self.assertFalse(lookup_price("").found)
        self.assertFalse(lookup_price("   ").found)

    def test_barcode_is_normalised(self):
        make_product()
        self.assertTrue(lookup_price(f"  {BARCODE}  ").found)

    def test_archived_and_inactive_excluded(self):
        product = make_product()
        product.archived_at = timezone.now()
        product.save(update_fields=["archived_at"])
        self.assertFalse(lookup_price(BARCODE).found)

        product.archived_at = None
        product.is_active = False
        product.save(update_fields=["archived_at", "is_active"])
        self.assertFalse(lookup_price(BARCODE).found)

    def test_service_product_is_in_stock(self):
        make_product(is_service=True)
        result = lookup_price(BARCODE)
        self.assertTrue(result.found)
        self.assertTrue(result.in_stock)

    def test_stockless_physical_product_is_out_of_stock(self):
        make_product()  # no Stock row -> quantity_on_hand == 0
        self.assertFalse(lookup_price(BARCODE).in_stock)


class FormattingTests(TestCase):
    def test_money_arabic_and_latin(self):
        self.assertEqual(format_money(Decimal("12.5"), allow_arabic=True), "12.50 د.ل")
        self.assertEqual(format_money(Decimal("12.5"), allow_arabic=False), "12.50 LYD")
        self.assertEqual(format_money(None, allow_arabic=True), "0.00 د.ل")

    def test_contains_arabic(self):
        self.assertTrue(contains_arabic("سعر"))
        self.assertFalse(contains_arabic("Price 12.50"))

    def test_unicode_tier_passes_logical_text_through(self):
        # Smart displays shape + reorder themselves; we must not touch the text.
        self.assertEqual(prepare_text("ابج", profile(Arabic.UNICODE)), "ابج")

    def test_cp1256_tier_reorders_base_letters(self):
        # No reshape, bidi only: logical "ابج" -> visual "جبا" (RTL reversed).
        self.assertEqual(prepare_text("ابج", profile(Arabic.CP1256)), "جبا")

    def test_glyphs_tier_reshapes_to_presentation_forms(self):
        out = prepare_text("ابج", profile(Arabic.GLYPHS))
        self.assertNotEqual(out, "ابج")
        # Presentation forms live at U+FB50+; their presence proves reshaping.
        self.assertTrue(any(ch >= "ﭐ" for ch in out))

    def test_cp1256_currency_line_is_encodable(self):
        prof = profile(Arabic.CP1256, encoding="cp1256")
        prepared = prepare_text("قميص 12.50 د.ل", prof)
        encoded = encode_text(prepared, prof)
        # The whole point of CP1256: base Arabic + digits all encode (no "?").
        self.assertNotIn(b"?", encoded)
        self.assertEqual(prepared, encoded.decode("cp1256"))

    def test_none_tier_uses_latin_currency(self):
        self.assertEqual(
            format_money(Decimal("5"), allow_arabic=profile(Arabic.NONE).allow_arabic),
            "5.00 LYD",
        )

    def test_layout_truncates_to_grid(self):
        lines = layout_lines(["abcdefghij", "row2", "row3"], profile(cols=5, rows=2))
        self.assertEqual(lines, ["abcde", "row2"])


class DriverTests(TestCase):
    def test_scantech_parse_strips_framing(self):
        driver = ScantechShuttleDriver()
        self.assertEqual(driver.parse_request(b"\x02 6001234500001 \r\n"), BARCODE)
        self.assertIsNone(driver.parse_request(b"\r\n"))

    def test_encode_response_contains_discounted_price(self):
        product = make_product(price="20.00")
        add_percentage_discount(product, "10")
        result = lookup_price(BARCODE)
        driver = GenericTcpDriver()
        payload = driver.encode_response(result, profile(Arabic.UNICODE))
        text = payload.decode("utf-8")
        self.assertIn("18.00", text)
        self.assertIn("بدلاً من", text)  # "was" label in Arabic

    def test_encode_response_not_found_label(self):
        driver = GenericTcpDriver()
        from .pricing import PriceResult

        payload = driver.encode_response(PriceResult.not_found("x"), profile(Arabic.UNICODE))
        self.assertIn("غير موجود", payload.decode("utf-8"))

    def test_scantech_cp1256_response_roundtrips(self):
        make_product(name="قميص", price="12.50")
        result = lookup_price(BARCODE)
        device = PriceCheckerDevice(
            arabic_support=Arabic.CP1256,
            encoding="cp1256",
            display_rows=5,
            display_cols=20,
        )
        from .formatting import profile_from_device

        payload = ScantechShuttleDriver().encode_response(
            result, profile_from_device(device)
        )
        self.assertNotIn(b"?", payload)
        decoded = payload.decode("cp1256")
        self.assertTrue(contains_arabic(decoded))


class DiscoveryTests(TestCase):
    def test_driver_for_port_fingerprints(self):
        self.assertEqual(discovery.driver_for_port(9101), "scantech_shuttle")
        self.assertEqual(discovery.driver_for_port(9100), "generic_tcp")
        self.assertEqual(discovery.driver_for_port(1234), "generic_tcp")
        self.assertEqual(discovery.driver_for_port(None), "generic_tcp")

    def test_probe_targets_detects_open_port_only(self):
        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        open_port = listener.getsockname()[1]

        # Grab a definitely-closed port by binding then closing it.
        spare = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        spare.bind(("127.0.0.1", 0))
        closed_port = spare.getsockname()[1]
        spare.close()

        try:
            found = discovery.probe_targets(
                [("127.0.0.1", open_port), ("127.0.0.1", closed_port)],
                timeout=0.5,
            )
        finally:
            listener.close()
        self.assertIn(("127.0.0.1", open_port), found)
        self.assertNotIn(("127.0.0.1", closed_port), found)

    def test_register_scanned_is_idempotent(self):
        candidate = {
            "address": "192.168.5.20",
            "port": 9101,
            "driver": "scantech_shuttle",
            "mac": "aa:bb:cc:dd:ee:ff",
        }
        first = discovery.register_scanned([candidate])
        second = discovery.register_scanned([candidate])
        self.assertEqual(PriceCheckerDevice.objects.count(), 1)
        self.assertEqual(first[0].pk, second[0].pk)
        device = first[0]
        self.assertEqual(device.status, PriceCheckerDevice.Status.DISCOVERED)
        self.assertEqual(device.discovery_method, PriceCheckerDevice.DiscoveryMethod.SCAN)
        self.assertEqual(device.driver, "scantech_shuttle")
        self.assertEqual(device.transport, TCP)

    def test_self_register_and_resolve(self):
        device = discovery.resolve_device_for_peer("10.0.0.5", TCP)
        self.assertIsNotNone(device)
        self.assertEqual(device.status, PriceCheckerDevice.Status.ACTIVE)
        self.assertEqual(device.discovery_method, PriceCheckerDevice.DiscoveryMethod.SELF)
        again = discovery.resolve_device_for_peer("10.0.0.5", TCP)
        self.assertEqual(device.pk, again.pk)
        self.assertEqual(PriceCheckerDevice.objects.count(), 1)


class SocketScanTests(TestCase):
    def setUp(self):
        self.product = make_product(price="20.00")
        add_percentage_discount(self.product, "10")
        self.device = PriceCheckerDevice.objects.create(
            identifier="pc-counter",
            name="Counter",
            driver="generic_tcp",
            transport=TCP,
            address="127.0.0.1",
            encoding="utf-8",
            arabic_support=Arabic.UNICODE,
            status=PriceCheckerDevice.Status.ACTIVE,
        )

    def test_found_scan_logs_event_and_renders_price(self):
        reply = service.process_socket_scan(
            f"{BARCODE}\r\n".encode(),
            peer_ip="127.0.0.1",
            transport=TCP,
            local_port=9100,
        )
        self.assertIn("18.00", reply.decode("utf-8"))
        event = PriceCheckEvent.objects.get()
        self.assertEqual(event.result, PriceCheckEvent.Result.FOUND)
        self.assertEqual(event.device, self.device)
        self.assertEqual(event.barcode, BARCODE)
        self.assertEqual(event.final_price, Decimal("18.00"))
        self.assertEqual(event.original_price, Decimal("20.00"))
        self.device.refresh_from_db()
        self.assertIsNotNone(self.device.last_seen_at)

    def test_not_found_scan_logs_event(self):
        reply = service.process_socket_scan(
            b"0000000000\r\n",
            peer_ip="127.0.0.1",
            transport=TCP,
            local_port=9100,
        )
        self.assertIn("غير موجود", reply.decode("utf-8"))
        event = PriceCheckEvent.objects.get()
        self.assertEqual(event.result, PriceCheckEvent.Result.NOT_FOUND)

    def test_unknown_peer_self_registers(self):
        service.process_socket_scan(
            f"{BARCODE}\r\n".encode(),
            peer_ip="10.0.0.99",
            transport=TCP,
            local_port=9101,
        )
        device = PriceCheckerDevice.objects.get(address="10.0.0.99")
        self.assertEqual(device.discovery_method, PriceCheckerDevice.DiscoveryMethod.SELF)
        # local_port 9101 fingerprints the Scantech driver.
        self.assertEqual(device.driver, "scantech_shuttle")


class FakeWriter:
    def __init__(self, peername=("127.0.0.1", 55555), sockname=("127.0.0.1", 9101)):
        self._info = {"peername": peername, "sockname": sockname}
        self.written = b""
        self.closed = False

    def get_extra_info(self, key):
        return self._info.get(key)

    def write(self, data):
        self.written += data

    async def drain(self):
        return None

    def close(self):
        self.closed = True


class DaemonPlumbingTests(TestCase):
    """Exercise the asyncio TCP read/respond loop without real sockets or DB."""

    def _run(self, data, writer):
        async def runner():
            reader = asyncio.StreamReader()
            reader.feed_data(data)
            reader.feed_eof()
            await daemon._handle_tcp(reader, writer)

        asyncio.run(runner())

    def test_private_peer_gets_reply(self):
        writer = FakeWriter()
        with patch.object(daemon, "_process", return_value=b"OK\r\n") as proc:
            self._run(b"12345\r\n", writer)
        proc.assert_called_once()
        self.assertEqual(writer.written, b"OK\r\n")
        self.assertTrue(writer.closed)

    def test_non_private_peer_is_dropped(self):
        writer = FakeWriter(peername=("8.8.8.8", 4000))
        with patch.object(daemon, "_process", return_value=b"OK\r\n") as proc:
            self._run(b"12345\r\n", writer)
        proc.assert_not_called()
        self.assertEqual(writer.written, b"")


class LookupApiTests(TestCase):
    def setUp(self):
        self.client = APIClient()
        self.url = reverse("price-checker-lookup")
        self.product = make_product(price="20.00")
        add_percentage_discount(self.product, "10")

    def test_lan_lookup_returns_display_ready_payload(self):
        response = self.client.get(self.url, {"barcode": BARCODE})
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        data = response.json()
        self.assertTrue(data["found"])
        self.assertEqual(data["final_price"], "18.00")
        self.assertEqual(data["original_price"], "20.00")
        self.assertTrue(data["has_discount"])
        self.assertEqual(data["discount_percent"], 10)
        self.assertEqual(data["final_price_display"], "18.00 د.ل")
        self.assertEqual(data["currency"], "د.ل")
        self.assertEqual(len(data["discounts"]), 1)
        self.assertTrue(data["display_lines"])
        self.assertEqual(PriceCheckEvent.objects.count(), 1)

    def test_unknown_barcode_payload(self):
        response = self.client.get(self.url, {"barcode": "nope"})
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertFalse(response.json()["found"])
        self.assertEqual(
            PriceCheckEvent.objects.get().result, PriceCheckEvent.Result.NOT_FOUND
        )

    def test_payload_includes_absolute_signed_image_url(self):
        attachment = attach_product_image(self.product)
        data = self.client.get(self.url, {"barcode": BARCODE}).json()
        self.assertIn("image_url", data)
        self.assertTrue(data["image_url"].startswith("http"))
        self.assertIn(f"/api/attachments/{attachment.pk}/content/", data["image_url"])
        self.assertIn("token=", data["image_url"])

    def test_payload_image_url_blank_without_image(self):
        data = self.client.get(self.url, {"barcode": BARCODE}).json()
        self.assertEqual(data["image_url"], "")


class RegisterApiTests(TestCase):
    def setUp(self):
        self.client = APIClient()
        self.url = reverse("price-checker-register")
        self.product = make_product(price="20.00")

    def test_lan_self_register_creates_http_kiosk(self):
        response = self.client.post(
            self.url,
            {"identifier": "Front Kiosk", "name": "Front", "location": "Entrance"},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK, response.content)
        device = PriceCheckerDevice.objects.get()
        self.assertEqual(device.identifier, "front-kiosk")  # slugified
        self.assertEqual(device.name, "Front")
        self.assertEqual(device.location, "Entrance")
        self.assertEqual(device.transport, PriceCheckerDevice.Transport.HTTP)
        self.assertEqual(device.driver, "generic_http")
        self.assertEqual(device.status, PriceCheckerDevice.Status.ACTIVE)
        self.assertEqual(
            device.discovery_method, PriceCheckerDevice.DiscoveryMethod.SELF
        )
        self.assertIsNotNone(device.last_seen_at)

    def test_register_is_idempotent_and_updates_fields(self):
        self.client.post(self.url, {"identifier": "k1", "name": "Old"}, format="json")
        self.client.post(self.url, {"identifier": "k1", "name": "New"}, format="json")
        self.assertEqual(PriceCheckerDevice.objects.count(), 1)
        self.assertEqual(PriceCheckerDevice.objects.get().name, "New")

    def test_register_respects_admin_disable(self):
        self.client.post(self.url, {"identifier": "k1", "name": "Kiosk"}, format="json")
        device = PriceCheckerDevice.objects.get()
        device.status = PriceCheckerDevice.Status.DISABLED
        device.save(update_fields=["status"])
        self.client.post(self.url, {"identifier": "k1", "name": "Kiosk"}, format="json")
        device.refresh_from_db()
        self.assertEqual(device.status, PriceCheckerDevice.Status.DISABLED)

    def test_register_requires_identifier(self):
        response = self.client.post(self.url, {"name": "x"}, format="json")
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_registered_device_attributes_scans(self):
        self.client.post(self.url, {"identifier": "k1", "name": "Kiosk"}, format="json")
        lookup_url = reverse("price-checker-lookup")
        self.client.get(lookup_url, {"barcode": BARCODE, "device": "k1"})
        event = PriceCheckEvent.objects.get()
        self.assertEqual(event.device.identifier, "k1")
        self.assertEqual(event.result, PriceCheckEvent.Result.FOUND)



class RelayedLanGateTests(TestCase):
    """The LAN gate must not treat a relay-tunnelled request as LAN-local.

    The connector dials the backend from the shop's own network, so a request
    that came in from the internet over the relay still arrives with a private
    ``REMOTE_ADDR``. Without the relayed check, the price-checker's
    "LAN hardware or a signed-in user" gate degrades to "anyone holding the
    shop's relay access token", with no user session at all.
    """

    RELAYED = {"HTTP_X_POINTY_RELAYED_REQUEST": "1"}
    DENIED = (status.HTTP_401_UNAUTHORIZED, status.HTTP_403_FORBIDDEN)

    def setUp(self):
        self.client = APIClient()
        self.lookup_url = reverse("price-checker-lookup")
        self.register_url = reverse("price-checker-register")
        self.product = make_product(price="20.00")

    def test_relayed_anonymous_lookup_is_refused(self):
        response = self.client.get(
            self.lookup_url, {"barcode": BARCODE}, **self.RELAYED
        )
        # 401 rather than 403: DRF challenges an anonymous caller. Either way
        # the lookup is refused and no catalogue row is disclosed.
        self.assertIn(response.status_code, self.DENIED)
        self.assertEqual(PriceCheckEvent.objects.count(), 0)

    def test_relayed_anonymous_register_is_refused(self):
        response = self.client.post(
            self.register_url,
            {"identifier": "k1", "name": "Kiosk"},
            format="json",
            **self.RELAYED,
        )
        self.assertIn(response.status_code, self.DENIED)
        self.assertEqual(PriceCheckerDevice.objects.count(), 0)

    def test_relayed_signed_in_staff_still_allowed(self):
        User = get_user_model()
        staff = User.objects.create_user("pc-remote", password="x")
        signed_in = APIClient()
        signed_in.force_authenticate(staff)
        response = signed_in.get(
            self.lookup_url, {"barcode": BARCODE}, **self.RELAYED
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertTrue(response.json()["found"])


class DeviceApiTests(TestCase):
    def setUp(self):
        User = get_user_model()
        self.admin = User.objects.create_superuser("pc-admin", password="x")
        self.plain = User.objects.create_user("pc-plain", password="x")
        self.admin_client = APIClient()
        self.admin_client.force_authenticate(self.admin)
        self.plain_client = APIClient()
        self.plain_client.force_authenticate(self.plain)

    def test_create_device_validates_driver(self):
        url = reverse("price-checker-device-list")
        ok = self.admin_client.post(
            url,
            {
                "identifier": "aisle-3",
                "name": "Aisle 3",
                "driver": "scantech_shuttle",
                "transport": "tcp",
                "arabic_support": "cp1256",
                "encoding": "cp1256",
            },
            format="json",
        )
        self.assertEqual(ok.status_code, status.HTTP_201_CREATED, ok.content)

        bad = self.admin_client.post(
            url,
            {"identifier": "x", "name": "x", "driver": "nonsense", "transport": "tcp"},
            format="json",
        )
        self.assertEqual(bad.status_code, status.HTTP_400_BAD_REQUEST)

    def test_drivers_action_lists_makes(self):
        url = reverse("price-checker-device-drivers")
        response = self.admin_client.get(url)
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        keys = {row["key"] for row in response.json()}
        self.assertIn("scantech_shuttle", keys)
        self.assertIn("generic_http", keys)

    def test_scan_action(self):
        url = reverse("price-checker-device-scan")
        summary = {"found": 0, "registered": [], "candidates": []}
        with patch("apps.price_checker.views.run_discovery_scan", return_value=summary):
            response = self.admin_client.post(url)
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.json(), summary)

    def test_permission_denied_without_perms(self):
        url = reverse("price-checker-device-list")
        response = self.plain_client.post(
            url,
            {"identifier": "x", "name": "x", "driver": "generic_http", "transport": "http"},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)


class RolePermissionApiTests(TestCase):
    """The price_checker permissions are wired into the role groups.

    DeviceApiTests above authenticates as a superuser, which bypasses every
    permission check, so it can't tell whether a real role was actually
    granted these permissions. This exercises ensure_role_groups(): a manager
    (no superuser flag) gets full device CRUD + event view, while a cashier —
    a legitimate role that simply isn't entitled to manage hardware — is
    refused both the device endpoints and the scan-event log.
    """

    def setUp(self):
        ensure_role_groups()
        User = get_user_model()
        self.manager = User.objects.create_user("pc-manager", password="x")
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.cashier = User.objects.create_user("pc-cashier", password="x")
        self.cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))

        self.manager_client = APIClient()
        self.manager_client.force_authenticate(self.manager)
        self.cashier_client = APIClient()
        self.cashier_client.force_authenticate(self.cashier)

        self.device_url = reverse("price-checker-device-list")
        self.event_url = reverse("price-check-event-list")

    def _device_payload(self, identifier="aisle-7"):
        return {
            "identifier": identifier,
            "name": "Aisle 7",
            "driver": "generic_http",
            "transport": "http",
        }

    def test_manager_can_create_and_list_devices(self):
        created = self.manager_client.post(
            self.device_url, self._device_payload(), format="json"
        )
        self.assertEqual(created.status_code, status.HTTP_201_CREATED, created.content)

        listed = self.manager_client.get(self.device_url)
        self.assertEqual(listed.status_code, status.HTTP_200_OK)
        identifiers = {row["identifier"] for row in listed.json()["results"]}
        self.assertIn("aisle-7", identifiers)

    def test_manager_can_list_events(self):
        device = PriceCheckerDevice.objects.create(
            identifier="aisle-7", name="Aisle 7", driver="generic_http"
        )
        PriceCheckEvent.objects.create(
            device=device,
            device_identifier=device.identifier,
            barcode=BARCODE,
            result=PriceCheckEvent.Result.FOUND,
        )

        listed = self.manager_client.get(self.event_url)
        self.assertEqual(listed.status_code, status.HTTP_200_OK)
        barcodes = {row["barcode"] for row in listed.json()["results"]}
        self.assertIn(BARCODE, barcodes)

    def test_cashier_cannot_manage_devices_or_view_events(self):
        created = self.cashier_client.post(
            self.device_url, self._device_payload(), format="json"
        )
        self.assertEqual(created.status_code, status.HTTP_403_FORBIDDEN)
        self.assertFalse(PriceCheckerDevice.objects.exists())

        self.assertEqual(
            self.cashier_client.get(self.device_url).status_code,
            status.HTTP_403_FORBIDDEN,
        )
        self.assertEqual(
            self.cashier_client.get(self.event_url).status_code,
            status.HTTP_403_FORBIDDEN,
        )


class KioskSkuFallbackTests(TestCase):
    """A shop that labels its own goods still gets an answer.

    One kiosk scan in eight came back not_found, against a catalogue where
    2,996 variants carry no barcode at all. When the scanned code is not a
    barcode we know, try it as a SKU before telling a customer nothing.
    """

    def setUp(self):
        self.product = Product.objects.create(name="خبز", is_active=True)
        self.variant = ProductVariant.objects.create(
            product=self.product,
            name="رغيف",
            sku="BREAD-01",
            barcode="",
            unit_price=Decimal("1.00"),
            is_active=True,
        )

    def test_scanning_a_sku_finds_the_product(self):
        result = lookup_price("BREAD-01")
        self.assertTrue(result.found)
        self.assertEqual(result.variant_id, self.variant.id)

    def test_sku_match_is_case_insensitive(self):
        self.assertTrue(lookup_price("bread-01").found)

    def test_a_barcode_still_wins_over_a_similar_sku(self):
        other = Product.objects.create(name="حليب", is_active=True)
        ProductVariant.objects.create(
            product=other,
            name="علبة",
            sku="MILK-01",
            barcode="BREAD-01",
            unit_price=Decimal("3.00"),
            is_active=True,
        )
        result = lookup_price("BREAD-01")
        self.assertTrue(result.found)
        # The barcode match is looked up first and must not be shadowed.
        self.assertEqual(result.product_name, "حليب")

    def test_an_unknown_code_is_still_not_found(self):
        self.assertFalse(lookup_price("NOTHING-HERE").found)

    def test_an_archived_product_is_not_resurrected_by_its_sku(self):
        self.product.archived_at = timezone.now()
        self.product.save(update_fields=["archived_at"])
        self.assertFalse(lookup_price("BREAD-01").found)


class UnmatchedScanWorklistTests(TestCase):
    """816 misses are 816 unread audit rows; grouped they are a worklist."""

    def setUp(self):
        ensure_role_groups()
        self.user = get_user_model().objects.create_user(
            username="manager", password="pw"
        )
        self.user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client = APIClient()
        self.client.force_authenticate(self.user)
        self.url = reverse("price-check-event-unmatched")

    def _scan(self, barcode, result):
        return PriceCheckEvent.objects.create(
            barcode=barcode, result=result, device_identifier="kiosk-1"
        )

    def test_ranks_codes_by_how_often_they_were_scanned(self):
        for _ in range(3):
            self._scan("111", PriceCheckEvent.Result.NOT_FOUND)
        self._scan("222", PriceCheckEvent.Result.NOT_FOUND)
        self._scan("333", PriceCheckEvent.Result.FOUND)

        response = self.client.get(self.url)
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        rows = response.data["results"]
        self.assertEqual([row["barcode"] for row in rows], ["111", "222"])
        self.assertEqual(rows[0]["scans"], 3)

    def test_ignores_scans_that_found_something(self):
        self._scan("999", PriceCheckEvent.Result.FOUND)
        response = self.client.get(self.url)
        self.assertEqual(response.data["results"], [])

    def test_ignores_empty_codes(self):
        self._scan("", PriceCheckEvent.Result.NOT_FOUND)
        self.assertEqual(self.client.get(self.url).data["results"], [])

    def test_window_excludes_older_scans(self):
        old = self._scan("111", PriceCheckEvent.Result.NOT_FOUND)
        PriceCheckEvent.objects.filter(pk=old.pk).update(
            created_at=timezone.now() - timedelta(days=45)
        )
        self.assertEqual(self.client.get(self.url).data["results"], [])
        rows = self.client.get(self.url, {"days": 60}).data["results"]
        self.assertEqual(len(rows), 1)

    def test_a_cashier_cannot_read_the_worklist(self):
        cashier = get_user_model().objects.create_user(
            username="till", password="pw"
        )
        cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))
        client = APIClient()
        client.force_authenticate(cashier)
        self.assertEqual(
            client.get(self.url).status_code, status.HTTP_403_FORBIDDEN
        )
