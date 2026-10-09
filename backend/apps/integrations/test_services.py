"""«الشحن المباشر» and «دفع الفواتير»: the directory the shop mirrors from the relay.

The relay's answers here follow its contract (``DIRECT_TOPUP_PLAN.md``, §2.3)
with made-up values; the relay itself is faked at the client
(:class:`FakeServicesRelay`), so the relay client, the driver, the mirror and the
sweep run for real against it. The tills' endpoints, the quote and the sale are in
``test_services_api`` and ``test_services_sale``.
"""

from __future__ import annotations

import io
import json
import re
from datetime import timedelta
from decimal import Decimal
from unittest import mock
from urllib import error as urllib_error

from django.db import connection
from django.test import SimpleTestCase, TestCase
from django.test.utils import CaptureQueriesContext
from django.utils import timezone
from PIL import Image

from apps.core.relay import RelayControlError

from . import services_mirror, services_options, services_sync, tasks
from .models import IntegrationAccount, IntegrationServiceCountry
from .providers.base import (
    ERROR_UNAVAILABLE,
    ERROR_UNEXPECTED,
    ERROR_UNREACHABLE,
    without_figures,
)
from .masking import mask_number, mask_numbers
from .providers.pointy import PointyProvider
from .test_pointy import (
    FakeRelay,
    PointyMixin,
    _Response,
    _writes,
    png,
    purchase,
    refusal,
    relay_client,
)

ML_FLAG = "sha256:" + "e" * 64
NE_FLAG = "sha256:" + "d" * 64
NG_FLAG = "sha256:" + "c" * 64
ML_FLAG_2 = "sha256:" + "b" * 64


# --- the relay's directory, with made-up values --------------------------------------------
def logo_ref(operator_id) -> str:
    """The relay's own copy of an operator's logo, named by its hash."""
    return "sha256:" + format(operator_id, "x").rjust(64, "0")


def amount(value, cost, retail, *, currency="XOF"):
    return {
        "amount": value,
        "receive": value,
        "receive_currency": currency,
        "unit_price": cost,
        "retail_price": retail,
    }


def operator(operator_id=289, *, name="أورنج مالي", name_en="Orange Mali", **overrides):
    row = {
        "id": operator_id,
        "name": name,
        "name_en": name_en,
        "logo": logo_ref(operator_id),
        "mode": "range",
        "amount_currency": "XOF",
        "receive_currency": "XOF",
        "approximate": False,
        "min": "1967",
        "max": "32800",
        "amounts": [amount("2500", "46.00", "48.50"), amount("5000", "91.30", "96.50")],
        "popular_amount": "5000",
    }
    row.update(overrides)
    return row


def biller(
    biller_id=5,
    *,
    name="كهرباء إيكيجا (مسبقة الدفع)",
    name_en="Ikeja Electricity Prepaid",
    kind="electricity",
    service="prepaid",
    mode="range",
    currency="NGN",
    requires_invoice=False,
    **overrides,
):
    row = {
        "id": biller_id,
        "name": name,
        "name_en": name_en,
        "type": kind,
        "service": service,
        "mode": mode,
        "requires_invoice": requires_invoice,
        "amount_currency": currency,
    }
    if mode == "range":
        row.update(
            min="1000",
            max="300000",
            suggested=[
                {"amount": "2000", "unit_price": "10.50", "retail_price": "11.25"},
                {"amount": "5000", "unit_price": "26.00", "retail_price": "27.50"},
            ],
        )
    else:
        row["plans"] = [
            {
                "id": 2,
                "amount": "10000",
                "description": "كانال بلس أكسيس إنجليش بيسك – شهر",
                "description_en": "Canalplus Acces English Basic (10000/1MOIS)",
                "unit_price": "184.00",
                "retail_price": "195.00",
            }
        ]
    row.update(overrides)
    return row


def country(code, name, dial, currency, currency_name, *, flag="", popular=0, **sections):
    row = {
        "code": code,
        "name": name,
        "dial": dial,
        "currency": currency,
        "currency_name": currency_name,
        "flag": flag,
        "popular": popular,
    }
    operators = sections.get("operators")
    billers = sections.get("billers")
    if operators:
        row["airtime"] = {"operators": operators}
    if billers:
        row["bills"] = {"billers": billers}
    return row


def niger():
    return country(
        "NE",
        "النيجر",
        ["227"],
        "XOF",
        "فرنك أفريقي",
        flag=NE_FLAG,
        popular=1,
        operators=[operator(301, name="إيرتل النيجر", name_en="Airtel Niger")],
    )


def mali():
    return country(
        "ML",
        "مالي",
        ["223"],
        "XOF",
        "فرنك أفريقي",
        flag=ML_FLAG,
        popular=2,
        operators=[
            operator(289),
            operator(
                290,
                name="ماليتل",
                name_en="Malitel",
                mode="fixed",
                min=None,
                max=None,
                amounts=[amount("1000", "19.00", "20.50"), amount("2000", "37.00", "39.50")],
            ),
        ],
        billers=[
            biller(
                30,
                name="كانال بلس مالي",
                name_en="Canal+ Mali",
                kind="tv",
                service="prepaid",
                mode="fixed",
                currency="XOF",
            )
        ],
    )


def nigeria():
    return country(
        "NG",
        "نيجيريا",
        ["234"],
        "NGN",
        "نيرة نيجيرية",
        flag=NG_FLAG,
        popular=3,
        operators=[
            operator(
                5,
                name="إم تي إن نيجيريا",
                name_en="MTN Nigeria",
                amount_currency="NGN",
                receive_currency="NGN",
                min="50",
                max="50000",
                amounts=[amount("500", "3.10", "3.50", currency="NGN")],
                popular_amount="500",
            )
        ],
        billers=[
            biller(5),
            # Not offered: tolls and the catch-all are in the directory, not on the till.
            biller(98, name="رسوم الطريق", name_en="Lekki Toll", kind="toll"),
            biller(99, name="أخرى", name_en="Other", kind="other"),
        ],
    )


def senegal():
    return country(
        "SN",
        "السنغال",
        ["221"],
        "XOF",
        "فرنك أفريقي",
        billers=[
            biller(
                24,
                name="سن إيو (مياه)",
                name_en="Sen-Eau",
                kind="water",
                service="postpaid",
                currency="XOF",
                requires_invoice=True,
                min="500",
                max="500000",
                suggested=[],
            ),
            biller(
                25,
                name="سن إلك (فاتورة لاحقة الدفع)",
                name_en="Sen-Elec Postpaid",
                kind="electricity",
                service="postpaid",
                currency="XOF",
                requires_invoice=True,
            ),
        ],
    )


UNSUPPORTED = [
    {"code": "SD", "name": "السودان"},
    {"code": "TD", "name": "تشاد", "name_en": "Chad"},
]


def services_directory(*, version="d1", countries=None, unsupported=None, **state):
    document = {
        "version": version,
        "generated_at": "2026-10-08T12:00:00Z",
        "currency": "LYD",
        "test_mode": False,
        "configured": True,
        "priced": True,
        "popular": ["NE", "ML", "NG"],
        "countries": countries
        if countries is not None
        else [niger(), mali(), nigeria(), senegal()],
        "unsupported": unsupported if unsupported is not None else list(UNSUPPORTED),
    }
    document.update(state)
    return document


# --- the relay's service purchases ----------------------------------------------------------
AIRTIME_RECEIPT = {
    "transaction_id": "4602843",
    "operator": "Orange Mali",
    "phone": "+22370123456",
    "delivered_amount": "5000",
    "delivered_currency": "XOF",
    "operator_reference": "7297929551:OrderConfirmed",
}
BILL_RECEIPT = {
    "transaction_id": "36",
    "biller": "Ikeja Electricity Prepaid",
    "account": "04223568280",
    "amount": "5000",
    "currency": "NGN",
    "token": "2737-6032-5315-7183-0856",
    "units": "10.7 kWh",
    "biller_reference": "T_QKTBYLMGPA",
}


#: "The receipt a purchase of this kind has" — as against ``None``, which leaves it out.
STANDARD = object()


def service_purchase(
    key="",
    *,
    kind="airtime",
    status="succeeded",
    item=None,
    unit_price="91.30",
    receipt=STANDARD,
    receipt_pending=False,
    error_code="",
    held=False,
    test_mode=False,
):
    if item is None:
        item = "airtime:289:5000:XOF" if kind == "airtime" else "bill:5:5000:NGN"
    if receipt is STANDARD:
        receipt = None
        if status == "succeeded":
            receipt = dict(AIRTIME_RECEIPT if kind == "airtime" else BILL_RECEIPT)
    purchase = {
        "id": "svc-1",
        "idempotency_key": key,
        "kind": kind,
        "item": item,
        "brand": kind,
        "name": "شحن مباشر",
        "quantity": 1,
        "unit_price": unit_price,
        "amount": unit_price,
        "status": status,
        "held": held,
        "error_code": error_code,
        "error_detail": "",
        "codes": [],
        "codes_pending": False,
        "target": "+223•••••456",
        "receipt_pending": receipt_pending,
        "test_mode": test_mode,
        "created_at": "2026-10-08T12:00:00Z",
        "completed_at": "2026-10-08T12:00:03Z",
    }
    if receipt is not None:
        purchase["receipt"] = receipt
    return purchase


def relay_quote(*, kind="airtime", cost="91.30", retail="96.50", amount="5000", currency="XOF"):
    quote = {
        "kind": kind,
        "name": "شحن مباشر",
        "unit_price": cost,
        "receive": {"amount": amount, "currency": currency},
        "approximate": False,
    }
    if retail is not None:
        quote["retail_price"] = retail
    return {"quote": quote}


def detection(operator_row=None, *, national="70123456"):
    return {
        "operator": operator_row if operator_row is not None else operator(289),
        "phone": {"e164": "+223" + national, "national": national, "country": "ML"},
    }


#: The calling code of the countries these tests dial, and whether their numbers
#: keep a leading zero (Côte d'Ivoire's and Benin's do). The relay knows all this
#: (its ParsePhone); the shop does not, and asks.
_DIALLING = {
    "ML": ("223", False),
    "NE": ("227", False),
    "NG": ("234", False),
    "SN": ("221", False),
    "EG": ("20", False),
    "CI": ("225", True),
    "BJ": ("229", True),
    "LR": ("231", False),
}


def relay_phone(country, typed):
    """The ``phone`` of a quote answer: the number as the relay reads it, or ``None``
    when it is not one of that country (a double of the relay's own ParsePhone,
    for the typed forms these tests use)."""
    dial, keeps_zero = _DIALLING.get(str(country).upper(), ("", False))
    text = services_options.ascii_digits(typed).strip()
    digits = re.sub(r"\D", "", text)
    if text.startswith("+"):
        pass
    elif digits.startswith("00"):
        digits = digits[2:]
    else:
        digits = dial + (digits if keeps_zero else digits[1:] if digits.startswith("0") else digits)
    national = digits[len(dial) :]
    if not dial or not digits.startswith(dial) or not 6 <= len(national) <= 12:
        return None
    return {"e164": "+" + digits, "national": national, "country": str(country).upper()}


class FakeServicesRelay(FakeRelay):
    """The relay's voucher shop (see :class:`FakeRelay`) and its services."""

    def __init__(self, directory=None):
        super().__init__()
        self.directory = directory if directory is not None else services_directory()
        self.directory_error = None
        self.directory_etags = []
        for flag, colour in (
            (ML_FLAG, (0, 150, 0)),
            (NE_FLAG, (250, 120, 0)),
            (NG_FLAG, (0, 128, 60)),
            (ML_FLAG_2, (200, 0, 0)),
        ):
            self.images[flag[7:]] = png(colour=colour)
        self.detect_answer = detection()
        self.detects = []
        self.quote_answer = relay_quote()
        self.quotes = []
        #: Whether a quote that asked about a number is answered with the number as
        #: the relay reads it (``phone``), the way the real relay does.
        self.reads_numbers = True
        self.order = (201, {"purchase": service_purchase(), "balance": "200.00", "replayed": False})
        self.orders = []
        self.order_timeouts = []
        #: What the supplier charges the relay now, when it has moved since the
        #: quote: an order whose ceiling is below it is refused ``price_changed``,
        #: any other is bought at it.
        self.live_cost = None

    def get_services_directory(self, *, access_token, etag="", timeout=None, max_bytes=None):
        self.directory_etags.append(etag)
        if self.directory_error is not None:
            raise self.directory_error
        current = f'"{self.directory.get("version")}"'
        if etag and etag == current:
            return None, etag
        return json.loads(json.dumps(self.directory)), current

    def post_service_detect(self, *, access_token, country, phone, timeout=None):
        self.detects.append((country, phone))
        if isinstance(self.detect_answer, Exception):
            raise self.detect_answer
        return self.detect_answer

    def quote_service(self, *, access_token, payload, timeout=None):
        self.quotes.append(payload)
        answer = self.quote_answer(payload) if callable(self.quote_answer) else self.quote_answer
        if isinstance(answer, Exception):
            raise answer
        if (
            self.reads_numbers
            and payload.get("phone")
            and isinstance(answer, dict)
            and "phone" not in answer
        ):
            number = relay_phone(payload.get("country") or "", payload["phone"])
            if number is None:
                raise refusal(422, "invalid_phone")
            answer = {**answer, "phone": number}
        return answer

    def create_service_order(self, *, access_token, payload, timeout=None):
        self.orders.append(payload)
        self.order_timeouts.append(timeout)
        if isinstance(self.order, Exception):
            raise self.order
        if self.live_cost is not None and payload.get("max_unit_price") is not None:
            live = Decimal(str(self.live_cost))
            if live > Decimal(payload["max_unit_price"]):
                raise refusal(409, "price_changed", unit_price=f"{live:.2f}")
            status, body = self.order
            bought = {**body["purchase"], "unit_price": f"{live:.2f}", "amount": f"{live:.2f}"}
            return status, {**body, "purchase": bought}
        return self.order


class ServicesMixin(PointyMixin):
    """A shop linked to the relay, a «كروت دفتر» account, and the fake relay with services."""

    def services_relay(self, directory=None):
        return self.use_relay(FakeServicesRelay(directory))

    def sync_services(self, account=None, **kwargs):
        account = account or IntegrationAccount.objects.get(provider="pointy")
        account.refresh_from_db()
        return services_sync.sync_account(account, **kwargs)

    def country(self, code):
        return IntegrationServiceCountry.objects.get(code=code)


# --- the relay client's new calls ----------------------------------------------------------------
class RelayServicesClientTests(SimpleTestCase):
    def setUp(self):
        for name in ("note_relay_transport_failure", "clear_relay_transport_cooldown"):
            patcher = mock.patch(f"apps.core.relay.{name}")
            patcher.start()
            self.addCleanup(patcher.stop)

    def test_the_directory_is_conditional_and_bounded(self):
        sent = []

        def urlopen(request, timeout=None, context=None):
            sent.append(request)
            raise urllib_error.HTTPError(
                request.full_url, 304, "Not Modified", {"ETag": '"d1"'}, None
            )

        with mock.patch("apps.core.relay.request.urlopen", side_effect=urlopen):
            payload, etag = relay_client().get_services_directory(access_token="tok", etag='"d1"')
        self.assertIsNone(payload)
        self.assertEqual(etag, '"d1"')
        self.assertTrue(sent[0].full_url.endswith("/v1/services/directory"))
        self.assertEqual(sent[0].get_header("If-none-match"), '"d1"')
        self.assertEqual(sent[0].get_header("X-pointy-relay-token"), "tok")

        body = json.dumps(services_directory()).encode()
        with mock.patch(
            "apps.core.relay.request.urlopen",
            return_value=_Response(200, body, {"ETag": '"d2"'}),
        ):
            payload, etag = relay_client().get_services_directory(access_token="tok")
        self.assertEqual(etag, '"d2"')
        self.assertEqual(payload["version"], "d1")

        too_big = _Response(200, b"x" * 100, {})
        with mock.patch("apps.core.relay.request.urlopen", return_value=too_big):
            with self.assertRaises(RelayControlError):
                relay_client().get_services_directory(access_token="tok", max_bytes=10)

    def test_detection_carries_the_country_and_the_number_in_the_body_never_the_address(self):
        sent = []

        def urlopen(request, timeout=None, context=None):
            sent.append(request)
            return _Response(200, json.dumps(detection()).encode())

        with mock.patch("apps.core.relay.request.urlopen", side_effect=urlopen):
            answer = relay_client().post_service_detect(
                access_token="tok", country="ML", phone="+223 70 12 34 56"
            )
        self.assertEqual(answer["operator"]["id"], 289)
        self.assertEqual(sent[0].get_method(), "POST")
        self.assertTrue(sent[0].full_url.endswith("/v1/services/detect"))
        self.assertNotIn("?", sent[0].full_url)
        self.assertNotIn("70", sent[0].full_url.replace("relay.test", ""))
        self.assertEqual(json.loads(sent[0].data), {"country": "ML", "phone": "+223 70 12 34 56"})
        self.assertEqual(sent[0].get_header("Content-type"), "application/json")
        self.assertEqual(sent[0].get_header("X-pointy-relay-token"), "tok")

    def test_the_old_get_call_is_gone(self):
        self.assertFalse(hasattr(relay_client(), "get_service_detect"))

    def test_a_quote_and_an_order_are_posted_as_they_are(self):
        sent = []

        def urlopen(request, timeout=None, context=None):
            sent.append(request)
            if request.full_url.endswith("/quote"):
                return _Response(200, json.dumps(relay_quote()).encode())
            return _Response(
                201, json.dumps({"purchase": service_purchase("k-1"), "balance": "1.00"}).encode()
            )

        question = {
            "kind": "airtime",
            "operator_id": 289,
            "amount": "5000",
            "amount_currency": "XOF",
        }
        order = {**question, "country": "ML", "phone": "+22370123456", "idempotency_key": "k-1"}
        with mock.patch("apps.core.relay.request.urlopen", side_effect=urlopen):
            quoted = relay_client().quote_service(access_token="tok", payload=question)
            status, answered = relay_client().create_service_order(
                access_token="tok", payload=order
            )
        self.assertEqual(quoted["quote"]["unit_price"], "91.30")
        self.assertEqual((status, answered["purchase"]["id"]), (201, "svc-1"))
        self.assertTrue(sent[0].full_url.endswith("/v1/services/quote"))
        self.assertEqual(json.loads(sent[0].data), question)
        self.assertTrue(sent[1].full_url.endswith("/v1/services/orders"))
        self.assertEqual(json.loads(sent[1].data), order)
        self.assertEqual(sent[1].get_method(), "POST")

    def test_an_order_says_whether_it_ever_left(self):
        cases = [
            (urllib_error.URLError(ConnectionRefusedError("refused")), False),
            (TimeoutError("read timed out"), True),
            (ConnectionResetError("reset by peer"), True),
        ]
        for failure, sent in cases:
            with self.subTest(failure=type(failure).__name__):
                with mock.patch("apps.core.relay.request.urlopen", side_effect=failure):
                    with self.assertRaises(RelayControlError) as caught:
                        relay_client().create_service_order(access_token="tok", payload={})
                self.assertIsNone(caught.exception.status_code)
                self.assertIs(caught.exception.request_sent, sent)

    def test_a_refusal_keeps_its_status_and_body(self):
        def urlopen(request, timeout=None, context=None):
            raise urllib_error.HTTPError(
                request.full_url,
                422,
                "Unprocessable",
                {},
                io.BytesIO(b'{"code": "amount_out_of_range", "min": "1967", "max": "32800"}'),
            )

        with mock.patch("apps.core.relay.request.urlopen", side_effect=urlopen):
            with self.assertRaises(RelayControlError) as caught:
                relay_client().quote_service(access_token="tok", payload={})
        self.assertEqual(caught.exception.status_code, 422)
        self.assertEqual(json.loads(caught.exception.body)["max"], "32800")


def failed_purchase(number, *, key=""):
    """A failed service purchase whose error text repeats the number."""
    return service_purchase(key, status="failed", error_code="supplier_refused", receipt=None) | {
        "error_detail": f"Reloadly refused {number}"
    }


class MaskingTests(SimpleTestCase):
    def test_a_number_shows_its_country_code_and_its_last_three_digits(self):
        self.assertEqual(mask_number("+22370123456"), "+223•••••456")
        self.assertEqual(mask_number("+223 70 12 34 56"), "+223•••••456")
        self.assertEqual(mask_number("04223568280"), "042•••••280")
        self.assertEqual(mask_number("70123456"), "•••••456", "a short one shows less")
        self.assertEqual(mask_number("123456"), "••••••", "and a shorter one nothing")
        self.assertEqual(mask_number(""), "")
        self.assertEqual(mask_number(None), "")

    def test_numbers_in_a_sentence_are_masked_and_nothing_else_is(self):
        sentence = (
            "refused +22370123456 (code 422) at 2026-10-08T12:00:03Z for purchase "
            "550e8400-e29b-41d4-a716-446655440000, balance 100.00 below 91.30"
        )
        self.assertEqual(
            mask_numbers(sentence),
            "refused +223•••••456 (code 422) at 2026-10-08T12:00:03Z for purchase "
            "550e8400-e29b-41d4-a716-446655440000, balance 100.00 below 91.30",
        )
        self.assertEqual(mask_numbers("account 04223568280."), "account 042•••••280.")
        self.assertEqual(mask_numbers("number 77 12 34 56 7 failed"), "number ••••••567 failed")
        self.assertEqual(mask_numbers("٧٠١٢٣٤٥٦"), "•••••٤٥٦", "Arabic-Indic digits too")
        self.assertEqual(mask_numbers("no digits here"), "no digits here")
        self.assertEqual(mask_numbers(None), "")
        self.assertEqual(mask_numbers("ML70123456x"), "ML70123456x", "part of a longer word")

    def test_an_account_is_masked_however_it_is_written(self):
        self.assertEqual(mask_numbers("meter 0422-3568-280 refused"), "meter 042•••••280 refused")
        self.assertEqual(mask_numbers("meter 0422.3568.280."), "meter 042•••••280.")
        self.assertEqual(mask_numbers("meter 0422 3568 280"), "meter 042•••••280")
        self.assertEqual(mask_numbers("070-123-456 refused"), "••••••456 refused")
        self.assertEqual(mask_numbers("account SC123456789 refused"), "account SC1•••••789 refused")
        self.assertEqual(mask_numbers("ML70123456"), "•••••••456", "a letters-then-digits account")
        self.assertEqual(mask_numbers("a card 4111-1111-1111-1111."), "a card 411••••••••••111.")

    def test_what_is_not_a_number_is_left_alone(self):
        for harmless in (
            "at 2026-10-08 12:00:03 for 5 minutes",
            "on 2026-10-08.",
            "on 08-10-2026",
            "12:30-13:45",
            "prices 100.00 and 1.5.2",
            "connect to 192.168.100.200 failed",
            "version 2.10.3",
            "amount 12,345.50",
            "request 550e8400-e29b-41d4-a716-446655440000 failed",
            "svc-1 and INV-2024",
            "code abcdef1234",
        ):
            self.assertEqual(mask_numbers(harmless), harmless)

    def test_masking_twice_changes_nothing(self):
        for text in (
            "sent to +22370123456",
            "meter 0422-3568-280 refused",
            "account SC123456789 refused",
        ):
            once = mask_numbers(text)
            self.assertEqual(mask_numbers(once), once, text)


class ErrorDetailTests(SimpleTestCase):
    def test_a_code_word_keeps_its_word_and_loses_its_figures(self):
        for detail, word in (
            ("price_changed: the relay now charges 99.00", "price_changed"),
            (
                "insufficient_balance: voucher balance 10.00 below 50.00",
                "insufficient_balance",
            ),
            ("supplier_credit: account balance 12.34 below 91.30", "supplier_credit"),
            ("price_changed", "price_changed"),
            ("in_flight", "in_flight"),
            ("receipt_pending", "receipt_pending"),
        ):
            self.assertEqual(without_figures(detail), word)

    def test_any_other_text_is_left_alone(self):
        for text in (
            "",
            "status is pending",
            "the purchase may have gone through: sent for +223•••••456, no answer",
            "رصيد الوكالة غير كاف: 12.00",
            "Timed out",
            "HTTP 502: bad gateway",
            "x: y",
        ):
            self.assertEqual(without_figures(text), text)
        self.assertEqual(without_figures(None), "")


# --- what an option is called -----------------------------------------------------------------------
class ServiceOptionTests(SimpleTestCase):
    def test_an_option_code_is_built_the_one_way(self):
        build = services_options.build_option
        self.assertEqual(build("airtime", 289, "5000.00", "xof").code, "air:289:5000:XOF")
        self.assertEqual(build("airtime", 289, "5e3", "XOF").code, "air:289:5000:XOF")
        self.assertEqual(build("airtime", 289, "10.50", "USD").code, "air:289:10.5:USD")
        self.assertEqual(build("bill", 5, "5000", "NGN").code, "bill:5:5000:NGN")
        self.assertEqual(build("bill", 3, "10000", "XOF", amount_id=2).code, "bill:3:10000:XOF:2")
        self.assertEqual(
            build("bill", 24, "15000", "XOF", invoice_id="2024-118833").code,
            "bill:24:15000:XOF::2024-118833",
        )
        self.assertEqual(
            build("bill", 24, "15000", "XOF", amount_id=7, invoice_id="A/1_b").code,
            "bill:24:15000:XOF:7:A/1_b",
        )

    def test_what_cannot_be_an_option_is_refused(self):
        build = services_options.build_option
        refused = [
            ("kind", dict(kind="toll", service_id=1, amount="5", currency="XOF")),
            ("service_id", dict(kind="airtime", service_id=0, amount="5", currency="XOF")),
            ("service_id", dict(kind="airtime", service_id="x", amount="5", currency="XOF")),
            ("amount", dict(kind="airtime", service_id=1, amount="0", currency="XOF")),
            ("amount", dict(kind="airtime", service_id=1, amount="-5", currency="XOF")),
            ("amount", dict(kind="airtime", service_id=1, amount="abc", currency="XOF")),
            ("amount", dict(kind="airtime", service_id=1, amount=True, currency="XOF")),
            ("amount", dict(kind="airtime", service_id=1, amount="1e999999999", currency="XOF")),
            ("amount", dict(kind="airtime", service_id=1, amount="1" * 13, currency="XOF")),
            # The relay takes five decimals of an amount, and no more.
            ("amount", dict(kind="airtime", service_id=1, amount="1.123456", currency="XOF")),
            ("amount", dict(kind="airtime", service_id=1, amount="0.000001", currency="XOF")),
            ("currency", dict(kind="airtime", service_id=1, amount="5", currency="X")),
            (
                "amount_id",
                dict(kind="airtime", service_id=1, amount="5", currency="XOF", amount_id=2),
            ),
            ("amount_id", dict(kind="bill", service_id=1, amount="5", currency="XOF", amount_id=0)),
            (
                "invoice_id",
                dict(kind="airtime", service_id=1, amount="5", currency="XOF", invoice_id="A"),
            ),
            (
                "invoice_id",
                dict(kind="bill", service_id=1, amount="5", currency="XOF", invoice_id="a:b"),
            ),
            (
                "invoice_id",
                dict(kind="bill", service_id=1, amount="5", currency="XOF", invoice_id="x" * 25),
            ),
        ]
        for field, arguments in refused:
            with self.subTest(field=field, arguments=arguments):
                with self.assertRaises(ValueError) as caught:
                    build(**arguments)
                self.assertEqual(str(caught.exception), field)

    def test_a_code_longer_than_the_fulfillment_holds_is_refused(self):
        with self.assertRaises(ValueError) as caught:
            services_options.build_option(
                "bill",
                1234567890,
                "123456789012.12345",
                "XOF123",
                amount_id=1234567890,
                invoice_id="x" * 24,
            )
        self.assertEqual(str(caught.exception), "too_long")
        longest = services_options.build_option(
            "bill", 99999, "9999999999", "XOF", amount_id=9999, invoice_id="x" * 24
        )
        self.assertLessEqual(len(longest.code), services_options.OPTION_CODE_MAX)
        self.assertEqual(services_options.parse_option_code(longest.code), longest)
        # A code someone made up that is longer is not read at all.
        too_long = "bill:1234567890:123456789012.12345:XOF123:1234567890:" + "x" * 24
        self.assertGreater(len(too_long), services_options.OPTION_CODE_MAX)
        self.assertIsNone(services_options.parse_option_code(too_long))

    def test_a_code_reads_back_as_what_built_it_and_only_as_that(self):
        parse = services_options.parse_option_code
        for code in (
            "air:289:5000:XOF",
            "air:5:10.5:USD",
            "air:5:0.00123:USD",
            "bill:5:5000:NGN",
            "bill:3:10000:XOF:2",
            "bill:24:15000:XOF::2024-118833",
            "bill:24:15000:XOF:7:A/1_b",
        ):
            with self.subTest(code=code):
                option = parse(code)
                self.assertEqual(option.code, code)
        parsed = parse("bill:24:15000:XOF::2024-118833")
        self.assertEqual(
            (parsed.kind, parsed.service_id, parsed.amount, parsed.currency, parsed.amount_id),
            ("bill", 24, "15000", "XOF", None),
        )
        self.assertEqual(parsed.invoice_id, "2024-118833")
        for code in (
            "",
            "air:289:05000:XOF",
            "air:289:5000.0:XOF",
            "air:0:5000:XOF",
            "air:289:5000:xof",
            "air:289:5000:XOF:",
            "air:289:5000:XOF:2",
            "bill:5:5000:NGN:",
            "bill:5:5000:NGN::",
            "bill:5:5000:NGN:0",
            "bill:24:15000:XOF::a:b",
            "bill:24:15000:XOF::" + "x" * 25,
            "itunes-us-10",
            "renew:1",
            "topup:45",
            "AIR:289:5000:XOF",
            "air:289:5000:XOF ",
            "air:5:0.123456:USD",
        ):
            with self.subTest(code=code):
                if code.strip() == code:
                    self.assertIsNone(parse(code))
        # Whitespace around it is not part of it.
        self.assertEqual(parse(" air:289:5000:XOF ").code, "air:289:5000:XOF")

    def test_only_ours_are_service_options(self):
        self.assertTrue(services_options.is_service_option("air:1:5:XOF"))
        self.assertTrue(services_options.is_service_option("bill:1:5:XOF"))
        self.assertTrue(services_options.is_service_option("air:garbage"))
        for item in ("", "itunes-us-10", "libyana-5", "renew:1", "topup:45", None):
            self.assertFalse(services_options.is_service_option(item))

    def test_who_it_is_for_has_a_shape_per_kind(self):
        valid = services_options.valid_subscriber_ref
        self.assertTrue(valid("airtime", "+22370123456"))
        self.assertTrue(valid("airtime", "+123456"))
        for ref in (
            "22370123456",
            "+223 70123456",
            "+12345",
            "+1234567890123456",
            "",
            "+22370x23456",
        ):
            self.assertFalse(valid("airtime", ref), ref)
        self.assertTrue(valid("bill", "04223568280"))
        self.assertTrue(valid("bill", "MTR-22/5_a.b 7"))
        self.assertTrue(valid("bill", "x" * 40), "the relay takes 40")
        self.assertTrue(valid("bill", "a-b-c"), "three letters or digits among the dashes")
        for ref in ("ab", " 0422356", "0422356 ", "x" * 41, "x" * 65, "0422:356", "٠٤٢٢٣٥٦", ""):
            self.assertFalse(valid("bill", ref), ref)
        for ref in ("---", "...", "_/_", "- - -", "a-b", "1.-.2"):
            self.assertFalse(valid("bill", ref), f"{ref!r}: punctuation is no account")
        self.assertFalse(valid("card", "04223568280"))

    def test_a_typed_number_is_only_checked_for_its_shape_the_relay_reads_it(self):
        plausible = services_options.plausible_phone
        # What is sent is what was typed (Arabic-Indic digits read as the digits
        # they are): the relay's own parser knows each country's trunk zero.
        for typed in (
            "70123456",
            "070123456",
            "0707123456",
            "70 12 34 56",
            "(70) 12-34.56",
            "+223 70 12 34 56",
            "00223 70123456",
            "+22370123456",
            "22370123456",
        ):
            self.assertEqual(plausible(typed), typed, typed)
        self.assertEqual(plausible("٧٠١٢٣٤٥٦"), "70123456", "Arabic-Indic digits")
        self.assertEqual(plausible("+٢٢٣٧٠١٢٣٤٥٦"), "+22370123456")
        self.assertEqual(plausible("  70123456 "), "70123456", "trimmed")
        for raw in ("", "abc", "+", "7012x456", "12", "٣", "12345", None, "++22370123456"):
            self.assertIsNone(plausible(raw), raw)
        self.assertIsNotNone(plausible("1" * 15))
        self.assertIsNone(plausible("1" * 16), "E.164 ends at 15 digits")
        self.assertIsNone(plausible("00" + "1" * 16))
        self.assertFalse(hasattr(services_options, "normalize_phone"), "the relay normalizes")

    def test_the_words_a_person_reads_are_arabic(self):
        self.assertEqual(services_options.group_amount("5000"), "5,000")
        self.assertEqual(services_options.group_amount("1234567.50"), "1,234,567.5")
        self.assertEqual(services_options.group_amount("0.5"), "0.5")
        names = {"XOF": "فرنك أفريقي", "NGN": "نيرة نيجيرية"}
        word = services_options.currency_word
        self.assertEqual(word("XOF", names=names), "فرنك أفريقي")
        self.assertEqual(word("xof ", names=names), "فرنك أفريقي", "a code however it is typed")
        self.assertEqual(word("USD"), "دولار أمريكي", "dollars when no country names them")
        self.assertEqual(word("EUR"), "يورو")
        self.assertEqual(
            word("USD", names={"USD": "دولار ليبيري"}),
            "دولار ليبيري",
            "a country that names its own currency USD is the one that is asked first",
        )
        self.assertEqual(word("GHS"), "GHS", "else the ISO code")
        self.assertEqual(word("GHS", names=names), "GHS", "an unnamed currency keeps its code")
        self.assertEqual(word(""), "")
        self.assertEqual(
            services_options.amount_text("5000", "XOF", names=names), "5,000 فرنك أفريقي"
        )
        self.assertEqual(services_options.amount_text("10", "USD"), "10 دولار أمريكي")
        self.assertEqual(
            services_options.amount_text("1234567.50", "NGN", names=names),
            "1,234,567.5 نيرة نيجيرية",
        )
        self.assertEqual(services_options.amount_text("5000", ""), "5,000", "no currency, no word")
        self.assertEqual(
            services_options.airtime_label("أورنج مالي", "5000", "XOF", names=names),
            "أورنج مالي · 5,000 فرنك أفريقي",
        )
        self.assertEqual(
            services_options.bill_label(
                "كهرباء إيكيجا (مسبقة الدفع)", "electricity", "5000", "NGN", names=names
            ),
            "كهرباء إيكيجا (مسبقة الدفع) · 5,000 نيرة نيجيرية",
            "the name already says it is electricity",
        )
        self.assertEqual(
            services_options.bill_label(
                "كانال بلس مالي",
                "tv",
                "10000",
                "XOF",
                plan_description="كانال بلس أكسيس إنجليش بيسك – شهر",
                names=names,
            ),
            "تلفزيون · كانال بلس أكسيس إنجليش بيسك – شهر · 10,000 فرنك أفريقي",
        )
        self.assertEqual(
            services_options.bill_label("سن إيو", "water", "15000", "XOF", names=names),
            "مياه · سن إيو · 15,000 فرنك أفريقي",
        )
        self.assertEqual(
            services_options.airtime_label("أورنج مالي", "10", "USD"),
            "أورنج مالي · 10 دولار أمريكي",
        )
        self.assertLessEqual(len(services_options.airtime_label("ا" * 300, "5000", "XOF")), 160)

    def test_an_amount_has_the_decimals_its_currency_has(self):
        places = services_options.minor_unit_places
        for code in ("XOF XAF XPF JPY KRW VND UGX RWF GNF PYG CLP ISK KMF DJF BIF VUV xof").split():
            self.assertEqual(places(code), 0, code)
        for code in ("USD", "NGN", "EGP", "GHS", "EUR", "KWD", "LYD", "MGA", ""):
            self.assertEqual(places(code), 2, code)
        fits = services_options.amount_fits_currency
        self.assertTrue(fits("5000", "XOF", {}))
        self.assertFalse(fits("5000.5", "XOF", {}))
        self.assertTrue(fits("10.55", "USD", {}))
        self.assertFalse(fits("10.555", "USD", {}))
        # What the network lists itself is its own to word, however it is written.
        pack = {"amounts": [{"amount": "0.00123"}], "plans": [{"amount": "7.123"}]}
        self.assertTrue(fits("0.00123", "USD", pack))
        self.assertTrue(fits("7.123", "USD", pack))
        self.assertFalse(fits("0.00124", "USD", pack))
        self.assertFalse(fits("5000.5", "XOF", {"suggested": "nonsense", "plans": [None, 3]}))

    def test_an_amount_is_rounded_to_its_minor_unit_only_when_asked_to_be(self):
        group = services_options.group_amount
        self.assertEqual(group("2010.002"), "2,010.002", "a label says what was asked")
        self.assertEqual(group("2010.002", "XOF"), "2,010")
        self.assertEqual(group("2010.5", "XOF"), "2,011", "half rounds up")
        self.assertEqual(group("1500.505", "NGN"), "1,500.51")
        self.assertEqual(group("1500.50", "NGN"), "1,500.5")
        self.assertEqual(group("0.004", "NGN"), "0.004", "never rounded to nothing")
        self.assertEqual(group("100", "XOF"), "100")
        self.assertEqual(group("1000000", "XOF"), "1,000,000")

    def test_a_phone_number_is_grouped_by_its_calling_code_only_when_that_is_safe(self):
        group = services_options.group_phone
        self.assertEqual(group("+22370123456", ["223"]), "+223 70123456")
        self.assertEqual(
            group("+22370123456", ("223",)), "+223 70123456", "a tuple, as the mirror has"
        )
        self.assertEqual(
            group("+18681234567", ["1", "1868"]), "+1868 1234567", "the longest code that fits"
        )
        self.assertEqual(group("+18681234567", ["1"]), "+1 8681234567")
        self.assertEqual(group("+22370123456", ["221", "223"]), "+223 70123456")
        # Never guessed, never changed: the digits stay, only a space is added.
        self.assertEqual(group("+22370123456", []), "+22370123456", "no code known")
        self.assertEqual(group("+22370123456", None), "+22370123456")
        self.assertEqual(group("+22370123456", ["221"]), "+22370123456", "another country's code")
        self.assertEqual(group("+223456", ["223456"]), "+223456", "nothing after the code")
        self.assertEqual(group("22370123456", ["223"]), "22370123456", "not an E.164 number")
        self.assertEqual(group("+223 70123456", ["223"]), "+223 70123456", "already grouped")
        self.assertEqual(group("", ["223"]), "")
        self.assertEqual(group("+22370123456", ["2x3", ""]), "+22370123456", "codes are digits")
        for number in ("+22370123456", "+18681234567", "+4915112345678"):
            for codes in (["223"], ["1", "1868"], ["49"], ["44"]):
                self.assertEqual(group(number, codes).replace(" ", ""), number)


# --- the mirror ---------------------------------------------------------------------------------------
class ServicesSyncTests(ServicesMixin, TestCase):
    def setUp(self):
        self.link_relay()
        self.relay = self.services_relay()
        self.account = self.pointy_account()

    def test_the_directory_becomes_a_mirror_in_the_relays_order(self):
        report = self.sync_services()
        self.assertTrue(report.ok, report)
        self.assertEqual((report.countries, report.changed), (4, 4))
        rows = list(IntegrationServiceCountry.objects.all())
        # The popular countries first (in the company's order), then the relay's own.
        self.assertEqual([row.code for row in rows], ["NE", "ML", "NG", "SN"])
        self.assertEqual([row.popular for row in rows], [1, 2, 3, 0])
        self.assertEqual([row.rank for row in rows], [1, 2, 3, 1003])
        mali = self.country("ML")
        self.assertEqual(
            (mali.name, mali.dial, mali.currency, mali.currency_name),
            ("مالي", ["223"], "XOF", "فرنك أفريقي"),
        )
        self.assertEqual((mali.airtime_count, mali.bills_count), (2, 1))
        self.assertEqual(mali.bill_types, {"tv": 1})
        self.assertEqual(mali.flag_path, ML_FLAG)
        self.assertEqual(len(mali.version), 32)
        # Both names kept, side by side, untouched: the till shows one and searches both.
        orange = mali.payload["airtime"]["operators"][0]
        self.assertEqual((orange["name"], orange["name_en"]), ("أورنج مالي", "Orange Mali"))
        self.assertEqual(orange["amounts"][1]["unit_price"], "91.30")
        plan = mali.payload["bills"]["billers"][0]["plans"][0]
        self.assertEqual(plan["description"], "كانال بلس أكسيس إنجليش بيسك – شهر")
        self.assertEqual(plan["description_en"], "Canalplus Acces English Basic (10000/1MOIS)")
        # Tolls and the catch-all are in the mirror as the relay sent them, and
        # in no count: they are not on the till.
        nigeria = self.country("NG")
        self.assertEqual(len(nigeria.payload["bills"]["billers"]), 3)
        self.assertEqual((nigeria.airtime_count, nigeria.bills_count), (1, 1))
        self.assertEqual(nigeria.bill_types, {"electricity": 1})
        senegal = self.country("SN")
        self.assertEqual((senegal.airtime_count, senegal.bills_count), (0, 2))
        self.assertEqual(senegal.bill_types, {"electricity": 1, "water": 1})
        self.assertNotIn("airtime", senegal.payload)
        self.assertTrue(senegal.payload["bills"]["billers"][0]["requires_invoice"])

    def test_the_service_products_are_made_by_the_sweep_not_by_the_first_till(self):
        from apps.catalog.models import ProductVariant

        self.assertFalse(ProductVariant.objects.filter(sku__startswith="INTEG-POINTY-").exists())
        self.sync_services()
        self.assertEqual(
            sorted(
                ProductVariant.objects.filter(sku__startswith="INTEG-POINTY-").values_list(
                    "sku", flat=True
                )
            ),
            ["INTEG-POINTY-AIRTIME", "INTEG-POINTY-BILL"],
        )
        # A directory with no networks has no airtime product to make.
        ProductVariant.objects.filter(sku__startswith="INTEG-POINTY-").delete()
        IntegrationServiceCountry.objects.all().delete()
        self.relay.directory = services_directory(version="d2", countries=[senegal()])
        self.sync_services()
        self.assertEqual(
            list(
                ProductVariant.objects.filter(sku__startswith="INTEG-POINTY-").values_list(
                    "sku", flat=True
                )
            ),
            ["INTEG-POINTY-BILL"],
        )

    def test_what_the_relay_says_about_the_directory_is_kept_on_the_account(self):
        self.sync_services()
        self.account.refresh_from_db()
        config = self.account.config
        self.assertEqual(config[services_mirror.CONFIG_ETAG], '"d1"')
        self.assertEqual(config[services_mirror.CONFIG_EDITION], "d1")
        self.assertEqual(config[services_mirror.CONFIG_SCHEMA], services_mirror.SCHEMA)
        self.assertEqual(
            config[services_mirror.CONFIG_STATE],
            {
                "configured": True,
                "priced": True,
                "test_mode": False,
                "generated_at": "2026-10-08T12:00:00Z",
            },
        )
        self.assertEqual(config[services_mirror.CONFIG_UNSUPPORTED], UNSUPPORTED)
        self.assertNotIn(services_mirror.CONFIG_ERROR, config)
        self.assertEqual(services_mirror.availability_error(self.account), "")

    def test_an_unchanged_directory_answers_304_and_writes_nothing(self):
        self.sync_services()
        self.assertEqual(self.relay.directory_etags, [""])
        with CaptureQueriesContext(connection) as queries:
            report = self.sync_services()
        self.assertTrue(report.not_modified)
        self.assertEqual((report.changed, report.countries), (0, 0))
        self.assertEqual(self.relay.directory_etags, ["", '"d1"'])
        self.assertEqual(_writes(queries.captured_queries), [])

    def test_the_same_directory_read_whole_again_moves_no_row(self):
        self.sync_services()
        stamps = dict(IntegrationServiceCountry.objects.values_list("code", "updated_at"))
        self.relay.directory["version"] = "d1-again"
        report = self.sync_services()
        self.assertEqual((report.changed, report.not_modified), (0, False))
        self.assertEqual(
            dict(IntegrationServiceCountry.objects.values_list("code", "updated_at")), stamps
        )
        self.account.refresh_from_db()
        self.assertEqual(self.account.config[services_mirror.CONFIG_EDITION], "d1-again")

    def test_a_new_edition_rewrites_only_the_countries_that_changed(self):
        self.sync_services()
        before = {
            row.code: (row.version, row.updated_at)
            for row in IntegrationServiceCountry.objects.all()
        }
        repriced = mali()
        repriced["airtime"]["operators"][0]["amounts"][1]["unit_price"] = "90.00"
        self.relay.directory = services_directory(
            version="d2", countries=[niger(), repriced, nigeria(), senegal()]
        )
        report = self.sync_services()
        self.assertEqual((report.changed, report.countries), (1, 4))
        after = {
            row.code: (row.version, row.updated_at)
            for row in IntegrationServiceCountry.objects.all()
        }
        self.assertNotEqual(after["ML"], before["ML"])
        for code in ("NE", "NG", "SN"):
            self.assertEqual(after[code], before[code], code)
        self.assertEqual(
            self.country("ML").payload["airtime"]["operators"][0]["amounts"][1]["unit_price"],
            "90.00",
        )

    def test_a_country_the_relay_stops_listing_goes(self):
        self.sync_services()
        self.relay.directory = services_directory(version="d2", countries=[niger(), mali()])
        report = self.sync_services()
        self.assertEqual(
            report.changed, 2, "two countries gone; the ranks of the rest did not move"
        )
        self.assertEqual(
            sorted(IntegrationServiceCountry.objects.values_list("code", flat=True)), ["ML", "NE"]
        )

    def test_the_mirror_names_each_currency_once_whichever_country_carries_it(self):
        self.assertEqual(services_mirror.currency_names(self.account), {}, "nothing mirrored yet")
        self.sync_services()
        with self.assertNumQueries(1):
            names = services_mirror.currency_names(self.account)
        self.assertEqual(names, {"XOF": "فرنك أفريقي", "NGN": "نيرة نيجيرية"})
        # The first country in the directory's own order names a currency; a currency
        # the directory gives no name is left out; a country that spends dollars names them.
        togo = country(
            "TG", "توغو", ["228"], "XOF", "فرنك غرب أفريقي", operators=[operator(7, name_en="Moov")]
        )
        ghana = country("GH", "غانا", ["233"], "GHS", "", operators=[operator(8, name_en="MTN")])
        zimbabwe = country(
            "ZW",
            "زيمبابوي",
            ["263"],
            "USD",
            "دولار أمريكي",
            operators=[operator(9, name_en="Econet")],
        )
        self.relay.directory = services_directory(
            version="d2", countries=[niger(), mali(), nigeria(), senegal(), togo, ghana, zimbabwe]
        )
        self.sync_services()
        names = services_mirror.currency_names(self.account)
        self.assertEqual(names["XOF"], "فرنك أفريقي")
        self.assertEqual(names["USD"], "دولار أمريكي")
        self.assertNotIn("GHS", names)

    def test_a_country_the_driver_cannot_read_keeps_the_row_it_had(self):
        self.sync_services()
        broken = mali()
        broken["airtime"] = "oops"
        self.relay.directory = services_directory(
            version="d2", countries=[niger(), broken, nigeria(), senegal()]
        )
        report = self.sync_services()
        self.assertTrue(report.ok)
        self.assertEqual(report.countries, 3)
        self.assertEqual(self.country("ML").airtime_count, 2, "kept as it was")
        # An operator list that is all unreadable is the same.
        garbled = mali()
        garbled["airtime"] = {"operators": [{"id": "x"}, "nonsense"]}
        self.relay.directory = services_directory(
            version="d3", countries=[niger(), garbled, nigeria(), senegal()]
        )
        self.sync_services()
        self.assertEqual(self.country("ML").airtime_count, 2)

    def test_one_bad_country_is_skipped_on_the_first_read_and_the_rest_stand(self):
        bad_code = mali()
        bad_code["code"] = "not a code!"
        no_code = {"name": "بلا رمز", "airtime": {"operators": [operator()]}}
        empty = country("GH", "غانا", ["233"], "GHS", "سيدي غاني")
        broken_operator = nigeria()
        broken_operator["airtime"]["operators"].append({"id": 0, "name": ""})
        broken_operator["airtime"]["operators"].append("nonsense")
        self.relay.directory = services_directory(
            countries=[niger(), bad_code, "nonsense", no_code, empty, broken_operator, senegal()]
        )
        report = self.sync_services()
        self.assertTrue(report.ok)
        self.assertEqual(
            sorted(IntegrationServiceCountry.objects.values_list("code", flat=True)),
            ["NE", "NG", "SN"],
        )
        self.assertEqual(self.country("NG").airtime_count, 1, "its one good operator stands")

    def test_what_is_kept_is_bounded_and_clean(self):
        hostile = mali()
        hostile["name"] = "م" * 500
        hostile["dial"] = ["223", "x", "1" * 20, 22, "+9"]
        hostile["currency"] = "XOF-and-more"
        hostile["flag"] = "http://169.254.169.254/latest"
        orange = hostile["airtime"]["operators"][0]
        orange["logo"] = "javascript:alert(1)"
        orange["name"] = "ن" * 500
        orange["amounts"].append({"amount": "abc"})
        orange["amounts"].append({"amount": "0"})
        orange["amounts"].append(
            {"amount": "7500", "unit_price": "not money", "retail_price": "-3"}
        )
        self.relay.directory = services_directory(countries=[hostile])
        self.sync_services()
        row = self.country("ML")
        self.assertEqual(len(row.name), 120)
        self.assertEqual(row.dial, ["223", "22"])
        self.assertEqual(row.currency, "")
        self.assertEqual(row.flag_path, "")
        saved = row.payload["airtime"]["operators"][0]
        self.assertEqual(saved["logo"], "")
        self.assertEqual(len(saved["name"]), 160)
        self.assertEqual([entry["amount"] for entry in saved["amounts"]], ["2500", "5000", "7500"])
        self.assertEqual(
            saved["amounts"][2], {"amount": "7500", "receive": "7500", "receive_currency": "XOF"}
        )

    def test_the_unsupported_list_keeps_what_the_relay_says_of_each(self):
        self.sync_services()
        self.account.refresh_from_db()
        listed = services_mirror.unsupported(self.account)
        self.assertEqual([row["code"] for row in listed], ["SD", "TD"])
        self.assertEqual(listed[1]["name_en"], "Chad")
        self.assertNotIn("name_en", listed[0])

    def test_a_relay_that_says_it_is_not_set_up_leaves_nothing_to_sell(self):
        self.relay.directory = services_directory(configured=False, countries=[])
        report = self.sync_services()
        self.assertTrue(report.ok)
        self.account.refresh_from_db()
        self.assertEqual(services_mirror.availability_error(self.account), ERROR_UNAVAILABLE)

        self.relay.directory = services_directory(version="d2", priced=False)
        self.sync_services()
        self.account.refresh_from_db()
        self.assertEqual(services_mirror.availability_error(self.account), "rate_unset")

        self.relay.directory = services_directory(version="d3")
        self.sync_services()
        self.account.refresh_from_db()
        self.assertEqual(services_mirror.availability_error(self.account), "")

    def test_a_relay_without_services_is_remembered_once_and_forgotten(self):
        self.sync_services()
        # What a relay from before the services answers its missing route with.
        self.relay.directory_error = RelayControlError(
            "404", status_code=404, body='{"error": "not found"}', request_sent=True
        )
        report = self.sync_services()
        self.assertEqual((report.ok, report.error_code), (False, ERROR_UNAVAILABLE))
        self.account.refresh_from_db()
        self.assertEqual(self.account.config[services_mirror.CONFIG_ERROR], ERROR_UNAVAILABLE)
        self.assertEqual(services_mirror.availability_error(self.account), ERROR_UNAVAILABLE)
        # Asked again, it is not written again.
        with CaptureQueriesContext(connection) as queries:
            self.sync_services()
        self.assertEqual(_writes(queries.captured_queries), [])
        # The mirror is as it was; it is back when the relay is.
        self.assertEqual(IntegrationServiceCountry.objects.count(), 4)
        self.relay.directory_error = None
        report = self.sync_services()
        self.assertTrue(report.not_modified)
        self.account.refresh_from_db()
        self.assertNotIn(services_mirror.CONFIG_ERROR, self.account.config)
        self.assertEqual(services_mirror.availability_error(self.account), "")

    def test_a_relay_that_cannot_read_its_suppliers_yet_says_unavailable_not_unreachable(self):
        self.sync_services()
        self.relay.directory_error = refusal(503, "services_unavailable")
        report = self.sync_services()
        self.assertEqual((report.ok, report.error_code), (False, ERROR_UNAVAILABLE))
        self.account.refresh_from_db()
        self.assertEqual(self.account.config[services_mirror.CONFIG_ERROR], ERROR_UNAVAILABLE)
        self.assertEqual(IntegrationServiceCountry.objects.count(), 4, "the copy is kept")
        # A proxy's 503 with no word of the relay's own is still an unreachable relay.
        self.relay.directory_error = refusal(503)
        report = self.sync_services()
        self.assertEqual((report.ok, report.error_code), (False, ERROR_UNREACHABLE))

    def test_a_relay_that_cannot_be_reached_changes_nothing(self):
        self.sync_services()
        self.relay.directory_error = RelayControlError("down", request_sent=False)
        report = self.sync_services()
        self.assertEqual((report.ok, report.error_code), (False, ERROR_UNREACHABLE))
        self.account.refresh_from_db()
        self.assertNotIn(services_mirror.CONFIG_ERROR, self.account.config)
        self.assertEqual(IntegrationServiceCountry.objects.count(), 4)

    def test_an_answer_that_is_not_a_directory_changes_nothing(self):
        self.sync_services()
        self.relay.directory = {"version": "d2", "nothing": "useful"}
        report = self.sync_services()
        self.assertEqual((report.ok, report.error_code), (False, ERROR_UNEXPECTED))
        self.assertEqual(IntegrationServiceCountry.objects.count(), 4)

    def test_a_relay_that_lists_nothing_does_not_empty_the_mirror(self):
        self.sync_services()
        self.relay.directory = services_directory(version="d2", countries=[])
        report = self.sync_services()
        self.assertEqual((report.ok, report.error_code), (False, "empty_directory"))
        self.assertEqual(IntegrationServiceCountry.objects.count(), 4)
        self.account.refresh_from_db()
        self.assertEqual(self.account.config[services_mirror.CONFIG_ETAG], '"d1"', "not remembered")

    def test_a_mirror_the_factory_reset_emptied_is_read_whole_again(self):
        self.sync_services()
        IntegrationServiceCountry.objects.all().delete()
        report = self.sync_services()
        self.assertEqual(
            self.relay.directory_etags[-1], "", "no edition is vouched for an empty mirror"
        )
        self.assertEqual((report.not_modified, report.changed), (False, 4))

    def test_a_mirror_of_another_shape_is_read_whole_again(self):
        self.sync_services()
        config = dict(self.account.config)
        config[services_mirror.CONFIG_SCHEMA] = services_mirror.SCHEMA - 1
        IntegrationAccount.objects.filter(pk=self.account.pk).update(config=config)
        self.sync_services()
        self.assertEqual(self.relay.directory_etags[-1], "")

    def test_the_five_minute_task_sweeps_the_services_of_a_connected_shop(self):
        result = tasks.sync_relay_services_task()
        self.assertEqual([report["provider"] for report in result["accounts"]], ["pointy"])
        self.assertEqual(result["accounts"][0]["countries"], 4)
        self.assertTrue(IntegrationServiceCountry.objects.filter(code="ML").exists())
        self.assertTrue(tasks.sync_relay_services_task()["accounts"][0]["not_modified"])

    def test_the_sweep_is_scheduled_every_five_minutes_like_the_shelf(self):
        from django.conf import settings

        entry = settings.CELERY_BEAT_SCHEDULE["integrations.sync-relay-services"]
        self.assertEqual(entry["task"], tasks.sync_relay_services_task.name)
        self.assertEqual(entry["schedule"], timedelta(minutes=5))
        self.assertEqual(
            entry["schedule"],
            settings.CELERY_BEAT_SCHEDULE["integrations.sync-relay-vouchers"]["schedule"],
        )

    def test_a_switched_off_or_disconnected_provider_is_not_swept(self):
        from apps.core.models import RelayInstallation

        RelayInstallation.objects.update(integrations_disabled=["pointy"])
        self.assertEqual(tasks.sync_relay_services_task(), {"accounts": []})
        RelayInstallation.objects.update(integrations_disabled=[])
        IntegrationAccount.objects.filter(pk=self.account.pk).update(is_active=False)
        self.assertEqual(tasks.sync_relay_services_task(), {"accounts": []})
        self.assertEqual(self.relay.directory_etags, [])

    def test_connecting_the_shop_reads_its_services_with_its_cards(self):
        result = tasks.sync_voucher_catalog_task(self.account.pk)
        self.assertTrue(result["ok"])
        self.assertEqual(result["services"]["countries"], 4)
        self.assertTrue(IntegrationServiceCountry.objects.exists())


class ServicesFlagTests(ServicesMixin, TestCase):
    def setUp(self):
        self.link_relay()
        self.relay = self.services_relay()
        self.account = self.pointy_account()

    def test_flags_arrive_through_the_image_path_small_and_once(self):
        report = self.sync_services()
        self.assertEqual(report.flags, 3, "ML, NE and NG have one; SN has none")
        mali = self.country("ML")
        flag = Image.open(io.BytesIO(bytes(mali.flag)))
        self.assertEqual(flag.format, "PNG")
        self.assertLessEqual(max(flag.size), 96)
        self.assertEqual(mali.flag_source, ML_FLAG)
        self.assertIsNone(self.country("SN").flag)
        flags = {flag[7:] for flag in (ML_FLAG, NE_FLAG, NG_FLAG, ML_FLAG_2)}

        def flag_reads():
            # Operator logos come through the same path (see ``services_logos``).
            return sorted(read for read in self.relay.image_reads if read in flags)

        reads = flag_reads()
        self.assertEqual(reads, sorted(flag[7:] for flag in (ML_FLAG, NE_FLAG, NG_FLAG)))

        # Unchanged, or changed in everything but its flags: nothing fetched again.
        self.assertTrue(self.sync_services().not_modified)
        self.relay.directory["version"] = "d1-again"
        self.sync_services()
        self.assertEqual(flag_reads(), reads)

        # A new picture is a new hash: fetched at once.
        moved = mali_with_flag(ML_FLAG_2)
        self.relay.directory = services_directory(
            version="d2", countries=[niger(), moved, nigeria(), senegal()]
        )
        self.assertEqual(self.sync_services().flags, 1)
        self.assertEqual(self.country("ML").flag_source, ML_FLAG_2)
        # No picture: no flag.
        self.relay.directory = services_directory(
            version="d3", countries=[niger(), mali_with_flag(""), nigeria(), senegal()]
        )
        self.sync_services()
        self.assertIsNone(self.country("ML").flag)

    def test_only_a_few_dozen_are_fetched_a_sweep_and_the_rest_follow(self):
        many = [
            country(
                f"C{index:02d}",
                f"بلد {index}",
                [str(300 + index)],
                "XOF",
                "فرنك أفريقي",
                flag=NE_FLAG if index % 2 else NG_FLAG,
                operators=[operator(1000 + index)],
            )
            for index in range(10)
        ]
        self.relay.directory = services_directory(countries=many)
        first = self.sync_services(flag_limit=4)
        self.assertEqual(first.flags, 4)
        # Even though the directory did not change: the flags are still owed.
        second = self.sync_services(flag_limit=4)
        self.assertTrue(second.not_modified)
        self.assertEqual(second.flags, 4)
        third = self.sync_services(flag_limit=4)
        self.assertEqual(third.flags, 2)
        self.assertEqual(IntegrationServiceCountry.objects.filter(flag__isnull=False).count(), 10)
        self.assertEqual(self.sync_services(flag_limit=4).flags, 0)

    def test_a_flag_that_did_not_come_is_asked_for_again_an_hour_later(self):
        del self.relay.images[ML_FLAG[7:]]
        self.sync_services()
        self.assertIsNone(self.country("ML").flag)
        reads = self.relay.image_reads.count(ML_FLAG[7:])
        self.assertEqual(reads, 1)
        self.sync_services()
        self.assertEqual(self.relay.image_reads.count(ML_FLAG[7:]), 1, "not before the hour")
        IntegrationServiceCountry.objects.update(
            flag_checked_at=timezone.now() - timedelta(hours=2)
        )
        self.relay.images[ML_FLAG[7:]] = png()
        report = self.sync_services()
        self.assertTrue(report.not_modified)
        self.assertEqual(report.flags, 1)
        self.assertIsNotNone(self.country("ML").flag)

    def test_a_picture_that_is_not_one_is_not_kept(self):
        self.relay.images[ML_FLAG[7:]] = b"<html>not a picture</html>"
        self.sync_services()
        self.assertIsNone(self.country("ML").flag)
        self.assertIsNotNone(self.country("NE").flag)


def mali_with_flag(flag):
    row = mali()
    row["flag"] = flag
    return row


class ServicesDriverReadTests(ServicesMixin, TestCase):
    """The driver's three reads, answer by answer."""

    def setUp(self):
        self.link_relay()
        self.relay = self.services_relay()
        self.account = self.pointy_account()
        self.driver = PointyProvider(self.account)

    def test_a_directory_is_read_into_the_drivers_vocabulary(self):
        result = self.driver.services_directory()
        self.assertTrue(result.ok)
        self.assertEqual(result.version, '"d1"')
        self.assertEqual(result.edition, "d1")
        self.assertEqual([c.code for c in result.countries], ["NE", "ML", "NG", "SN"])
        self.assertEqual(result.countries[1].popular, 2)
        self.assertEqual(result.skipped, ())
        self.assertEqual((result.configured, result.priced, result.test_mode), (True, True, False))
        self.assertEqual([c["code"] for c in result.unsupported], ["SD", "TD"])
        unchanged = self.driver.services_directory('"d1"')
        self.assertTrue(unchanged.ok and unchanged.not_modified)
        self.assertEqual(unchanged.version, '"d1"')

    def test_a_country_with_no_popularity_of_its_own_takes_the_lists(self):
        flat = mali()
        flat["popular"] = 0
        self.relay.directory = services_directory(countries=[flat])
        self.assertEqual(self.driver.services_directory().countries[0].popular, 2)

    def test_a_shop_not_linked_to_the_relay_asks_nothing(self):
        from apps.core.models import RelayInstallation

        RelayInstallation.objects.all().delete()
        for answer in (
            self.driver.services_directory(),
            self.driver.service_detect("ML", "70123456"),
            self.driver.service_quote({"kind": "airtime"}),
        ):
            self.assertFalse(answer.ok)
            self.assertEqual(answer.error_code, "not_configured")
        self.assertEqual(self.relay.directory_etags + self.relay.detects + self.relay.quotes, [])

    def test_detection_tells_a_network_from_a_number_it_cannot_place(self):
        found = self.driver.service_detect("ML", "70123456")
        self.assertTrue(found.ok)
        self.assertEqual(found.operator["name"], "أورنج مالي")
        self.assertEqual(
            found.phone, {"e164": "+22370123456", "national": "70123456", "country": "ML"}
        )
        self.assertEqual(self.relay.detects, [("ML", "70123456")])

        cases = {
            "operator_not_detected": (refusal(404, "operator_not_detected"), "not_detected"),
            "invalid_phone": (refusal(422, "invalid_phone"), "invalid_phone"),
        }
        for name, (answer, reason) in cases.items():
            with self.subTest(name):
                self.relay.detect_answer = answer
                result = self.driver.service_detect("ML", "7")
                self.assertTrue(result.ok, "an answer, not a fault")
                self.assertEqual((result.operator, result.reason), (None, reason))
                self.assertEqual(result.error_code, "")

    def test_detection_faults_are_told_apart_from_answers(self):
        faults = {
            "unreachable": (RelayControlError("down", request_sent=False), "unreachable"),
            "reloadly down (503)": (refusal(503, "reloadly_unreachable"), "unreachable"),
            "refused token": (refusal(401, "unauthorized"), "unauthorized"),
            "a relay without the route": (
                RelayControlError("404", status_code=404, body='{"error": "not found"}'),
                "unavailable",
            ),
            "services not set up": (refusal(503, "services_unconfigured"), "unavailable"),
            "services unavailable (503)": (refusal(503, "services_unavailable"), "unavailable"),
            "no operator in the answer": ({"operator": {"id": 0}}, ERROR_UNEXPECTED),
            "no answer at all": ({}, ERROR_UNEXPECTED),
        }
        for name, (answer, code) in faults.items():
            with self.subTest(name):
                self.relay.detect_answer = answer
                result = self.driver.service_detect("ML", "70123456")
                self.assertFalse(result.ok)
                self.assertEqual(result.error_code, code)

    def test_a_quote_is_priced_in_dinars_at_two_places(self):
        self.relay.quote_answer = relay_quote(cost="91.3", retail="96.504")
        result = self.driver.service_quote(
            {"kind": "airtime", "operator_id": 289, "amount": "5000", "amount_currency": "XOF"}
        )
        self.assertTrue(result.ok)
        self.assertEqual((result.cost, result.price), (Decimal("91.30"), Decimal("96.50")))
        self.assertEqual((result.receive_amount, result.receive_currency), ("5000", "XOF"))
        self.assertFalse(result.approximate)
        self.assertEqual(self.relay.quotes[0]["operator_id"], 289)

    def test_a_quote_that_asked_about_a_number_answers_with_it_as_e164(self):
        request = {
            "kind": "airtime",
            "operator_id": 289,
            "country": "ML",
            "phone": "070123456",
            "amount": "5000",
            "amount_currency": "XOF",
        }
        self.relay.quote_answer = relay_quote()
        result = self.driver.service_quote(request)
        self.assertTrue(result.ok)
        self.assertEqual(result.phone, "+22370123456")
        self.assertEqual(self.relay.quotes[0]["phone"], "070123456", "sent as it was typed")
        self.assertEqual(self.relay.quotes[0]["country"], "ML")
        # The number may ride beside the quote or inside it; either is the relay's.
        self.relay.reads_numbers = False
        number = {"e164": "+2250707123456", "national": "0707123456", "country": "CI"}
        for answer in (
            {**relay_quote(), "phone": number},
            {"quote": {**relay_quote()["quote"], "phone": number}},
        ):
            self.relay.quote_answer = answer
            self.assertEqual(
                self.driver.service_quote({**request, "country": "CI"}).phone, "+2250707123456"
            )

    def test_a_quote_that_names_no_usable_number_is_unreadable_not_guessed_at(self):
        request = {
            "kind": "airtime",
            "operator_id": 289,
            "country": "ML",
            "phone": "70123456",
            "amount": "5000",
            "amount_currency": "XOF",
        }
        answers = {
            "none at all": relay_quote(),
            "no e164": {**relay_quote(), "phone": {"national": "70123456", "country": "ML"}},
            "a malformed e164": {**relay_quote(), "phone": {"e164": "70123456"}},
            "a number with no plus": {**relay_quote(), "phone": {"e164": "22370123456"}},
            "another country's": {
                **relay_quote(),
                "phone": {"e164": "+2348031234567", "country": "NG"},
            },
            "not an object": {**relay_quote(), "phone": "+22370123456"},
        }
        self.relay.reads_numbers = False
        for name, answer in answers.items():
            with self.subTest(name):
                self.relay.quote_answer = answer
                result = self.driver.service_quote(request)
                self.assertFalse(result.ok)
                self.assertEqual((result.refusal, result.error_code), ("", ERROR_UNEXPECTED))
        # A bill asks about no number and needs none.
        self.relay.quote_answer = relay_quote(kind="bill", amount="5000", currency="NGN")
        bill = {"kind": "bill", "biller_id": 5, "amount": "5000", "amount_currency": "NGN"}
        self.assertTrue(self.driver.service_quote(bill).ok)

    def test_a_quote_with_no_cost_is_no_quote(self):
        for cost in ("0", "0.00", "-1.00", "", None, "abc"):
            with self.subTest(cost=cost):
                self.relay.quote_answer = relay_quote(cost=cost)
                result = self.driver.service_quote({"kind": "airtime"})
                self.assertFalse(result.ok)
                self.assertEqual(result.error_code, ERROR_UNEXPECTED)
        self.relay.quote_answer = relay_quote(cost="0.01", retail=None)
        self.assertTrue(self.driver.service_quote({"kind": "airtime"}).ok)

    def test_a_quote_refusal_is_an_answer_in_the_relays_words(self):
        cases = [
            (
                refusal(422, "amount_out_of_range", min="1967", max="32800"),
                "amount_out_of_range",
                {"min": "1967", "max": "32800"},
            ),
            (refusal(422, "amount_not_offered"), "amount_not_offered", {}),
            (refusal(422, "invalid_amount"), "invalid_amount", {}),
            (refusal(422, "invoice_required"), "invoice_required", {}),
            (refusal(422, "invalid_invoice"), "invalid_invoice", {}),
            (refusal(404, "unknown_operator"), "unknown_operator", {}),
            (refusal(404, "unknown_biller"), "unknown_biller", {}),
            (
                refusal(409, "service_unavailable", reason="supplier_down"),
                "service_unavailable",
                {"reason": "supplier_down"},
            ),
            (refusal(409, "service_unavailable", reason="rate_unset"), "rate_unset", {}),
            (refusal(503, "services_unpriced"), "rate_unset", {}),
            (
                refusal(503, "services_unconfigured"),
                "service_unavailable",
                {"reason": "unconfigured"},
            ),
        ]
        for answer, refusal_code, data in cases:
            with self.subTest(refusal_code=refusal_code, data=data):
                self.relay.quote_answer = answer
                result = self.driver.service_quote({"kind": "airtime"})
                self.assertFalse(result.ok)
                self.assertEqual((result.refusal, result.refusal_data), (refusal_code, data))
                self.assertEqual(result.error_code, "", "not a fault of the relay")

    def test_a_quote_the_relay_could_not_give_is_a_fault(self):
        faults = {
            "unreachable": (RelayControlError("down", request_sent=False), "unreachable"),
            "a proxy's 502": (refusal(502), "unreachable"),
            "refused token": (refusal(403, "forbidden"), "unauthorized"),
            "no route": (
                RelayControlError("404", status_code=404, body="404 page not found"),
                "unavailable",
            ),
            "no price": ({"quote": {"kind": "airtime"}}, ERROR_UNEXPECTED),
            "nothing": ({}, ERROR_UNEXPECTED),
            "an unknown refusal": (refusal(422, "something_new"), "provider_error"),
        }
        for name, (answer, code) in faults.items():
            with self.subTest(name):
                self.relay.quote_answer = answer
                result = self.driver.service_quote({"kind": "airtime"})
                self.assertFalse(result.ok)
                self.assertEqual((result.refusal, result.error_code), ("", code))


class ServicesTelemetryTests(ServicesMixin, TestCase):
    """A row for each of the relay's service answers — and none that mistakes a
    mistyped number or an amount out of range for the relay being down."""

    def setUp(self):
        from apps.analytics import buffer as analytics_buffer

        from . import telemetry

        telemetry.reset()
        analytics_buffer.reset()
        self.addCleanup(analytics_buffer.reset)
        self.link_relay()
        self.relay = self.services_relay()
        self.account = self.pointy_account()
        self.driver = PointyProvider(self.account)

    def rows(self):
        from apps.analytics import buffer
        from apps.analytics.models import AnalyticsEvent

        from . import telemetry

        buffer.flush()
        return list(AnalyticsEvent.objects.filter(name=telemetry.EVENT_NAME).order_by("pk"))

    def test_each_call_leaves_a_row_naming_what_was_asked(self):
        self.driver.services_directory()
        self.driver.service_detect("ML", "70123456")
        self.driver.service_quote({"kind": "airtime", "operator_id": 289})
        rows = self.rows()
        self.assertEqual(
            [(row.attributes["operation"], row.attributes["outcome"]) for row in rows],
            [("services", "ok"), ("service_detect", "ok"), ("service_quote", "ok")],
        )
        self.assertTrue(all(row.attributes["provider"] == "pointy" for row in rows))

    def test_an_unchanged_directory_leaves_no_row(self):
        self.driver.services_directory('"d1"')
        self.assertEqual(self.rows(), [])

    def test_an_attempt_that_stays_unsettled_is_one_row_not_one_every_two_minutes(self):
        from . import telemetry

        def outcome_rows():
            return [row for row in self.rows() if row.attributes["operation"] == "outcome"]

        self.sync_services()
        waiting = {"purchase": service_purchase("k", receipt_pending=True), "balance": "1.00"}
        clock = [1000.0]
        with mock.patch.object(telemetry.time, "monotonic", side_effect=lambda: clock[0]):
            self.relay.outcomes["k"] = waiting
            for _ in range(5):
                clock[0] += 120  # settlement asks every two minutes
                self.driver.attempt_outcome("k", option_code="air:289:5000:XOF")
            rows = outcome_rows()
            self.assertEqual([row.attributes["attempt_state"] for row in rows], ["unknown"])
            # The day it settles is a row of its own, and says what it came to.
            self.relay.outcomes["k"] = {"purchase": service_purchase("k"), "balance": "1.00"}
            self.driver.attempt_outcome("k", option_code="air:289:5000:XOF")
            states = [row.attributes["attempt_state"] for row in outcome_rows()]
            self.assertEqual(states, ["unknown", "charged"])
            # One that sticks for an hour is written again, with the asks it folded.
            self.relay.outcomes["k"] = waiting
            clock[0] += 3601
            self.driver.attempt_outcome("k", option_code="air:289:5000:XOF")
            clock[0] += 120
            self.driver.attempt_outcome("k", option_code="air:289:5000:XOF")
            clock[0] += 3601
            self.driver.attempt_outcome("k", option_code="air:289:5000:XOF")
        rows = outcome_rows()
        self.assertEqual(len(rows), 4)
        self.assertEqual(rows[-1].metrics.get("suppressed_repeats"), 1)

    def test_a_failed_read_of_an_attempt_is_throttled_as_every_failed_read_is(self):
        self.sync_services()
        self.relay.outcomes["k"] = RelayControlError("down", request_sent=False)
        for _ in range(4):
            self.driver.attempt_outcome("k", option_code="air:289:5000:XOF")
        rows = [row for row in self.rows() if row.attributes["operation"] == "outcome"]
        self.assertEqual(len(rows), 1)

    def test_an_answer_about_a_number_or_an_amount_is_not_a_fault(self):
        self.relay.detect_answer = refusal(404, "operator_not_detected")
        self.driver.service_detect("ML", "70123456")
        self.relay.quote_answer = refusal(422, "amount_out_of_range", min="1", max="2")
        self.driver.service_quote({"kind": "airtime", "operator_id": 289})
        self.assertEqual([row.attributes["outcome"] for row in self.rows()], ["ok", "ok"])

    def test_a_relay_that_cannot_be_asked_is_a_fault_with_its_word(self):
        self.relay.detect_answer = RelayControlError("down", request_sent=False)
        self.driver.service_detect("ML", "70123456")
        self.relay.quote_answer = refusal(401, "unauthorized")
        self.driver.service_quote({"kind": "airtime", "operator_id": 289})
        self.relay.directory_error = RelayControlError("down", request_sent=False)
        self.driver.services_directory()
        outcomes = {row.attributes["operation"]: row.attributes["outcome"] for row in self.rows()}
        self.assertEqual(
            outcomes,
            {
                "service_detect": "unreachable",
                "service_quote": "unauthorized",
                "services": "unreachable",
            },
        )

    def test_nothing_that_names_a_customer_is_recorded(self):
        # Through the real client: the number is in the body of the request and in
        # no address, and in no row.
        client = relay_client()
        failures = [
            urllib_error.URLError(ConnectionRefusedError(61, "Connection refused")),
            TimeoutError("timed out"),
            urllib_error.HTTPError(
                "http://relay.test/v1/services/detect",
                422,
                "Unprocessable",
                {},
                io.BytesIO(b'{"code": "invalid_phone"}'),
            ),
        ]
        addresses = []
        with mock.patch("apps.integrations.relay_link.scoped_relay_client", return_value=client):
            with mock.patch("apps.core.relay.note_relay_transport_failure"):
                for failure in failures:
                    with mock.patch("apps.core.relay.request.urlopen", side_effect=failure) as sent:
                        self.driver.service_detect("ML", "70123456")
                    addresses.append(sent.call_args[0][0].full_url)
        self.assertTrue(all(address.endswith("/v1/services/detect") for address in addresses))
        self.assertFalse(any("70123456" in address for address in addresses))
        # The two transport failures are one fact, written once; the relay's
        # "not a number" is an answer.
        rows = self.rows()
        self.assertEqual([row.attributes["outcome"] for row in rows], ["unreachable", "ok"])
        self.assertNotIn("70123456", json.dumps([row.attributes for row in rows]))

    def test_an_error_that_repeats_a_number_back_is_masked_wherever_it_lands(self):
        # A relay's (or a proxy's) words may carry the number they were asked about.
        self.sync_services()
        number = "+22370123456"
        self.relay.detect_answer = RelayControlError(f"no route to {number}", request_sent=False)
        detected = self.driver.service_detect("ML", "70123456")
        self.relay.quote_answer = RelayControlError(f"{number} reset", request_sent=False)
        quoted = self.driver.service_quote({"kind": "airtime", "operator_id": 289})
        self.relay.order = refusal(502, "supplier_refused", purchase=failed_purchase(number))
        sent = self.driver.recharge(
            number, "air:289:5000:XOF", expected_cost=Decimal("91.30"), attempt_key="k-1"
        )
        self.relay.order = RelayControlError(f"sent for {number}, no answer", request_sent=True)
        lost = self.driver.recharge(
            number, "air:289:5000:XOF", expected_cost=Decimal("91.30"), attempt_key="k-2"
        )
        self.relay.outcomes["k-3"] = {
            "purchase": failed_purchase(number, key="k-3"),
            "balance": "1.00",
        }
        read = self.driver.attempt_outcome("k-3", option_code="air:289:5000:XOF")
        details = [
            detected.error_detail,
            quoted.error_detail,
            sent.error_detail,
            lost.error_detail,
            read.error_detail,
        ]
        for detail in details:
            self.assertIn("+223•••••456", detail)
            self.assertNotIn("70123", detail)
        rows = self.rows()
        self.assertTrue(any("+223•••••456" in row.attributes.get("detail", "") for row in rows))
        self.assertNotIn("70123", json.dumps([row.attributes for row in rows]))

    def test_a_card_keeps_its_details_as_they_were(self):
        self.sync(self.account)
        self.relay.purchase = refusal(
            502,
            "supplier_refused",
            purchase=purchase(status="failed", error_code="x")
            | {"error_detail": "order 12345678 refused"},
        )
        result = self.driver.recharge(
            "", "itunes-us-10", expected_cost=Decimal("50.00"), attempt_key="k-1"
        )
        self.assertIn("order 12345678 refused", result.error_detail)

    def test_sending_one_is_a_recharge_row_like_a_cards(self):
        self.sync_services()
        self.driver.recharge(
            "+22370123456", "air:289:5000:XOF", expected_cost=Decimal("91.30"), attempt_key="k-1"
        )
        rows = [row for row in self.rows() if row.attributes["operation"] == "recharge"]
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0].attributes["outcome"], "ok")
        self.assertEqual(rows[0].attributes["provider_reference"], "svc-1")
        self.assertNotIn("+223", json.dumps(rows[0].attributes))
