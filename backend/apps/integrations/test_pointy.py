"""«كروت دفتر»: the company's own cards, bought through the relay.

The relay's answers here follow its contract (``VOUCHER_SHOP_PLAN.md``, "Shop
API") with made-up values; the relay itself is faked at the client
(:class:`FakeRelay`), so the driver, the mirror, the menu and the charge run
for real against it.
"""

from __future__ import annotations

import io
import json
import re
import tempfile
import threading
from datetime import datetime, timedelta, timezone as dt_timezone
from decimal import Decimal
from unittest import mock
from urllib import error as urllib_error

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.db import connection
from django.test import SimpleTestCase, TestCase, TransactionTestCase, override_settings
from django.test.utils import CaptureQueriesContext
from django.utils import timezone
from PIL import Image
from rest_framework.test import APIClient

from apps.attachments.models import Attachment
from apps.attachments.services import active_attachments_for
from apps.catalog.models import Product, ProductAlias, ProductCategory, ProductVariant
from apps.core.models import RelayInstallation
from apps.core.relay import RelayControlClient, RelayControlConfig, RelayControlError
from apps.core.roles import CASHIER_GROUP, MANAGER_GROUP, ensure_role_groups
from apps.customers.models import Customer
from apps.printing.services import build_receipt_payload
from apps.sales.models import Order, RegisterSession

from . import recharge, relay_link, vouchers
from .models import (
    IntegrationAccount,
    IntegrationFulfillment,
    IntegrationVoucher,
    IntegrationVoucherBrand,
    IntegrationVoucherCountry,
)
from .providers.base import (
    ATTEMPT_ABSENT,
    ATTEMPT_CHARGED,
    ATTEMPT_REFUSED,
    ATTEMPT_UNKNOWN,
    ERROR_BUSY,
    ERROR_INDETERMINATE,
    ERROR_INSUFFICIENT_FLOAT,
    ERROR_NOT_CONFIGURED,
    ERROR_OUT_OF_STOCK,
    ERROR_PRICE_CHANGED,
    ERROR_PROVIDER_ERROR,
    ERROR_UNAVAILABLE,
    ERROR_UNEXPECTED,
    ERROR_UNREACHABLE,
    in_parallel,
    without_figures,
)
from .providers.pointy import PointyProvider
from .reconciliation import ATTEMPT_SETTLE_AFTER, reconcile_account, settle_relay_attempts
from .shelf_category import system_key
from .tasks import settle_relay_vouchers_task, sync_relay_vouchers_task

LOGO = "sha256:" + "a" * 64
PRINT_LOGO = "sha256:" + "b" * 64
US_FLAG = "sha256:" + "c" * 64
US_FLAG_2 = "sha256:" + "d" * 64


# --- a fake relay -------------------------------------------------------------------------
def png(width=300, height=200, colour=(200, 30, 30)) -> bytes:
    buffer = io.BytesIO()
    Image.new("RGB", (width, height), colour).save(buffer, format="PNG")
    return buffer.getvalue()


def card(
    key,
    *,
    label,
    face,
    cost,
    price,
    country="",
    currency="USD",
    rank=0,
    available=True,
    promo=None,
    regular=None,
):
    return {
        "key": key,
        "country": country,
        "label": label,
        "face_value": face,
        "face_currency": currency,
        "unit_price": cost,
        "retail_price": price,
        "regular_unit_price": cost,
        "regular_retail_price": regular or price,
        "promo": promo,
        "available": available,
        "rank": rank,
    }


def itunes(**overrides):
    brand = {
        "key": "itunes",
        "name": "آيتونز",
        "aliases": ["iTunes", "Apple"],
        "category": "gift_cards",
        "rank": 0,
        "featured": True,
        "badge": "الأكثر مبيعاً",
        "redeem_hint": "App Store ← الحساب ← استرداد بطاقة هدية",
        "logo": LOGO,
        "print_logo": PRINT_LOGO,
        "items": [
            card(
                "itunes-us-10",
                country="US",
                label="10 دولار",
                face="10",
                cost="50.00",
                price="60.00",
                rank=0,
                promo={"badge": "عرض", "ends_at": "2026-10-20T00:00:00Z"},
            ),
            card(
                "itunes-us-25",
                country="US",
                label="25 دولار",
                face="25",
                cost="120.00",
                price="140.00",
                rank=1,
            ),
            card(
                "itunes-gb-10",
                country="GB",
                label="10 جنيه",
                face="10",
                currency="GBP",
                cost="60.00",
                price="70.00",
                rank=2,
                available=False,
            ),
        ],
    }
    brand.update(overrides)
    return brand


def libyana(**overrides):
    brand = {
        "key": "libyana",
        "name": "ليبيانا",
        "aliases": ["Libyana"],
        "category": "telecom",
        "rank": 1,
        "featured": False,
        "badge": "",
        "redeem_hint": "",
        "logo": "",
        "print_logo": "",
        "items": [
            card(
                "libyana-5",
                label="5 دينار",
                face="5",
                currency="LYD",
                cost="4.85",
                price="5.00",
                rank=0,
            ),
            card(
                "libyana-10",
                label="10 دينار",
                face="10",
                currency="LYD",
                cost="9.70",
                price="10.00",
                rank=1,
            ),
        ],
    }
    brand.update(overrides)
    return brand


def shelf(*, version="v1", brands=None, countries=None):
    return {
        "version": version,
        "currency": "LYD",
        "test_mode": False,
        "generated_at": "2026-10-07T12:00:00Z",
        "categories": [
            {"key": "telecom", "name": "الاتصالات", "rank": 0},
            {"key": "gift_cards", "name": "بطاقات الهدايا", "rank": 1},
        ],
        "countries": countries
        if countries is not None
        else [
            {"code": "US", "name": "الولايات المتحدة", "flag": US_FLAG},
            {"code": "GB", "name": "المملكة المتحدة", "flag": ""},
        ],
        "brands": brands if brands is not None else [itunes(), libyana()],
    }


def purchase(
    key="",
    *,
    status="succeeded",
    item="itunes-us-10",
    unit_price="50.00",
    codes=None,
    codes_pending=False,
    error_code="",
    test_mode=False,
):
    if codes is None:
        codes = [{"code": "ABCD-1234-EFGH", "serial": "SN-9"}] if status == "succeeded" else []
    return {
        "id": "pur-1",
        "idempotency_key": key,
        "item": item,
        "brand": "itunes",
        "name": "آيتونز · الولايات المتحدة · 10 دولار",
        "quantity": 1,
        "unit_price": unit_price,
        "amount": unit_price,
        "status": status,
        "held": False,
        "error_code": error_code,
        "error_detail": "",
        "codes": codes,
        "codes_pending": codes_pending,
        "test_mode": test_mode,
        "created_at": "2026-10-07T12:00:00Z",
        "completed_at": "2026-10-07T12:00:03Z",
    }


def refusal(status, code="", **extra):
    """The relay refusing in its own words, or (no code) something in front of it."""
    body = (
        json.dumps({"error": code or "refused", "code": code, **extra})
        if code
        else "<html>502</html>"
    )
    return RelayControlError(f"relay {status}", status_code=status, body=body, request_sent=True)


class FakeRelay:
    """Stands in for ``RelayControlClient``: the relay's voucher shop and wallet."""

    def __init__(self, document=None):
        self.document = document if document is not None else shelf()
        self.catalog_error = None
        self.etags_sent = []
        self.images = {
            LOGO[7:]: png(),
            PRINT_LOGO[7:]: png(colour=(0, 0, 0)),
            US_FLAG[7:]: png(colour=(0, 0, 200)),
            US_FLAG_2[7:]: png(colour=(0, 200, 0)),
        }
        self.image_reads = []
        self.purchase = (201, {"purchase": purchase(), "balance": "200.00", "replayed": False})
        self.purchases_sent = []
        self.outcomes = {}
        self.outcome_reads = []
        self.wallet = {
            "balance": "100.000",
            "vouchers": {"balance": "250.00", "configured": True, "test_mode": False},
        }
        self._lock = threading.Lock()

    def etag(self):
        return f'"{self.document.get("version")}"'

    def get_voucher_catalog(self, *, access_token, etag="", timeout=None):
        self.etags_sent.append(etag)
        if self.catalog_error is not None:
            raise self.catalog_error
        if etag and etag == self.etag():
            return None, etag
        return json.loads(json.dumps(self.document)), self.etag()

    def get_voucher_image(self, *, access_token, digest, timeout=None, max_bytes=None):
        with self._lock:
            self.image_reads.append(digest)
        if digest not in self.images:
            raise refusal(404, "not_found")
        return self.images[digest], "image/png"

    def create_voucher_purchase(self, **kwargs):
        self.purchases_sent.append(kwargs)
        if isinstance(self.purchase, Exception):
            raise self.purchase
        return self.purchase

    def get_voucher_purchase(self, *, access_token, idempotency_key, timeout=None):
        self.outcome_reads.append(idempotency_key)
        answer = self.outcomes.get(idempotency_key, refusal(404, "not_found"))
        if isinstance(answer, Exception):
            raise answer
        return answer

    def get_wallet(self, *, access_token, timeout=None):
        return self.wallet


class PointyMixin:
    """A shop linked to the relay, a «كروت دفتر» account, and the fake relay."""

    def link_relay(self, **fields):
        values = {
            "installation_id": "inst-1",
            "relay_public_api_url": "https://relay.example",
            "connector_token": "c",
            "access_token": "access-token",
        }
        values.update(fields)
        return RelayInstallation.objects.create(**values)

    def use_relay(self, fake=None):
        fake = fake or FakeRelay()
        patcher = mock.patch("apps.integrations.relay_link.scoped_relay_client", return_value=fake)
        patcher.start()
        self.addCleanup(patcher.stop)
        return fake

    def pointy_account(self, **fields):
        return IntegrationAccount.objects.create(provider="pointy", **fields)

    def sync(self, account, **kwargs):
        kwargs.setdefault("logo_limit", 0)
        account.refresh_from_db()
        return vouchers.sync_account(account, **kwargs)

    def voucher(self, code):
        return IntegrationVoucher.objects.select_related("variant", "brand").get(code=code)


def _writes(queries, *, ignore=("analytics_",)):
    """The statements in ``queries`` that wrote something, less telemetry."""
    found = []
    for query in queries:
        sql = query["sql"].lstrip().upper()
        if not sql.startswith(("INSERT", "UPDATE", "DELETE")):
            continue
        if any(table.upper() in sql for table in ignore):
            continue
        found.append(query["sql"])
    return found


# --- the provider, and the relay link that configures it ------------------------------------
class PointyProviderTests(PointyMixin, TestCase):
    def setUp(self):
        ensure_role_groups()
        manager = get_user_model().objects.create_user(username="mgr", password="x")
        manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client = APIClient()
        self.client.force_authenticate(manager)

    def test_configured_exactly_while_the_shop_is_linked(self):
        account = self.pointy_account()
        self.assertFalse(account.is_configured, "no relay link, nothing to buy through")
        self.link_relay()
        self.assertTrue(account.is_configured)
        RelayInstallation.objects.update(access_token="")
        self.assertFalse(account.is_configured)

    def test_switching_it_on_is_an_empty_put_and_reads_the_shelf(self):
        self.link_relay()
        with mock.patch("apps.integrations.views.schedule_voucher_sync") as schedule:
            response = self.client.put("/api/integrations/pointy/", {}, format="json")
        self.assertEqual(response.status_code, 200, response.data)
        account = IntegrationAccount.objects.get(provider="pointy")
        self.assertTrue(account.is_active)
        self.assertTrue(response.data["account"]["is_configured"])
        self.assertTrue(response.data["is_configurable"])
        schedule.assert_called_once_with(account)
        # The low-balance warning is its only setting, at 50 by default.
        settings = {item["key"]: item for item in response.data["settings"]}
        self.assertEqual(settings["low_balance_threshold"]["value"], "50")

    def test_a_shop_not_linked_to_the_relay_cannot_switch_it_on(self):
        response = self.client.put("/api/integrations/pointy/", {}, format="json")
        self.assertEqual(response.status_code, 409)
        self.assertEqual(response.data["error_code"], ERROR_NOT_CONFIGURED)
        self.assertFalse(IntegrationAccount.objects.filter(provider="pointy").exists())

    def test_its_float_is_never_topped_up_by_hand(self):
        self.link_relay()
        self.pointy_account()
        response = self.client.post(
            "/api/integrations/pointy/float/",
            {"amount": "100", "from_outside": True},
            format="json",
        )
        self.assertEqual(response.status_code, 409)
        self.assertEqual(response.data["error_code"], "filled_from_wallet")

    def test_probe_reads_the_voucher_balance(self):
        self.link_relay()
        fake = self.use_relay()
        account = self.pointy_account()
        self.assertEqual(PointyProvider(account).probe().balance, Decimal("250.00"))
        fake.wallet["vouchers"]["configured"] = False
        self.assertEqual(PointyProvider(account).probe().error_code, ERROR_UNAVAILABLE)
        del fake.wallet["vouchers"]
        self.assertEqual(PointyProvider(account).probe().error_code, ERROR_UNAVAILABLE)

    def test_workers_call_through_the_link_their_caller_read(self):
        # A worker must not query (see providers.base.in_parallel): the link
        # is read on the calling thread and pinned for it.
        installation = self.link_relay()
        caller = threading.get_ident()
        readers = []
        load = RelayInstallation.load.__func__

        def spy(cls):
            readers.append(threading.get_ident())
            return load(cls)

        with mock.patch.object(RelayInstallation, "load", classmethod(spy)):
            links = in_parallel([relay_link.current, relay_link.current])
        self.assertEqual({link.access_token for link in links}, {installation.access_token})
        self.assertEqual(set(readers), {caller})

    def test_the_shelf_category_is_known_by_its_system_key(self):
        self.link_relay()
        self.use_relay()
        account = self.pointy_account()
        self.sync(account)
        category = ProductCategory.objects.get(system_key=system_key("pointy"))
        self.assertEqual(category.name, "كروت دفتر")
        response = self.client.get("/api/product-categories/")
        self.assertEqual(response.status_code, 200)
        rows = response.data["results"] if isinstance(response.data, dict) else response.data
        row = next(row for row in rows if row["id"] == category.pk)
        self.assertEqual(row["system_key"], "vouchers:pointy")
        self.assertTrue(row["is_system"])
        # Read-only: nobody can declare one.
        self.client.patch(
            f"/api/product-categories/{category.pk}/", {"system_key": "x"}, format="json"
        )
        category.refresh_from_db()
        self.assertEqual(category.system_key, "vouchers:pointy")


# --- the relay client's new calls --------------------------------------------------------------
class _Response:
    def __init__(self, status=200, body=b"{}", headers=None):
        self.status = status
        self._body = body
        self.headers = headers or {}

    def read(self, limit=None):
        return self._body if limit is None else self._body[:limit]

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def relay_client():
    return RelayControlClient(
        config=RelayControlConfig(
            control_url="http://relay.test",
            public_api_url="http://relay.test",
            connector_address="relay.test:443",
            admin_token="",
            access_token="tok",
            installation_id="inst-1",
            connector_token="",
            enrollment_token="",
            timeout_seconds=5,
            ai_timeout_seconds=5,
            image_search_timeout_seconds=5,
            allow_insecure_control=True,
            ca_file="",
            client_cert_file="",
            client_key_file="",
        )
    )


class RelayVoucherClientTests(SimpleTestCase):
    def setUp(self):
        patcher = mock.patch("apps.core.relay.note_relay_transport_failure")
        patcher.start()
        self.addCleanup(patcher.stop)
        patcher = mock.patch("apps.core.relay.clear_relay_transport_cooldown")
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_the_catalog_is_conditional(self):
        sent = []

        def urlopen(request, timeout=None, context=None):
            sent.append(request)
            raise urllib_error.HTTPError(
                request.full_url, 304, "Not Modified", {"ETag": '"v1"'}, None
            )

        with mock.patch("apps.core.relay.request.urlopen", side_effect=urlopen):
            payload, etag = relay_client().get_voucher_catalog(access_token="tok", etag='"v1"')
        self.assertIsNone(payload)
        self.assertEqual(etag, '"v1"')
        self.assertEqual(sent[0].get_header("If-none-match"), '"v1"')
        self.assertEqual(sent[0].get_header("X-pointy-relay-token"), "tok")

    def test_a_purchase_is_posted_once_with_its_key_and_ceiling(self):
        sent = []

        def urlopen(request, timeout=None, context=None):
            sent.append(request)
            return _Response(201, json.dumps({"purchase": {"status": "succeeded"}}).encode())

        with mock.patch("apps.core.relay.request.urlopen", side_effect=urlopen):
            status, payload = relay_client().create_voucher_purchase(
                access_token="tok",
                item="itunes-us-10",
                idempotency_key="k-1",
                max_unit_price="50.00",
            )
        self.assertEqual(status, 201)
        self.assertEqual(len(sent), 1)
        self.assertEqual(
            json.loads(sent[0].data),
            {
                "item": "itunes-us-10",
                "quantity": 1,
                "idempotency_key": "k-1",
                "max_unit_price": "50.00",
            },
        )

    def test_never_sent_and_sent_without_an_answer_are_told_apart(self):
        cases = [
            (urllib_error.URLError(ConnectionRefusedError("refused")), False),
            (TimeoutError("read timed out"), True),
            (ConnectionResetError("reset by peer"), True),
        ]
        for failure, sent in cases:
            with self.subTest(failure=type(failure).__name__):
                with mock.patch("apps.core.relay.request.urlopen", side_effect=failure):
                    with self.assertRaises(RelayControlError) as caught:
                        relay_client().create_voucher_purchase(
                            access_token="tok", item="x", idempotency_key="k"
                        )
                self.assertIsNone(caught.exception.status_code)
                self.assertIs(caught.exception.request_sent, sent)

    def test_a_refusal_keeps_its_status_and_body(self):
        def urlopen(request, timeout=None, context=None):
            raise urllib_error.HTTPError(
                request.full_url, 409, "Conflict", {}, io.BytesIO(b'{"code": "in_flight"}')
            )

        with mock.patch("apps.core.relay.request.urlopen", side_effect=urlopen):
            with self.assertRaises(RelayControlError) as caught:
                relay_client().create_voucher_purchase(
                    access_token="tok", item="x", idempotency_key="k"
                )
        self.assertEqual(caught.exception.status_code, 409)
        self.assertEqual(json.loads(caught.exception.body)["code"], "in_flight")

    def test_moving_money_into_the_voucher_balance(self):
        sent = []

        def urlopen(request, timeout=None, context=None):
            sent.append(request)
            return _Response(201, b'{"balance": "50.000"}')

        with mock.patch("apps.core.relay.request.urlopen", side_effect=urlopen):
            relay_client().allocate_wallet_vouchers(
                access_token="tok",
                amount=Decimal("25.00"),
                idempotency_key="v-1",
                requested_by="owner",
            )
        self.assertTrue(sent[0].full_url.endswith("/v1/wallet/vouchers/allocations"))
        self.assertEqual(
            json.loads(sent[0].data),
            {"amount": "25.00", "idempotency_key": "v-1", "requested_by": "owner"},
        )


# --- buying one card ------------------------------------------------------------------------
class PointyPurchaseAnswerTests(PointyMixin, TestCase):
    """Every answer the relay can give a purchase, and what the till makes of it."""

    def setUp(self):
        self.link_relay()
        self.relay = self.use_relay()
        self.account = self.pointy_account()
        self.sync(self.account)

    def buy(self, answer=None, *, item="itunes-us-10", expected_cost=Decimal("50.00"), key="7-1"):
        if answer is not None:
            self.relay.purchase = answer
        return PointyProvider(self.account).recharge(
            "", item, expected_cost=expected_cost, attempt_key=key
        )

    def test_a_card_bought_comes_back_with_its_code_and_what_the_slip_prints(self):
        result = self.buy()
        self.assertTrue(result.ok)
        self.assertEqual(result.reference, "pur-1")
        self.assertEqual(result.balance_after, Decimal("200.00"))
        self.assertEqual(result.actual_cost, Decimal("50.00"))
        self.assertEqual(
            result.receipt["printed"],
            {
                "brand": "آيتونز",
                "product": "الولايات المتحدة · 10 دولار",
                "code": "ABCD-1234-EFGH",
                "serial": "SN-9",
                "instructions": "App Store ← الحساب ← استرداد بطاقة هدية",
            },
        )
        self.assertEqual(result.receipt["purchase_id"], "pur-1")
        sent = self.relay.purchases_sent[0]
        self.assertEqual(sent["item"], "itunes-us-10")
        self.assertEqual(sent["idempotency_key"], "7-1")
        self.assertEqual(sent["max_unit_price"], "50.00")
        self.assertEqual(sent["quantity"], 1)

    def test_a_replay_answers_with_the_first_purchase(self):
        result = self.buy((200, {"purchase": purchase(), "balance": "200.00", "replayed": True}))
        self.assertTrue(result.ok)

    def test_outcomes_nobody_can_vouch_for_are_indeterminate(self):
        unknown = {
            "pending (202)": (202, {"purchase": purchase(status="pending"), "balance": "150.00"}),
            "codes not read back": (
                201,
                {"purchase": purchase(codes=[], codes_pending=True), "balance": "150.00"},
            ),
            "in flight": refusal(409, "in_flight"),
            "a proxy's 502": refusal(502),
            "a proxy's 503": refusal(503),
            "a gateway timeout": refusal(504),
            "the relay's own 500": refusal(500, "internal_error"),
            "sent, no answer": RelayControlError("timed out", request_sent=True),
            "unreadable answer": (201, {"nothing": "useful"}),
        }
        for name, answer in unknown.items():
            with self.subTest(name):
                result = self.buy(answer)
                self.assertFalse(result.ok)
                self.assertTrue(result.indeterminate)
                self.assertEqual(result.error_code, ERROR_INDETERMINATE)

    def test_refusals_the_relay_states_are_definite(self):
        definite = {
            "insufficient balance": (
                refusal(402, "insufficient_balance", balance="10.00", amount="50.00"),
                ERROR_INSUFFICIENT_FLOAT,
            ),
            "unavailable item": (refusal(409, "item_unavailable"), ERROR_OUT_OF_STOCK),
            "unknown item": (refusal(404, "unknown_item"), ERROR_OUT_OF_STOCK),
            "supplier out of stock": (
                refusal(
                    502,
                    "supplier_out_of_stock",
                    purchase=purchase(status="failed", error_code="supplier_out_of_stock"),
                ),
                ERROR_OUT_OF_STOCK,
            ),
            "supplier refused": (refusal(502, "supplier_refused"), ERROR_PROVIDER_ERROR),
            "vouchers not set up": (refusal(503, "vouchers_unconfigured"), ERROR_UNAVAILABLE),
            "rate limited": (refusal(429, "rate_limited"), ERROR_BUSY),
            "malformed request": (refusal(422, "invalid_request"), ERROR_UNEXPECTED),
            "never reached the relay": (
                RelayControlError("refused", request_sent=False),
                ERROR_UNREACHABLE,
            ),
        }
        for name, (answer, code) in definite.items():
            with self.subTest(name):
                result = self.buy(answer)
                self.assertFalse(result.ok)
                self.assertFalse(result.indeterminate)
                self.assertEqual(result.error_code, code)

    def test_a_price_rise_is_refused_in_plain_technical_words(self):
        result = self.buy(refusal(409, "price_changed", unit_price="55.00"))
        self.assertTrue(result.is_definite_failure)
        # A code of its own, for the till to word in Arabic; the figure follows the
        # code word, where only a reader who may see cost is given it.
        self.assertEqual(result.error_code, ERROR_PRICE_CHANGED)
        self.assertEqual(result.error_code, "price_changed")
        self.assertTrue(result.error_detail.startswith("price_changed"))
        self.assertIn("55.00", result.error_detail)
        self.assertEqual(without_figures(result.error_detail), "price_changed")
        self.assertIsNone(re.search(r"[؀-ۿ]", result.error_detail))

    def test_an_empty_float_names_its_figures_after_its_code_word(self):
        result = self.buy(refusal(402, "insufficient_balance", balance="10.00", amount="50.00"))
        self.assertEqual(result.error_code, ERROR_INSUFFICIENT_FLOAT)
        self.assertIn("10.00", result.error_detail)
        self.assertIn("50.00", result.error_detail)
        self.assertEqual(without_figures(result.error_detail), "insufficient_balance")

    def test_a_card_whose_promotion_started_costs_what_was_charged(self):
        cheaper = (201, {"purchase": purchase(unit_price="48.00"), "balance": "202.00"})
        self.assertEqual(self.buy(cheaper).actual_cost, Decimal("48.00"))

    def test_a_card_from_the_test_supplier_says_so_on_its_slip(self):
        result = self.buy((201, {"purchase": purchase(test_mode=True), "balance": "200.00"}))
        self.assertTrue(result.ok)
        self.assertTrue(result.receipt["test_mode"])
        printed = result.receipt["printed"]
        self.assertEqual(printed["notice"], "عملية تجريبية: هذا الرمز غير حقيقي ولا يمكن استخدامه.")
        self.assertEqual(printed["code"], "ABCD-1234-EFGH", "the rest of the slip is as it was")
        # Read back later, it says the same; a real purchase never does.
        self.relay.outcomes["k"] = {"purchase": purchase("k", test_mode=True), "balance": "1.00"}
        read = PointyProvider(self.account).attempt_outcome("k")
        self.assertIn("عملية تجريبية", read.receipt["printed"]["notice"])
        real = self.buy((201, {"purchase": purchase(), "balance": "200.00"}))
        self.assertNotIn("notice", real.receipt["printed"])
        self.assertNotIn("test_mode", real.receipt)

    def test_nothing_is_sent_without_a_key_to_read_it_back_by(self):
        result = PointyProvider(self.account).recharge(
            "", "itunes-us-10", expected_cost=Decimal("50")
        )
        self.assertTrue(result.is_definite_failure)
        self.assertEqual(self.relay.purchases_sent, [])

    def test_nothing_is_sent_without_a_relay_link(self):
        RelayInstallation.objects.all().delete()
        result = self.buy()
        self.assertEqual(result.error_code, ERROR_NOT_CONFIGURED)
        self.assertEqual(self.relay.purchases_sent, [])

    def test_a_purchase_read_back_by_its_key(self):
        driver = PointyProvider(self.account)
        cases = {
            "bought": ({"purchase": purchase("k"), "balance": "200.00"}, ATTEMPT_CHARGED),
            "failed and refunded": (
                {
                    "purchase": purchase("k", status="failed", error_code="supplier_out_of_stock"),
                    "balance": "250.00",
                },
                ATTEMPT_REFUSED,
            ),
            "still pending": ({"purchase": purchase("k", status="pending")}, ATTEMPT_UNKNOWN),
            "code not read back yet": (
                {"purchase": purchase("k", codes=[], codes_pending=True)},
                ATTEMPT_UNKNOWN,
            ),
            "never heard of": (refusal(404, "not_found"), ATTEMPT_ABSENT),
            "a bare 404 is no proof": (
                RelayControlError("404", status_code=404, body="404 page not found"),
                ATTEMPT_UNKNOWN,
            ),
            # What a relay without the voucher routes answers: JSON, but not
            # the relay's own "no such purchase".
            "a routeless relay's 404 is no proof": (
                RelayControlError("404", status_code=404, body='{"error": "not found"}'),
                ATTEMPT_UNKNOWN,
            ),
            "unreachable": (RelayControlError("down", request_sent=False), ATTEMPT_UNKNOWN),
        }
        for name, (answer, state) in cases.items():
            with self.subTest(name):
                self.relay.outcomes["k"] = answer
                outcome = driver.attempt_outcome("k")
                self.assertEqual(outcome.state, state)
        self.relay.outcomes["k"] = {"purchase": purchase("k"), "balance": "200.00"}
        outcome = driver.attempt_outcome("k")
        self.assertEqual(outcome.receipt["printed"]["code"], "ABCD-1234-EFGH")
        self.assertEqual(outcome.actual_cost, Decimal("50.00"))
        self.assertEqual(outcome.at.isoformat(), "2026-10-07T12:00:03+00:00")
        refused = {"purchase": purchase("k", status="failed", error_code="supplier_out_of_stock")}
        self.relay.outcomes["k"] = refused
        self.assertEqual(driver.attempt_outcome("k").error_code, ERROR_OUT_OF_STOCK)

    def test_only_a_catalog_picture_is_ever_fetched(self):
        driver = PointyProvider(self.account)
        for path in (
            "http://169.254.169.254/latest",
            "/media/x.png",
            "sha256:XYZ",
            "sha256:" + "a" * 63,
        ):
            with self.subTest(path=path):
                self.assertFalse(driver.voucher_logo(path).ok)
        self.assertEqual(self.relay.image_reads, [])
        logo = driver.voucher_logo(LOGO)
        self.assertTrue(logo.ok)
        self.assertEqual(self.relay.image_reads, ["a" * 64])


# --- the shelf in the catalog ----------------------------------------------------------------
class PointyShelfTests(PointyMixin, TestCase):
    def setUp(self):
        self.link_relay()
        self.relay = self.use_relay()
        self.account = self.pointy_account()

    def test_the_shelf_becomes_system_products_in_our_order(self):
        report = self.sync(self.account)
        self.assertTrue(report.ok)
        self.assertEqual(report.brands_listed, 2)
        brand = IntegrationVoucherBrand.objects.select_related("product").get(code="itunes")
        self.assertEqual(
            (
                brand.rank,
                brand.featured,
                brand.badge,
                brand.category_key,
                brand.category_name,
                brand.category_rank,
                brand.aliases,
            ),
            (0, True, "الأكثر مبيعاً", "gift_cards", "بطاقات الهدايا", 1, ["iTunes", "Apple"]),
        )
        self.assertEqual(brand.redeem_hint, "App Store ← الحساب ← استرداد بطاقة هدية")
        product = brand.product
        self.assertEqual(product.name, "آيتونز")
        self.assertTrue(product.is_system)
        self.assertEqual(product.system_kind, Product.SystemKind.VOUCHER)
        self.assertTrue(ProductAlias.objects.filter(product=product, alias="iTunes").exists())
        self.assertTrue(ProductAlias.objects.filter(product=product, alias="Apple").exists())

        us10 = self.voucher("itunes-us-10")
        self.assertEqual(us10.variant.name, "الولايات المتحدة · 10 دولار")
        self.assertEqual(us10.variant.sku, "DFT-ITUNESUS10")
        self.assertEqual(self.voucher("itunes-us-25").variant.sku, "DFT-ITUNESUS25")
        self.assertEqual(us10.variant.unit_price, Decimal("60.00"))
        self.assertEqual(us10.cost, Decimal("50.00"))
        self.assertEqual(
            (us10.country, us10.face_currency, us10.rank, us10.badge), ("US", "USD", 0, "عرض")
        )
        self.assertEqual(us10.promo_ends_at.isoformat(), "2026-10-20T00:00:00+00:00")
        self.assertEqual(us10.regular_price, Decimal("60.00"))
        self.assertTrue(us10.variant.is_default, "the cheapest card on offer")
        # Listed but not sellable right now: on the product, switched off.
        gb = self.voucher("itunes-gb-10")
        self.assertEqual(gb.variant.name, "المملكة المتحدة · 10 جنيه")
        self.assertFalse(gb.variant.is_active)
        self.assertTrue(gb.is_listed)
        self.assertFalse(gb.is_available)
        # A card for no store region is named by its denomination alone.
        self.assertEqual(self.voucher("libyana-5").variant.name, "5 دينار")
        self.assertEqual(
            list(
                IntegrationVoucherCountry.objects.values_list("code", "name", "rank", "flag_path")
            ),
            [("US", "الولايات المتحدة", 0, US_FLAG), ("GB", "المملكة المتحدة", 1, "")],
        )
        self.account.refresh_from_db()
        self.assertEqual(self.account.config[vouchers.CONFIG_ETAG], '"v1"')

    def test_an_unchanged_shelf_answers_304_and_writes_nothing(self):
        self.sync(self.account)
        with CaptureQueriesContext(connection) as queries:
            report = self.sync(self.account)
        self.assertTrue(report.not_modified)
        self.assertEqual(self.relay.etags_sent, ["", '"v1"'])
        self.assertEqual(_writes(queries.captured_queries), [])

    def test_the_same_shelf_read_whole_again_moves_no_catalog_row(self):
        self.sync(self.account)
        stamps = dict(ProductVariant.objects.values_list("pk", "updated_at"))
        products = dict(Product.objects.values_list("pk", "updated_at"))
        # An edition the relay no longer recognises: the whole shelf again.
        self.relay.document["version"] = "v1-again"
        with CaptureQueriesContext(connection) as queries:
            report = self.sync(self.account)
        self.assertEqual(report.changed, 0)
        self.assertEqual(dict(ProductVariant.objects.values_list("pk", "updated_at")), stamps)
        self.assertEqual(dict(Product.objects.values_list("pk", "updated_at")), products)
        catalog_writes = [sql for sql in _writes(queries.captured_queries) if "catalog_" in sql]
        self.assertEqual(catalog_writes, [])

    def test_what_the_relay_stops_listing_is_withdrawn(self):
        self.sync(self.account)
        brand = itunes()
        brand["items"] = [item for item in brand["items"] if item["key"] != "itunes-us-25"]
        self.relay.document = shelf(version="v2", brands=[brand])
        self.sync(self.account)
        gone = self.voucher("itunes-us-25")
        self.assertFalse(gone.is_listed)
        self.assertFalse(gone.variant.is_active)
        libyana_brand = IntegrationVoucherBrand.objects.select_related("product").get(
            code="libyana"
        )
        self.assertFalse(libyana_brand.is_listed)
        self.assertFalse(libyana_brand.product.is_active)
        self.account.refresh_from_db()
        self.assertEqual(self.account.config[vouchers.CONFIG_ETAG], '"v2"')

    def test_a_promotion_moves_the_price_and_the_cost(self):
        self.sync(self.account)
        brand = itunes()
        brand["items"][1].update(
            unit_price="110.00",
            retail_price="130.00",
            promo={"badge": "خصم", "ends_at": None},
            regular_retail_price="140.00",
        )
        self.relay.document = shelf(version="v2", brands=[brand, libyana()])
        self.sync(self.account)
        us25 = self.voucher("itunes-us-25")
        self.assertEqual(
            (us25.cost, us25.variant.unit_price), (Decimal("110.00"), Decimal("130.00"))
        )
        self.assertEqual((us25.badge, us25.regular_price), ("خصم", Decimal("140.00")))
        self.assertTrue(us25.has_promo)

    def test_a_withdrawn_shelf_is_read_whole_when_it_comes_back(self):
        self.sync(self.account)
        vouchers.withdraw_shelf(self.account)
        self.account.refresh_from_db()
        self.assertNotIn(vouchers.CONFIG_ETAG, self.account.config)
        self.sync(self.account)
        self.assertEqual(self.relay.etags_sent[-1], "", "a whole read, never 'unchanged'")
        self.assertTrue(IntegrationVoucherBrand.objects.get(code="itunes").product.is_active)

    def test_an_emptied_mirror_never_asks_whether_it_changed(self):
        # A factory reset empties the mirror but keeps the account's config.
        self.sync(self.account)
        IntegrationVoucher.objects.all().delete()
        IntegrationVoucherBrand.objects.all().delete()
        self.sync(self.account)
        self.assertEqual(self.relay.etags_sent[-1], "")
        self.assertTrue(IntegrationVoucherBrand.objects.filter(code="itunes").exists())

    def test_a_relay_that_sells_nothing_says_so_and_recovers(self):
        self.sync(self.account)
        self.relay.catalog_error = refusal(503, "vouchers_unconfigured")
        report = self.sync(self.account)
        self.assertFalse(report.ok)
        self.account.refresh_from_db()
        self.assertEqual(self.account.config[vouchers.CONFIG_LISTING_ERROR], ERROR_UNAVAILABLE)
        self.relay.catalog_error = None
        self.assertTrue(self.sync(self.account).not_modified)
        self.account.refresh_from_db()
        self.assertNotIn(vouchers.CONFIG_LISTING_ERROR, self.account.config)

    def test_the_five_minute_sweep_reads_only_the_relays_shelf(self):
        with mock.patch("apps.integrations.vouchers.sync_account") as sync_account:
            sync_account.return_value = vouchers.SyncReport(provider="pointy")
            vouchers.sync_all(relay_hosted=True)
            self.assertEqual(
                [call.args[0].provider for call in sync_account.call_args_list], ["pointy"]
            )
            sync_account.reset_mock()
            vouchers.sync_all(relay_hosted=False)
            self.assertEqual(sync_account.call_args_list, [])


class PointyPictureTests(PointyMixin, TestCase):
    """Logos and flags: fetched by hash, once."""

    def setUp(self):
        storage = tempfile.TemporaryDirectory()
        self.addCleanup(storage.cleanup)
        settings = override_settings(
            POINTY_ATTACHMENT_STORAGE_ROOT=storage.name,
            POINTY_ATTACHMENT_ALLOWED_CONTENT_TYPES=[],
        )
        settings.enable()
        self.addCleanup(settings.disable)
        self.link_relay()
        self.relay = self.use_relay()
        self.account = self.pointy_account()

    def test_the_five_minute_task_reads_the_shelf_and_its_pictures(self):
        result = sync_relay_vouchers_task()
        self.assertEqual([report["provider"] for report in result["accounts"]], ["pointy"])
        self.assertEqual(result["accounts"][0]["flags"], 1)
        self.assertTrue(IntegrationVoucherBrand.objects.filter(code="itunes").exists())

    def test_logos_and_flags_arrive_with_the_shelf_and_are_not_fetched_again(self):
        report = self.sync(self.account, logo_limit=24)
        self.assertEqual(report.logos, 2, "the tile's and the receipt's")
        self.assertEqual(report.flags, 1)
        brand = IntegrationVoucherBrand.objects.select_related("product").get(code="itunes")
        self.assertEqual(
            len(active_attachments_for(brand.product, role=Attachment.Role.PRODUCT_IMAGE)), 1
        )
        self.assertTrue(brand.print_logo)
        us = IntegrationVoucherCountry.objects.get(code="US")
        flag = Image.open(io.BytesIO(bytes(us.flag)))
        self.assertEqual(flag.format, "PNG")
        self.assertLessEqual(max(flag.size), 96)
        self.assertEqual(us.flag_source, US_FLAG)
        reads = list(self.relay.image_reads)

        # Unchanged: nothing fetched, nothing written.
        self.assertTrue(self.sync(self.account, logo_limit=24).not_modified)
        self.relay.document["version"] = "v1-again"
        self.sync(self.account, logo_limit=24)
        self.assertEqual(self.relay.image_reads, reads)

        # A new flag is a new hash: fetched at once. No flag: none shown.
        self.relay.document = shelf(
            version="v2",
            countries=[
                {"code": "US", "name": "الولايات المتحدة", "flag": US_FLAG_2},
                {"code": "GB", "name": "المملكة المتحدة", "flag": ""},
            ],
        )
        self.assertEqual(self.sync(self.account, logo_limit=24).flags, 1)
        self.assertEqual(IntegrationVoucherCountry.objects.get(code="US").flag_source, US_FLAG_2)
        self.relay.document = shelf(
            version="v3",
            countries=[
                {"code": "US", "name": "الولايات المتحدة", "flag": ""},
                {"code": "GB", "name": "المملكة المتحدة", "flag": ""},
            ],
        )
        self.sync(self.account, logo_limit=24)
        self.assertIsNone(IntegrationVoucherCountry.objects.get(code="US").flag)


# --- the till's menu --------------------------------------------------------------------------
class PointyMenuTests(PointyMixin, TestCase):
    def setUp(self):
        ensure_role_groups()
        User = get_user_model()
        self.manager = User.objects.create_user(username="mgr", password="x")
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.cashier = User.objects.create_user(username="csh", password="x")
        self.cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.client = APIClient()
        self.link_relay()
        self.relay = self.use_relay()
        self.account = self.pointy_account(balance=Decimal("55.00"), balance_at=timezone.now())
        self.sync(self.account)

    def menu(self, user=None):
        self.client.force_authenticate(user or self.cashier)
        response = self.client.get("/api/integrations/vouchers/menu/")
        self.assertEqual(response.status_code, 200, getattr(response, "data", None))
        return response.data

    def test_the_menu_in_the_companys_order(self):
        data = self.menu(self.manager)
        self.assertEqual(
            (data["available"], data["provider"], data["error_code"], data["balance"]),
            (True, "pointy", "", "55.00"),
        )
        self.assertEqual(
            data["categories"],
            [
                {"key": "telecom", "name": "الاتصالات"},
                {"key": "gift_cards", "name": "بطاقات الهدايا"},
            ],
        )
        self.assertEqual(
            data["countries"],
            [
                {"code": "US", "name": "الولايات المتحدة", "flag": None},
                {"code": "GB", "name": "المملكة المتحدة", "flag": None},
            ],
        )
        self.assertEqual([brand["key"] for brand in data["brands"]], ["itunes", "libyana"])
        brand = data["brands"][0]
        self.assertEqual(
            {
                key: brand[key]
                for key in ("name", "category", "featured", "badge", "has_promo", "redeem_hint")
            },
            {
                "name": "آيتونز",
                "category": "gift_cards",
                "featured": True,
                "badge": "الأكثر مبيعاً",
                "has_promo": True,
                "redeem_hint": "App Store ← الحساب ← استرداد بطاقة هدية",
            },
        )
        self.assertEqual(brand["aliases"], ["iTunes", "Apple"])
        self.assertEqual(data["brands"][1]["aliases"], ["Libyana"])
        self.assertEqual(
            [item["key"] for item in brand["items"]],
            ["itunes-us-10", "itunes-us-25", "itunes-gb-10"],
        )
        us10 = self.voucher("itunes-us-10")
        self.assertEqual(
            brand["items"][0],
            {
                "variant_id": us10.variant_id,
                "key": "itunes-us-10",
                "label": "10 دولار",
                "name": "الولايات المتحدة · 10 دولار",
                "country": "US",
                "face_value": "10",
                "face_currency": "USD",
                "price": "60.00",
                "regular_price": "60.00",
                "badge": "عرض",
                "promo_ends_at": "2026-10-20T00:00:00+00:00",
                "available": True,
                "exceeds_float": False,
                "cost": "50.00",
            },
        )
        self.assertTrue(brand["items"][1]["exceeds_float"], "120.00 is more than the 55.00 left")
        self.assertFalse(brand["items"][2]["available"])
        self.assertFalse(data["brands"][1]["has_promo"])
        self.assertEqual(data["brands"][1]["items"][0]["name"], "5 دينار")

    def test_each_brand_carries_its_product_as_the_catalog_list_sends_it(self):
        self.client.force_authenticate(self.manager)
        # As both go over the wire: the rendered JSON.
        data = json.loads(self.client.get("/api/integrations/vouchers/menu/").content)
        product = data["brands"][0]["product"]
        listed = json.loads(self.client.get("/api/products/?system=sellable").content)
        rows = listed["results"] if isinstance(listed, dict) else listed
        row = next(row for row in rows if row["id"] == product["id"])
        self.assertEqual(product, row)
        variant_ids = {variant["id"] for variant in product["variants"]}
        self.assertIn(self.voucher("itunes-us-10").variant_id, variant_ids)
        self.assertIn("primary_image", product)

    def test_the_cards_cost_is_the_reporting_roles_figure(self):
        cashier_items = [item for brand in self.menu()["brands"] for item in brand["items"]]
        self.assertTrue(cashier_items)
        self.assertTrue(all("cost" not in item for item in cashier_items))
        self.assertTrue(all("exceeds_float" in item for item in cashier_items))
        manager_items = [
            item for brand in self.menu(self.manager)["brands"] for item in brand["items"]
        ]
        self.assertTrue(all("cost" in item for item in manager_items))

    def test_a_shop_that_cannot_sell_is_told_why(self):
        self.account.config = {
            **self.account.config,
            vouchers.CONFIG_LISTING_ERROR: ERROR_UNAVAILABLE,
        }
        self.account.save(update_fields=["config"])
        data = self.menu()
        self.assertEqual(
            (data["available"], data["error_code"], data["brands"]), (False, "unavailable", [])
        )

        IntegrationAccount.objects.filter(pk=self.account.pk).update(config={}, is_active=False)
        self.assertEqual(self.menu()["error_code"], "not_configured")

        IntegrationAccount.objects.filter(pk=self.account.pk).update(is_active=True)
        RelayInstallation.objects.update(integrations_disabled=["pointy"])
        self.assertEqual(self.menu()["error_code"], "switched_off")

        RelayInstallation.objects.all().delete()
        self.assertEqual(self.menu()["error_code"], "not_configured")

    def test_the_menu_costs_the_same_queries_however_big_the_shelf(self):
        self.menu()  # warm whatever is cached per process
        with CaptureQueriesContext(connection) as small:
            self.menu()
        more = [
            libyana(
                key=f"brand-{n}",
                name=f"بطاقة {n}",
                rank=10 + n,
                items=[
                    card(
                        f"brand-{n}-{m}",
                        label=f"{m} دينار",
                        face=str(m),
                        currency="LYD",
                        cost=f"{m}.00",
                        price=f"{m + 1}.00",
                        rank=m,
                    )
                    for m in range(1, 4)
                ],
            )
            for n in range(4)
        ]
        self.relay.document = shelf(version="v2", brands=[itunes(), libyana(), *more])
        self.sync(self.account)
        with CaptureQueriesContext(connection) as large:
            data = self.menu()
        self.assertEqual(len(data["brands"]), 6)
        self.assertEqual(len(large.captured_queries), len(small.captured_queries))

    def test_cashiers_without_the_till_permission_are_refused(self):
        stranger = get_user_model().objects.create_user(username="nobody", password="x")
        self.client.force_authenticate(stranger)
        self.assertEqual(self.client.get("/api/integrations/vouchers/menu/").status_code, 403)


# --- selling it -------------------------------------------------------------------------------
class PointySaleTests(PointyMixin, TestCase):
    def setUp(self):
        ensure_role_groups()
        self.link_relay()
        self.relay = self.use_relay()
        self.account = self.pointy_account()
        self.sync(self.account)
        self.manager = get_user_model().objects.create_user(username="mgr", password="x")
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.register = RegisterSession.objects.create(
            owner=self.manager, owner_key=f"user:{self.manager.pk}"
        )
        self.client = APIClient()
        self.client.force_authenticate(self.manager)

    def checkout(self, code="itunes-us-10", **extra):
        body = {
            "register_session": self.register.pk,
            "lines": [{"variant": self.voucher(code).variant_id, "quantity": "1"}],
            "payment_method": "cash",
            **extra,
        }
        return self.client.post("/api/orders/checkout/", body, format="json")

    def test_a_card_is_a_line_with_its_region_in_the_fulfillment(self):
        response = self.checkout()
        self.assertEqual(response.status_code, 201, response.data)
        line = Order.objects.get(pk=response.data["id"]).lines.get()
        self.assertEqual((line.unit_price, line.unit_cost), (Decimal("60.00"), Decimal("50.00")))
        fulfillment = line.integration_fulfillment
        self.assertEqual(fulfillment.provider, "pointy")
        self.assertEqual(fulfillment.option_code, "itunes-us-10")
        self.assertEqual(fulfillment.package_id, "itunes")
        self.assertEqual(fulfillment.option_label, "آيتونز الولايات المتحدة · 10 دولار")
        self.assertEqual(fulfillment.status, IntegrationFulfillment.Status.PENDING)

    def test_a_card_the_relay_cannot_sell_right_now_is_not_sold(self):
        response = self.checkout("itunes-gb-10")
        self.assertEqual(response.status_code, 400)
        self.assertFalse(Order.objects.exists())

    def test_a_credit_sale_carries_a_card_like_any_other(self):
        # The owner's decision: the shop owes the company either way, so an
        # آجل invoice is charged right after checkout, as Qareeb's are.
        customer = Customer.objects.create(full_name="زبون")
        response = self.client.post(
            "/api/orders/checkout/",
            {
                "lines": [{"variant": self.voucher("itunes-us-10").variant_id, "quantity": "1"}],
                "customer": customer.pk,
                "sale_type": "credit",
                "register_session": self.register.pk,
            },
            format="json",
        )
        self.assertEqual(response.status_code, 201, response.data)
        order = Order.objects.get(pk=response.data["id"])
        self.assertEqual(order.sale_type, Order.SaleType.CREDIT)
        self.assertEqual(order.lines.get().integration_fulfillment.provider, "pointy")


class PointySettleTests(PointyMixin, TestCase):
    """A purchase whose answer was lost, settled by reading it back by key."""

    def setUp(self):
        ensure_role_groups()
        self.link_relay()
        self.relay = self.use_relay()
        self.account = self.pointy_account()
        self.sync(self.account)
        user = get_user_model().objects.create_user(username="mgr", password="x")
        user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        register = RegisterSession.objects.create(owner=user, owner_key=f"user:{user.pk}")
        client = APIClient()
        client.force_authenticate(user)
        response = client.post(
            "/api/orders/checkout/",
            {
                "register_session": register.pk,
                "payment_method": "cash",
                "lines": [{"variant": self.voucher("itunes-us-10").variant_id, "quantity": "1"}],
            },
            format="json",
        )
        self.row = Order.objects.get(pk=response.data["id"]).lines.get().integration_fulfillment
        self.sent(minutes=5)

    def sent(self, **ago):
        IntegrationFulfillment.objects.filter(pk=self.row.pk).update(
            status=IntegrationFulfillment.Status.SUBMITTED,
            attempt_count=1,
            submitted_at=timezone.now() - timedelta(**ago),
            last_error_code=ERROR_INDETERMINATE,
        )
        self.row.refresh_from_db()
        return recharge.attempt_key(self.row)

    def test_a_card_bought_after_all_is_confirmed_with_its_code(self):
        key = recharge.attempt_key(self.row)
        self.relay.outcomes[key] = {
            "purchase": purchase(key, unit_price="48.00"),
            "balance": "202.00",
        }
        result = settle_relay_attempts()
        self.assertEqual(result["accounts"][0]["confirmed"], 1)
        self.row.refresh_from_db()
        self.assertEqual(self.row.status, IntegrationFulfillment.Status.CONFIRMED)
        self.assertEqual(self.row.provider_reference, "pur-1")
        self.assertEqual(self.row.provider_receipt["printed"]["code"], "ABCD-1234-EFGH")
        self.assertEqual(self.row.confirmed_at.isoformat(), "2026-10-07T12:00:03+00:00")
        self.assertEqual(self.row.cost, Decimal("48.00"))
        self.assertEqual(self.row.order_line.unit_cost, Decimal("48.00"))
        self.account.refresh_from_db()
        self.assertEqual(self.account.balance, Decimal("202.00"))
        payload = build_receipt_payload(self.row.order_line.order)
        self.assertEqual(
            payload["order"]["lines"][0]["integration"]["printed"]["code"], "ABCD-1234-EFGH"
        )

    def test_a_purchase_the_relay_never_recorded_is_retryable_once_old_enough(self):
        self.sent(seconds=30)
        settle_relay_attempts()
        self.row.refresh_from_db()
        self.assertEqual(
            self.row.status, IntegrationFulfillment.Status.SUBMITTED, "maybe still in flight"
        )
        self.sent(seconds=ATTEMPT_SETTLE_AFTER.total_seconds() + 1)
        settle_relay_attempts()
        self.row.refresh_from_db()
        self.assertEqual(self.row.status, IntegrationFulfillment.Status.PENDING)
        # The next attempt is a new key: it can never be answered with this one.
        self.row.attempt_count += 1
        self.assertNotEqual(recharge.attempt_key(self.row), self.relay.outcome_reads[-1])

    def test_a_refunded_purchase_goes_back_with_its_reason(self):
        key = recharge.attempt_key(self.row)
        self.relay.outcomes[key] = {
            "purchase": purchase(key, status="failed", error_code="supplier_out_of_stock"),
            "balance": "250.00",
        }
        settle_relay_attempts()
        self.row.refresh_from_db()
        self.assertEqual(self.row.status, IntegrationFulfillment.Status.PENDING)
        self.assertEqual(self.row.last_error_code, ERROR_OUT_OF_STOCK)

    def test_the_two_minute_task_settles_them(self):
        key = recharge.attempt_key(self.row)
        self.relay.outcomes[key] = {"purchase": purchase(key), "balance": "200.00"}
        result = settle_relay_vouchers_task()
        self.assertEqual(result["accounts"][0]["confirmed"], 1)

    def test_a_purchase_still_pending_is_left_alone(self):
        key = recharge.attempt_key(self.row)
        self.relay.outcomes[key] = {"purchase": purchase(key, status="pending")}
        result = settle_relay_attempts()
        self.assertEqual(len(result["accounts"][0]["unknown"]), 1)
        self.row.refresh_from_db()
        self.assertEqual(self.row.status, IntegrationFulfillment.Status.SUBMITTED)

    def test_nothing_unsettled_costs_one_query(self):
        IntegrationFulfillment.objects.filter(pk=self.row.pk).update(
            status=IntegrationFulfillment.Status.CONFIRMED
        )
        with CaptureQueriesContext(connection) as queries:
            self.assertEqual(settle_relay_attempts(), {"accounts": []})
        self.assertEqual(len(queries.captured_queries), 1)
        self.assertEqual(self.relay.outcome_reads, [])

    def test_the_nightly_reconciliation_reads_it_back_too_never_a_log(self):
        key = recharge.attempt_key(self.row)
        self.relay.outcomes[key] = {"purchase": purchase(key), "balance": "200.00"}
        with mock.patch.object(PointyProvider, "purchase_history") as history:
            report = reconcile_account(self.account)
        history.assert_not_called()
        self.assertEqual(report["resolved"]["confirmed"], 1)
        self.row.refresh_from_db()
        self.assertEqual(self.row.status, IntegrationFulfillment.Status.CONFIRMED)


class PointyChargeTests(PointyMixin, TransactionTestCase):
    """The till's charge, end to end: checkout, purchase, receipt."""

    reset_sequences = True

    def setUp(self):
        ensure_role_groups()
        self.link_relay()
        self.relay = self.use_relay()
        self.account = self.pointy_account()
        self.sync(self.account)
        user = get_user_model().objects.create_user(username="till", password="x")
        user.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.register = RegisterSession.objects.create(owner=user, owner_key=f"user:{user.pk}")
        self.client = APIClient()
        self.client.force_authenticate(user)

    def sell(self, code):
        response = self.client.post(
            "/api/orders/checkout/",
            {
                "register_session": self.register.pk,
                "payment_method": "cash",
                "lines": [{"variant": self.voucher(code).variant_id, "quantity": "1"}],
            },
            format="json",
        )
        self.assertEqual(response.status_code, 201, response.data)
        return Order.objects.get(pk=response.data["id"])

    def charge(self, order):
        return self.client.post(
            "/api/integrations/fulfillments/charge/", {"order": order.pk}, format="json"
        ).data

    def test_the_sale_buys_the_card_at_what_the_relay_charged(self):
        order = self.sell("itunes-us-10")
        row = order.lines.get().integration_fulfillment
        self.relay.purchase = (201, {"purchase": purchase(unit_price="48.00"), "balance": "202.00"})
        result = self.charge(order)["results"][0]
        self.assertEqual(result["outcome"], recharge.OUTCOME_CHARGED)
        self.assertEqual(result["kind"], "voucher")
        self.assertEqual(result["receipt"]["code"], "ABCD-1234-EFGH")
        row.refresh_from_db()
        self.assertEqual(self.relay.purchases_sent[0]["idempotency_key"], recharge.attempt_key(row))
        self.assertEqual(self.relay.purchases_sent[0]["max_unit_price"], "50.00")
        self.assertEqual(row.cost, Decimal("48.00"))
        self.assertEqual(row.order_line.unit_cost, Decimal("48.00"))
        self.account.refresh_from_db()
        self.assertEqual(self.account.balance, Decimal("202.00"))

    def test_libyana_prints_what_its_customer_dials(self):
        order = self.sell("libyana-5")
        self.relay.purchase = (
            201,
            {
                "purchase": purchase(
                    item="libyana-5",
                    unit_price="4.85",
                    codes=[{"code": "1111222233334", "serial": "77"}],
                ),
                "balance": "245.15",
            },
        )
        result = self.charge(order)["results"][0]
        self.assertEqual(result["receipt"]["dial"], "1201111222233334")

    def test_a_lost_answer_is_settled_with_the_code_on_the_receipt(self):
        order = self.sell("itunes-us-10")
        self.relay.purchase = RelayControlError("timed out", request_sent=True)
        result = self.charge(order)["results"][0]
        self.assertEqual(result["outcome"], recharge.OUTCOME_UNKNOWN)
        row = IntegrationFulfillment.objects.get()
        self.assertEqual(row.status, IntegrationFulfillment.Status.SUBMITTED)
        key = self.relay.purchases_sent[0]["idempotency_key"]
        self.assertEqual(key, recharge.attempt_key(row))
        self.relay.outcomes[key] = {"purchase": purchase(key), "balance": "200.00"}
        settle_relay_attempts()
        row.refresh_from_db()
        self.assertEqual(row.status, IntegrationFulfillment.Status.CONFIRMED)
        printed = build_receipt_payload(order)["order"]["lines"][0]["integration"]["printed"]
        self.assertEqual(printed["code"], "ABCD-1234-EFGH")
        self.assertEqual(printed["brand"], "آيتونز")

    def test_a_refusal_leaves_the_line_to_try_again_under_a_new_key(self):
        order = self.sell("itunes-us-10")
        self.relay.purchase = refusal(402, "insufficient_balance", balance="10.00", amount="50.00")
        result = self.charge(order)["results"][0]
        self.assertEqual(result["outcome"], recharge.OUTCOME_REFUSED)
        self.assertEqual(result["error_code"], ERROR_INSUFFICIENT_FLOAT)
        self.relay.purchase = (201, {"purchase": purchase(), "balance": "200.00"})
        self.assertEqual(self.charge(order)["results"][0]["outcome"], recharge.OUTCOME_CHARGED)
        first, second = (sent["idempotency_key"] for sent in self.relay.purchases_sent)
        self.assertNotEqual(first, second)
        self.assertTrue(first.endswith("-1") and second.endswith("-2"))


class AttemptKeyTests(SimpleTestCase):
    def test_a_key_names_the_row_its_birth_and_the_attempt(self):
        row = IntegrationFulfillment(
            pk=42,
            attempt_count=3,
            created_at=datetime(2026, 10, 7, 12, 30, 1, 123456, tzinfo=dt_timezone.utc),
        )
        self.assertEqual(recharge.attempt_key(row), "42-20261007123001123456-3")
        self.assertLessEqual(len(recharge.attempt_key(row)), 100)
