"""Qareeb: the driver, the shelf it mirrors into the catalog, and selling from it.

Every response here is shaped after the capture of the agency's own app
(``tools/qareeb-capture/API_CONTRACT.md``) with the values made up: no token,
PIN, serial or phone number in this file came from the real account.
"""

from __future__ import annotations

import base64
import json
import time
from datetime import timedelta
from decimal import Decimal
from unittest import mock
from urllib.parse import urlparse

import requests
from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase, TransactionTestCase
from django.utils import timezone
from rest_framework.test import APIClient

from apps.catalog.models import Product, ProductAlias
from apps.core.roles import CASHIER_GROUP, MANAGER_GROUP, ensure_role_groups
from apps.printing.services import build_receipt_payload
from apps.sales.models import Order, RegisterSession

from . import catalog, recharge, vouchers
from .models import (
    IntegrationAccount,
    IntegrationFulfillment,
    IntegrationVoucher,
    IntegrationVoucherBrand,
)
from .providers import provider_for
from .providers import qareeb as qareeb_driver
from .providers.base import (
    ERROR_ATTESTATION_REQUIRED,
    ERROR_BUSY,
    ERROR_DEVICE_VERIFICATION,
    ERROR_INDETERMINATE,
    ERROR_INSUFFICIENT_FLOAT,
    ERROR_OUT_OF_STOCK,
    ERROR_PIN_REQUIRED,
    ERROR_PROFILE_MISMATCH,
    ERROR_UNEXPECTED,
    ERROR_UNREACHABLE,
    ERROR_VERIFICATION_REJECTED,
    VoucherBrand,
    VoucherCatalogResult,
    VoucherItem,
)
from .reconciliation import reconcile_account

LIBYANA_5 = "2789f02f-0000-4000-8000-000000000005"
LIBYANA_10 = "d84346d1-0000-4000-8000-000000000010"
ALMADAR_10 = "c4812700-0000-4000-8000-000000000010"
PSN_25 = "06384419-0000-4000-8000-000000000025"
PSN_50 = "abd49ed8-0000-4000-8000-000000000050"
FOREIGN = "3a8af3bf-0000-4000-8000-00000000f00f"
STORE_PROFILE = "39395b3a-0000-4000-8000-000000000001"
PERSONAL_PROFILE = "3c325ed3-0000-4000-8000-000000000002"


# --- a fake api.qareb.ly ------------------------------------------------------------
def _jwt(*, expires_in: int = 28 * 24 * 3600) -> str:
    def part(data):
        raw = json.dumps(data).encode()
        return base64.urlsafe_b64encode(raw).decode().rstrip("=")

    now = int(time.time())
    return ".".join(
        [
            part({"alg": "HS256", "typ": "JWT"}),
            part({"token_type": "access", "exp": now + expires_in, "iat": now, "user_id": 7}),
            "signature",
        ]
    )


class _Resp:
    def __init__(self, status=200, payload=None, *, content=b"", content_type="application/json"):
        self.status_code = status
        self._payload = payload
        self.content = content
        self.headers = {"content-type": content_type}
        self.text = json.dumps(payload, ensure_ascii=False) if payload is not None else ""

    def json(self):
        if self._payload is None:
            raise ValueError("no json")
        return self._payload


class _FakeQareeb:
    """Stands in for ``requests.Session`` against api.qareb.ly.

    Routed by method and path. A route holding several responses answers them
    in order and then keeps answering the last one — the shape a basket that is
    read, changed and read again has.
    """

    def __init__(self):
        self.routes: dict = {}
        self.calls: list = []

    def on(self, method, path, *responses):
        self.routes.setdefault((method, path), []).extend(responses)
        return self

    def mount(self, prefix, adapter):
        """A real Session has one; the driver mounts the shared pool on it."""

    def request(self, method, url, json=None, params=None, headers=None, timeout=None):
        path = urlparse(url).path
        self.calls.append({"method": method, "path": path, "json": json, "params": params, "headers": headers})
        queue = self.routes.get((method, path))
        if not queue:
            raise AssertionError(f"unscripted {method} {path}")
        response = queue.pop(0) if len(queue) > 1 else queue[0]
        if isinstance(response, Exception):
            raise response
        if callable(response):
            return response(json=json, params=params)
        return response

    def get(self, url, **kwargs):
        return self.request("GET", url, **kwargs)

    def post(self, url, **kwargs):
        return self.request("POST", url, **kwargs)

    def paths(self, method=None):
        return [c["path"] for c in self.calls if method is None or c["method"] == method]


def patch_qareeb(fake):
    return mock.patch(
        "apps.integrations.providers.qareeb.requests.Session", return_value=fake
    )


def qareeb_account(**config) -> IntegrationAccount:
    account = IntegrationAccount.objects.create(
        provider="qareeb", username="0912345678", config=config
    )
    account.set_secret(catalog.FIELD_PASSWORD, "pw")
    account.save()
    return account


def logged_in(account, token=None) -> IntegrationAccount:
    account.set_secret(qareeb_driver.SECRET_ACCESS, token or _jwt())
    account.save()
    return account


def _product(code, desc, *, amount, price, cost):
    return {
        "desc": desc,
        "amount": amount,
        "price": price,
        "cost": cost,
        "profit": 0.1,
        "favorite": False,
        "id": code,
        "cart": 0,
    }


LISTING = {
    "detail": "success",
    "status": True,
    "client_type": "store",
    "result": [
        {
            "category_name": "الاتصالات",
            "display_product": True,
            "is_collapse": False,
            "data": [
                {
                    "code": "30",
                    "en_desc": "Libyana",
                    "ar_desc": "ليبيانا",
                    "product_currency": "LYD",
                    "logo": "/media/products/libyana.png",
                    "products": [
                        _product(LIBYANA_10, "10 دينار", amount="10.000", price="10.000", cost=9.7),
                        _product(LIBYANA_5, "5 دينار", amount="5.000", price="5.000", cost=4.85),
                    ],
                },
                {
                    "code": "31",
                    "en_desc": "Almadar",
                    "ar_desc": "المدار",
                    "product_currency": "LYD",
                    "products": [
                        _product(ALMADAR_10, "10 دينار", amount="10.000", price="10.000", cost=9.7),
                    ],
                },
            ],
        },
        {
            "category_name": "الدولية",
            "display_product": False,
            "is_collapse": True,
            "data": [
                {
                    "code": "115",
                    "en_desc": "PSN USA",
                    "ar_desc": "امريكي بلاي ستيشن",
                    "product_currency": "USD",
                    "products": [],
                }
            ],
        },
        {
            "category_name": "الحوالات الدولية",
            "display_product": False,
            "data": [
                {"code": "2000", "en_desc": "vodafone cash", "ar_desc": "فودافون كاش",
                 "product_currency": "EGP", "products": []}
            ],
        },
    ],
}

PSN_BRAND = {
    "detail": "success",
    "status": True,
    "result": {
        "code": "115",
        "en_desc": "PSN USA",
        "ar_desc": "امريكي بلاي ستيشن",
        "product_currency": "USD",
        "products": [
            _product(PSN_25, "25$ PSN USA", amount="25.000", price="245.000", cost=237.65),
            _product(PSN_50, "50$ PSN USA", amount="50.000", price="489.000", cost=474.33),
        ],
    },
}

ACCOUNT_INFO = {
    "message": "success",
    "status": True,
    "result": {
        "balance": 674.9,
        "available_balance": 674.9,
        "max_overdraft": 0.0,
        "loan": 0.0,
        "account_name": "النسيم",
        "account_type": "client",
        "use_pin": False,
        "has_pin": False,
        "is_quick_switch_enabled": False,
    },
    "result_count": 1,
}

PROFILES = {
    "available_profiles": [
        {"profile_id": PERSONAL_PROFILE, "profile_type": "individual", "is_active": False,
         "individual": {"id": "i-1", "name": "صاحب المتجر"}},
        {"profile_id": STORE_PROFILE, "profile_type": "store_employee", "is_active": True,
         "store_employee": {"id": "s-1", "name": "النسيم"}},
    ]
}


def switch_ok(profile_id):
    """The provider's answer to a successful ``switch_profile`` (2026-09-24)."""
    return _Resp(200, {"status": True, "profile_id": profile_id, "role": "sub_admin"})


def cart(*items, pin=False, quick=False):
    return {
        "hash": "h" * 64,
        "items": [
            {
                "id": f"line-{code[:4]}",
                "product_code": "0300003",
                "product": {"desc": "كرت", "cost": cost, "id": code, "price": "0"},
                "quantity": quantity,
            }
            for code, quantity, cost in items
        ],
        "totals": [],
        "is_pin_required": pin,
        "is_quick_switch_enabled": quick,
        "has_pin": pin,
    }


CART_ADDED = {"status": True, "detail": "تمت الإضافة بنجاح"}


def checkout_ok(code=LIBYANA_5):
    return {
        "detail": "Success",
        "status": True,
        "order_reference": "650a750997b9486ebece71be175327bc",
        "result": [
            {
                "SN": "123456789012345",
                "id": "dc94d6b1-6861-492e-9951-ee9314d56dac",
                "code": "1111222233334",
                "product": "5 دينار",
                "purchase_date": "2026-09-23T14:57:59.574970",
                "purchase_price": "5.000",
                "status": "sent",
                "mno_type": "Libyana",
                "mno_type_code": "30",
                "mno_type_ar": "ليبيانا",
                "instructions_print": "# الرقم السري * 120 *",
                "help_print": "لاي استفسارات الرجاء الاتصال",
                "tran_ref": "28491139",
                "ccv": "",
                "expiry_date": "",
                "order_reference": "650a750997b9486ebece71be175327bc",
            }
        ],
    }


def buying(fake, *, code=LIBYANA_5, cost=4.85, checkout=None, pin=False, quick=False):
    """A basket that takes one card and hands it over at checkout."""
    fake.on("POST", qareeb_driver.CART_PATH, _Resp(200, CART_ADDED))
    fake.on("GET", qareeb_driver.CART_PATH, _Resp(200, cart((code, 1, cost), pin=pin, quick=quick)))
    fake.on("POST", qareeb_driver.CHECKOUT_PATH, checkout or _Resp(200, checkout_ok(code)))
    fake.on("GET", qareeb_driver.ACCOUNT_PATH, _Resp(200, ACCOUNT_INFO))
    return fake


# --- the catalog entry ----------------------------------------------------------------
class QareebCatalogTests(TestCase):
    def test_qareeb_is_connectable_and_has_no_till_lookup(self):
        spec = catalog.QAREEB
        self.assertTrue(spec.is_available)
        self.assertNotIn(catalog.CAPABILITY_LOOKUP, spec.capabilities)
        self.assertIn(catalog.CAPABILITY_VOUCHERS, spec.capabilities)
        self.assertIn(catalog.CAPABILITY_PROFILES, spec.capabilities)

    def test_the_purchase_pin_is_optional(self):
        account = IntegrationAccount.objects.create(provider="qareeb", username="0912345678")
        account.set_secret(catalog.FIELD_PASSWORD, "pw")
        account.save()
        self.assertTrue(account.is_configured)


# --- logging in -----------------------------------------------------------------------
class QareebLoginTests(TestCase):
    def test_a_login_is_kept_encrypted_and_reused(self):
        account = qareeb_account()
        token = _jwt()
        fake = _FakeQareeb()
        fake.on("POST", qareeb_driver.LOGIN_PATH, _Resp(200, {"status": True, "access": token, "refresh": "r"}))
        fake.on("GET", qareeb_driver.ACCOUNT_PATH, _Resp(200, ACCOUNT_INFO))
        with patch_qareeb(fake):
            first = provider_for(account).probe()
            account.refresh_from_db()
            second = provider_for(account).probe()
        self.assertTrue(first.ok and second.ok)
        self.assertEqual(first.balance, Decimal("674.90"))
        self.assertEqual(first.account_label, "النسيم")
        self.assertEqual(fake.paths("POST").count(qareeb_driver.LOGIN_PATH), 1)
        self.assertNotIn(token, account.secrets_encrypted)
        self.assertEqual(account.get_secret(qareeb_driver.SECRET_ACCESS), token)
        # The login carries this device's identity, minted once and kept.
        login = fake.calls[0]
        self.assertEqual(login["json"]["username"], "0912345678")
        self.assertEqual(login["json"]["fcm_token"], "")
        self.assertEqual(login["headers"]["x-device-model"], "iPhone")
        self.assertEqual(
            login["headers"]["x-device-uuid"], account.config[qareeb_driver.CONFIG_DEVICE_UUID]
        )
        self.assertEqual(
            fake.calls[-1]["headers"]["x-device-uuid"], login["headers"]["x-device-uuid"]
        )

    def test_a_new_device_is_sent_to_verification_not_called_a_bad_password(self):
        account = qareeb_account()
        fake = _FakeQareeb().on(
            "POST",
            qareeb_driver.LOGIN_PATH,
            _Resp(400, {"error": "جهاز جديد: الرجاء تسجيل الدخول بكلمة مرور مؤقتة (OTP)"}),
        )
        with patch_qareeb(fake):
            result = provider_for(account).probe()
        self.assertEqual(result.error_code, ERROR_DEVICE_VERIFICATION)

    def test_an_app_check_demand_is_named_for_what_it_is(self):
        account = qareeb_account()
        fake = _FakeQareeb().on(
            "POST",
            qareeb_driver.LOGIN_PATH,
            _Resp(401, {"detail": "Firebase App Check token is missing"}),
        )
        with patch_qareeb(fake):
            result = provider_for(account).probe()
        self.assertEqual(result.error_code, ERROR_ATTESTATION_REQUIRED)

    def test_an_expired_token_is_replaced_before_it_is_sent(self):
        account = logged_in(qareeb_account(), token=_jwt(expires_in=-10))
        fresh = _jwt()
        fake = _FakeQareeb()
        fake.on("POST", qareeb_driver.LOGIN_PATH, _Resp(200, {"access": fresh, "refresh": "r"}))
        fake.on("GET", qareeb_driver.ACCOUNT_PATH, _Resp(200, ACCOUNT_INFO))
        with patch_qareeb(fake):
            self.assertTrue(provider_for(account).probe().ok)
        self.assertEqual(fake.calls[-1]["headers"]["authorization"], f"Bearer {fresh}")

    def test_a_refused_token_logs_in_again_exactly_once(self):
        account = logged_in(qareeb_account())
        fake = _FakeQareeb()
        fake.on("GET", qareeb_driver.ACCOUNT_PATH, _Resp(401, {"detail": "token not valid"}), _Resp(200, ACCOUNT_INFO))
        fake.on("POST", qareeb_driver.LOGIN_PATH, _Resp(200, {"access": _jwt(), "refresh": "r"}))
        with patch_qareeb(fake):
            self.assertTrue(provider_for(account).probe().ok)
        self.assertEqual(fake.paths("POST").count(qareeb_driver.LOGIN_PATH), 1)


# --- the shelf --------------------------------------------------------------------------
class QareebShelfReadTests(TestCase):
    def test_the_listing_spells_out_one_category_and_skips_transfers(self):
        account = logged_in(qareeb_account())
        fake = _FakeQareeb().on("GET", qareeb_driver.CATALOG_PATH, _Resp(200, LISTING))
        with patch_qareeb(fake):
            result = provider_for(account).voucher_catalog()
        self.assertTrue(result.ok)
        by_code = {brand.code: brand for brand in result.brands}
        self.assertEqual(set(by_code), {"30", "31", "115"})
        self.assertTrue(by_code["30"].items_known)
        self.assertFalse(by_code["115"].items_known)
        libyana = {item.code: item for item in by_code["30"].items}
        self.assertEqual(libyana[LIBYANA_5].cost, Decimal("4.85"))
        self.assertEqual(libyana[LIBYANA_5].suggested_price, Decimal("5.00"))
        self.assertEqual(by_code["115"].currency, "USD")

    def test_a_collapsed_brand_is_read_on_its_own(self):
        account = logged_in(qareeb_account())
        fake = _FakeQareeb().on("GET", "/api/store/v1/get_product_price/115/", _Resp(200, PSN_BRAND))
        with patch_qareeb(fake):
            result = provider_for(account).voucher_brand("115")
        brand = result.brands[0]
        self.assertTrue(brand.items_known)
        self.assertEqual({item.code for item in brand.items}, {PSN_25, PSN_50})
        # Dinars, whatever is printed on the card.
        self.assertEqual({item.cost for item in brand.items}, {Decimal("237.65"), Decimal("474.33")})


# --- buying one card ------------------------------------------------------------------------
class QareebPurchaseTests(TestCase):
    def setUp(self):
        self.account = logged_in(qareeb_account())

    def buy(self, fake, *, expected_cost=Decimal("4.85")):
        with patch_qareeb(fake):
            return provider_for(self.account).recharge("", LIBYANA_5, expected_cost=expected_cost)

    def test_one_card_is_bought_and_its_pin_comes_back_for_the_receipt(self):
        fake = buying(_FakeQareeb())
        result = self.buy(fake)
        self.assertTrue(result.ok, result)
        self.assertEqual(result.reference, "dc94d6b1-6861-492e-9951-ee9314d56dac")
        printed = result.receipt["printed"]
        self.assertEqual(printed["code"], "1111222233334")
        self.assertEqual(printed["serial"], "123456789012345")
        self.assertEqual(printed["instructions"], "# الرقم السري * 120 *")
        self.assertEqual(result.balance_after, Decimal("674.90"))
        checkout = [c for c in fake.calls if c["path"] == qareeb_driver.CHECKOUT_PATH][0]
        # The hash is the one the basket was read back with, never invented.
        self.assertEqual(checkout["json"], {"hash": "h" * 64, "pin": None, "profile": None})
        added = [c for c in fake.calls if c["path"] == qareeb_driver.CART_PATH and c["method"] == "POST"]
        self.assertEqual(added[0]["json"], {"product": LIBYANA_5, "quantity": 1})

    def test_somebody_elses_cards_are_taken_out_before_checkout(self):
        fake = _FakeQareeb()
        fake.on("POST", qareeb_driver.CART_PATH, _Resp(200, CART_ADDED))
        fake.on(
            "GET",
            qareeb_driver.CART_PATH,
            _Resp(200, cart((FOREIGN, 2, 9.7), (LIBYANA_5, 1, 4.85))),
            _Resp(200, cart((LIBYANA_5, 1, 4.85))),
        )
        fake.on("POST", qareeb_driver.CHECKOUT_PATH, _Resp(200, checkout_ok()))
        fake.on("GET", qareeb_driver.ACCOUNT_PATH, _Resp(200, ACCOUNT_INFO))
        self.assertTrue(self.buy(fake).ok)
        removed = [
            c["json"] for c in fake.calls
            if c["path"] == qareeb_driver.CART_PATH and c["method"] == "POST"
        ]
        self.assertIn({"product": FOREIGN, "quantity": 0}, removed)

    def test_a_moved_price_is_refused_before_anything_is_bought(self):
        fake = _FakeQareeb()
        fake.on("POST", qareeb_driver.CART_PATH, _Resp(200, CART_ADDED))
        fake.on("GET", qareeb_driver.CART_PATH, _Resp(200, cart((LIBYANA_5, 1, 5.10))))
        result = self.buy(fake)
        self.assertTrue(result.is_definite_failure)
        self.assertNotIn(qareeb_driver.CHECKOUT_PATH, fake.paths())
        # And the card is taken back out, leaving the basket as it found it.
        self.assertIn(
            {"product": LIBYANA_5, "quantity": 0},
            [c["json"] for c in fake.calls if c["method"] == "POST"],
        )

    def test_the_pin_is_sent_only_when_the_basket_asks_for_it(self):
        self.account.set_secret(catalog.FIELD_PIN, "4321")
        self.account.save()
        fake = buying(_FakeQareeb(), pin=True)
        self.assertTrue(self.buy(fake).ok)
        checkout = [c for c in fake.calls if c["path"] == qareeb_driver.CHECKOUT_PATH][0]
        self.assertEqual(checkout["json"]["pin"], "4321")

    def test_a_pin_the_account_needs_and_we_lack_is_refused_not_guessed(self):
        fake = buying(_FakeQareeb(), pin=True)
        result = self.buy(fake)
        self.assertEqual(result.error_code, ERROR_PIN_REQUIRED)
        self.assertNotIn(qareeb_driver.CHECKOUT_PATH, fake.paths())

    def test_an_empty_float_is_a_definite_refusal(self):
        fake = buying(
            _FakeQareeb(),
            checkout=_Resp(400, {"error": "رصيدك غير كاف لإتمام العملية"}),
        )
        result = self.buy(fake)
        self.assertEqual(result.error_code, ERROR_INSUFFICIENT_FLOAT)
        self.assertFalse(result.indeterminate)

    def test_a_sold_out_card_says_so(self):
        fake = _FakeQareeb().on(
            "POST", qareeb_driver.CART_PATH, _Resp(400, {"error": "المنتج غير متوفر حالياً"})
        )
        self.assertEqual(self.buy(fake).error_code, ERROR_OUT_OF_STOCK)

    def test_a_checkout_whose_answer_never_came_is_unknown(self):
        fake = buying(_FakeQareeb(), checkout=requests.ReadTimeout("read timed out"))
        result = self.buy(fake)
        self.assertTrue(result.indeterminate)
        self.assertEqual(result.error_code, ERROR_INDETERMINATE)

    def test_a_server_error_at_checkout_is_unknown(self):
        fake = buying(_FakeQareeb(), checkout=_Resp(502, {"detail": "bad gateway"}))
        self.assertTrue(self.buy(fake).indeterminate)

    def test_a_success_with_no_card_in_it_is_unknown(self):
        fake = buying(
            _FakeQareeb(),
            checkout=_Resp(200, {"detail": "Success", "status": True, "order_reference": "x", "result": []}),
        )
        self.assertTrue(self.buy(fake).indeterminate)

    def test_a_connection_that_never_opened_bought_nothing(self):
        fake = buying(_FakeQareeb(), checkout=requests.ConnectTimeout("connect timed out"))
        result = self.buy(fake)
        self.assertTrue(result.is_definite_failure)
        self.assertEqual(result.error_code, ERROR_UNREACHABLE)

    def test_a_basket_another_till_holds_is_waited_for_then_refused(self):
        fake = buying(_FakeQareeb())
        with mock.patch.object(qareeb_driver, "CART_LOCK_WAIT_SECONDS", 0.2), mock.patch(
            "apps.integrations.providers.qareeb.cache.add", return_value=False
        ):
            with patch_qareeb(fake):
                result = provider_for(self.account).recharge("", LIBYANA_5, expected_cost=None)
        self.assertEqual(result.error_code, ERROR_BUSY)
        self.assertEqual(fake.calls, [])


class QareebProfileTests(TestCase):
    def test_profiles_name_each_identity_and_the_current_one(self):
        account = logged_in(qareeb_account())
        fake = _FakeQareeb().on("GET", qareeb_driver.PROFILES_PATH, _Resp(200, PROFILES))
        with patch_qareeb(fake):
            result = provider_for(account).profiles()
        by_id = {profile.profile_id: profile for profile in result.profiles}
        self.assertEqual(by_id[STORE_PROFILE].name, "النسيم")
        self.assertTrue(by_id[STORE_PROFILE].is_current)
        self.assertEqual(by_id[PERSONAL_PROFILE].kind, "individual")

    def test_a_purchase_switches_the_session_to_the_chosen_profile(self):
        # PERSONAL is chosen but STORE is the active one, so the driver switches
        # the session to PERSONAL and then buys. The session is now on the right
        # profile, so checkout carries profile: null exactly as the app does.
        account = logged_in(qareeb_account(profile_id=PERSONAL_PROFILE))
        fake = buying(_FakeQareeb())
        fake.on("GET", qareeb_driver.PROFILES_PATH, _Resp(200, PROFILES))
        fake.on("POST", qareeb_driver.SWITCH_PROFILE_PATH, switch_ok(PERSONAL_PROFILE))
        with patch_qareeb(fake):
            result = provider_for(account).recharge("", LIBYANA_5, expected_cost=None)
        self.assertTrue(result.ok)
        switched = [c for c in fake.calls if c["path"] == qareeb_driver.SWITCH_PROFILE_PATH]
        self.assertEqual(switched[0]["json"], {"profile_id": PERSONAL_PROFILE})
        checkout = [c for c in fake.calls if c["path"] == qareeb_driver.CHECKOUT_PATH][0]
        self.assertIsNone(checkout["json"]["profile"])

    def test_the_chosen_profile_already_active_needs_no_switch(self):
        # STORE is chosen and already active: nothing to switch, checkout null.
        account = logged_in(qareeb_account(profile_id=STORE_PROFILE))
        fake = buying(_FakeQareeb())
        fake.on("GET", qareeb_driver.PROFILES_PATH, _Resp(200, PROFILES))
        with patch_qareeb(fake):
            self.assertTrue(provider_for(account).recharge("", LIBYANA_5, expected_cost=None).ok)
        self.assertNotIn(qareeb_driver.SWITCH_PROFILE_PATH, fake.paths())
        checkout = [c for c in fake.calls if c["path"] == qareeb_driver.CHECKOUT_PATH][0]
        self.assertIsNone(checkout["json"]["profile"])

    def test_quick_switch_names_the_profile_when_the_session_switch_fails(self):
        # The provider refuses the session switch, but this basket allows a
        # per-checkout override, so checkout names the chosen profile instead of
        # refusing the sale — the fallback the older driver relied on alone.
        account = logged_in(qareeb_account(profile_id=PERSONAL_PROFILE))
        fake = buying(_FakeQareeb(), quick=True)
        fake.on("GET", qareeb_driver.PROFILES_PATH, _Resp(200, PROFILES))
        fake.on("POST", qareeb_driver.SWITCH_PROFILE_PATH,
                _Resp(400, {"error": "تعذّر تبديل الحساب"}))
        with patch_qareeb(fake):
            self.assertTrue(provider_for(account).recharge("", LIBYANA_5, expected_cost=None).ok)
        checkout = [c for c in fake.calls if c["path"] == qareeb_driver.CHECKOUT_PATH][0]
        self.assertEqual(checkout["json"]["profile"], PERSONAL_PROFILE)

    def test_a_purchase_refuses_when_the_chosen_profile_is_gone(self):
        # The chosen profile is not one of the login's at all: it cannot be
        # switched to and cannot be named, so the sale is refused rather than
        # paid from whatever wallet the login happens to be on.
        account = logged_in(qareeb_account(profile_id="ghost-profile"))
        fake = buying(_FakeQareeb(), quick=True)
        fake.on("GET", qareeb_driver.PROFILES_PATH, _Resp(200, PROFILES))
        with patch_qareeb(fake):
            result = provider_for(account).recharge("", LIBYANA_5, expected_cost=None)
        self.assertEqual(result.error_code, ERROR_PROFILE_MISMATCH)
        self.assertNotIn(qareeb_driver.CHECKOUT_PATH, fake.paths())
        self.assertNotIn(qareeb_driver.SWITCH_PROFILE_PATH, fake.paths())

    def test_a_probe_switches_to_the_chosen_profile_then_reads_its_balance(self):
        account = logged_in(qareeb_account(profile_id=PERSONAL_PROFILE))
        fake = _FakeQareeb()
        fake.on("GET", qareeb_driver.ACCOUNT_PATH, _Resp(200, ACCOUNT_INFO))
        fake.on("GET", qareeb_driver.PROFILES_PATH, _Resp(200, PROFILES))
        fake.on("POST", qareeb_driver.SWITCH_PROFILE_PATH, switch_ok(PERSONAL_PROFILE))
        with patch_qareeb(fake):
            result = provider_for(account).probe()
        self.assertTrue(result.ok)
        self.assertEqual(result.balance, Decimal("674.90"))
        self.assertIn(qareeb_driver.SWITCH_PROFILE_PATH, fake.paths())

    def test_a_probe_refuses_when_the_chosen_profile_is_gone(self):
        account = logged_in(qareeb_account(profile_id="ghost-profile"))
        fake = _FakeQareeb()
        fake.on("GET", qareeb_driver.PROFILES_PATH, _Resp(200, PROFILES))
        with patch_qareeb(fake):
            result = provider_for(account).probe()
        self.assertEqual(result.error_code, ERROR_PROFILE_MISMATCH)
        self.assertIsNone(result.balance)


class QareebVerificationTests(TestCase):
    def test_picture_then_code_then_a_trusted_device(self):
        account = qareeb_account()
        token = _jwt()
        fake = _FakeQareeb()
        fake.on("GET", qareeb_driver.CAPTCHA_PATH, _Resp(200, {
            "status": True,
            "field": {"hashkey": "ref-1", "image_url": "/captcha/image/ref-1/", "help_text": "اكتب الحروف"},
        }))
        fake.on("GET", "/captcha/image/ref-1/", _Resp(200, None, content=b"\x89PNG-bytes", content_type="image/png"))
        fake.on("POST", qareeb_driver.SEND_CODE_PATH, _Resp(200, {
            "status": True, "results": {"phone": "0912345678", "uuid": "otp-session", "expires_in": 5},
        }))
        # verify_otp proves the phone and answers a one-time temp_token — no
        # session yet; the driver must spend it at login_with_otp for tokens.
        fake.on("POST", qareeb_driver.VERIFY_CODE_PATH, _Resp(200, {
            "status": True, "detail": "OTP verified successfully.", "temp_token": "tmp-1234",
        }))
        fake.on("POST", qareeb_driver.LOGIN_WITH_OTP_PATH, _Resp(200, {"access": token, "refresh": "r"}))
        with patch_qareeb(fake):
            driver = provider_for(account)
            challenge = driver.start_verification()
            sent = driver.send_verification_code(challenge.challenge_ref, "ab12cd")
            confirmed = driver.confirm_verification("1234")
        self.assertEqual(challenge.image, b"\x89PNG-bytes")
        self.assertEqual(sent.expires_in, 5)
        self.assertTrue(confirmed.ok)
        send = [c for c in fake.calls if c["path"] == qareeb_driver.SEND_CODE_PATH][0]
        self.assertEqual(
            send["json"],
            {"phone": "0912345678", "action": "login", "captcha": "ab12cd", "captcha_ref": "ref-1"},
        )
        verify = [c for c in fake.calls if c["path"] == qareeb_driver.VERIFY_CODE_PATH][0]
        self.assertEqual(verify["json"]["uuid"], "otp-session")
        # The temp_token from verify_otp is spent, by phone, at login_with_otp.
        exchange = [c for c in fake.calls if c["path"] == qareeb_driver.LOGIN_WITH_OTP_PATH][0]
        self.assertEqual(exchange["json"], {"username": "0912345678", "temp_token": "tmp-1234"})
        account.refresh_from_db()
        self.assertEqual(account.get_secret(qareeb_driver.SECRET_ACCESS), token)
        self.assertEqual(account.get_secret(qareeb_driver.SECRET_VERIFICATION), "")

    def test_a_wrong_code_is_rejected_plainly(self):
        account = qareeb_account()
        account.set_secret(qareeb_driver.SECRET_VERIFICATION, "otp-session")
        account.save()
        fake = _FakeQareeb().on(
            "POST", qareeb_driver.VERIFY_CODE_PATH, _Resp(400, {"error": "رمز التحقق غير صحيح"})
        )
        with patch_qareeb(fake):
            result = provider_for(account).confirm_verification("0000")
        self.assertEqual(result.error_code, ERROR_VERIFICATION_REJECTED)

    def test_a_temp_token_is_spent_for_real_tokens(self):
        account = qareeb_account()
        account.set_secret(qareeb_driver.SECRET_VERIFICATION, "otp-session")
        account.save()
        token = _jwt()
        fake = _FakeQareeb()
        fake.on("POST", qareeb_driver.VERIFY_CODE_PATH, _Resp(200, {
            "status": True, "detail": "OTP verified successfully.", "temp_token": "tmp-9",
        }))
        fake.on("POST", qareeb_driver.LOGIN_WITH_OTP_PATH, _Resp(200, {"access": token, "refresh": "r2"}))
        with patch_qareeb(fake):
            self.assertTrue(provider_for(account).confirm_verification("1234").ok)
        account.refresh_from_db()
        self.assertEqual(account.get_secret(qareeb_driver.SECRET_ACCESS), token)
        self.assertEqual(account.get_secret(qareeb_driver.SECRET_REFRESH), "r2")
        self.assertEqual(account.get_secret(qareeb_driver.SECRET_VERIFICATION), "")

    def test_a_rejected_temp_token_exchange_is_reported(self):
        account = qareeb_account()
        account.set_secret(qareeb_driver.SECRET_VERIFICATION, "otp-session")
        account.save()
        fake = _FakeQareeb()
        fake.on("POST", qareeb_driver.VERIFY_CODE_PATH, _Resp(200, {
            "status": True, "detail": "OTP verified successfully.", "temp_token": "tmp-9",
        }))
        fake.on("POST", qareeb_driver.LOGIN_WITH_OTP_PATH, _Resp(400, {"error": "expired"}))
        with patch_qareeb(fake):
            result = provider_for(account).confirm_verification("1234")
        self.assertFalse(result.ok)
        self.assertEqual(result.error_code, ERROR_VERIFICATION_REJECTED)

    def test_a_confirmation_with_neither_token_nor_handle_is_unexpected(self):
        # A success body with no token and no temp_token cannot enrol the
        # device; the driver must not loop back into a "new device" login.
        account = qareeb_account()
        account.set_secret(qareeb_driver.SECRET_VERIFICATION, "otp-session")
        account.save()
        fake = _FakeQareeb()
        fake.on("POST", qareeb_driver.VERIFY_CODE_PATH, _Resp(200, {"status": True}))
        with patch_qareeb(fake):
            result = provider_for(account).confirm_verification("1234")
        self.assertFalse(result.ok)
        self.assertEqual(result.error_code, ERROR_UNEXPECTED)
        self.assertEqual(fake.paths("POST").count(qareeb_driver.LOGIN_PATH), 0)


class QareebHistoryTests(TestCase):
    def test_the_log_reads_as_purchases_with_their_pins(self):
        account = logged_in(qareeb_account())
        page = {
            "page": 1, "total_results": 1, "total_pages": 1, "success": True,
            "results": [{
                "voucher_id": "v-1", "mno_type__code": "30", "SN": "999",
                "product": "5 دينار", "purchase_date": "2026-09-23T14:57:59.574970",
                "status": "sent", "purchase_price": "5.000", "mno_type__name": "Libyana",
                "code": "5555", "cost": "4.850", "purchase_user": "0912345678",
                "instructions_print": "# الرقم السري * 120 *",
            }],
        }
        fake = _FakeQareeb().on("GET", qareeb_driver.VOUCHERS_PATH, _Resp(200, page))
        with patch_qareeb(fake):
            result = provider_for(account).purchase_history("", limit=25)
        entry = result.purchases[0]
        self.assertEqual(entry.reference, "v-1")
        self.assertEqual(entry.cost, Decimal("4.85"))
        self.assertEqual(entry.package_id, "30")
        self.assertTrue(entry.is_ours)
        self.assertEqual(entry.printed["code"], "5555")
        # Libyan wall clock → UTC.
        self.assertEqual(entry.at.isoformat(), "2026-09-23T12:57:59.574970+00:00")
        # One page that is the whole log proves everything since the beginning.
        self.assertTrue(result.covers(timezone.now() - timedelta(days=3650)))


# --- the shelf in the catalog ------------------------------------------------------------------
class _StubDriver:
    def __init__(self, listing=None, brands=None):
        self.listing = listing
        self.brands = brands or {}
        self.may_login = True
        self.brand_reads = []

    def voucher_catalog(self):
        return self.listing

    def voucher_brand(self, code):
        self.brand_reads.append(code)
        brand = self.brands.get(code)
        if brand is None:
            return VoucherCatalogResult(ok=False, error_code="provider_error")
        return VoucherCatalogResult(ok=True, brands=(brand,))


def _item(code, label, cost, price):
    return VoucherItem(code=code, label=label, cost=Decimal(cost), suggested_price=Decimal(price))


def _listing(*, libyana=None, almadar=True):
    libyana = libyana if libyana is not None else (
        _item(LIBYANA_10, "10 دينار", "9.70", "10.00"),
        _item(LIBYANA_5, "5 دينار", "4.85", "5.00"),
    )
    brands = [
        VoucherBrand(code="30", name="ليبيانا", name_en="Libyana", category="الاتصالات",
                     items=tuple(libyana), items_known=True),
        VoucherBrand(code="115", name="امريكي بلاي ستيشن", name_en="PSN USA",
                     category="الدولية", currency="USD", items_known=False),
    ]
    if almadar:
        brands.append(
            VoucherBrand(code="31", name="المدار", name_en="Almadar", category="الاتصالات",
                         items=(_item(ALMADAR_10, "10 دينار", "9.70", "10.00"),), items_known=True)
        )
    return VoucherCatalogResult(ok=True, brands=tuple(brands))


PSN = VoucherBrand(
    code="115", name="امريكي بلاي ستيشن", name_en="PSN USA", currency="USD",
    items=(_item(PSN_25, "25$ PSN USA", "237.65", "245.00"),), items_known=True,
)


def sync(account, driver, **kwargs):
    with mock.patch("apps.integrations.vouchers.provider_for", return_value=driver):
        return vouchers.sync_account(account, **kwargs)


class VoucherShelfSyncTests(TestCase):
    def setUp(self):
        self.account = logged_in(qareeb_account())

    def test_each_brand_becomes_a_locked_product_with_a_variant_per_card(self):
        report = sync(self.account, _StubDriver(_listing(), {"115": PSN}))
        self.assertTrue(report.ok)
        libyana = IntegrationVoucherBrand.objects.get(code="30").product
        self.assertTrue(libyana.is_system)
        self.assertEqual(libyana.system_kind, Product.SystemKind.VOUCHER)
        self.assertTrue(libyana.is_service)
        self.assertEqual(libyana.name, "ليبيانا")
        variants = {v.name: v for v in libyana.variants.all()}
        self.assertEqual(variants["10 دينار"].unit_price, Decimal("10.00"))
        # The cheapest card is the default, so the tile shows what it starts at.
        self.assertTrue(variants["5 دينار"].is_default)
        self.assertFalse(variants["10 دينار"].is_default)
        self.assertTrue(variants["5 دينار"].sku.startswith("QRB-"))
        # "libyana" typed in Latin finds «ليبيانا».
        self.assertTrue(ProductAlias.objects.filter(product=libyana, alias="Libyana").exists())
        # A collapsed brand is read on its own and sold at the provider's price.
        psn = IntegrationVoucherBrand.objects.get(code="115").product
        self.assertEqual(psn.variants.get().unit_price, Decimal("245.00"))

    def test_an_unchanged_shelf_writes_nothing(self):
        driver = _StubDriver(_listing(), {"115": PSN})
        sync(self.account, driver)
        again = sync(self.account, driver)
        self.assertEqual(again.changed, 0)

    def test_a_sold_out_card_and_a_vanished_brand_leave_the_till(self):
        sync(self.account, _StubDriver(_listing(), {"115": PSN}))
        only_ten = (_item(LIBYANA_10, "10 دينار", "9.70", "10.00"),)
        sync(self.account, _StubDriver(_listing(libyana=only_ten, almadar=False)))
        five = IntegrationVoucher.objects.get(code=LIBYANA_5)
        self.assertFalse(five.is_available)
        self.assertFalse(five.variant.is_active)
        almadar = IntegrationVoucherBrand.objects.get(code="31")
        self.assertFalse(almadar.is_listed)
        self.assertFalse(almadar.product.is_active)
        # The default moves to the cheapest card still on sale.
        ten = IntegrationVoucher.objects.get(code=LIBYANA_10).variant
        self.assertTrue(ten.is_default)

    def test_a_brand_nobody_asked_about_keeps_what_it_knew(self):
        sync(self.account, _StubDriver(_listing(), {"115": PSN}))
        # Next sweep: the PSN read fails. Unasked is not sold out.
        sync(self.account, _StubDriver(_listing()), refresh_limit=0)
        self.assertTrue(IntegrationVoucher.objects.get(code=PSN_25).variant.is_active)

    def test_a_price_the_provider_moved_moves_the_variant(self):
        sync(self.account, _StubDriver(_listing(), {"115": PSN}))
        dearer = (
            _item(LIBYANA_10, "10 دينار", "9.70", "10.50"),
            _item(LIBYANA_5, "5 دينار", "4.85", "5.00"),
        )
        sync(self.account, _StubDriver(_listing(libyana=dearer)), refresh_limit=0)
        self.assertEqual(
            IntegrationVoucher.objects.get(code=LIBYANA_10).variant.unit_price, Decimal("10.50")
        )

    def test_a_provider_unreadable_for_too_long_takes_its_shelf_down(self):
        sync(self.account, _StubDriver(_listing(), {"115": PSN}))
        self.account.refresh_from_db()
        config = dict(self.account.config)
        config[vouchers.CONFIG_LISTED_AT] = (timezone.now() - timedelta(hours=2)).isoformat()
        IntegrationAccount.objects.filter(pk=self.account.pk).update(config=config)
        self.account.refresh_from_db()
        failing = _StubDriver(VoucherCatalogResult(ok=False, error_code="unreachable"))
        sync(self.account, failing)
        self.assertFalse(
            Product.objects.filter(system_kind=Product.SystemKind.VOUCHER, is_active=True).exists()
        )


# --- selling it --------------------------------------------------------------------------------
class VoucherSaleTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.account = logged_in(qareeb_account())
        sync(self.account, _StubDriver(_listing(), {"115": PSN}))
        self.user = get_user_model().objects.create_user(username="till", password="x")
        self.user.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.register = RegisterSession.objects.create(owner=self.user, owner_key=f"user:{self.user.pk}")
        self.client = APIClient()
        self.client.force_authenticate(self.user)
        self.five = IntegrationVoucher.objects.get(code=LIBYANA_5).variant

    def checkout(self, *, quantity="1", sale_type=None, variant=None):
        body = {
            "register_session": self.register.pk,
            "lines": [{"variant": (variant or self.five).pk, "quantity": quantity}],
            "payment_method": "cash",
        }
        if sale_type:
            body["sale_type"] = sale_type
        return self.client.post("/api/orders/checkout/", body, format="json")

    def test_a_card_sold_from_the_catalog_carries_its_purchase(self):
        response = self.checkout()
        self.assertEqual(response.status_code, 201, response.data)
        line = Order.objects.get(pk=response.data["id"]).lines.get()
        self.assertEqual(line.unit_price, Decimal("5.00"))
        self.assertEqual(line.unit_cost, Decimal("4.85"))
        fulfillment = line.integration_fulfillment
        self.assertEqual(fulfillment.provider, "qareeb")
        self.assertEqual(fulfillment.option_code, LIBYANA_5)
        self.assertEqual(fulfillment.subscriber_ref, "")
        self.assertEqual(fulfillment.package_id, "30")
        self.assertEqual(fulfillment.status, IntegrationFulfillment.Status.PENDING)
        self.assertEqual(response.data["lines"][0]["integration"]["provider"], "qareeb")

    def test_a_card_previews_at_its_price_with_nothing_from_the_till(self):
        # A system product like a top-up's, but its payload is built from the
        # variant server-side — so the preview's refusal of a top-up that
        # arrived without its details must not catch it.
        response = self.client.post(
            "/api/orders/discount-preview/",
            {"lines": [{"variant": self.five.pk, "quantity": "1"}]},
            format="json",
        )
        self.assertEqual(response.status_code, 200, response.data)
        self.assertEqual(response.data["total"], "5.00")

    def test_a_card_is_sold_one_to_a_line(self):
        response = self.checkout(quantity="2")
        self.assertEqual(response.status_code, 400)
        self.assertFalse(Order.objects.exists())

    def test_a_card_the_provider_ran_out_of_is_not_sold(self):
        IntegrationVoucher.objects.filter(code=LIBYANA_5).update(is_available=False)
        response = self.checkout()
        self.assertEqual(response.status_code, 400)
        self.assertFalse(Order.objects.exists())

    def test_a_quotation_cannot_carry_a_card(self):
        response = self.checkout(sale_type="quotation")
        self.assertEqual(response.status_code, 400)

    def test_the_till_lists_cards_but_not_the_recharge_service_products(self):
        from .provisioning import service_variant_for

        service = service_variant_for("hdbox").product
        libyana = IntegrationVoucherBrand.objects.get(code="30").product
        manager = get_user_model().objects.create_user(username="mgr", password="x")
        manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client.force_authenticate(manager)

        def ids(query):
            response = self.client.get(f"/api/products/{query}")
            return {row["id"] for row in response.data["results"]}

        self.assertNotIn(libyana.pk, ids(""))
        self.assertIn(libyana.pk, ids("?system=sellable"))
        self.assertNotIn(service.pk, ids("?system=sellable"))
        self.assertIn(service.pk, ids("?system=all"))
        self.assertIn(libyana.pk, ids("?system=sellable&search=libyana"))


class VoucherChargeTests(TransactionTestCase):
    reset_sequences = True

    def setUp(self):
        ensure_role_groups()
        self.account = logged_in(qareeb_account())
        sync(self.account, _StubDriver(_listing(), {"115": PSN}))
        self.user = get_user_model().objects.create_user(username="till", password="x")
        self.user.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.register = RegisterSession.objects.create(owner=self.user, owner_key=f"user:{self.user.pk}")
        self.client = APIClient()
        self.client.force_authenticate(self.user)
        variant = IntegrationVoucher.objects.get(code=LIBYANA_5).variant
        response = self.client.post(
            "/api/orders/checkout/",
            {"register_session": self.register.pk,
             "lines": [{"variant": variant.pk, "quantity": "1"}],
             "payment_method": "cash"},
            format="json",
        )
        self.order = Order.objects.get(pk=response.data["id"])

    def test_the_sale_buys_the_card_and_the_receipt_prints_its_pin(self):
        with patch_qareeb(buying(_FakeQareeb())):
            response = self.client.post(
                "/api/integrations/fulfillments/charge/", {"order": self.order.pk}, format="json"
            )
        result = response.data["results"][0]
        self.assertEqual(result["outcome"], recharge.OUTCOME_CHARGED)
        self.assertEqual(result["kind"], "voucher")
        self.assertEqual(result["receipt"]["code"], "1111222233334")
        payload = build_receipt_payload(self.order)
        integration = payload["order"]["lines"][0]["integration"]
        self.assertEqual(integration["kind"], "voucher")
        self.assertEqual(integration["status"], "confirmed")
        self.assertEqual(integration["printed"]["serial"], "123456789012345")

    def test_a_lost_answer_is_settled_from_the_log_with_its_pin(self):
        with patch_qareeb(buying(_FakeQareeb(), checkout=requests.ReadTimeout("lost"))):
            self.client.post(
                "/api/integrations/fulfillments/charge/", {"order": self.order.pk}, format="json"
            )
        row = IntegrationFulfillment.objects.get()
        self.assertEqual(row.status, IntegrationFulfillment.Status.SUBMITTED)
        bought_at = timezone.localtime(row.submitted_at, qareeb_driver.business_timezone())
        page = {
            "page": 1, "total_results": 2, "total_pages": 1,
            "results": [
                # The owner's phone bought the same card an hour earlier: not ours.
                {"voucher_id": "earlier", "mno_type__code": "30", "SN": "1", "code": "0000",
                 "product": "5 دينار", "status": "sent", "cost": "4.850",
                 "purchase_date": (bought_at - timedelta(hours=1)).replace(tzinfo=None).isoformat(),
                 "purchase_user": "0912345678"},
                {"voucher_id": "ours", "mno_type__code": "30", "SN": "2", "code": "7777",
                 "product": "5 دينار", "status": "sent", "cost": "4.850",
                 "purchase_date": (bought_at + timedelta(seconds=3)).replace(tzinfo=None).isoformat(),
                 "purchase_user": "0912345678"},
            ],
        }
        fake = _FakeQareeb()
        fake.on("GET", qareeb_driver.VOUCHERS_PATH, _Resp(200, page))
        fake.on("GET", qareeb_driver.ACCOUNT_PATH, _Resp(200, ACCOUNT_INFO))
        with patch_qareeb(fake):
            reconcile_account(self.account)
        row.refresh_from_db()
        self.assertEqual(row.status, IntegrationFulfillment.Status.CONFIRMED)
        self.assertEqual(row.provider_reference, "ours")
        self.assertEqual(row.provider_receipt["printed"]["code"], "7777")


# --- the lock -------------------------------------------------------------------------------------
class SystemProductLockTests(TestCase):
    """Nobody edits a system product — managers included."""

    def setUp(self):
        ensure_role_groups()
        self.account = logged_in(qareeb_account())
        sync(self.account, _StubDriver(_listing(), {"115": PSN}))
        self.product = IntegrationVoucherBrand.objects.get(code="30").product
        manager = get_user_model().objects.create_user(username="mgr", password="x")
        manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client = APIClient()
        self.client.force_authenticate(manager)

    def assertLocked(self, response):
        self.assertEqual(response.status_code, 403, getattr(response, "data", None))
        self.assertEqual(response.data["code"], "system_product")

    def test_no_detail_write_reaches_it(self):
        url = f"/api/products/{self.product.pk}/"
        self.assertLocked(self.client.patch(url, {"name": "غيره"}, format="json"))
        self.assertLocked(self.client.delete(url))
        self.assertLocked(self.client.post(f"{url}archive/"))
        self.assertLocked(self.client.post(f"{url}variants/", {"name": "x", "unit_price": "1"}, format="json"))
        self.assertLocked(self.client.post(f"{url}set-variant-prices/", {"variants": []}, format="json"))
        # Reading it is fine: the back office shows it.
        self.assertEqual(self.client.get(url).status_code, 200)
        self.product.refresh_from_db()
        self.assertEqual(self.product.name, "ليبيانا")

    def test_bulk_actions_refuse_a_selection_that_holds_one(self):
        self.assertLocked(
            self.client.post(
                "/api/products/bulk-reprice/",
                {"ids": [self.product.pk], "mode": "set", "value": "1"},
                format="json",
            )
        )
        self.assertLocked(
            self.client.post(
                "/api/products/bulk-archive/", {"ids": [self.product.pk], "archived": True}, format="json"
            )
        )

    def test_its_variants_cannot_be_added_moved_or_restocked(self):
        variant = self.product.variants.first()
        self.assertLocked(
            self.client.post(
                "/api/product-variants/",
                {"product": self.product.pk, "name": "x", "sku": "X-1", "unit_price": "1"},
                format="json",
            )
        )
        response = self.client.post(
            "/api/stock-movements/",
            {"variant": variant.pk, "movement_type": "increase", "quantity": "5"},
            format="json",
        )
        self.assertLocked(response)


# --- the till's settings payload ------------------------------------------------------------------
class TillButtonsTests(TestCase):
    def test_qareeb_is_connected_but_draws_no_top_up_button(self):
        ensure_role_groups()
        qareeb_account()
        manager = get_user_model().objects.create_user(username="mgr", password="x")
        manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        client = APIClient()
        client.force_authenticate(manager)
        data = client.get("/api/shop-settings/").data
        self.assertIn("qareeb", data["connected_integrations"])
        self.assertNotIn("qareeb", data["lookup_integrations"])


class QareebSettingsApiTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        manager = get_user_model().objects.create_user(username="mgr", password="x")
        manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client = APIClient()
        self.client.force_authenticate(manager)

    def test_the_pin_is_stored_encrypted_and_never_echoed(self):
        with mock.patch("apps.integrations.views.schedule_voucher_sync"):
            response = self.client.put(
                "/api/integrations/qareeb/",
                {"username": "0912345678", "password": "pw", "pin": "4321"},
                format="json",
            )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(sorted(response.data["account"]["stored_secrets"]), ["password", "pin"])
        self.assertNotIn("4321", str(response.data))
        account = IntegrationAccount.objects.get(provider="qareeb")
        self.assertEqual(account.get_secret("pin"), "4321")

    def test_a_new_password_forgets_the_kept_login(self):
        account = logged_in(qareeb_account())
        with mock.patch("apps.integrations.views.schedule_voucher_sync"):
            self.client.put("/api/integrations/qareeb/", {"password": "new"}, format="json")
        account.refresh_from_db()
        self.assertEqual(account.get_secret(qareeb_driver.SECRET_ACCESS), "")
        self.assertEqual(account.password, "new")

    def test_verification_hands_the_picture_back_inline(self):
        qareeb_account()
        fake = _FakeQareeb()
        fake.on("GET", qareeb_driver.CAPTCHA_PATH, _Resp(200, {
            "status": True, "field": {"hashkey": "ref-1", "image_url": "/captcha/image/ref-1/"},
        }))
        fake.on("GET", "/captcha/image/ref-1/", _Resp(200, None, content=b"png", content_type="image/png"))
        with patch_qareeb(fake):
            response = self.client.post("/api/integrations/qareeb/verification/")
        self.assertTrue(response.data["ok"])
        self.assertEqual(response.data["challenge_ref"], "ref-1")
        self.assertTrue(response.data["image"].startswith("data:image/png;base64,"))

    def test_choosing_a_profile_is_checked_against_the_login(self):
        account = logged_in(qareeb_account())
        fake = _FakeQareeb()
        fake.on("GET", qareeb_driver.PROFILES_PATH, _Resp(200, PROFILES))
        fake.on("GET", qareeb_driver.ACCOUNT_PATH, _Resp(200, ACCOUNT_INFO))
        with patch_qareeb(fake):
            listed = self.client.get("/api/integrations/qareeb/profiles/")
            bad = self.client.put(
                "/api/integrations/qareeb/profiles/", {"profile_id": "nope"}, format="json"
            )
            good = self.client.put(
                "/api/integrations/qareeb/profiles/", {"profile_id": STORE_PROFILE}, format="json"
            )
        self.assertEqual(len(listed.data["profiles"]), 2)
        self.assertEqual(bad.status_code, 400)
        self.assertTrue(good.data["ok"])
        account.refresh_from_db()
        self.assertEqual(account.config["profile_id"], STORE_PROFILE)
        self.assertEqual(account.config["profile_name"], "النسيم")

    def test_disconnecting_an_account_that_sold_keeps_it_and_takes_its_cards_down(self):
        account = logged_in(qareeb_account())
        sync(account, _StubDriver(_listing(), {"115": PSN}))
        from .models import IntegrationFulfillment as Fulfillment  # noqa: F401 - clarity

        with mock.patch.object(IntegrationAccount, "fulfillments") as fulfillments:
            fulfillments.exists.return_value = True
            self.client.delete("/api/integrations/qareeb/")
        account.refresh_from_db()
        self.assertFalse(account.is_active)
        self.assertEqual(account.username, "")
        self.assertFalse(
            Product.objects.filter(system_kind=Product.SystemKind.VOUCHER, is_active=True).exists()
        )

    def test_the_till_asks_a_brand_again_when_its_picker_opens(self):
        account = logged_in(qareeb_account())
        sync(account, _StubDriver(_listing(), {"115": PSN}))
        product = IntegrationVoucherBrand.objects.get(code="115").product
        sold_out = VoucherBrand(code="115", name="امريكي بلاي ستيشن", items=(), items_known=True)
        with mock.patch(
            "apps.integrations.vouchers.provider_for", return_value=_StubDriver(brands={"115": sold_out})
        ):
            response = self.client.get(f"/api/integrations/vouchers/{product.pk}/")
        self.assertTrue(response.data["ok"])
        self.assertEqual([card["is_available"] for card in response.data["cards"]], [False])
