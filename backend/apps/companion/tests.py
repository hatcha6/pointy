import io
import tempfile
import time
from unittest.mock import patch
from decimal import Decimal
from pathlib import Path

from django.contrib.auth import get_user_model
from django.db import connection
from django.test.utils import CaptureQueriesContext
from django.contrib.auth.models import Group
from django.core.files.uploadedfile import SimpleUploadedFile
from django.test import TestCase, override_settings
from django.urls import reverse
from django.utils import timezone
from PIL import Image
from rest_framework import status
from rest_framework.test import APIClient

from apps.attachments.models import Attachment
from apps.catalog.testing import create_product_with_default_variant
from apps.core.discovery import RELAYED_REQUEST_META
from apps.core.roles import CASHIER_GROUP, MANAGER_GROUP, ensure_role_groups
from apps.sales.models import RegisterSession

from . import services
from .models import (
    CompanionCaptureRequest,
    CompanionDevice,
    CompanionEvent,
    CompanionPairing,
)
from .tokens import hash_secret, normalize_pairing_code

TILL = "device-abc123"
LAN = "192.168.1.40"


def photo_bytes(color=(200, 40, 40)) -> bytes:
    buffer = io.BytesIO()
    Image.new("RGB", (64, 48), color).save(buffer, format="JPEG")
    return buffer.getvalue()



def barcode_image(symbology: str, value: str):
    """Render a real barcode, so the decoder is tested against a real symbology."""
    import zxingcpp

    fmt = getattr(zxingcpp.BarcodeFormat, symbology)
    try:
        written = zxingcpp.create_barcode(value, fmt)
        array = zxingcpp.write_barcode_to_image(written)
    except AttributeError:  # older zxing-cpp
        array = zxingcpp.write_barcode(fmt, value, width=600, height=260)
    return Image.fromarray(array)


def photographed(image, blur=1.4, angle=6, brightness=0.82):
    """Degrade a clean render the way a handheld phone photo degrades one.

    Blur, a few degrees of rotation and dim shop lighting are exactly what the
    browser's decoder could not cope with, so a test on a pristine render would
    prove nothing about the case this endpoint exists for.
    """
    from PIL import ImageEnhance, ImageFilter

    image = image.convert("L")
    # zxing renders one pixel per module. A code in a real photo is hundreds of
    # pixels across, so scale up before degrading — blurring a 33x33 render
    # destroys it outright and would test nothing.
    scale = max(1, round(520 / max(image.size)))
    image = image.resize(
        (image.width * scale, image.height * scale), Image.NEAREST
    )
    padded = Image.new("L", (image.width + 80, image.height + 80), 235)
    padded.paste(image, (40, 40))
    padded = padded.rotate(angle, expand=True, fillcolor=235, resample=Image.BICUBIC)
    padded = padded.filter(ImageFilter.GaussianBlur(blur))
    return ImageEnhance.Brightness(padded).enhance(brightness)


class CompanionTestCase(TestCase):
    """Shared setup: a till user on the LAN, and somewhere to put photos."""

    def setUp(self):
        self.storage_root = tempfile.TemporaryDirectory()
        (Path(self.storage_root.name) / "volume-a").mkdir()
        overrides = override_settings(
            POINTY_ATTACHMENT_STORAGE_ROOT=self.storage_root.name,
            POINTY_ATTACHMENT_ALLOWED_CONTENT_TYPES=[],
            POINTY_ATTACHMENT_MAX_UPLOAD_BYTES=8 * 1024 * 1024,
            POINTY_DISCOVERY_PRIVATE_ONLY=True,
        )
        overrides.enable()
        self.addCleanup(overrides.disable)
        self.addCleanup(self.storage_root.cleanup)

        ensure_role_groups()
        self.user = get_user_model().objects.create_user(
            username="cashier-companion", password="pass"
        )
        self.user.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.till = APIClient()
        self.till.force_authenticate(user=self.user)
        # The phone holds no session at all — that is the point.
        self.phone = APIClient()

    # -- helpers ---------------------------------------------------------

    def create_pairing(self, till_key=TILL):
        response = self.till.post(
            reverse("companion:pairing"),
            {"till_key": till_key, "till_label": "الصندوق الأول"},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        return response.data

    def claim(self, code, remote_addr=LAN):
        return self.phone.post(
            reverse("companion:pair"),
            {"code": code, "label": "iPhone"},
            format="json",
            REMOTE_ADDR=remote_addr,
        )

    def pair_phone(self, till_key=TILL):
        pairing = self.create_pairing(till_key)
        response = self.claim(pairing["code"])
        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        return response.data["token"]

    def as_phone(self, token):
        return {"HTTP_AUTHORIZATION": f"Companion {token}", "REMOTE_ADDR": LAN}


class PairingTests(CompanionTestCase):
    def test_pairing_url_carries_the_code_in_the_fragment(self):
        pairing = self.create_pairing()
        self.assertIn("/c/#", pairing["url"])
        self.assertTrue(pairing["url"].endswith(pairing["code"]))

    def test_code_is_never_stored_in_the_clear(self):
        pairing = self.create_pairing()
        row = CompanionPairing.objects.get()
        self.assertNotEqual(row.code_hash, pairing["code"])
        self.assertEqual(row.code_hash, hash_secret(pairing["code"]))

    def test_claiming_returns_a_token_and_pairs_the_device(self):
        pairing = self.create_pairing()
        response = self.claim(pairing["code"])

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        token = response.data["token"]
        device = CompanionDevice.objects.get()
        self.assertEqual(device.till_key, TILL)
        self.assertEqual(device.paired_by, self.user)
        self.assertEqual(device.token_hash, hash_secret(token))
        self.assertEqual(response.data["context"]["device_label"], "iPhone")

    def test_a_code_can_only_be_claimed_once(self):
        pairing = self.create_pairing()
        self.assertEqual(self.claim(pairing["code"]).status_code, 201)

        second = self.claim(pairing["code"])
        self.assertEqual(second.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(CompanionDevice.objects.count(), 1)

    def test_an_expired_code_is_refused(self):
        pairing = self.create_pairing()
        CompanionPairing.objects.update(expires_at=timezone.now() - timezone.timedelta(seconds=1))

        response = self.claim(pairing["code"])
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_opening_a_new_pairing_retires_the_previous_one(self):
        first = self.create_pairing()
        self.create_pairing()

        self.assertEqual(self.claim(first["code"]).status_code, status.HTTP_400_BAD_REQUEST)

    def test_codes_are_typed_forgivingly(self):
        pairing = self.create_pairing()
        spaced = " ".join(pairing["code"].lower())

        self.assertEqual(normalize_pairing_code(spaced), pairing["code"])
        self.assertEqual(self.claim(spaced).status_code, status.HTTP_201_CREATED)

    def test_pairing_binds_to_the_open_register_session(self):
        session = RegisterSession.objects.create(
            owner=self.user, owner_key=f"user:{self.user.pk}"
        )
        token = self.pair_phone()

        device = CompanionDevice.objects.get()
        self.assertEqual(device.register_session, session)

        session.status = RegisterSession.Status.CLOSED
        session.save(update_fields=["status"])

        response = self.phone.get(reverse("companion:context"), **self.as_phone(token))
        self.assertEqual(response.status_code, status.HTTP_401_UNAUTHORIZED)
        device.refresh_from_db()
        self.assertEqual(device.revoked_reason, CompanionDevice.RevokedReason.SESSION_CLOSED)


class CompanionIsolationTests(CompanionTestCase):
    """A companion token is not a login. This is the load-bearing boundary."""

    def test_companion_token_cannot_reach_the_ordinary_api(self):
        token = self.pair_phone()

        for name in ("product-list", "order-list", "customer-list"):
            response = self.phone.get(reverse(name), **self.as_phone(token))
            self.assertIn(
                response.status_code,
                (status.HTTP_401_UNAUTHORIZED, status.HTTP_403_FORBIDDEN),
                f"{name} answered a companion token with {response.status_code}",
            )

    def test_companion_request_never_authenticates_a_user(self):
        token = self.pair_phone()
        response = self.phone.get(reverse("companion:context"), **self.as_phone(token))

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertFalse(response.wsgi_request.user.is_authenticated)
        self.assertIsNotNone(response.wsgi_request.companion_device)

    def test_a_relayed_request_is_not_on_the_shop_network(self):
        token = self.pair_phone()

        response = self.phone.get(
            reverse("companion:context"),
            **{**self.as_phone(token), RELAYED_REQUEST_META: "1"},
        )
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)

    def test_a_public_address_cannot_pair(self):
        pairing = self.create_pairing()
        response = self.claim(pairing["code"], remote_addr="41.208.1.1")

        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)
        self.assertFalse(CompanionDevice.objects.exists())

    def test_an_unknown_token_is_rejected(self):
        response = self.phone.get(
            reverse("companion:context"),
            HTTP_AUTHORIZATION="Companion not-a-real-token",
            REMOTE_ADDR=LAN,
        )
        self.assertEqual(response.status_code, status.HTTP_401_UNAUTHORIZED)

    def test_a_revoked_device_stops_working_immediately(self):
        token = self.pair_phone()
        CompanionDevice.objects.get().revoke()

        response = self.phone.post(
            reverse("companion:scan"), {"value": "123"}, format="json", **self.as_phone(token)
        )
        self.assertEqual(response.status_code, status.HTTP_401_UNAUTHORIZED)


class ScanDeliveryTests(CompanionTestCase):
    def test_a_scan_reaches_the_till(self):
        token = self.pair_phone()

        response = self.phone.post(
            reverse("companion:scan"),
            {"value": "https://moamalat.example/r/9931", "symbology": "qr"},
            format="json",
            **self.as_phone(token),
        )
        self.assertEqual(response.status_code, status.HTTP_201_CREATED)

        inbox = self.till.get(reverse("companion:event-list"), {"till_key": TILL})
        events = inbox.data["events"]
        self.assertEqual(len(events), 2)  # connected, then the scan
        self.assertEqual(events[-1]["kind"], CompanionEvent.Kind.SCAN)
        self.assertEqual(events[-1]["payload"]["value"], "https://moamalat.example/r/9931")
        self.assertEqual(inbox.data["cursor"], events[-1]["id"])

    def test_the_cursor_only_returns_what_is_new(self):
        token = self.pair_phone()
        first = self.till.get(reverse("companion:event-list"), {"till_key": TILL})
        cursor = first.data["cursor"]

        self.phone.post(
            reverse("companion:scan"), {"value": "AAA"}, format="json", **self.as_phone(token)
        )
        second = self.till.get(
            reverse("companion:event-list"), {"till_key": TILL, "since": cursor}
        )

        self.assertEqual([event["payload"]["value"] for event in second.data["events"]], ["AAA"])

    def test_a_paused_phone_keeps_working_but_nothing_reaches_the_till(self):
        token = self.pair_phone()
        device = CompanionDevice.objects.get()
        self.till.patch(
            reverse("companion:device-detail", args=[device.pk]),
            {"is_paused": True},
            format="json",
        )
        before = CompanionEvent.objects.filter(kind=CompanionEvent.Kind.SCAN).count()

        response = self.phone.post(
            reverse("companion:scan"), {"value": "POCKET"}, format="json", **self.as_phone(token)
        )

        self.assertEqual(response.status_code, status.HTTP_202_ACCEPTED)
        self.assertTrue(response.data["paused"])
        self.assertEqual(
            CompanionEvent.objects.filter(kind=CompanionEvent.Kind.SCAN).count(), before
        )

    def test_an_empty_scan_is_refused(self):
        token = self.pair_phone()
        response = self.phone.post(
            reverse("companion:scan"), {"value": "  "}, format="json", **self.as_phone(token)
        )
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_scans_are_scoped_to_their_own_till(self):
        token = self.pair_phone(till_key=TILL)
        self.phone.post(
            reverse("companion:scan"), {"value": "MINE"}, format="json", **self.as_phone(token)
        )

        other = self.till.get(
            reverse("companion:event-list"), {"till_key": "device-someone-else"}
        )
        self.assertEqual(other.data["events"], [])


class CaptureTests(CompanionTestCase):
    def setUp(self):
        super().setUp()
        self.product = create_product_with_default_variant(
            sku="COMPANION-1", name="علبة تونة", unit_price=Decimal("3.50")
        )
        self.manager = get_user_model().objects.create_user(
            username="manager-companion", password="pass"
        )
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.manager_till = APIClient()
        self.manager_till.force_authenticate(user=self.manager)

    def upload(self, token, **extra):
        payload = SimpleUploadedFile("shot.jpg", photo_bytes(), content_type="image/jpeg")
        return self.phone.post(
            reverse("companion:capture"),
            {"file": payload, **extra},
            format="multipart",
            **self.as_phone(token),
        )

    def test_a_free_photo_is_parked_on_the_device(self):
        token = self.pair_phone()

        response = self.upload(token)

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        attachment = Attachment.objects.get(pk=response.data["attachment_id"])
        self.assertEqual(attachment.owner_type, "companion.companiondevice")
        self.assertEqual(attachment.created_by, self.user)
        self.assertEqual(attachment.metadata["source"], "companion")

    def test_a_requested_photo_files_itself_against_the_target(self):
        token = self.pair_phone()
        request = self.manager_till.post(
            reverse("companion:capture-request"),
            {
                "till_key": TILL,
                "prompt": "صوّر علبة التونة",
                "owner_type": "catalog.product",
                "owner_id": self.product.pk,
                "role": Attachment.Role.PRODUCT_IMAGE,
                "is_primary": True,
            },
            format="json",
        )
        self.assertEqual(request.status_code, status.HTTP_201_CREATED, request.data)

        # The phone is told what is wanted without being told anything else.
        context = self.phone.get(reverse("companion:context"), **self.as_phone(token))
        self.assertEqual(context.data["capture_request"]["prompt"], "صوّر علبة التونة")

        response = self.upload(token, capture_request=request.data["id"])

        attachment = Attachment.objects.get(pk=response.data["attachment_id"])
        self.assertEqual(attachment.owner_type, "catalog.product")
        self.assertEqual(attachment.owner_object_id, self.product.pk)
        self.assertEqual(attachment.role, Attachment.Role.PRODUCT_IMAGE)
        self.assertTrue(attachment.is_primary)
        self.assertEqual(
            CompanionCaptureRequest.objects.get().status,
            CompanionCaptureRequest.Status.FULFILLED,
        )

    def test_capture_request_needs_permission_on_what_it_targets(self):
        response = self.till.post(
            reverse("companion:capture-request"),
            {
                "till_key": TILL,
                "owner_type": "catalog.product",
                "owner_id": self.product.pk,
                "role": Attachment.Role.PRODUCT_IMAGE,
            },
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)

    def test_capture_request_refuses_a_target_type_attachments_would_refuse(self):
        response = self.manager_till.post(
            reverse("companion:capture-request"),
            {"till_key": TILL, "owner_type": "auth.user", "owner_id": self.user.pk},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_a_photo_that_is_not_an_image_is_refused(self):
        token = self.pair_phone()
        payload = SimpleUploadedFile("shot.jpg", b"not an image", content_type="image/jpeg")

        response = self.phone.post(
            reverse("companion:capture"),
            {"file": payload},
            format="multipart",
            **self.as_phone(token),
        )
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertFalse(Attachment.objects.exists())

    def test_the_capture_event_carries_the_photo_to_the_till(self):
        token = self.pair_phone()
        self.upload(token)

        inbox = self.till.get(reverse("companion:event-list"), {"till_key": TILL})
        capture = inbox.data["events"][-1]
        self.assertEqual(capture["kind"], CompanionEvent.Kind.CAPTURE)
        self.assertIsNotNone(capture["attachment_detail"])
        self.assertIn("content_url", capture["attachment_detail"])


class DeviceManagementTests(CompanionTestCase):
    def test_the_till_lists_and_unpairs_its_phones(self):
        self.pair_phone()
        device = CompanionDevice.objects.get()

        listed = self.till.get(reverse("companion:device-list"), {"till_key": TILL})
        self.assertEqual(len(listed.data), 1)
        self.assertTrue(listed.data[0]["is_live"])

        removed = self.till.delete(reverse("companion:device-detail", args=[device.pk]))
        self.assertEqual(removed.status_code, status.HTTP_204_NO_CONTENT)
        self.assertEqual(self.till.get(
            reverse("companion:device-list"), {"till_key": TILL}
        ).data, [])

    def test_another_cashier_cannot_unpair_someone_elses_phone(self):
        self.pair_phone()
        device = CompanionDevice.objects.get()
        intruder = get_user_model().objects.create_user(username="other", password="pass")
        intruder.groups.add(Group.objects.get(name=CASHIER_GROUP))
        client = APIClient()
        client.force_authenticate(user=intruder)

        response = client.delete(reverse("companion:device-detail", args=[device.pk]))
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)

    def test_a_phone_can_unpair_itself(self):
        token = self.pair_phone()

        response = self.phone.post(reverse("companion:leave"), **self.as_phone(token))

        self.assertEqual(response.status_code, status.HTTP_204_NO_CONTENT)
        self.assertIsNotNone(CompanionDevice.objects.get().revoked_at)

    def test_till_key_is_required(self):
        response = self.till.get(reverse("companion:device-list"))
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_listing_phones_does_not_cost_a_query_per_phone(self):
        """``is_live`` reads the register session, and this response is the only
        way a till learns that a phone's shift ended — nothing emits an event
        for it. So it is worth one join rather than one query per device."""
        self.pair_phone()
        url = reverse("companion:device-list")

        with CaptureQueriesContext(connection) as one_phone:
            self.assertEqual(
                len(self.till.get(url, {"till_key": TILL}).data), 1
            )

        CompanionDevice.objects.create(
            till_key=TILL,
            token_hash="second-phone-token-hash",
            paired_by=self.user,
        )
        with CaptureQueriesContext(connection) as two_phones:
            self.assertEqual(
                len(self.till.get(url, {"till_key": TILL}).data), 2
            )

        self.assertEqual(
            len(two_phones.captured_queries),
            len(one_phone.captured_queries),
            "a second phone should not cost a second round trip",
        )


class HousekeepingTests(CompanionTestCase):
    def test_purge_retires_what_has_aged_out(self):
        token = self.pair_phone()
        self.phone.post(
            reverse("companion:scan"), {"value": "OLD"}, format="json", **self.as_phone(token)
        )
        old = timezone.now() - timezone.timedelta(days=7)
        CompanionEvent.objects.update(created_at=old)
        CompanionDevice.objects.update(last_seen_at=old)

        summary = services.purge_expired()

        self.assertGreater(summary["events"], 0)
        self.assertEqual(CompanionEvent.objects.count(), 0)
        self.assertIsNotNone(CompanionDevice.objects.get().revoked_at)

    def test_purge_is_safe_to_run_on_a_quiet_shop(self):
        self.assertEqual(
            services.purge_expired(),
            {"events": 0, "pairings": 0, "capture_requests": 0, "devices": 0},
        )


class CompanionPageTests(CompanionTestCase):
    def test_the_page_is_served_on_the_lan(self):
        response = self.client.get("/c/", REMOTE_ADDR=LAN)

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertIn("text/html", response["Content-Type"])
        self.assertIn(b'dir="rtl"', response.content)
        self.assertTrue(response["ETag"])

    def test_the_page_revalidates_instead_of_going_stale(self):
        first = self.client.get("/c/", REMOTE_ADDR=LAN)
        again = self.client.get("/c/", REMOTE_ADDR=LAN, HTTP_IF_NONE_MATCH=first["ETag"])

        self.assertEqual(again.status_code, status.HTTP_304_NOT_MODIFIED)
        self.assertEqual(first["Cache-Control"], "no-cache")

    def test_a_weakened_etag_still_revalidates(self):
        """Gzip downgrades the tag to weak on the way out, and the browser sends
        that back. A literal comparison never matched, so every reload re-sent
        the whole bundle."""
        first = self.client.get("/c/app.js", REMOTE_ADDR=LAN)
        again = self.client.get(
            "/c/app.js",
            REMOTE_ADDR=LAN,
            HTTP_IF_NONE_MATCH=f'W/{first["ETag"]}',
        )

        self.assertEqual(again.status_code, status.HTTP_304_NOT_MODIFIED)

    def test_the_bundle_assets_are_served(self):
        for name, expected in (("app.js", "text/javascript"), ("app.css", "text/css")):
            response = self.client.get(f"/c/{name}", REMOTE_ADDR=LAN)
            self.assertEqual(response.status_code, status.HTTP_200_OK, name)
            self.assertIn(expected, response["Content-Type"])

    def test_the_page_is_not_served_off_the_shop_network(self):
        response = self.client.get("/c/", REMOTE_ADDR="41.208.1.1")
        self.assertEqual(response.status_code, status.HTTP_404_NOT_FOUND)

    def test_the_bundle_cannot_be_escaped(self):
        response = self.client.get("/c/../../settings.py", REMOTE_ADDR=LAN)
        self.assertEqual(response.status_code, status.HTTP_404_NOT_FOUND)


class StreamTests(CompanionTestCase):
    """The generator behind the till's SSE connection.

    Driven directly rather than through the view: a streaming response is
    consumed lazily, and the test client would either buffer it whole or hang.
    """

    def drain(self, generator, frames):
        collected = []
        for frame in generator:
            collected.append(frame)
            if len(collected) >= frames:
                break
        generator.close()
        return collected

    def test_the_stream_opens_by_announcing_its_cursor(self):
        stream = services.stream_events(till_key=TILL, cursor=0, serialize=lambda e: {"id": e.pk})
        frames = self.drain(stream, 1)

        self.assertTrue(frames[0].startswith("event: ready\n"))
        self.assertIn('"cursor": 0', frames[0])

    def test_the_stream_delivers_a_scan_that_arrives_after_it_opened(self):
        token = self.pair_phone()
        cursor = services.latest_event_id(TILL)
        stream = services.stream_events(
            till_key=TILL,
            cursor=cursor,
            serialize=lambda event: {"kind": event.kind, **event.payload},
        )
        self.drain_ready = next(stream)

        self.phone.post(
            reverse("companion:scan"), {"value": "LATE"}, format="json", **self.as_phone(token)
        )

        frame = next(stream)
        stream.close()
        self.assertTrue(frame.startswith("event: companion\n"))
        self.assertIn("LATE", frame)

    def test_a_reconnecting_till_replays_only_what_it_missed(self):
        token = self.pair_phone()
        cursor = services.latest_event_id(TILL)
        for value in ("A", "B"):
            self.phone.post(
                reverse("companion:scan"),
                {"value": value},
                format="json",
                **self.as_phone(token),
            )

        stream = services.stream_events(
            till_key=TILL, cursor=cursor, serialize=lambda event: event.payload
        )
        frames = self.drain(stream, 3)

        self.assertIn("A", frames[1])
        self.assertIn("B", frames[2])

    @override_settings(POINTY_COMPANION_STREAM_MAX_AGE_SECONDS=-1)
    def test_the_stream_asks_the_till_to_reconnect_instead_of_living_forever(self):
        stream = services.stream_events(till_key=TILL, cursor=0, serialize=lambda e: {})
        frames = list(stream)

        self.assertTrue(frames[-1].startswith("event: reconnect\n"))

    def test_the_stream_still_delivers_when_redis_cannot_answer(self):
        token = self.pair_phone()
        cursor = services.latest_event_id(TILL)
        self.phone.post(
            reverse("companion:scan"), {"value": "NOREDIS"}, format="json", **self.as_phone(token)
        )

        with patch.object(services.bus, "latest_cursor", return_value=None):
            stream = services.stream_events(
                till_key=TILL, cursor=cursor, serialize=lambda event: event.payload
            )
            frames = self.drain(stream, 2)

        self.assertIn("NOREDIS", frames[1])


class ServerDecodeTests(CompanionTestCase):
    """The fallback that reads what the phone's own decoder could not.

    jsQR is a clean-image, QR-only decoder, so on an iPhone every 1-D barcode
    and every slightly-blurred receipt QR died in the browser. These prove the
    server picks them up.
    """

    def frame(self, image) -> SimpleUploadedFile:
        buffer = io.BytesIO()
        image.convert("RGB").save(buffer, format="JPEG", quality=85)
        return SimpleUploadedFile("frame.jpg", buffer.getvalue(), content_type="image/jpeg")

    def post_frame(self, token, image):
        return self.phone.post(
            reverse("companion:decode"),
            {"file": self.frame(image)},
            format="multipart",
            **self.as_phone(token),
        )

    def test_a_photographed_barcode_is_read_and_recorded_as_a_scan(self):
        token = self.pair_phone()
        image = photographed(barcode_image("EAN13", "6001234500001"))

        response = self.post_frame(token, image)

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.assertTrue(response.data["found"], response.data)
        self.assertEqual(response.data["value"], "6001234500001")
        self.assertIn("ean", response.data["symbology"])

        inbox = self.till.get(reverse("companion:event-list"), {"till_key": TILL})
        scan = inbox.data["events"][-1]
        self.assertEqual(scan["kind"], CompanionEvent.Kind.SCAN)
        self.assertEqual(scan["payload"]["value"], "6001234500001")

    def test_a_photographed_qr_is_read(self):
        token = self.pair_phone()
        image = photographed(barcode_image("QRCode", "https://moamalat.ly/r/9931"))

        response = self.post_frame(token, image)

        self.assertTrue(response.data["found"], response.data)
        self.assertEqual(response.data["value"], "https://moamalat.ly/r/9931")

    def test_a_photo_with_no_code_is_a_clean_miss_not_an_error(self):
        token = self.pair_phone()
        blank = Image.new("RGB", (400, 300), (210, 210, 210))

        response = self.post_frame(token, blank)

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertFalse(response.data["found"])
        self.assertFalse(
            CompanionEvent.objects.filter(kind=CompanionEvent.Kind.SCAN).exists()
        )

    def test_a_paused_phone_decodes_but_nothing_reaches_the_till(self):
        token = self.pair_phone()
        CompanionDevice.objects.update(is_paused=True)
        image = photographed(barcode_image("QRCode", "PAUSED-1"))

        response = self.post_frame(token, image)

        self.assertTrue(response.data["found"])
        self.assertTrue(response.data["paused"])
        self.assertFalse(response.data["accepted"])
        self.assertFalse(
            CompanionEvent.objects.filter(kind=CompanionEvent.Kind.SCAN).exists()
        )

    def test_decoding_needs_a_companion_token(self):
        image = photographed(barcode_image("QRCode", "NOPE"))
        response = self.phone.post(
            reverse("companion:decode"),
            {"file": self.frame(image)},
            format="multipart",
            REMOTE_ADDR=LAN,
        )
        self.assertEqual(response.status_code, status.HTTP_401_UNAUTHORIZED)

    def test_a_missing_file_is_refused(self):
        token = self.pair_phone()
        response = self.phone.post(
            reverse("companion:decode"), {}, format="multipart", **self.as_phone(token)
        )
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_rubbish_bytes_are_a_miss_rather_than_a_crash(self):
        token = self.pair_phone()
        payload = SimpleUploadedFile("frame.jpg", b"not an image", content_type="image/jpeg")
        response = self.phone.post(
            reverse("companion:decode"),
            {"file": payload},
            format="multipart",
            **self.as_phone(token),
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertFalse(response.data["found"])


class StreamResilienceTests(CompanionTestCase):
    """A cache in any state must not be able to make a till stop receiving."""

    def test_a_stale_redis_hint_does_not_blind_the_stream(self):
        """The hint says "nothing newer than 1" while the table has more.

        A naive ``published > cursor`` check treats that as "nothing to do" and
        suppresses every read for the rest of the shift — the till looks
        connected and receives nothing. The table is the authority.
        """
        token = self.pair_phone()
        cursor = services.latest_event_id(TILL)
        self.phone.post(
            reverse("companion:scan"), {"value": "BEHIND"}, format="json", **self.as_phone(token)
        )

        with patch.object(services.bus, "latest_cursor", return_value=1):
            stream = services.stream_events(
                till_key=TILL, cursor=cursor, serialize=lambda event: event.payload
            )
            frames = [next(stream), next(stream)]
            stream.close()

        self.assertIn("BEHIND", frames[1])

    def test_a_matching_hint_skips_the_database(self):
        """The whole point of the hint: an idle stream must not poll Postgres."""
        token = self.pair_phone()
        cursor = services.latest_event_id(TILL)

        with patch.object(services.bus, "latest_cursor", return_value=cursor):
            with patch.object(
                services, "events_since", wraps=services.events_since
            ) as spy:
                stream = services.stream_events(
                    till_key=TILL, cursor=cursor, serialize=lambda event: event.payload
                )
                next(stream)  # ready
                time.sleep(0.6)
                stream.close()

        self.assertEqual(spy.call_count, 0)
