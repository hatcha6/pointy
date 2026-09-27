"""Brand logos on the card products and their receipts: fetched from Qareeb, kept for a month.

The driver half runs against a fake session addressed by full URL, because
which *host* answers is the point: Qareeb's two hosts each lack logos the other
has. The sync half runs against a stub driver.
"""

from __future__ import annotations

import base64
import dataclasses
import io
import tempfile
from datetime import timedelta
from unittest import mock

import requests
from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.db import connection
from django.test import TestCase, override_settings
from django.test.utils import CaptureQueriesContext
from django.utils import timezone
from PIL import Image, ImageDraw
from rest_framework.test import APIClient

from apps.attachments.models import Attachment
from apps.attachments.services import active_attachments_for, open_attachment
from apps.catalog.serializers import ProductCatalogSummarySerializer
from apps.core.roles import CASHIER_GROUP, ensure_role_groups
from apps.printing.services import build_receipt_payload
from apps.sales.models import Order, RegisterSession

from . import voucher_logos, vouchers
from .models import IntegrationVoucher, IntegrationVoucherBrand
from .providers import provider_for
from .providers import qareeb as qareeb_driver
from .providers.base import ERROR_NOT_FOUND, ERROR_UNREACHABLE, VoucherLogo
from .test_qareeb import (
    LIBYANA_5,
    LIBYANA_10,
    PSN,
    _listing,
    _StubDriver,
    logged_in,
    qareeb_account,
)

LIBYANA_LOGO = "/media/products/7671138237167963211.png"
LIBYANA_PRINT = "/media/products/3828099958789567141.jpeg"
ALMADAR_LOGO = "/media/products/3085707942299050599.png"
PSN_LOGO = "/media/products/6441526735238889328.png"
NEW_HOST = "https://api.qareeb.ly"
OLD_HOST = "https://api.qareb.ly"


def _png(color=(200, 0, 0), size=(148, 148), mode="RGBA") -> bytes:
    buffer = io.BytesIO()
    Image.new(mode, size, color).save(buffer, format="PNG")
    return buffer.getvalue()


def _drawn(*, size=(160, 120), box=(40, 30, 119, 89), background=(255, 255, 255, 255), fmt="PNG") -> bytes:
    """A black rectangle (``box``) on ``background``: a logo with a margin."""
    image = Image.new("RGBA", size, background)
    ImageDraw.Draw(image).rectangle(box, fill=(0, 0, 0, 255))
    buffer = io.BytesIO()
    if fmt == "JPEG":
        image = image.convert("RGB")
    image.save(buffer, format=fmt)
    return buffer.getvalue()


def _decoded(data: bytes) -> Image.Image:
    image = Image.open(io.BytesIO(data))
    image.load()
    return image


# --- the driver ---------------------------------------------------------------------
class _MediaResponse:
    def __init__(self, status=200, content=b"", headers=None):
        self.status_code = status
        self.content = content
        self.headers = {"content-type": "image/png", **(headers or {})}
        self.closed = False

    def iter_content(self, chunk_size):
        for start in range(0, len(self.content), chunk_size):
            yield self.content[start:start + chunk_size]

    def close(self):
        self.closed = True


class _MediaSession:
    """``requests.Session`` for pictures, routed by the whole URL."""

    def __init__(self, routes):
        self.routes = routes
        self.calls = []

    def mount(self, prefix, adapter):
        """The driver mounts the shared pool on every session it builds."""

    def get(self, url, headers=None, timeout=None, stream=False):
        self.calls.append({"url": url, "headers": headers, "timeout": timeout, "stream": stream})
        answer = self.routes.get(url, _MediaResponse(404, b"<h1>Not Found</h1>", {"content-type": "text/html"}))
        if isinstance(answer, Exception):
            raise answer
        return answer


def media(routes):
    session = _MediaSession(routes)
    patcher = mock.patch("apps.integrations.providers.qareeb.requests.Session", return_value=session)
    return patcher, session


class QareebLogoFetchTests(TestCase):
    def setUp(self):
        self.account = logged_in(qareeb_account())
        self.logo = _png()

    def fetch(self, routes, path=LIBYANA_LOGO):
        patcher, session = media(routes)
        with patcher:
            return provider_for(self.account).voucher_logo(path), session

    def test_a_logo_is_read_from_the_accounts_host_as_the_app_asks_for_it(self):
        result, session = self.fetch({NEW_HOST + LIBYANA_LOGO: _MediaResponse(200, self.logo)})
        self.assertTrue(result.ok)
        self.assertEqual(result.data, self.logo)
        self.assertEqual(result.url, NEW_HOST + LIBYANA_LOGO)
        [call] = session.calls
        # The app's own headers, and no bearer: a picture spends no login.
        self.assertEqual(call["headers"]["user-agent"], "Dart/3.6 (dart:io)")
        self.assertNotIn("authorization", call["headers"])
        self.assertTrue(call["stream"])

    def test_a_logo_one_host_lacks_is_found_on_the_other(self):
        result, session = self.fetch({OLD_HOST + LIBYANA_LOGO: _MediaResponse(200, self.logo)})
        self.assertTrue(result.ok)
        self.assertEqual(result.url, OLD_HOST + LIBYANA_LOGO)
        self.assertEqual([c["url"] for c in session.calls], [NEW_HOST + LIBYANA_LOGO, OLD_HOST + LIBYANA_LOGO])

    def test_a_logo_no_host_has_is_not_found(self):
        result, _ = self.fetch({})
        self.assertFalse(result.ok)
        self.assertEqual(result.error_code, ERROR_NOT_FOUND)

    def test_a_host_that_did_not_answer_is_not_a_missing_logo(self):
        result, _ = self.fetch({NEW_HOST + LIBYANA_LOGO: requests.ConnectionError("reset")})
        self.assertFalse(result.ok)
        self.assertEqual(result.error_code, ERROR_UNREACHABLE)

    def test_only_a_path_on_the_api_host_is_followed(self):
        for path in ("https://elsewhere.example/logo.png", "//elsewhere.example/logo.png", "logo.png"):
            with self.subTest(path):
                result, session = self.fetch({}, path=path)
                self.assertFalse(result.ok)
                self.assertEqual(session.calls, [])

    def test_a_body_too_big_to_be_a_logo_is_refused(self):
        huge = _MediaResponse(200, b"x", {"content-length": str(qareeb_driver.MEDIA_MAX_BYTES + 1)})
        result, _ = self.fetch({NEW_HOST + LIBYANA_LOGO: huge, OLD_HOST + LIBYANA_LOGO: huge})
        self.assertFalse(result.ok)
        self.assertTrue(huge.closed)

    def test_the_listing_names_both_logos(self):
        brand = qareeb_driver._parse_brand(
            {"code": "30", "ar_desc": "ليبيانا", "logo": LIBYANA_LOGO, "logo_print": LIBYANA_PRINT},
            category="الاتصالات",
        )
        self.assertEqual(brand.logo_path, LIBYANA_LOGO)
        self.assertEqual(brand.print_logo_path, LIBYANA_PRINT)
        self.assertEqual(qareeb_driver._with_items_known(brand, True).print_logo_path, LIBYANA_PRINT)


# --- a receipt logo, ready to print ---------------------------------------------------
class PrintReadyTests(TestCase):
    def test_a_logo_is_trimmed_to_its_ink_in_grey(self):
        ready = _decoded(voucher_logos.print_ready(_drawn()))
        self.assertEqual(ready.format, "PNG")
        self.assertEqual(ready.mode, "L")
        # The 40 px margin is gone: every brand fills the same box on a slip.
        self.assertEqual(ready.size, (80, 60))

    def test_a_transparent_logo_is_laid_on_paper_not_on_black(self):
        ready = _decoded(voucher_logos.print_ready(_drawn(background=(0, 0, 0, 0))))
        self.assertEqual(ready.size, (80, 60))
        clear = _decoded(voucher_logos.print_ready(_drawn(size=(160, 120), box=(0, 0, 159, 59), background=(0, 0, 0, 0))))
        # Ink across the top half, the transparent half white paper beneath it.
        self.assertEqual(clear.size, (160, 60))

    def test_a_big_logo_is_scaled_to_what_a_receipt_prints(self):
        ready = _decoded(voucher_logos.print_ready(_drawn(size=(1024, 1024), box=(0, 0, 1023, 1023), fmt="JPEG")))
        self.assertEqual(max(ready.size), voucher_logos.PRINT_LOGO_MAX_DIMENSION)

    def test_a_faint_background_baked_into_the_file_is_paper(self):
        ready = _decoded(voucher_logos.print_ready(_drawn(background=(232, 232, 232, 255))))
        self.assertEqual(ready.size, (80, 60))
        self.assertEqual(set(ready.getdata()), {0})

    def test_greys_are_few_and_the_paper_stays_white(self):
        image = Image.new("L", (100, 100), 255)
        draw = ImageDraw.Draw(image)
        draw.rectangle((0, 0, 99, 99), outline=0, width=4)
        draw.rectangle((30, 30, 69, 69), fill=100)
        buffer = io.BytesIO()
        image.save(buffer, format="PNG")
        levels = set(_decoded(voucher_logos.print_ready(buffer.getvalue())).getdata())
        # White exactly white, or an office printer draws a grey box.
        self.assertIn(255, levels)
        self.assertIn(0, levels)
        self.assertLessEqual(levels, {17 * step for step in range(16)})

    def test_what_is_not_a_logo_prints_nothing(self):
        self.assertIsNone(voucher_logos.print_ready(b"<html>404</html>"))
        self.assertIsNone(voucher_logos.print_ready(_png((255, 255, 255, 255))))


# --- the sync -------------------------------------------------------------------------
class _LogoDriver(_StubDriver):
    """The shelf of ``_StubDriver``, plus pictures by path (bytes, or an error)."""

    def __init__(self, listing=None, brands=None, logos=None):
        super().__init__(listing, brands)
        self.logos = logos or {}
        self.logo_reads = []

    def voucher_logo(self, path):
        self.logo_reads.append(path)
        logo = self.logos.get(path)
        if isinstance(logo, Exception):
            raise logo
        if logo is None:
            return VoucherLogo(ok=False, error_code=ERROR_NOT_FOUND, error_detail="404")
        return VoucherLogo(ok=True, data=logo, url=NEW_HOST + path)


def _with_logos(listing, logos_by_code, prints_by_code):
    brands = tuple(
        dataclasses.replace(
            brand,
            logo_path=logos_by_code.get(brand.code, ""),
            print_logo_path=prints_by_code.get(brand.code, ""),
        )
        for brand in listing.brands
    )
    return dataclasses.replace(listing, brands=brands)


def shelf(logos_by_code, prints=None):
    """``_listing()`` with the given brands' logo paths, keyed by brand code.

    ``prints`` names their receipt logos the same way.
    """
    return _with_logos(_listing(), logos_by_code, prints or {})


def sync(account, driver, **kwargs):
    with mock.patch("apps.integrations.vouchers.provider_for", return_value=driver), mock.patch(
        "apps.integrations.voucher_logos.provider_for", return_value=driver
    ):
        return vouchers.sync_account(account, **kwargs)


class VoucherLogoSyncTests(TestCase):
    def setUp(self):
        storage = tempfile.TemporaryDirectory()
        self.addCleanup(storage.cleanup)
        settings = override_settings(
            POINTY_ATTACHMENT_STORAGE_ROOT=storage.name,
            POINTY_ATTACHMENT_ALLOWED_CONTENT_TYPES=[],
        )
        settings.enable()
        self.addCleanup(settings.disable)
        self.account = logged_in(qareeb_account())
        self.red = _png((200, 0, 0))
        self.blue = _png((0, 0, 200))

    def libyana(self):
        return IntegrationVoucherBrand.objects.select_related("product").get(code="30")

    def logos(self, product):
        return active_attachments_for(product, role=Attachment.Role.PRODUCT_IMAGE)

    def age(self, field="logo_checked_at", **delta):
        """Pretend the last look at Libyana's logo was that long ago."""
        IntegrationVoucherBrand.objects.filter(code="30").update(
            **{field: timezone.now() - timedelta(**delta)}
        )

    def test_a_brand_logo_becomes_its_products_picture(self):
        driver = _LogoDriver(shelf({"30": LIBYANA_LOGO}), {"115": PSN}, {LIBYANA_LOGO: self.red})
        report = sync(self.account, driver)
        self.assertEqual(report.logos, 1)
        brand = self.libyana()
        [logo] = self.logos(brand.product)
        self.assertTrue(logo.is_primary)
        self.assertEqual(logo.metadata["imported_from"], voucher_logos.IMPORTED_FROM)
        self.assertEqual(logo.metadata["logo_path"], LIBYANA_LOGO)
        self.assertEqual(logo.content_type, "image/png")
        with open_attachment(logo) as stored:
            self.assertEqual(stored.read(), self.red)
        self.assertEqual(brand.logo_source, LIBYANA_LOGO)
        # What the till's catalog carries for the tile.
        payload = ProductCatalogSummarySerializer(brand.product, context={}).data
        self.assertEqual(payload["primary_image"]["id"], logo.pk)

    def test_a_logo_that_is_in_is_not_fetched_again_for_a_month(self):
        driver = _LogoDriver(shelf({"30": LIBYANA_LOGO}), logos={LIBYANA_LOGO: self.red})
        sync(self.account, driver)
        sync(self.account, driver)
        self.age(days=29)
        sync(self.account, driver)
        self.assertEqual(driver.logo_reads, [LIBYANA_LOGO])

        # A month on it is read again; unchanged, it moves nothing a till sees.
        [before] = self.logos(self.libyana().product)
        self.age(days=31)
        report = sync(self.account, driver)
        self.assertEqual(driver.logo_reads, [LIBYANA_LOGO, LIBYANA_LOGO])
        self.assertEqual(report.logos, 0)
        [after] = self.logos(self.libyana().product)
        self.assertEqual(after.pk, before.pk)
        self.assertGreater(self.libyana().logo_checked_at, timezone.now() - timedelta(minutes=1))

    def test_a_logo_redrawn_at_the_provider_is_replaced_after_a_month(self):
        driver = _LogoDriver(shelf({"30": LIBYANA_LOGO}), logos={LIBYANA_LOGO: self.red})
        sync(self.account, driver)
        [old] = self.logos(self.libyana().product)
        driver.logos[LIBYANA_LOGO] = self.blue
        self.age(days=31)
        self.assertEqual(sync(self.account, driver).logos, 1)
        [new] = self.logos(self.libyana().product)
        # A new attachment, not new bytes under the old one: tills cache a
        # picture by its URL and would keep showing the old logo.
        self.assertNotEqual(new.pk, old.pk)
        self.assertTrue(new.is_primary)
        old.refresh_from_db()
        self.assertEqual(old.status, Attachment.Status.DELETED)

    def test_a_new_logo_file_is_fetched_on_the_next_sweep(self):
        driver = _LogoDriver(shelf({"30": LIBYANA_LOGO}), logos={LIBYANA_LOGO: self.red})
        sync(self.account, driver)
        renamed = "/media/products/7671138237167963211_Xy12Ab3.png"
        driver.listing = shelf({"30": renamed})
        driver.logos[renamed] = self.blue
        sync(self.account, driver)
        self.assertEqual(driver.logo_reads, [LIBYANA_LOGO, renamed])
        [logo] = self.logos(self.libyana().product)
        self.assertEqual(logo.metadata["logo_path"], renamed)
        self.assertEqual(self.libyana().logo_source, renamed)

    def test_a_missing_logo_is_asked_again_an_hour_later_not_every_sweep(self):
        driver = _LogoDriver(shelf({"30": LIBYANA_LOGO}))
        sync(self.account, driver)
        sync(self.account, driver)
        brand = self.libyana()
        self.assertEqual(list(self.logos(brand.product)), [])
        self.assertEqual(brand.logo_source, "")
        self.assertEqual(driver.logo_reads, [LIBYANA_LOGO])

        self.age(minutes=61)
        driver.logos[LIBYANA_LOGO] = self.red
        sync(self.account, driver)
        self.assertEqual(driver.logo_reads, [LIBYANA_LOGO, LIBYANA_LOGO])
        self.assertEqual(len(self.logos(self.libyana().product)), 1)

    def test_a_logo_gone_from_the_provider_keeps_the_picture_the_product_has(self):
        driver = _LogoDriver(shelf({"30": LIBYANA_LOGO}), logos={LIBYANA_LOGO: self.red})
        sync(self.account, driver)
        del driver.logos[LIBYANA_LOGO]
        self.age(days=31)
        sync(self.account, driver)
        brand = self.libyana()
        self.assertEqual(len(self.logos(brand.product)), 1)
        self.assertEqual(brand.logo_source, LIBYANA_LOGO)
        # Looked at, so the next look is a month away rather than an hour.
        self.age(hours=2)
        sync(self.account, driver)
        self.assertEqual(driver.logo_reads, [LIBYANA_LOGO, LIBYANA_LOGO])

    def test_an_error_page_served_as_a_logo_is_not_stored(self):
        driver = _LogoDriver(shelf({"30": LIBYANA_LOGO}), logos={LIBYANA_LOGO: b"<html>404</html>"})
        sync(self.account, driver)
        brand = self.libyana()
        self.assertEqual(list(self.logos(brand.product)), [])
        self.assertIsNotNone(brand.logo_checked_at)

    def test_a_big_logo_is_scaled_down_for_the_tiles(self):
        big = _png((10, 120, 30), size=(1024, 1024), mode="RGB")
        driver = _LogoDriver(shelf({"30": LIBYANA_LOGO}), logos={LIBYANA_LOGO: big})
        sync(self.account, driver)
        [logo] = self.logos(self.libyana().product)
        with open_attachment(logo) as stored, Image.open(stored) as image:
            self.assertEqual(max(image.size), voucher_logos.LOGO_MAX_DIMENSION)
        # Recognised as unchanged next month by what the provider served.
        self.age(days=31)
        self.assertEqual(sync(self.account, driver).logos, 0)

    def test_one_sweep_fetches_no_more_than_its_share(self):
        driver = _LogoDriver(
            shelf({"30": LIBYANA_LOGO, "31": ALMADAR_LOGO, "115": PSN_LOGO}),
            {"115": PSN},
            {LIBYANA_LOGO: self.red, ALMADAR_LOGO: self.blue, PSN_LOGO: self.red},
        )
        sync(self.account, driver, logo_limit=2)
        self.assertEqual(len(driver.logo_reads), 2)
        sync(self.account, driver, logo_limit=2)
        self.assertEqual(sorted(driver.logo_reads), sorted([LIBYANA_LOGO, ALMADAR_LOGO, PSN_LOGO]))

    def test_the_tills_picker_refresh_never_waits_on_a_logo(self):
        driver = _LogoDriver(shelf({"30": LIBYANA_LOGO}), logos={LIBYANA_LOGO: self.red})
        sync(self.account, driver, logo_limit=0)
        with mock.patch("apps.integrations.vouchers.provider_for", return_value=driver), mock.patch(
            "apps.integrations.voucher_logos.provider_for", return_value=driver
        ):
            vouchers.refresh_brand(self.account, self.libyana())
        self.assertEqual(driver.logo_reads, [])

    def test_a_driver_that_crashes_on_a_logo_costs_the_logo_not_the_shelf(self):
        driver = _LogoDriver(shelf({"30": LIBYANA_LOGO}), logos={LIBYANA_LOGO: RuntimeError("boom")})
        report = sync(self.account, driver)
        self.assertTrue(report.ok)
        brand = self.libyana()
        self.assertTrue(brand.product.is_active)
        self.assertEqual(list(self.logos(brand.product)), [])

    # --- the receipt's logo ------------------------------------------------------------
    def test_a_brand_receipt_logo_is_kept_ready_to_print(self):
        drawn = _drawn(fmt="JPEG")
        driver = _LogoDriver(shelf({}, prints={"30": LIBYANA_PRINT}), logos={LIBYANA_PRINT: drawn})
        report = sync(self.account, driver)
        self.assertEqual(report.logos, 1)
        brand = self.libyana()
        self.assertEqual(bytes(brand.print_logo), voucher_logos.print_ready(drawn))
        self.assertEqual(brand.print_logo_source, LIBYANA_PRINT)
        # A receipt logo is nobody's picture: the product gallery never sees it.
        self.assertEqual(list(self.logos(brand.product)), [])

    def test_a_receipt_logo_is_read_again_only_after_a_month(self):
        driver = _LogoDriver(shelf({}, prints={"30": LIBYANA_PRINT}), logos={LIBYANA_PRINT: _drawn()})
        sync(self.account, driver)
        sync(self.account, driver)
        self.age("print_logo_checked_at", days=29)
        sync(self.account, driver)
        self.assertEqual(driver.logo_reads, [LIBYANA_PRINT])

        self.age("print_logo_checked_at", days=31)
        self.assertEqual(sync(self.account, driver).logos, 0)
        self.assertEqual(driver.logo_reads, [LIBYANA_PRINT, LIBYANA_PRINT])

        redrawn = _drawn(box=(10, 10, 149, 109))
        driver.logos[LIBYANA_PRINT] = redrawn
        self.age("print_logo_checked_at", days=31)
        self.assertEqual(sync(self.account, driver).logos, 1)
        self.assertEqual(bytes(self.libyana().print_logo), voucher_logos.print_ready(redrawn))

    def test_a_receipt_logo_gone_from_the_provider_keeps_the_one_kept(self):
        drawn = _drawn()
        driver = _LogoDriver(shelf({}, prints={"30": LIBYANA_PRINT}), logos={LIBYANA_PRINT: drawn})
        sync(self.account, driver)
        del driver.logos[LIBYANA_PRINT]
        self.age("print_logo_checked_at", days=31)
        sync(self.account, driver)
        self.assertEqual(bytes(self.libyana().print_logo), voucher_logos.print_ready(drawn))

    def test_a_new_receipt_logo_file_is_fetched_on_the_next_sweep(self):
        driver = _LogoDriver(shelf({}, prints={"30": LIBYANA_PRINT}), logos={LIBYANA_PRINT: _drawn()})
        sync(self.account, driver)
        renamed = "/media/products/3828099958789567141_Ab12Cd3.jpeg"
        driver.listing = shelf({}, prints={"30": renamed})
        driver.logos[renamed] = _drawn(box=(0, 0, 159, 119))
        sync(self.account, driver)
        self.assertEqual(driver.logo_reads, [LIBYANA_PRINT, renamed])
        self.assertEqual(self.libyana().print_logo_source, renamed)

    def test_tiles_come_first_within_one_sweeps_share(self):
        driver = _LogoDriver(
            shelf({"30": LIBYANA_LOGO}, prints={"30": LIBYANA_PRINT}),
            logos={LIBYANA_LOGO: self.red, LIBYANA_PRINT: _drawn()},
        )
        sync(self.account, driver, logo_limit=1)
        self.assertEqual(driver.logo_reads, [LIBYANA_LOGO])
        sync(self.account, driver, logo_limit=1)
        self.assertEqual(driver.logo_reads, [LIBYANA_LOGO, LIBYANA_PRINT])


# --- the receipt logo in what the till prints from ----------------------------------------
class ReceiptLogoPayloadTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.account = logged_in(qareeb_account())
        vouchers_driver = _LogoDriver(_listing(), {"115": PSN})
        sync(self.account, vouchers_driver)
        self.logo = voucher_logos.print_ready(_drawn())
        IntegrationVoucherBrand.objects.filter(code="30").update(print_logo=self.logo)
        user = get_user_model().objects.create_user(username="till", password="x")
        user.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.register = RegisterSession.objects.create(owner=user, owner_key=f"user:{user.pk}")
        self.client = APIClient()
        self.client.force_authenticate(user)

    def sell(self, *codes):
        lines = [
            {"variant": IntegrationVoucher.objects.get(code=code).variant_id, "quantity": "1"}
            for code in codes
        ]
        response = self.client.post(
            "/api/orders/checkout/",
            {"register_session": self.register.pk, "lines": lines, "payment_method": "cash"},
            format="json",
        )
        self.assertEqual(response.status_code, 201, response.data)
        return response

    def test_a_card_line_carries_its_brands_receipt_logo(self):
        response = self.sell(LIBYANA_5)
        expected = base64.b64encode(self.logo).decode("ascii")
        # What the invoice (A4, roll) is printed from...
        self.assertEqual(response.data["lines"][0]["integration"]["receipt_logo"], expected)
        # ...and what a thermal receipt is.
        payload = build_receipt_payload(Order.objects.get(pk=response.data["id"]))
        self.assertEqual(payload["order"]["lines"][0]["integration"]["receipt_logo"], expected)

    def test_a_brand_without_a_receipt_logo_prints_none(self):
        IntegrationVoucherBrand.objects.filter(code="30").update(print_logo=None)
        response = self.sell(LIBYANA_5)
        self.assertIsNone(response.data["lines"][0]["integration"]["receipt_logo"])

    def test_one_read_per_brand_however_many_of_its_cards_are_sold(self):
        response = self.sell(LIBYANA_5, LIBYANA_5, LIBYANA_10)
        order = Order.objects.get(pk=response.data["id"])
        with CaptureQueriesContext(connection) as queries:
            payload = build_receipt_payload(order)
        brand_reads = [
            query for query in queries.captured_queries
            if "integrations_integrationvoucherbrand" in query["sql"]
        ]
        self.assertEqual(len(brand_reads), 1)
        self.assertEqual(
            {line["integration"]["receipt_logo"] for line in payload["order"]["lines"]},
            {base64.b64encode(self.logo).decode("ascii")},
        )
