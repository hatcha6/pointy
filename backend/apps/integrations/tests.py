from __future__ import annotations

import threading

import requests
from datetime import timedelta
from datetime import timezone as dt_timezone
from decimal import Decimal
from unittest import mock

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.conf import settings
from django.db import transaction
from django.core.cache import cache
from django.test import TestCase, TransactionTestCase, override_settings
from django.utils import timezone

from rest_framework import serializers
from rest_framework.test import APIClient

from apps.catalog.models import Product
from apps.catalog.testing import create_product_with_default_variant
from apps.core.roles import (
    ACCOUNTANT_GROUP,
    CASHIER_GROUP,
    MANAGER_GROUP,
    ensure_role_groups,
)
from apps.analytics import buffer as analytics_buffer
from apps.analytics import context as analytics_context
from apps.core.timeutils import business_timezone
from apps.customers.models import Customer
from apps.expenses.models import Expense
from apps.notifications.models import BusinessNotification
from apps.notifications.services import sync_business_notifications
from apps.inventory.models import StockMovement
from apps.sales.models import Order, OrderLine, RegisterSession
from apps.sales.serializers import DiscountPreviewSerializer
from apps.sales.services import checkout_order
from apps.treasury.models import MoneyAccount, MoneyTransfer
from apps.treasury.position import treasury_position

import json

from . import catalog
from . import connection_pool
from . import float_ledger
from . import telemetry as integ_telemetry
from . import recharge
from .fulfillment import resolve_line_integration
from .reconciliation import reconcile_account
from .models import (
    IntegrationAccount,
    IntegrationFulfillment,
    IntegrationSubscriber,
)
from .providers import is_implemented, provider_for
from .providers.base import in_parallel  # noqa: E402
from .providers.base import (
    ERROR_INDETERMINATE,
    ERROR_NOT_CONFIGURED,
    ERROR_NOT_FOUND,
    ERROR_PROVIDER_ERROR,
    ERROR_UNAUTHORIZED,
    ERROR_UNAVAILABLE,
    ERROR_UNEXPECTED,
    ERROR_UNREACHABLE,
    ProbeResult,
)
from .providers.base import HistoryResult, RechargeOption
from .providers import hdbox
from .providers.hdbox import (
    DETAIL_VIEW_PATH,
    LIST_PATH,
    RENEW_VIEW_PATH,
    HdBoxProvider,
)
from .provisioning import service_variant_for
from .services import (
    probe_account,
    record_seen_offers,
    record_subscriber,
    refresh_float_balances,
)

# Trimmed to the parts the driver actually keys off.
AUTHED_PAGE = """
<header><div class="balance">Balance: <span id="balanceId"> 25.00 </span>$ </div>
<span class="hidden-xs">Alnassim</span></header>
"""
LOGIN_PAGE = """
<form action="" method="post">
  <input type="text" name="username"><input type="password" name="password">
</form>
"""
ERROR_PAGE = "<html><head><title>ERROR</title></head><body>Sorry!We made a mistake.</body></html>"


class _FakeResponse:
    def __init__(self, text, status_code=200):
        self.text = text
        self.status_code = status_code


class _FakeSession:
    """Stands in for requests.Session: canned POST login + scripted GETs.

    GETs are answered in the order they were scripted, which is the right
    shape for a driver that talks in a fixed sequence. Pass ``routes``
    instead — ``{url_fragment: response}`` — wherever the caller makes two
    calls **at once**: "the next response in the list" has no meaning when
    two threads are asking, and a test that depends on which of them got
    there first is a test that will lie eventually.
    """

    def __init__(self, login_response, get_responses=(), *, routes=None):
        self._login_response = login_response
        self._get_responses = list(get_responses)
        self._routes = dict(routes or {})
        self._lock = threading.Lock()
        self.get_calls = []
        self.post_calls = []
        # A real Session always has one; _login reads it on a successful
        # login to feed the session cache (a no-op under TESTING, but the
        # read itself must not blow up on a fake that has none).
        self.cookies = {}

    def post(self, url, **kwargs):
        with self._lock:
            self.post_calls.append((url, kwargs))
        return self._login_response

    def mount(self, prefix, adapter):
        """A real Session has one; the drivers mount a shared pool on it."""

    def get(self, url, **kwargs):
        with self._lock:
            self.get_calls.append((url, kwargs))
            if not self._routes:
                return self._get_responses.pop(0)
        for fragment, response in self._routes.items():
            if fragment in url:
                return response
        raise AssertionError(f"unscripted GET {url}")


def make_account(**kwargs) -> IntegrationAccount:
    defaults = {
        "provider": "hdbox",
        "base_url": "http://cas.example:18688",
        "username": "Alnassim",
    }
    defaults.update(kwargs)
    account = IntegrationAccount.objects.create(**defaults)
    account.set_secret(catalog.FIELD_PASSWORD, "secret-pw")
    account.save()
    return account


def patch_session(session):
    return mock.patch(
        "apps.integrations.providers.hdbox.requests.Session", return_value=session
    )


class CatalogTests(TestCase):
    def test_every_catalog_provider_has_a_registered_driver(self):
        # Totality is what lets the settings screen render the catalog without
        # branching on whether a driver happens to exist.
        for spec in catalog.PROVIDERS:
            account = IntegrationAccount(provider=spec.key)
            self.assertIsNotNone(provider_for(account))

    def test_availability_matches_which_drivers_are_real(self):
        self.assertTrue(is_implemented("hdbox"))
        self.assertTrue(is_implemented("lnet"))
        self.assertFalse(is_implemented("qareeb"))

    def test_planned_providers_say_why(self):
        self.assertEqual(catalog.QAREEB.blocked_reason, catalog.BLOCKED_AWAITING_ACCESS)

    def test_an_available_provider_gives_no_blocked_reason(self):
        # The two fields are one statement. A provider that works while still
        # naming an excuse would render as both ready and blocked.
        for spec in catalog.PROVIDERS:
            if spec.is_available:
                self.assertEqual(spec.blocked_reason, "", spec.key)
            else:
                self.assertNotEqual(spec.blocked_reason, "", spec.key)

    def test_every_provider_settles_in_dinar(self):
        # HD Box prints a "$" glyph on a balance that is Libyan dinar. If this
        # ever flips to USD it must be a deliberate edit, not a drift.
        for spec in catalog.PROVIDERS:
            self.assertEqual(spec.currency, "LYD", spec.key)


class AccountModelTests(TestCase):
    def test_password_is_encrypted_at_rest(self):
        account = make_account()
        account.refresh_from_db()
        self.assertNotIn("secret-pw", account.secrets_encrypted)
        self.assertEqual(account.password, "secret-pw")

    def test_is_configured_requires_every_field(self):
        account = make_account()
        self.assertTrue(account.is_configured)
        account.username = ""
        self.assertFalse(account.is_configured)

    def test_is_configured_is_false_without_a_password(self):
        account = IntegrationAccount.objects.create(
            provider="hdbox", base_url="http://x:1", username="u"
        )
        self.assertFalse(account.is_configured)

    def test_base_url_falls_back_to_the_catalog_default(self):
        account = IntegrationAccount.objects.create(provider="hdbox", username="u")
        self.assertEqual(account.resolved_base_url(), catalog.HDBOX.default_base_url)


class HdBoxDriverTests(TestCase):
    """The failure modes that would otherwise be read as success."""

    def test_probe_reads_balance_and_label(self):
        session = _FakeSession(_FakeResponse(AUTHED_PAGE), [_FakeResponse(AUTHED_PAGE)])
        with patch_session(session):
            result = HdBoxProvider(make_account()).probe()
        self.assertTrue(result.ok)
        self.assertEqual(result.balance, Decimal("25.00"))
        self.assertEqual(result.account_label, "Alnassim")

    def test_login_form_coming_back_is_unauthorized_not_success(self):
        # HD Box answers a bad password with HTTP 200 and the login form.
        session = _FakeSession(_FakeResponse(LOGIN_PAGE), [])
        with patch_session(session):
            result = HdBoxProvider(make_account()).probe()
        self.assertFalse(result.ok)
        self.assertEqual(result.error_code, ERROR_UNAUTHORIZED)

    def test_expired_session_on_a_later_request_is_unauthorized(self):
        session = _FakeSession(_FakeResponse(AUTHED_PAGE), [_FakeResponse(LOGIN_PAGE)])
        with patch_session(session):
            result = HdBoxProvider(make_account()).probe()
        self.assertFalse(result.ok)
        self.assertEqual(result.error_code, ERROR_UNAUTHORIZED)

    def test_error_page_with_status_200_is_a_failure(self):
        # The trap: status 200, HTML body, "Sorry!We made a mistake."
        session = _FakeSession(_FakeResponse(AUTHED_PAGE), [_FakeResponse(ERROR_PAGE, 200)])
        with patch_session(session):
            result = HdBoxProvider(make_account()).lookup("12345")
        self.assertFalse(result.ok)
        self.assertEqual(result.error_code, ERROR_NOT_FOUND)

    def test_lookup_parses_json_served_as_text_html(self):
        body = (
            '{"status":"success","message":"","total":1,"rows":[{"cardNo":"12345",'
            '"status":"Active","statusId":3,"startDay":1750000000,'
            '"expireDay":1780000000,"packageName":"Full"}]}'
        )
        session = _FakeSession(_FakeResponse(AUTHED_PAGE), [_FakeResponse(body)])
        with patch_session(session):
            result = HdBoxProvider(make_account()).lookup("12345")
        self.assertTrue(result.ok)
        card = result.card
        self.assertEqual(card.card_no, "12345")
        self.assertEqual(card.status_id, 3)
        self.assertEqual(card.package_name, "Full")
        # Unix seconds, not milliseconds and not a date string.
        self.assertEqual(card.start_at.tzinfo, dt_timezone.utc)
        self.assertEqual(int(card.start_at.timestamp()), 1750000000)

    def test_zero_epoch_means_unset_not_1970(self):
        body = (
            '{"status":"success","total":1,"rows":[{"cardNo":"7","startDay":0,'
            '"expireDay":0}]}'
        )
        session = _FakeSession(_FakeResponse(AUTHED_PAGE), [_FakeResponse(body)])
        with patch_session(session):
            result = HdBoxProvider(make_account()).lookup("7")
        self.assertIsNone(result.card.start_at)
        self.assertIsNone(result.card.expire_at)

    def test_non_numeric_card_never_reaches_the_network(self):
        session = _FakeSession(_FakeResponse(AUTHED_PAGE), [])
        with patch_session(session):
            result = HdBoxProvider(make_account()).lookup("abc")
        self.assertFalse(result.ok)
        self.assertEqual(result.error_code, ERROR_NOT_FOUND)
        self.assertEqual(session.get_calls, [])

    def test_unparseable_body_is_reported_not_guessed(self):
        session = _FakeSession(_FakeResponse(AUTHED_PAGE), [_FakeResponse("<html>?</html>")])
        with patch_session(session):
            result = HdBoxProvider(make_account()).lookup("12345")
        self.assertFalse(result.ok)
        self.assertEqual(result.error_code, ERROR_UNEXPECTED)

    def test_missing_card_json_is_not_found(self):
        body = '{"message":"card no is null!","rows":null,"status":"fail","total":0}'
        session = _FakeSession(_FakeResponse(AUTHED_PAGE), [_FakeResponse(body)])
        with patch_session(session):
            result = HdBoxProvider(make_account()).lookup("12345")
        self.assertFalse(result.ok)
        self.assertEqual(result.error_code, ERROR_NOT_FOUND)


class PlannedProviderTests(TestCase):
    def test_planned_provider_refuses_uniformly(self):
        account = IntegrationAccount.objects.create(provider="qareeb")
        driver = provider_for(account)
        self.assertEqual(driver.probe().error_code, ERROR_UNAVAILABLE)
        self.assertEqual(driver.lookup("1").error_code, ERROR_UNAVAILABLE)


class ProbeServiceTests(TestCase):
    def test_success_records_balance_and_clears_the_error(self):
        account = make_account(last_error="old", last_error_code="unreachable")
        session = _FakeSession(_FakeResponse(AUTHED_PAGE), [_FakeResponse(AUTHED_PAGE)])
        with patch_session(session):
            probe_account(account)
        account.refresh_from_db()
        self.assertEqual(account.balance, Decimal("25.00"))
        self.assertEqual(account.last_error, "")
        self.assertEqual(account.last_error_code, "")
        self.assertIsNotNone(account.last_connected_at)
        self.assertIsNotNone(account.balance_at)

    def test_failure_records_the_reason_and_keeps_the_last_balance(self):
        account = make_account(balance=Decimal("25.00"))
        session = _FakeSession(_FakeResponse(LOGIN_PAGE), [])
        with patch_session(session):
            probe_account(account)
        account.refresh_from_db()
        self.assertEqual(account.last_error_code, ERROR_UNAUTHORIZED)
        self.assertIsNotNone(account.last_error_at)
        # The last known float is still the last known float.
        self.assertEqual(account.balance, Decimal("25.00"))

    def test_unconfigured_account_is_not_probed(self):
        account = IntegrationAccount.objects.create(provider="hdbox", username="")
        result = probe_account(account)
        self.assertEqual(result.error_code, ERROR_NOT_CONFIGURED)

    def test_a_driver_that_raises_does_not_escape(self):
        account = make_account()
        with mock.patch(
            "apps.integrations.services.provider_for",
            side_effect=RuntimeError("boom"),
        ):
            result = probe_account(account)
        self.assertFalse(result.ok)
        account.refresh_from_db()
        self.assertEqual(account.last_error_code, ERROR_UNEXPECTED)


class IntegrationApiTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        User = get_user_model()
        self.manager = User.objects.create_user(username="mgr", password="x")
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.cashier = User.objects.create_user(username="csh", password="x")
        self.cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.client = APIClient()

    def test_catalog_lists_every_provider_even_unconfigured(self):
        self.client.force_authenticate(self.manager)
        resp = self.client.get("/api/integrations/")
        self.assertEqual(resp.status_code, 200)
        keys = [p["key"] for p in resp.data["providers"]]
        self.assertEqual(keys, ["hdbox", "lnet", "qareeb"])
        by_key = {p["key"]: p for p in resp.data["providers"]}
        self.assertTrue(by_key["hdbox"]["is_configurable"])
        self.assertTrue(by_key["lnet"]["is_configurable"])
        self.assertFalse(by_key["qareeb"]["is_configurable"])
        self.assertEqual(by_key["qareeb"]["blocked_reason"], "awaiting_access")
        self.assertIsNone(by_key["hdbox"]["account"])

    def test_cashier_cannot_read_integration_settings(self):
        self.client.force_authenticate(self.cashier)
        self.assertEqual(self.client.get("/api/integrations/").status_code, 403)

    def test_save_credentials_never_echoes_the_password(self):
        self.client.force_authenticate(self.manager)
        resp = self.client.put(
            "/api/integrations/hdbox/",
            {"base_url": "http://cas.example:18688", "username": "Alnassim", "password": "pw"},
            format="json",
        )
        self.assertEqual(resp.status_code, 200)
        # The catalog names "password" as a field the form should render; what
        # must never come back is the value itself.
        self.assertNotIn("pw", str(resp.data["account"]))
        self.assertNotIn("password", resp.data["account"])
        self.assertTrue(resp.data["account"]["has_password"])
        self.assertTrue(resp.data["account"]["is_configured"])
        self.assertEqual(IntegrationAccount.objects.get(provider="hdbox").password, "pw")

    def test_resaving_without_a_password_keeps_the_stored_one(self):
        # The client can never read the password back, so it cannot resend it —
        # a blank must not be taken as "erase it".
        self.client.force_authenticate(self.manager)
        self.client.put(
            "/api/integrations/hdbox/",
            {"base_url": "http://a:1", "username": "u", "password": "pw"},
            format="json",
        )
        self.client.put(
            "/api/integrations/hdbox/",
            {"base_url": "http://b:2", "username": "u", "password": ""},
            format="json",
        )
        account = IntegrationAccount.objects.get(provider="hdbox")
        self.assertEqual(account.base_url, "http://b:2")
        self.assertEqual(account.password, "pw")

    def test_planned_provider_cannot_be_configured(self):
        self.client.force_authenticate(self.manager)
        resp = self.client.put(
            "/api/integrations/qareeb/",
            {"username": "x", "password": "y"},
            format="json",
        )
        self.assertEqual(resp.status_code, 409)
        self.assertFalse(IntegrationAccount.objects.filter(provider="qareeb").exists())

    def test_unknown_provider_is_404(self):
        self.client.force_authenticate(self.manager)
        resp = self.client.put("/api/integrations/nope/", {"username": "x"}, format="json")
        self.assertEqual(resp.status_code, 404)

    def test_delete_removes_the_account_but_keeps_the_catalog_entry(self):
        self.client.force_authenticate(self.manager)
        make_account()
        resp = self.client.delete("/api/integrations/hdbox/")
        self.assertEqual(resp.status_code, 200)
        self.assertIsNone(resp.data["account"])
        self.assertFalse(IntegrationAccount.objects.filter(provider="hdbox").exists())

    def test_probe_reports_failure_as_200_with_ok_false(self):
        # A provider saying no is a fact to render, not a broken request.
        self.client.force_authenticate(self.manager)
        make_account()
        session = _FakeSession(_FakeResponse(LOGIN_PAGE), [])
        with patch_session(session):
            resp = self.client.post("/api/integrations/hdbox/probe/")
        self.assertEqual(resp.status_code, 200)
        self.assertFalse(resp.data["ok"])
        self.assertEqual(resp.data["error_code"], ERROR_UNAUTHORIZED)

    def test_probe_of_an_unconfigured_provider_says_so(self):
        self.client.force_authenticate(self.manager)
        resp = self.client.post("/api/integrations/hdbox/probe/")
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.data["error_code"], ERROR_NOT_CONFIGURED)

    def test_lookup_requires_only_the_use_right(self):
        make_account()
        self.client.force_authenticate(self.manager)
        body = '{"status":"success","total":1,"rows":[{"cardNo":"12345","statusId":3}]}'
        session = _FakeSession(_FakeResponse(AUTHED_PAGE), [_FakeResponse(body)])
        with patch_session(session):
            resp = self.client.get("/api/integrations/hdbox/lookup/?card_no=12345")
        self.assertEqual(resp.status_code, 200)
        self.assertTrue(resp.data["ok"])
        self.assertEqual(resp.data["card"]["card_no"], "12345")


# Trimmed from the real renew form: the two <select>s, with their different
# price attributes, are the whole reason the parser needs two patterns.
# Trimmed from the real renew form, keeping every field the write path reads.
# data-expiration is 2026-09-20 23:59:59 +02:00, so the dates below are fixed
# and this fixture does not drift with the clock.
RENEW_FORM = """
<form id="renewCardForm">
  <input type="hidden" name="token" value="eb1c2a63-25d2-4b6f-9091-c0b4a85238d8"/>
  <input type="hidden" name="changePackage" value="0"/>
  <input type="hidden" name="dealerId" value="265"/>
  <input type="text" name="cardNo" class="form-control" value="210906803499" readonly />
  <!-- Hidden by HD Box, and nothing on the page ever selects an option: a real
       browser therefore submits the FIRST one on every renew. Not a package
       change — changePackage stays 0 and the server ignores it. -->
  <select name="pid" data-old-pid="4" style="display:none;">
    <option data-price="5.00" value="1">radwan(5.00$)</option>
    <option data-price="10.00" value="3">HDBOX ACTIVE NEW(10.00$)</option>
  </select>
  <select name="month" id="month">
    <option value="1" price="25.00">1 month 25.00$</option>
    <option value="3" price="65.00">3 month 65.00$</option>
    <option value="12" price="220.00">12 month 220.00$</option>
  </select>
  <input type="text" name="expireDay" value="0" data-expiration="1789941599" />
  <input type="text" name="pay" value="0" />
</form>
"""

# The card-detail modal: a disabled form whose labels are the field names.
# Subscriber and Phone come back masked for an agency login.
DETAIL_FORM = """
<div class="modal-body">
  <div class="form-group-sm"><label>Card Nr.</label><input value="210906803499" disabled/></div>
  <div class="form-group-sm"><label>Status</label><input value="On hold" disabled/></div>
  <div class="form-group-sm"><label>Device model</label><input value="R-10000 Plus" disabled/>
    <label>Device price</label><input value="0.02" disabled/></div>
  <div class="form-group-sm"><label>Subscriber</label><input value="-----------------" disabled/>
    <label>Phone</label><input value="-----------------" disabled/></div>
  <div class="form-group-sm"><label>Package</label><input value="HDBOX Full package" disabled/>
    <label>Price/month</label><input value="10.00" disabled/></div>
  <div class="form-group-sm"><label>Activate date</label><input value="2022/11/27" disabled/></div>
  <div class="form-group-sm"><label>Expire date</label><input value="2026/08/01" disabled/></div>
  <div class="form-group-sm"><label>Balance</label><input value="0.00" disabled/></div>
  <div class="form-group-sm"><label>Buy times</label><input value="6" disabled/>
    <label>Total pay</label><input value="750.00" disabled/></div>
</div>
"""

BUY_LOG = (
    '{"message":"Success!","rows":['
    '{"id":523415,"cost":25.00,"month":1,"buyDate":1782856800,"type":2,'
    '"packageName":"HDBOX Full package","operatorName":"Alnassim"},'
    '{"id":484140,"cost":65.00,"month":3,"buyDate":1774908000,"type":2,'
    '"packageName":"HDBOX Full package","operatorName":"zhra"}'
    '],"status":"success","total":6}'
)

STATUS_LOG = (
    '{"message":"Success!","rows":['
    '{"fromStatus":"Soon to expire","status":"On hold","operaterName":"System",'
    '"action":"Auto operation by system timer.","changeDate":1785621600}'
    '],"status":"success","total":31}'
)


CACHED_PROVIDER_SESSIONS = override_settings(
    CACHES={
        "default": {
            "BACKEND": "django.core.cache.backends.locmem.LocMemCache",
            "LOCATION": "integrations-provider-session-reuse-tests",
        },
    },
    POINTY_INTEGRATION_SESSION_CACHE_TTL=600,
)


@CACHED_PROVIDER_SESSIONS
class HdBoxSessionReuseTests(TestCase):
    """Three capability calls for one card used to mean three logins.

    HD Box's own docstring names the login as the expensive step — a servlet
    session cookie with nothing to refresh — and the field measured it at
    2-9 seconds. ``IntegrationCardView`` calls ``lookup``, ``offers`` and
    ``subscriber_profile`` on ONE driver instance for exactly this reason
    (its own docstring: "three sequential provider logins is a wait a
    cashier can feel"), but each of those methods called ``_login()`` on its
    own with no memory of the others. These prove the fix: with the cache
    warm, that whole chain spends the network-login POST once.
    """

    def setUp(self):
        cache.clear()

    def test_one_login_serves_lookup_offers_and_profile(self):
        card_json = (
            '{"status":"success","total":1,"rows":[{"cardNo":"210906803499",'
            '"status":"Active","statusId":3}]}'
        )
        session = _FakeSession(
            _FakeResponse(AUTHED_PAGE),
            [
                _FakeResponse(card_json),   # lookup
                _FakeResponse(RENEW_FORM),  # offers
                _FakeResponse(DETAIL_FORM),  # subscriber_profile
            ],
        )
        with patch_session(session):
            driver = HdBoxProvider(make_account())
            lookup = driver.lookup("210906803499")
            self.assertTrue(lookup.ok, lookup.error_detail)
            offers = driver.offers("210906803499")
            self.assertTrue(offers.ok, offers.error_detail)
            profile = driver.subscriber_profile("210906803499")
            self.assertTrue(profile.ok, profile.error_detail)

        # post() is only ever used to submit the login form — one for the
        # whole chain, not one per capability call.
        self.assertEqual(len(session.post_calls), 1)
        self.assertEqual(len(session.get_calls), 3)

    def test_a_second_driver_instance_reuses_the_warm_cache_too(self):
        """Not just within one request — the next search in the shift too."""
        session = _FakeSession(
            _FakeResponse(AUTHED_PAGE),
            [_FakeResponse(AUTHED_PAGE), _FakeResponse(AUTHED_PAGE)],
        )
        account = make_account()
        with patch_session(session):
            self.assertTrue(HdBoxProvider(account).probe().ok)
            self.assertTrue(HdBoxProvider(account).probe().ok)
        self.assertEqual(len(session.post_calls), 1)

    def test_a_stale_cached_session_is_retried_once_not_reported_as_a_failure(self):
        """The cached session died on the portal's side between two calls.

        The first authenticated request after the cache hit comes back as the
        login form — HD Box's own signature for "your session is gone" — and
        the driver must recover by logging in for real, not hand the cashier
        an "unauthorized" for a card that was working a minute ago.
        """
        account = make_account()
        # Warm the cache with a real login.
        warm_up = _FakeSession(_FakeResponse(AUTHED_PAGE), [_FakeResponse(AUTHED_PAGE)])
        with patch_session(warm_up):
            self.assertTrue(HdBoxProvider(account).probe().ok)

        # The next driver picks up the cached cookie, tries it, finds it is
        # dead (login form), and must fall back to a real login + retry.
        card_json = (
            '{"status":"success","total":1,"rows":[{"cardNo":"7","status":"Active"}]}'
        )
        stale_then_fresh = _FakeSession(
            _FakeResponse(AUTHED_PAGE),
            [_FakeResponse(LOGIN_PAGE), _FakeResponse(card_json)],
        )
        with patch_session(stale_then_fresh):
            result = HdBoxProvider(account).lookup("7")

        self.assertTrue(result.ok, result.error_detail)
        self.assertEqual(result.card.card_no, "7")
        # One fresh login, spent on the retry.
        self.assertEqual(len(stale_then_fresh.post_calls), 1)

    def test_a_session_that_was_never_cached_gets_no_retry_on_expiry(self):
        """The honest failure this app has always given, still given.

        Without a cache hit there is nothing "stale" about this session — it
        was logged in moments ago in this very call — so a login-form reply
        here is reported exactly as it always was, with no silent extra
        network round trip.
        """
        session = _FakeSession(_FakeResponse(AUTHED_PAGE), [_FakeResponse(LOGIN_PAGE)])
        with patch_session(session):
            result = HdBoxProvider(make_account()).probe()
        self.assertFalse(result.ok)
        self.assertEqual(result.error_code, ERROR_UNAUTHORIZED)
        self.assertEqual(len(session.post_calls), 1)

    def test_a_password_edit_is_not_served_a_replay_of_the_old_login(self):
        """probe() exists to check a NEW password; a cache hit must not skip it."""
        account = make_account()
        first_login = _FakeSession(_FakeResponse(AUTHED_PAGE), [_FakeResponse(AUTHED_PAGE)])
        with patch_session(first_login):
            self.assertTrue(HdBoxProvider(account).probe().ok)

        account.set_secret(catalog.FIELD_PASSWORD, "a-new-password")
        account.save()

        second_login = _FakeSession(_FakeResponse(AUTHED_PAGE), [_FakeResponse(AUTHED_PAGE)])
        with patch_session(second_login):
            self.assertTrue(HdBoxProvider(account).probe().ok)
        # A real login, not a cache hit — proven by a real POST having gone out.
        self.assertEqual(len(second_login.post_calls), 1)


class HdBoxOffersTests(TestCase):
    def test_reads_the_duration_ladder_off_the_renew_form(self):
        session = _FakeSession(_FakeResponse(AUTHED_PAGE), [_FakeResponse(RENEW_FORM)])
        with patch_session(session):
            result = HdBoxProvider(make_account()).offers("12345")

        self.assertTrue(result.ok)
        self.assertEqual([o.months for o in result.options], [1, 3, 12])
        self.assertEqual(
            [o.cost for o in result.options],
            [Decimal("25.00"), Decimal("65.00"), Decimal("220.00")],
        )

    def test_a_package_switch_is_never_offered(self):
        # HD Box hides its package <select>, and the agency does not do it.
        # A cashier must not be one tap from moving a subscriber onto the
        # wrong package and breaking their card.
        form = RENEW_FORM.replace(
            "<!-- HD Box renders",
            '<select name="pid"><option data-price="5.00" value="1">radwan(5.00$)'
            "</option></select><!-- HD Box renders",
        )
        session = _FakeSession(_FakeResponse(AUTHED_PAGE), [_FakeResponse(form)])
        with patch_session(session):
            result = HdBoxProvider(make_account()).offers("12345")

        self.assertTrue(all(o.kind == "renew" for o in result.options))
        self.assertNotIn("switch:1", [o.code for o in result.options])

    def test_option_codes_are_stable(self):
        session = _FakeSession(_FakeResponse(AUTHED_PAGE), [_FakeResponse(RENEW_FORM)])
        with patch_session(session):
            result = HdBoxProvider(make_account()).offers("12345")
        self.assertIn("renew:12", [o.code for o in result.options])

    def test_a_form_with_no_prices_is_an_error_not_an_empty_picker(self):
        # "Nothing to buy" and "we could not read the prices" look identical to
        # a cashier unless we say which one it is.
        session = _FakeSession(
            _FakeResponse(AUTHED_PAGE), [_FakeResponse("<form></form>")]
        )
        with patch_session(session):
            result = HdBoxProvider(make_account()).offers("12345")
        self.assertFalse(result.ok)
        self.assertEqual(result.error_code, ERROR_UNEXPECTED)


class HdBoxHistoryTests(TestCase):
    def test_purchase_log_marks_which_sales_were_ours(self):
        session = _FakeSession(_FakeResponse(AUTHED_PAGE), [_FakeResponse(BUY_LOG)])
        with patch_session(session):
            result = HdBoxProvider(make_account(username="Alnassim")).purchase_history(
                "12345"
            )

        self.assertTrue(result.ok)
        self.assertEqual(result.total, 6)  # the provider's count, not the page
        self.assertEqual(len(result.purchases), 2)
        ours, theirs = result.purchases
        self.assertTrue(ours.is_ours)
        self.assertEqual(ours.cost, Decimal("25.00"))
        self.assertEqual(ours.reference, "523415")
        self.assertFalse(theirs.is_ours)
        self.assertEqual(theirs.operator_name, "zhra")

    def test_ownership_match_ignores_case(self):
        session = _FakeSession(_FakeResponse(AUTHED_PAGE), [_FakeResponse(BUY_LOG)])
        with patch_session(session):
            result = HdBoxProvider(make_account(username="alnassim")).purchase_history(
                "12345"
            )
        self.assertTrue(result.purchases[0].is_ours)

    def test_status_log_reads_the_misspelled_operator_field(self):
        # The buy log says "operatorName"; the status log says "operaterName".
        session = _FakeSession(_FakeResponse(AUTHED_PAGE), [_FakeResponse(STATUS_LOG)])
        with patch_session(session):
            result = HdBoxProvider(make_account()).status_history("12345")

        self.assertTrue(result.ok)
        entry = result.statuses[0]
        self.assertEqual(entry.operator_name, "System")
        self.assertEqual(entry.to_status, "On hold")
        self.assertEqual(entry.from_status, "Soon to expire")

    def test_history_passes_pagination_through_to_the_provider(self):
        session = _FakeSession(_FakeResponse(AUTHED_PAGE), [_FakeResponse(BUY_LOG)])
        with patch_session(session):
            HdBoxProvider(make_account()).purchase_history("12345", limit=25, offset=50)
        _url, kwargs = session.get_calls[0]
        self.assertEqual(kwargs["params"], {"limit": 25, "offset": 50})


class ServiceVariantTests(TestCase):
    def test_provisioning_is_idempotent(self):
        first = service_variant_for("hdbox")
        second = service_variant_for("hdbox")
        self.assertEqual(first.pk, second.pk)
        self.assertTrue(first.product.is_service)

    def test_an_archived_service_product_comes_back(self):
        # A shop that tidied it away should not hit a wall at the till.
        variant = service_variant_for("hdbox")
        variant.product.archived_at = timezone.now()
        variant.product.is_active = False
        variant.product.save(update_fields=["archived_at", "is_active"])

        restored = service_variant_for("hdbox")
        self.assertEqual(restored.pk, variant.pk)
        self.assertIsNone(restored.product.archived_at)
        self.assertTrue(restored.product.is_active)

    def test_the_service_product_is_marked_as_one_the_shop_did_not_choose(self):
        # It is the flag that keeps a 0.00 «شحن اشتراك HD Box» out of the till's
        # catalog grid, off the price checker, and out of a cart.
        variant = service_variant_for("hdbox")
        self.assertTrue(variant.product.is_system)

    def test_a_product_provisioned_before_the_flag_existed_is_repaired(self):
        # Every shop already selling top-ups has this product without the flag;
        # the next top-up must fix it, not wait for a data migration it may
        # already have run past.
        variant = service_variant_for("hdbox")
        Product.objects.filter(pk=variant.product.pk).update(is_system=False)

        repaired = service_variant_for("hdbox")
        self.assertEqual(repaired.pk, variant.pk)
        self.assertTrue(repaired.product.is_system)


class TillApiTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        User = get_user_model()
        self.cashier = User.objects.create_user(username="csh", password="x")
        self.cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.client = APIClient()
        self.client.force_authenticate(self.cashier)
        make_account()

    def test_card_call_returns_state_prices_and_the_cart_variant(self):
        card_json = (
            '{"status":"success","total":1,"rows":[{"cardNo":210906803499,'
            '"status":"On hold","statusId":6,"startDay":1669500000,'
            '"expireDay":1785621599,"packageName":"HDBOX Full package"}]}'
        )
        # The card view reads the renew form and the card detail AT THE SAME
        # TIME, so these are routed by path rather than handed out in order.
        session = _FakeSession(
            _FakeResponse(AUTHED_PAGE),
            routes={
                LIST_PATH: _FakeResponse(card_json),
                RENEW_VIEW_PATH: _FakeResponse(RENEW_FORM),
                DETAIL_VIEW_PATH: _FakeResponse(DETAIL_FORM),
            },
        )
        with patch_session(session):
            resp = self.client.get("/api/integrations/hdbox/card/?card_no=210906803499")

        self.assertEqual(resp.status_code, 200)
        self.assertTrue(resp.data["ok"])
        self.assertEqual(resp.data["card"]["card_no"], "210906803499")
        self.assertEqual(resp.data["card"]["status_id"], 6)
        self.assertEqual(len(resp.data["offers"]), 3)
        self.assertEqual(resp.data["currency"], "LYD")
        # The detail modal's extras, kept against the card.
        subscriber = resp.data["subscriber"]
        self.assertEqual(subscriber["device_model"], "R-10000 Plus")
        self.assertEqual(subscriber["lifetime_spend"], Decimal("750.00"))
        self.assertEqual(subscriber["purchase_count"], 6)
        # HD Box masks the name; Pointy has not been told one yet.
        self.assertFalse(subscriber["is_identified"])
        self.assertEqual(subscriber["display_name"], "")
        # The till is handed the whole variant identity, not just an id it
        # would have to go and look up with a customer waiting.
        variant = resp.data["service_variant"]
        self.assertEqual(variant["sku"], "INTEG-HDBOX")
        self.assertIsNotNone(variant["id"])
        self.assertIsNotNone(variant["product_id"])
        # Both numbers, so the cart cannot show one and the invoice the other.
        offer = resp.data["offers"][0]
        self.assertIn("cost", offer)
        self.assertIn("price", offer)

    def test_a_cashier_can_read_history_without_the_manage_right(self):
        session = _FakeSession(_FakeResponse(AUTHED_PAGE), [_FakeResponse(BUY_LOG)])
        with patch_session(session):
            resp = self.client.get(
                "/api/integrations/hdbox/history/?card_no=12345&kind=purchases"
            )
        self.assertEqual(resp.status_code, 200)
        self.assertTrue(resp.data["ok"])
        self.assertEqual(resp.data["total"], 6)
        self.assertTrue(resp.data["entries"][0]["is_ours"])

    def test_a_cashier_cannot_read_the_credentials_screen(self):
        self.assertEqual(self.client.get("/api/integrations/").status_code, 403)

    def test_page_size_is_clamped(self):
        session = _FakeSession(_FakeResponse(AUTHED_PAGE), [_FakeResponse(BUY_LOG)])
        with patch_session(session):
            resp = self.client.get(
                "/api/integrations/hdbox/history/?card_no=12345&limit=9999"
            )
        self.assertEqual(resp.data["limit"], 50)

    def test_a_nonsense_page_size_falls_back_rather_than_500s(self):
        session = _FakeSession(_FakeResponse(AUTHED_PAGE), [_FakeResponse(BUY_LOG)])
        with patch_session(session):
            resp = self.client.get(
                "/api/integrations/hdbox/history/?card_no=12345&limit=abc&offset=-5"
            )
        self.assertEqual(resp.data["limit"], 10)
        self.assertEqual(resp.data["offset"], 0)


class LnetCardViewTests(TestCase):
    """The till's actual round trip: search, then price what was found.

    This is what a cashier does hundreds of times a shift, and — before the
    resolved-card fix — searching by phone number (the driver's own docstring:
    what a till does "almost always") landed here with an empty offer list and
    no way to sell anything, even though the line the search found was real.
    Nothing in this file exercised the ``/card/`` endpoint for LNET at all
    until this class, which is exactly how that shipped unnoticed.
    """

    def setUp(self):
        ensure_role_groups()
        User = get_user_model()
        self.cashier = User.objects.create_user(username="csh-lnet", password="x")
        self.cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.client = APIClient()
        self.client.force_authenticate(self.cashier)
        lnet_account()

    def test_a_phone_search_prices_the_line_it_found(self):
        with patch_lnet(lnet_session()):
            resp = self.client.get(
                "/api/integrations/lnet/card/?card_no=0910682854"
            )

        self.assertEqual(resp.status_code, 200)
        self.assertTrue(resp.data["ok"], resp.data)
        # The line the search found — a username, not the phone typed.
        self.assertEqual(resp.data["card"]["card_no"], "alhussainbasheir")
        # The whole bug: this used to come back empty for exactly this search.
        self.assertTrue(resp.data["offers"])
        self.assertEqual(resp.data["offers_error_code"], "")
        self.assertTrue(resp.data["subscriber"]["subscriber_ref"])

    def test_a_phone_search_still_offers_somewhere_to_type_an_amount(self):
        """The till's amount field, which went missing with the quick-picks.

        ``open_amount`` and the offer list fail together — both come off the
        same OfferResult — so the failed re-search took the typed-amount
        field with it, and the recharge screen, seeing neither a button nor
        a field, showed "تعذّر قراءة الأسعار من المزوّد" and nothing to sell.
        A cashier could not fall back to typing the amount, because there was
        nowhere left to type it.
        """
        with patch_lnet(lnet_session()):
            resp = self.client.get(
                "/api/integrations/lnet/card/?card_no=0910682854"
            )

        open_amount = resp.data["open_amount"]
        self.assertIsNotNone(open_amount, resp.data)
        self.assertEqual(open_amount["minimum"], Decimal("1"))

    def test_a_shop_that_keeps_only_two_quick_picks_gets_both_and_the_field(self):
        """Annaseem's own configuration, end to end.

        Two amounts is a deliberate answer, not a broken one — the provider
        takes any amount and the field is always there, so a short list is a
        shop saying "these two are what people ask for". What it must never
        mean is an empty screen.
        """
        IntegrationAccount.objects.filter(provider="lnet").update(
            config={catalog.SETTING_DENOMINATIONS: ["25", "45"]}
        )
        with patch_lnet(lnet_session()):
            resp = self.client.get(
                "/api/integrations/lnet/card/?card_no=0910682854"
            )

        self.assertTrue(resp.data["ok"], resp.data)
        self.assertEqual(
            [offer["code"] for offer in resp.data["offers"]],
            ["topup:25", "topup:45"],
        )
        self.assertEqual(resp.data["offers_error_code"], "")
        self.assertIsNotNone(resp.data["open_amount"])

    def test_searching_by_the_exact_username_still_works(self):
        with patch_lnet(lnet_session()):
            resp = self.client.get(
                "/api/integrations/lnet/card/?card_no=alhussainbasheir"
            )
        self.assertTrue(resp.data["ok"])
        self.assertTrue(resp.data["offers"])

    def test_several_lines_are_still_offered_as_a_choice_not_priced(self):
        with patch_lnet(lnet_session(users=LNET_THREE_LINES)):
            resp = self.client.get("/api/integrations/lnet/card/?card_no=basheir")
        self.assertTrue(resp.data["ok"])
        self.assertTrue(resp.data["needs_selection"])
        self.assertEqual(len(resp.data["candidates"]), 3)


class SellingPriceTests(TestCase):
    def test_no_markup_sells_at_cost(self):
        account = make_account()
        self.assertEqual(account.selling_price(Decimal("25.00")), Decimal("25.00"))

    def test_percent_markup(self):
        account = make_account(
            markup_kind=IntegrationAccount.Markup.PERCENT, markup_value=Decimal("20")
        )
        self.assertEqual(account.selling_price(Decimal("25.00")), Decimal("30.00"))

    def test_amount_markup(self):
        account = make_account(
            markup_kind=IntegrationAccount.Markup.AMOUNT, markup_value=Decimal("5")
        )
        self.assertEqual(account.selling_price(Decimal("220.00")), Decimal("225.00"))

    def test_percent_markup_rounds_once_at_the_end(self):
        account = make_account(
            markup_kind=IntegrationAccount.Markup.PERCENT, markup_value=Decimal("7.5")
        )
        # 65.00 * 1.075 = 69.875 → 69.88, not 69.87
        self.assertEqual(account.selling_price(Decimal("65.00")), Decimal("69.88"))

    def test_a_negative_markup_never_sells_below_cost(self):
        # A misconfiguration is not an instruction to lose money on every sale.
        account = make_account(
            markup_kind=IntegrationAccount.Markup.AMOUNT, markup_value=Decimal("-10")
        )
        self.assertEqual(account.selling_price(Decimal("25.00")), Decimal("25.00"))


class LineResolutionTests(TestCase):
    def setUp(self):
        self.account = make_account()
        self.variant = service_variant_for("hdbox")

    def _payload(self, **overrides):
        payload = {
            "provider": "hdbox",
            "subscriber_ref": "210906803499",
            "option_code": "renew:12",
            "option_label": "12 month 220.00$",
            "months": 12,
            "cost": Decimal("220.00"),
        }
        payload.update(overrides)
        return payload

    def test_resolves_price_from_the_shops_markup(self):
        self.account.markup_kind = IntegrationAccount.Markup.PERCENT
        self.account.markup_value = Decimal("10")
        self.account.save()
        resolved = resolve_line_integration(self._payload(), self.variant)
        self.assertEqual(resolved["cost"], Decimal("220.00"))
        self.assertEqual(resolved["price"], Decimal("242.00"))

    def test_a_top_up_cannot_be_attached_to_an_unrelated_product(self):
        # Otherwise a recharge could ride on a bag of rice, and every receipt,
        # report and return downstream would read it as one.
        other = create_product_with_default_variant(
            name="أرز", sku="RICE-1", unit_price=Decimal("5.00"), barcode=""
        ).default_variant
        with self.assertRaises(serializers.ValidationError):
            resolve_line_integration(self._payload(), other)

    def test_an_unconfigured_provider_is_refused(self):
        IntegrationAccount.objects.all().delete()
        with self.assertRaises(serializers.ValidationError):
            resolve_line_integration(self._payload(), self.variant)

    def test_a_planned_provider_is_refused(self):
        with self.assertRaises(serializers.ValidationError):
            resolve_line_integration(
                self._payload(provider="lnet"), service_variant_for("lnet")
            )


class RechargeCheckoutTests(TestCase):
    """A top-up must behave like any other line, and carry its own cost."""

    def setUp(self):
        ensure_role_groups()
        self.user = get_user_model().objects.create_user(username="till", password="x")
        self.user.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.session = RegisterSession.objects.create(
            owner=self.user, owner_key=f"user:{self.user.pk}"
        )
        self.account = make_account(
            markup_kind=IntegrationAccount.Markup.AMOUNT, markup_value=Decimal("5")
        )
        self.variant = service_variant_for("hdbox")

    def _line(self, card="210906803499", cost="25.00", code="renew:1"):
        resolved = resolve_line_integration(
            {
                "provider": "hdbox",
                "subscriber_ref": card,
                "option_code": code,
                "option_label": "1 month",
                "months": 1,
                "cost": Decimal(cost),
            },
            self.variant,
        )
        return {
            "variant": self.variant,
            "quantity": Decimal("1"),
            "effective_unit_price": resolved["price"],
            "integration": resolved,
        }

    def test_sale_records_price_cost_and_a_pending_fulfillment(self):
        order = checkout_order(
            register_session=self.session,
            lines_data=[self._line()],
            payments_data=[{"method": "cash", "amount": Decimal("30.00")}],
            request=None,
        )

        line = order.lines.get()
        self.assertEqual(line.unit_price, Decimal("30.00"))   # 25 cost + 5 markup
        self.assertEqual(line.unit_cost, Decimal("25.00"))    # the float's share
        self.assertEqual(line.line_profit, Decimal("5.00"))

        fulfillment = IntegrationFulfillment.objects.get(order_line=line)
        self.assertEqual(fulfillment.status, IntegrationFulfillment.Status.PENDING)
        self.assertEqual(fulfillment.subscriber_ref, "210906803499")
        self.assertEqual(fulfillment.cost, Decimal("25.00"))
        # Nothing has been sent to the provider, and the row says so rather
        # than implying the top-up has happened.
        self.assertEqual(fulfillment.provider_reference, "")
        self.assertIsNone(fulfillment.submitted_at)

    def test_two_cards_on_one_sale_stay_two_fulfillments(self):
        order = checkout_order(
            register_session=self.session,
            lines_data=[self._line(card="111"), self._line(card="222")],
            payments_data=[{"method": "cash", "amount": Decimal("60.00")}],
            request=None,
        )
        self.assertEqual(order.lines.count(), 2)
        refs = set(
            IntegrationFulfillment.objects.values_list("subscriber_ref", flat=True)
        )
        self.assertEqual(refs, {"111", "222"})

    def test_a_recharge_does_not_touch_stock(self):
        checkout_order(
            register_session=self.session,
            lines_data=[self._line()],
            payments_data=[{"method": "cash", "amount": Decimal("30.00")}],
            request=None,
        )
        self.assertFalse(StockMovement.objects.exists())

    def test_the_service_product_cannot_be_rung_up_on_its_own(self):
        # Its standing price is zero, because the real one is computed per
        # line from the provider's quote. A line that reached checkout without
        # the top-up payload — a held invoice from before this release, a till
        # that has not updated — would have handed a customer a free recharge
        # that reached no provider and recorded no fulfillment.
        with self.assertRaises(serializers.ValidationError) as caught:
            checkout_order(
                register_session=self.session,
                lines_data=[
                    {
                        "variant": self.variant,
                        "quantity": Decimal("1"),
                        "effective_unit_price": Decimal("0.00"),
                    }
                ],
                payments_data=[{"method": "cash", "amount": Decimal("0.00")}],
                request=None,
            )
        # Named, so this cannot pass on some unrelated complaint about a
        # zero-value sale.
        self.assertEqual(
            str(caught.exception.detail["variants"][0]["variant_id"]),
            str(self.variant.pk),
        )
        self.assertFalse(Order.objects.exists())

    def test_the_discount_preview_still_prices_a_cart_holding_a_top_up(self):
        # The preview re-uses the checkout LINE serializer and drops the
        # integration payload on purpose — it prices, it does not sell. The
        # guard above therefore lives in checkout, not in that serializer; a
        # preview that 400s would silently stop the cashier's total updating
        # every time a top-up is in the cart.
        preview = DiscountPreviewSerializer(
            data={
                "lines": [{"variant": self.variant.pk, "quantity": "1"}],
            }
        )
        self.assertTrue(preview.is_valid(), preview.errors)


class OptionPricingTests(TestCase):
    """The real shape of a shop's margin: a hand-set list, not one rule."""

    def setUp(self):
        self.account = make_account()
        self.variant = service_variant_for("hdbox")

    def _seed_ladder(self):
        session = _FakeSession(_FakeResponse(AUTHED_PAGE), [_FakeResponse(RENEW_FORM)])
        with patch_session(session):
            options = HdBoxProvider(self.account).offers("12345").options
        record_seen_offers(self.account, options)
        return options

    def test_options_are_learned_from_a_real_lookup(self):
        # There is no catalog endpoint — the ladder only exists inside a
        # per-card renew form — so a lookup is where Settings learns it.
        self._seed_ladder()
        codes = set(
            self.account.option_prices.values_list("option_code", flat=True)
        )
        self.assertEqual(codes, {"renew:1", "renew:3", "renew:12"})
        row = self.account.option_prices.get(option_code="renew:12")
        self.assertEqual(row.last_cost, Decimal("220.00"))
        self.assertIsNone(row.price)  # the shop has chosen nothing…
        # …but HD Box's own recommended retail is there from the first lookup,
        # so a newly connected shop is not left reselling at cost.
        self.assertEqual(row.suggested_price, Decimal("240.00"))
        self.assertTrue(row.is_suggested)
        self.assertEqual(row.effective_price, Decimal("240.00"))

    def test_the_whole_recommended_ladder_is_seeded(self):
        self._seed_ladder()
        seeded = {
            row.option_code: row.suggested_price
            for row in self.account.option_prices.all()
        }
        self.assertEqual(seeded["renew:1"], Decimal("30.00"))
        self.assertEqual(seeded["renew:3"], Decimal("80.00"))
        self.assertEqual(seeded["renew:12"], Decimal("240.00"))
        self.assertEqual(seeded["renew:6"] if "renew:6" in seeded else None, None)

    def test_a_shop_price_overrides_the_recommendation(self):
        self._seed_ladder()
        row = self.account.option_prices.get(option_code="renew:12")
        row.price = Decimal("250.00")
        row.save()
        row.refresh_from_db()
        self.assertFalse(row.is_suggested)
        self.assertEqual(row.effective_price, Decimal("250.00"))
        self.assertEqual(
            self.account.selling_price(Decimal("220.00"), "renew:12"),
            Decimal("250.00"),
        )

    def test_clearing_a_shop_price_falls_back_to_the_recommendation(self):
        # Not to cost: the provider's card is a better default than nothing.
        self._seed_ladder()
        row = self.account.option_prices.get(option_code="renew:12")
        row.price = Decimal("250.00")
        row.save()
        row.price = None
        row.save()
        self.assertEqual(
            self.account.selling_price(Decimal("220.00"), "renew:12"),
            Decimal("240.00"),
        )

    def test_a_recommendation_below_live_cost_is_still_floored(self):
        # Reference data goes stale when a provider raises its price.
        self._seed_ladder()
        row = self.account.option_prices.get(option_code="renew:12")
        row.last_cost = Decimal("260.00")
        row.save()
        self.assertTrue(row.is_below_cost)
        self.assertEqual(
            self.account.selling_price(Decimal("260.00"), "renew:12"),
            Decimal("260.00"),
        )

    def test_a_cost_change_updates_the_row_without_touching_the_price(self):
        self._seed_ladder()
        row = self.account.option_prices.get(option_code="renew:12")
        row.price = Decimal("240.00")
        row.save()

        # The provider raises its price, as HD Box did between 2024 and 2026.
        dearer = RechargeOption(
            code="renew:12", kind="renew", label="12 month", cost=Decimal("250.00"), months=12
        )
        record_seen_offers(self.account, [dearer])

        row.refresh_from_db()
        self.assertEqual(row.last_cost, Decimal("250.00"))
        self.assertEqual(row.price, Decimal("240.00"))  # the shop's choice stands
        self.assertTrue(row.is_below_cost)  # …and is now visibly wrong

    def test_the_real_field_ladder_prices_exactly(self):
        # 25/65/125/220 selling at 30/80/140/240 — neither a fixed amount nor
        # a fixed percentage, which is why per-option prices exist at all.
        self._seed_ladder()
        wanted = {
            "renew:1": Decimal("30.00"),
            "renew:3": Decimal("80.00"),
            "renew:12": Decimal("240.00"),
        }
        for code, price in wanted.items():
            row = self.account.option_prices.get(option_code=code)
            row.price = price
            row.save()

        prices = self.account.option_price_map()
        self.assertEqual(
            self.account.selling_price(Decimal("25.00"), "renew:1", prices=prices),
            Decimal("30.00"),
        )
        self.assertEqual(
            self.account.selling_price(Decimal("65.00"), "renew:3", prices=prices),
            Decimal("80.00"),
        )
        self.assertEqual(
            self.account.selling_price(Decimal("220.00"), "renew:12", prices=prices),
            Decimal("240.00"),
        )

    def test_an_option_with_no_recommendation_falls_back_to_the_markup(self):
        # An option the published card does not cover — a duration HD Box
        # adds later, say — still gets a price rather than selling at cost.
        self._seed_ladder()
        self.account.markup_kind = IntegrationAccount.Markup.AMOUNT
        self.account.markup_value = Decimal("10")
        self.account.save()
        self.assertEqual(
            self.account.selling_price(Decimal("5.00"), "renew:99"), Decimal("15.00")
        )

    def test_an_override_below_cost_is_floored(self):
        self._seed_ladder()
        row = self.account.option_prices.get(option_code="renew:12")
        row.price = Decimal("100.00")
        row.save()
        # Never sell below what the float pays, whatever the list says.
        self.assertEqual(
            self.account.selling_price(Decimal("220.00"), "renew:12"),
            Decimal("220.00"),
        )

    def test_a_sale_uses_the_per_option_price(self):
        self._seed_ladder()
        row = self.account.option_prices.get(option_code="renew:12")
        row.price = Decimal("240.00")
        row.save()

        resolved = resolve_line_integration(
            {
                "provider": "hdbox",
                "subscriber_ref": "210906803499",
                "option_code": "renew:12",
                "months": 12,
                "cost": Decimal("220.00"),
            },
            self.variant,
        )
        self.assertEqual(resolved["price"], Decimal("240.00"))
        self.assertEqual(resolved["cost"], Decimal("220.00"))


class PriceListApiTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        User = get_user_model()
        self.manager = User.objects.create_user(username="mgr2", password="x")
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.cashier = User.objects.create_user(username="csh2", password="x")
        self.cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.client = APIClient()
        self.account = make_account()
        session = _FakeSession(_FakeResponse(AUTHED_PAGE), [_FakeResponse(RENEW_FORM)])
        with patch_session(session):
            record_seen_offers(
                self.account, HdBoxProvider(self.account).offers("12345").options
            )

    def test_manager_sets_the_ladder_and_sees_the_margin(self):
        self.client.force_authenticate(self.manager)
        resp = self.client.put(
            "/api/integrations/hdbox/prices/",
            {
                "prices": [
                    {"option_code": "renew:1", "price": "30.00"},
                    {"option_code": "renew:12", "price": "240.00"},
                ]
            },
            format="json",
        )
        self.assertEqual(resp.status_code, 200)
        by_code = {row["option_code"]: row for row in resp.data["options"]}
        self.assertEqual(by_code["renew:1"]["price"], Decimal("30.00"))
        self.assertEqual(by_code["renew:1"]["margin"], Decimal("5.00"))
        self.assertEqual(by_code["renew:12"]["margin"], Decimal("20.00"))
        # Untouched by the owner, so still on the provider's recommendation.
        self.assertIsNone(by_code["renew:3"]["price"])
        self.assertTrue(by_code["renew:3"]["is_suggested"])
        self.assertEqual(by_code["renew:3"]["effective_price"], Decimal("80.00"))

    def test_clearing_a_price_restores_the_fallback(self):
        self.client.force_authenticate(self.manager)
        self.client.put(
            "/api/integrations/hdbox/prices/",
            {"prices": [{"option_code": "renew:1", "price": "30.00"}]},
            format="json",
        )
        self.client.put(
            "/api/integrations/hdbox/prices/",
            {"prices": [{"option_code": "renew:1", "price": None}]},
            format="json",
        )
        # Cleared back to HD Box's recommendation, not to nothing.
        self.assertEqual(
            self.account.option_price_map()["renew:1"], Decimal("30.00")
        )

    def test_an_unseen_option_cannot_be_priced(self):
        self.client.force_authenticate(self.manager)
        resp = self.client.put(
            "/api/integrations/hdbox/prices/",
            {"prices": [{"option_code": "renew:99", "price": "5.00"}]},
            format="json",
        )
        self.assertEqual(resp.status_code, 400)
        self.assertEqual(resp.data["option_codes"], ["renew:99"])

    def test_a_cashier_cannot_set_prices(self):
        self.client.force_authenticate(self.cashier)
        resp = self.client.put(
            "/api/integrations/hdbox/prices/",
            {"prices": [{"option_code": "renew:1", "price": "1.00"}]},
            format="json",
        )
        self.assertEqual(resp.status_code, 403)

    def test_the_card_call_quotes_the_shops_own_prices(self):
        self.client.force_authenticate(self.manager)
        self.client.put(
            "/api/integrations/hdbox/prices/",
            {"prices": [{"option_code": "renew:12", "price": "240.00"}]},
            format="json",
        )
        card_json = (
            '{"status":"success","total":1,"rows":[{"cardNo":210906803499,'
            '"status":"On hold","statusId":6,"expireDay":1785621599}]}'
        )
        session = _FakeSession(
            _FakeResponse(AUTHED_PAGE),
            routes={
                LIST_PATH: _FakeResponse(card_json),
                RENEW_VIEW_PATH: _FakeResponse(RENEW_FORM),
                DETAIL_VIEW_PATH: _FakeResponse(DETAIL_FORM),
            },
        )
        with patch_session(session):
            resp = self.client.get("/api/integrations/hdbox/card/?card_no=210906803499")

        offers = {o["code"]: o for o in resp.data["offers"]}
        self.assertEqual(offers["renew:12"]["cost"], Decimal("220.00"))
        self.assertEqual(offers["renew:12"]["price"], Decimal("240.00"))
        # An option the owner never touched quotes the provider's own
        # recommended retail, not cost.
        self.assertEqual(offers["renew:3"]["price"], Decimal("80.00"))


class FloatLedgerTests(TestCase):
    """A float is the shop's money in someone else's hands."""

    def setUp(self):
        self.account = make_account()
        # A shop already has a default cash box; take it rather than adding
        # a second one the unique-default constraint would refuse.
        self.cash = MoneyAccount.objects.filter(
            kind=MoneyAccount.Kind.CASH
        ).first() or MoneyAccount.objects.create(
            name="الصندوق", kind=MoneyAccount.Kind.CASH, is_default=True
        )

    def _fulfilment(self, cost, *, status, when=None):
        order = Order.objects.create()
        line = OrderLine.objects.create(
            order=order,
            variant=service_variant_for("hdbox"),
            quantity=Decimal("1"),
            unit_price=Decimal(cost),
            unit_cost=Decimal(cost),
        )
        return IntegrationFulfillment.objects.create(
            order_line=line,
            account=self.account,
            provider="hdbox",
            subscriber_ref="1",
            option_code="renew:12",
            cost=Decimal(cost),
            status=status,
            confirmed_at=when,
        )

    def test_a_top_up_moves_money_rather_than_spending_it(self):
        float_ledger.record_top_up(
            self.account, amount=Decimal("1000.00"), from_account=self.cash
        )

        transfer = MoneyTransfer.objects.get()
        self.assertEqual(transfer.from_account, self.cash)
        self.assertEqual(transfer.to_account, self.account.money_account)
        self.assertEqual(transfer.amount, Decimal("1000.00"))
        # Not an expense: the shop still has the money, somewhere else.
        self.assertFalse(Expense.objects.exists())

    def test_the_float_account_is_never_a_default(self):
        # Untagged cash and card takings must never land in a provider float.
        float_ledger.record_top_up(self.account, amount=Decimal("100.00"))
        money_account = self.account.money_account
        self.assertEqual(money_account.kind, MoneyAccount.Kind.PROVIDER)
        self.assertFalse(money_account.is_default)

    def test_only_confirmed_draws_reduce_the_balance(self):
        float_ledger.record_top_up(
            self.account, amount=Decimal("1000.00"), from_account=self.cash
        )
        self._fulfilment("220.00", status=IntegrationFulfillment.Status.CONFIRMED,
                         when=timezone.now())
        self._fulfilment("65.00", status=IntegrationFulfillment.Status.PENDING)

        self.assertEqual(float_ledger.drawn(self.account), Decimal("220.00"))
        self.assertEqual(float_ledger.committed(self.account), Decimal("65.00"))
        # The pending one is still money sitting with the provider.
        self.assertEqual(
            float_ledger.expected_balance(self.account), Decimal("780.00")
        )

    def test_the_float_shows_up_in_the_money_position(self):
        float_ledger.record_top_up(
            self.account, amount=Decimal("1000.00"), from_account=self.cash
        )
        self._fulfilment("220.00", status=IntegrationFulfillment.Status.CONFIRMED,
                         when=timezone.now())

        position = treasury_position()
        floats = [
            row
            for row in position["accounts"]
            if row["account"].kind == MoneyAccount.Kind.PROVIDER
        ]
        self.assertEqual(len(floats), 1)
        self.assertEqual(floats[0]["expected_balance"], Decimal("780.00"))
        codes = {part["code"] for part in floats[0]["components"]}
        self.assertIn("integration_draw", codes)
        self.assertIn("transfer_in", codes)

    def test_a_top_up_moves_money_out_of_spendable_and_into_the_float(self):
        """Two different totals, and the difference is the point.

        ``total`` is what the shop can spend — cash and bank — and paying a
        provider really does reduce it: the money is locked in a float now and
        cannot pay a wage. What must not change is the shop's money *overall*,
        because nothing was consumed.
        """
        before = treasury_position()["totals"]
        float_ledger.record_top_up(
            self.account, amount=Decimal("1000.00"), from_account=self.cash
        )
        after = treasury_position()["totals"]

        self.assertEqual(after["total"], before["total"] - Decimal("1000.00"))
        self.assertEqual(
            after["provider_float"], before["provider_float"] + Decimal("1000.00")
        )
        self.assertEqual(
            after["total"] + after["provider_float"],
            before["total"] + before["provider_float"],
        )


class FloatApiTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        User = get_user_model()
        self.manager = User.objects.create_user(username="mgr3", password="x")
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.cashier = User.objects.create_user(username="csh3", password="x")
        self.cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.client = APIClient()
        self.account = make_account()
        # A shop already has a default cash box; take it rather than adding
        # a second one the unique-default constraint would refuse.
        self.cash = MoneyAccount.objects.filter(
            kind=MoneyAccount.Kind.CASH
        ).first() or MoneyAccount.objects.create(
            name="الصندوق", kind=MoneyAccount.Kind.CASH, is_default=True
        )

    def test_recording_a_top_up(self):
        self.client.force_authenticate(self.manager)
        resp = self.client.post(
            "/api/integrations/hdbox/float/",
            {
                "amount": "1000.00",
                "from_account": self.cash.id,
                "reference": "حوالة 8891",
            },
            format="json",
        )
        self.assertEqual(resp.status_code, 201)
        self.assertEqual(resp.data["topped_up"], Decimal("1000.00"))
        self.assertEqual(resp.data["expected_balance"], Decimal("1000.00"))
        self.assertEqual(MoneyTransfer.objects.get().reference, "حوالة 8891")

    def test_the_drift_against_the_providers_own_number_is_reported(self):
        self.account.balance = Decimal("25.00")
        self.account.save(update_fields=["balance"])
        # The single most useful thing here: Pointy says 1000, HD Box says
        # 25, so 975 left the float outside Pointy.
        self.client.force_authenticate(self.manager)
        self.client.post(
            "/api/integrations/hdbox/float/",
            {"amount": "1000.00", "from_account": self.cash.id},
            format="json",
        )
        resp = self.client.get("/api/integrations/hdbox/float/")
        self.assertEqual(resp.data["reported_balance"], Decimal("25.00"))
        self.assertEqual(resp.data["drift"], Decimal("-975.00"))

    def test_a_float_cannot_fund_another_float(self):
        self.client.force_authenticate(self.manager)
        self.client.post(
            "/api/integrations/hdbox/float/", {"amount": "10.00"}, format="json"
        )
        self.account.refresh_from_db()
        other = self.account.money_account
        resp = self.client.post(
            "/api/integrations/hdbox/float/",
            {"amount": "10.00", "from_account": other.id},
            format="json",
        )
        self.assertEqual(resp.status_code, 400)

    def test_an_accountant_can_record_a_top_up_without_managing_the_account(self):
        # The whole point of the separate right: the person who paid is not
        # the person who configures the provider.
        User = get_user_model()
        accountant = User.objects.create_user(username="acct", password="x")
        accountant.groups.add(Group.objects.get(name=ACCOUNTANT_GROUP))
        self.client.force_authenticate(accountant)

        self.assertFalse(accountant.has_perm("integrations.manage_integrations"))
        resp = self.client.post(
            "/api/integrations/hdbox/float/",
            {"amount": "500.00"},
            format="json",
        )
        self.assertEqual(resp.status_code, 201)
        self.assertEqual(resp.data["topped_up"], Decimal("500.00"))

    def test_an_accountant_can_read_the_float(self):
        User = get_user_model()
        accountant = User.objects.create_user(username="acct2", password="x")
        accountant.groups.add(Group.objects.get(name=ACCOUNTANT_GROUP))
        self.client.force_authenticate(accountant)
        self.assertEqual(
            self.client.get("/api/integrations/hdbox/float/").status_code, 200
        )

    def test_a_cashier_still_cannot_top_up(self):
        # Recording a float top-up moves real money in the books; it stays
        # with the roles that already record money going out.
        self.client.force_authenticate(self.cashier)
        resp = self.client.post(
            "/api/integrations/hdbox/float/", {"amount": "10.00"}, format="json"
        )
        self.assertEqual(resp.status_code, 403)

    def test_an_accountant_still_cannot_change_the_credentials(self):
        User = get_user_model()
        accountant = User.objects.create_user(username="acct3", password="x")
        accountant.groups.add(Group.objects.get(name=ACCOUNTANT_GROUP))
        self.client.force_authenticate(accountant)
        resp = self.client.put(
            "/api/integrations/hdbox/",
            {"username": "x", "password": "y"},
            format="json",
        )
        self.assertEqual(resp.status_code, 403)


class ReconciliationTests(TestCase):
    """Proving a sale happened — and refusing to pretend when it cannot."""

    def setUp(self):
        self.account = make_account(username="Alnassim")
        self.cash = MoneyAccount.objects.filter(
            kind=MoneyAccount.Kind.CASH
        ).first() or MoneyAccount.objects.create(
            name="الصندوق", kind=MoneyAccount.Kind.CASH, is_default=True
        )

    def _sold(self, *, cost="220.00", card="210906803499", ago=timedelta(hours=1)):
        order = Order.objects.create()
        line = OrderLine.objects.create(
            order=order,
            variant=service_variant_for("hdbox"),
            quantity=Decimal("1"),
            unit_price=Decimal("240.00"),
            unit_cost=Decimal(cost),
        )
        row = IntegrationFulfillment.objects.create(
            order_line=line,
            account=self.account,
            provider="hdbox",
            subscriber_ref=card,
            option_code="renew:12",
            cost=Decimal(cost),
        )
        IntegrationFulfillment.objects.filter(pk=row.pk).update(
            created_at=timezone.now() - ago
        )
        row.refresh_from_db()
        return row

    def _run(self, buy_log_rows):
        body = (
            '{"status":"success","total":%d,"rows":[%s]}'
            % (len(buy_log_rows), ",".join(buy_log_rows))
        )
        session = _FakeSession(
            _FakeResponse(AUTHED_PAGE),
            # probe → home page, then one buy-log fetch per distinct card
            [_FakeResponse(AUTHED_PAGE)] + [_FakeResponse(body)] * 4,
        )
        with patch_session(session):
            return reconcile_account(self.account)

    @staticmethod
    def _entry(ref, cost, operator="Alnassim", when=None):
        at = int((when or timezone.now()).timestamp())
        return (
            '{"id":%s,"cost":%s,"month":12,"buyDate":%d,"type":2,'
            '"packageName":"HDBOX Full package","operatorName":"%s"}'
            % (ref, cost, at, operator)
        )

    def test_a_matching_purchase_confirms_the_sale(self):
        row = self._sold()
        result = self._run([self._entry("523415", "220.00")])

        self.assertEqual(result["confirmed"], 1)
        row.refresh_from_db()
        self.assertEqual(row.status, IntegrationFulfillment.Status.CONFIRMED)
        self.assertEqual(row.provider_reference, "523415")
        self.assertIsNotNone(row.confirmed_at)
        # The provider's own record, kept for printing beside our invoice.
        self.assertEqual(row.provider_receipt["cost"], "220.00")
        self.assertEqual(row.provider_receipt["operator_name"], "Alnassim")

    def test_one_provider_entry_cannot_confirm_two_sales(self):
        # Otherwise a single recharge would clear both, and a customer who
        # paid twice and got one renewal would look fully served.
        self._sold()
        self._sold()
        result = self._run([self._entry("523415", "220.00")])
        self.assertEqual(result["confirmed"], 1)
        self.assertEqual(
            IntegrationFulfillment.objects.filter(
                status=IntegrationFulfillment.Status.PENDING
            ).count(),
            1,
        )

    def test_a_different_amount_is_not_a_match(self):
        self._sold(cost="220.00")
        result = self._run([self._entry("523415", "65.00")])
        self.assertEqual(result["confirmed"], 0)

    def test_a_purchase_made_before_the_sale_is_not_a_match(self):
        # It belongs to an earlier renewal, not to the one just rung up.
        self._sold(ago=timedelta(hours=1))
        result = self._run(
            [self._entry("111", "220.00", when=timezone.now() - timedelta(days=3))]
        )
        self.assertEqual(result["confirmed"], 0)

    def test_another_agencys_purchase_is_never_ours(self):
        self._sold()
        result = self._run([self._entry("999", "220.00", operator="zhra")])
        self.assertEqual(result["confirmed"], 0)

    def test_a_purchase_no_sale_explains_is_reported_as_off_book(self):
        # Cash taken at the counter and the recharge done on the portal.
        self._sold()
        result = self._run(
            [self._entry("523415", "220.00"), self._entry("777", "220.00")]
        )
        self.assertEqual(result["confirmed"], 1)
        self.assertEqual(len(result["off_book"]), 1)
        self.assertEqual(result["off_book"][0]["reference"], "777")

    def test_sold_long_ago_and_still_not_performed_is_reported(self):
        self._sold(ago=timedelta(days=2))
        result = self._run([])
        self.assertEqual(len(result["unperformed"]), 1)
        self.assertEqual(result["unperformed"][0]["card_no"], "210906803499")

    def test_a_fresh_sale_is_not_yet_a_problem(self):
        # The cashier may still be typing it into the portal.
        self._sold(ago=timedelta(minutes=5))
        result = self._run([])
        self.assertEqual(result["unperformed"], [])

    def test_drift_is_reported_against_the_providers_own_balance(self):
        float_ledger.record_top_up(
            self.account, amount=Decimal("1000.00"), from_account=self.cash
        )
        result = self._run([])
        # The probe reads 25.00 off the page; we expect 1000.00.
        self.assertEqual(result["reported_balance"], Decimal("25.00"))
        self.assertEqual(result["expected_balance"], Decimal("1000.00"))
        self.assertEqual(result["drift"], Decimal("-975.00"))
        self.assertTrue(result["drift_material"])

    def test_an_unreachable_provider_confirms_nothing_and_says_so(self):
        self._sold()
        session = _FakeSession(_FakeResponse(LOGIN_PAGE), [])
        with patch_session(session):
            result = reconcile_account(self.account)
        self.assertFalse(result["ok"])
        self.assertEqual(result["confirmed"], 0)

    def test_a_confirmed_sale_draws_the_float_down(self):
        float_ledger.record_top_up(
            self.account, amount=Decimal("1000.00"), from_account=self.cash
        )
        self._sold()
        self.assertEqual(
            float_ledger.expected_balance(self.account), Decimal("1000.00")
        )
        self._run([self._entry("523415", "220.00")])
        # Only now, once the provider is known to have performed it.
        self.assertEqual(
            float_ledger.expected_balance(self.account), Decimal("780.00")
        )


class ReconciliationNotificationTests(TestCase):
    def setUp(self):
        self.account = make_account(username="Alnassim")

    def test_an_unperformed_recharge_reaches_the_alert_feed(self):
        order = Order.objects.create()
        line = OrderLine.objects.create(
            order=order,
            variant=service_variant_for("hdbox"),
            quantity=Decimal("1"),
            unit_price=Decimal("240.00"),
            unit_cost=Decimal("220.00"),
        )
        row = IntegrationFulfillment.objects.create(
            order_line=line,
            account=self.account,
            provider="hdbox",
            subscriber_ref="210906803499",
            option_code="renew:12",
            cost=Decimal("220.00"),
        )
        IntegrationFulfillment.objects.filter(pk=row.pk).update(
            created_at=timezone.now() - timedelta(days=1)
        )

        sync_business_notifications()
        alert = BusinessNotification.objects.get(
            code="integrations.unperformed_recharge"
        )
        self.assertEqual(alert.severity, BusinessNotification.Severity.CRITICAL)
        self.assertEqual(alert.payload["card_no"], "210906803499")

    def test_performing_it_clears_the_alert(self):
        self.test_an_unperformed_recharge_reaches_the_alert_feed()
        IntegrationFulfillment.objects.update(
            status=IntegrationFulfillment.Status.CONFIRMED,
            confirmed_at=timezone.now(),
        )
        sync_business_notifications()
        alert = BusinessNotification.objects.get(
            code="integrations.unperformed_recharge"
        )
        self.assertEqual(alert.status, BusinessNotification.Status.RESOLVED)

    def test_the_nightly_sweep_is_scheduled(self):
        self.assertIn(
            "integrations.reconcile-providers", settings.CELERY_BEAT_SCHEDULE
        )


class LowFloatNotificationTests(TestCase):
    """The float warning, and the threshold the owner sets it against."""

    def setUp(self):
        self.account = make_account(username="Alnassim")

    def _set_balance(self, amount):
        self.account.balance = Decimal(amount)
        self.account.balance_at = timezone.now()
        self.account.save(update_fields=["balance", "balance_at"])

    def _alert(self):
        return BusinessNotification.objects.filter(
            code="integrations.low_float",
            status=BusinessNotification.Status.ACTIVE,
        ).first()

    def test_a_float_under_the_threshold_warns(self):
        self._set_balance("180.00")  # hdbox default threshold is 250
        sync_business_notifications()
        alert = self._alert()
        self.assertIsNotNone(alert)
        self.assertEqual(alert.severity, BusinessNotification.Severity.WARNING)
        self.assertEqual(alert.payload["provider"], "hdbox")
        self.assertEqual(alert.payload["amount"], "180.00")
        self.assertEqual(alert.payload["threshold"], "250.00")
        self.assertEqual(alert.payload["currency"], "LYD")

    def test_a_healthy_float_says_nothing(self):
        self._set_balance("900.00")
        sync_business_notifications()
        self.assertIsNone(self._alert())

    def test_the_threshold_is_the_shops_own(self):
        # The default would fire at 180; an owner who runs a thin float and
        # says so must not be warned at all.
        self.account.config = {catalog.SETTING_LOW_BALANCE_THRESHOLD: "100"}
        self.account.save(update_fields=["config"])
        self._set_balance("180.00")
        sync_business_notifications()
        self.assertIsNone(self._alert())

        # ...and the same shop is warned at its own number.
        self._set_balance("90.00")
        sync_business_notifications()
        self.assertIsNotNone(self._alert())

    def test_zero_turns_the_warning_off_even_on_an_empty_float(self):
        # An owner who switched it off and then got a critical alert anyway
        # would conclude the switch does not work.
        self.account.config = {catalog.SETTING_LOW_BALANCE_THRESHOLD: "0"}
        self.account.save(update_fields=["config"])
        self._set_balance("0.00")
        sync_business_notifications()
        self.assertIsNone(self._alert())

    def test_an_exhausted_float_is_critical_and_re_reaches_a_dismissed_reader(
        self,
    ):
        self._set_balance("40.00")
        sync_business_notifications()
        warning = self._alert()
        self.assertEqual(warning.severity, BusinessNotification.Severity.WARNING)

        self._set_balance("0.00")
        sync_business_notifications()
        critical = self._alert()
        self.assertEqual(critical.severity, BusinessNotification.Severity.CRITICAL)
        # A separate row, so somebody who acknowledged "getting low" is still
        # told "cannot sell anything" — an in-place severity bump would leave
        # the acknowledgement standing and the bell silent.
        self.assertNotEqual(critical.pk, warning.pk)
        warning.refresh_from_db()
        self.assertEqual(warning.status, BusinessNotification.Status.RESOLVED)

    def test_topping_the_float_up_clears_it(self):
        self._set_balance("40.00")
        sync_business_notifications()
        self.assertIsNotNone(self._alert())
        self._set_balance("900.00")
        sync_business_notifications()
        self.assertIsNone(self._alert())

    def test_a_float_nobody_has_read_is_never_called_low(self):
        self.assertIsNone(self.account.balance)
        sync_business_notifications()
        self.assertIsNone(self._alert())

    def test_a_provider_with_no_credentials_is_not_warned_about(self):
        # The stored balance is a memory of a float we can no longer read.
        self._set_balance("10.00")
        self.account.secrets_encrypted = ""
        self.account.save(update_fields=["secrets_encrypted"])
        sync_business_notifications()
        self.assertIsNone(self._alert())

    def test_a_disconnected_provider_is_not_warned_about(self):
        self._set_balance("10.00")
        self.account.is_active = False
        self.account.save(update_fields=["is_active"])
        sync_business_notifications()
        self.assertIsNone(self._alert())

    def test_it_needs_no_money_account(self):
        # A shop that has never recorded a top-up in Pointy still has a float,
        # and is the shop most likely to be surprised by it running out.
        self.assertIsNone(self.account.money_account_id)
        self._set_balance("10.00")
        sync_business_notifications()
        self.assertIsNotNone(self._alert())

    def test_two_providers_are_two_alerts(self):
        lnet = lnet_account()
        lnet.balance = Decimal("20.00")  # lnet default threshold is 100
        lnet.balance_at = timezone.now()
        lnet.save(update_fields=["balance", "balance_at"])
        self._set_balance("40.00")
        sync_business_notifications()
        providers = {
            row.payload["provider"]
            for row in BusinessNotification.objects.filter(
                code="integrations.low_float",
                status=BusinessNotification.Status.ACTIVE,
            )
        }
        self.assertEqual(providers, {"hdbox", "lnet"})

    def test_the_hourly_refresh_is_scheduled(self):
        self.assertIn(
            "integrations.refresh-float-balances", settings.CELERY_BEAT_SCHEDULE
        )


class LowFloatThresholdSettingTests(TestCase):
    """The threshold as a declared setting, on every provider that has a float."""

    def setUp(self):
        ensure_role_groups()
        self.manager = get_user_model().objects.create_user(
            username="owner", password="pw"
        )
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client = APIClient()
        self.client.force_authenticate(self.manager)

    def test_every_provider_that_reports_a_balance_can_warn_on_it(self):
        # The guard against the next provider shipping with a float nobody can
        # be warned about.
        for spec in catalog.PROVIDERS:
            if catalog.CAPABILITY_BALANCE not in spec.capabilities:
                continue
            with self.subTest(provider=spec.key):
                setting = spec.setting(catalog.SETTING_LOW_BALANCE_THRESHOLD)
                self.assertIsNotNone(setting, f"{spec.key} declares no threshold")
                self.assertEqual(setting.kind, catalog.SETTING_KIND_AMOUNT)
                self.assertEqual(setting.minimum, Decimal("0"))
                self.assertGreater(Decimal(setting.default), 0)

    def test_the_catalog_publishes_it_with_its_value(self):
        make_account()
        resp = self.client.get("/api/integrations/")
        hdbox_payload = {p["key"]: p for p in resp.data["providers"]}["hdbox"]
        by_key = {item["key"]: item for item in hdbox_payload["settings"]}
        threshold = by_key[catalog.SETTING_LOW_BALANCE_THRESHOLD]
        self.assertEqual(threshold["kind"], catalog.SETTING_KIND_AMOUNT)
        self.assertEqual(threshold["value"], "250")

    def test_an_owner_can_change_it(self):
        make_account()
        resp = self.client.put(
            "/api/integrations/hdbox/",
            {"settings": {catalog.SETTING_LOW_BALANCE_THRESHOLD: "600"}},
            format="json",
        )
        self.assertEqual(resp.status_code, 200)
        account = IntegrationAccount.objects.get(provider="hdbox")
        self.assertEqual(
            account.setting(catalog.SETTING_LOW_BALANCE_THRESHOLD), "600"
        )

    def test_a_negative_threshold_is_refused_not_stored(self):
        make_account()
        resp = self.client.put(
            "/api/integrations/hdbox/",
            {"settings": {catalog.SETTING_LOW_BALANCE_THRESHOLD: "-5"}},
            format="json",
        )
        self.assertEqual(resp.status_code, 400)
        self.assertIn(catalog.SETTING_LOW_BALANCE_THRESHOLD, resp.data["settings"])
        self.assertEqual(
            IntegrationAccount.objects.get(provider="hdbox").setting(
                catalog.SETTING_LOW_BALANCE_THRESHOLD
            ),
            "250",
            "the stored value must survive a rejected write",
        )

    def test_an_extra_zero_is_refused_rather_than_pinning_the_warning_on(self):
        make_account()
        resp = self.client.put(
            "/api/integrations/hdbox/",
            {"settings": {catalog.SETTING_LOW_BALANCE_THRESHOLD: "50000000"}},
            format="json",
        )
        self.assertEqual(resp.status_code, 400)


class FloatBalanceRefreshTests(TestCase):
    """The hourly probe that keeps the warning's number current."""

    def test_it_probes_each_connected_provider_that_has_a_float(self):
        make_account()
        lnet_account()
        with mock.patch(
            "apps.integrations.services.probe_account",
            return_value=ProbeResult(ok=True, balance=Decimal("5.00")),
        ) as probe:
            result = refresh_float_balances()
        self.assertEqual(result, {"checked": 2, "connected": 2})
        self.assertEqual(
            {call.args[0].provider for call in probe.call_args_list},
            {"hdbox", "lnet"},
        )

    def test_an_unconfigured_provider_is_not_probed_every_hour(self):
        account = make_account()
        account.secrets_encrypted = ""
        account.save(update_fields=["secrets_encrypted"])
        with mock.patch("apps.integrations.services.probe_account") as probe:
            self.assertEqual(
                refresh_float_balances(), {"checked": 0, "connected": 0}
            )
        probe.assert_not_called()

    def test_one_provider_being_down_does_not_stop_the_next(self):
        make_account()
        lnet_account()
        outcomes = {
            "hdbox": ProbeResult(ok=False, error_code=ERROR_UNREACHABLE),
            "lnet": ProbeResult(ok=True, balance=Decimal("5.00")),
        }
        with mock.patch(
            "apps.integrations.services.probe_account",
            side_effect=lambda account: outcomes[account.provider],
        ):
            self.assertEqual(
                refresh_float_balances(), {"checked": 2, "connected": 1}
            )


class IntegrationAlertAudienceTests(TestCase):
    """Who each provider alert reaches.

    Every one of these was generated, stored and swept while being shown to
    nobody: ``_codes_for_user`` only returns codes that appear in
    ``NOTIFICATION_AUDIENCE_RULES``, and none of the provider codes did.
    """

    def setUp(self):
        ensure_role_groups()
        self.users = {}
        for group in (MANAGER_GROUP, ACCOUNTANT_GROUP, CASHIER_GROUP):
            user = get_user_model().objects.create_user(
                username=f"user-{group}", password="pw"
            )
            user.groups.add(Group.objects.get(name=group))
            self.users[group] = get_user_model().objects.get(pk=user.pk)

    def _codes(self, group):
        from apps.notifications.services import _codes_for_user

        return set(_codes_for_user(self.users[group]))

    def test_every_provider_alert_reaches_somebody(self):
        from apps.notifications.services import (
            MANAGED_CODES,
            NOTIFICATION_AUDIENCE_RULES,
        )

        for code in MANAGED_CODES:
            if not code.startswith("integrations."):
                continue
            with self.subTest(code=code):
                self.assertIn(
                    code,
                    NOTIFICATION_AUDIENCE_RULES,
                    "a code with no audience rule is shown to nobody",
                )

    def test_the_owner_sees_all_of_them(self):
        codes = self._codes(MANAGER_GROUP)
        self.assertIn("integrations.low_float", codes)
        self.assertIn("integrations.float_drift", codes)
        self.assertIn("integrations.unresolved_recharge", codes)

    def test_whoever_refills_the_float_is_told_it_is_low(self):
        # The accountant walks to the provider's office with the money; the
        # owner may be nowhere near the shop.
        self.assertIn("integrations.low_float", self._codes(ACCOUNTANT_GROUP))

    def test_a_cashier_sees_the_sale_that_failed_but_not_the_float(self):
        codes = self._codes(CASHIER_GROUP)
        self.assertIn("integrations.unperformed_recharge", codes)
        self.assertNotIn("integrations.float_drift", codes)
        self.assertNotIn("integrations.low_float", codes)


class SubscriberTests(TestCase):
    """The provider supplies the subscription; Pointy supplies the person."""

    def setUp(self):
        ensure_role_groups()
        User = get_user_model()
        self.cashier = User.objects.create_user(username="csh4", password="x")
        self.cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.client = APIClient()
        self.client.force_authenticate(self.cashier)
        self.account = make_account()

    def test_a_masked_identity_is_stored_as_blank_not_as_dashes(self):
        session = _FakeSession(_FakeResponse(AUTHED_PAGE), [_FakeResponse(DETAIL_FORM)])
        with patch_session(session):
            result = HdBoxProvider(self.account).subscriber_profile("210906803499")

        self.assertTrue(result.ok)
        profile = result.profile
        self.assertEqual(profile.display_name, "")
        self.assertEqual(profile.phone, "")
        self.assertEqual(profile.device_model, "R-10000 Plus")
        self.assertEqual(profile.lifetime_spend, Decimal("750.00"))
        self.assertEqual(profile.purchase_count, 6)
        self.assertEqual(profile.expire_at.date().isoformat(), "2026-08-01")

    def test_a_cashier_can_name_the_card_and_it_sticks(self):
        resp = self.client.put(
            "/api/integrations/hdbox/subscribers/210906803499/",
            {"display_name": "أحمد"},
            format="json",
        )
        self.assertEqual(resp.status_code, 200)
        self.assertTrue(resp.data["is_identified"])
        self.assertEqual(resp.data["label"], "أحمد")

    def test_a_sync_never_overwrites_a_name_somebody_typed(self):
        # The provider does not know who this is; a refresh must not erase
        # the one thing the shop does know.
        self.client.put(
            "/api/integrations/hdbox/subscribers/210906803499/",
            {"display_name": "أحمد"},
            format="json",
        )
        session = _FakeSession(_FakeResponse(AUTHED_PAGE), [_FakeResponse(DETAIL_FORM)])
        with patch_session(session):
            profile = HdBoxProvider(self.account).subscriber_profile("210906803499")
        record_subscriber(self.account, profile.profile)

        subscriber = IntegrationSubscriber.objects.get(subscriber_ref="210906803499")
        self.assertEqual(subscriber.display_name, "أحمد")
        self.assertEqual(subscriber.device_model, "R-10000 Plus")

    def test_linking_a_real_customer_wins_over_a_typed_name(self):
        customer = Customer.objects.create(full_name="أحمد الطرابلسي")
        self.client.put(
            "/api/integrations/hdbox/subscribers/210906803499/",
            {"display_name": "أحمد"},
            format="json",
        )
        resp = self.client.put(
            "/api/integrations/hdbox/subscribers/210906803499/",
            {"customer": customer.pk},
            format="json",
        )
        self.assertEqual(resp.data["customer_id"], customer.pk)
        self.assertEqual(resp.data["label"], customer.full_name)

    def test_an_unknown_customer_is_refused(self):
        resp = self.client.put(
            "/api/integrations/hdbox/subscribers/210906803499/",
            {"customer": 999999},
            format="json",
        )
        self.assertEqual(resp.status_code, 400)


class TillVisibilityTests(TestCase):
    """Connecting a provider has to reach the tills that are already open."""

    def test_connecting_a_provider_moves_the_settings_counter(self):
        # has_integrations is derived from these rows, so the settings payload
        # changes without the settings row changing. Nothing else would tell a
        # till that its top-up button should now exist.
        # Assert the signal asks for the bump, not that Redis moved: bump()
        # no-ops when state versions are disabled (they are, in tests), so
        # watching the counter would pass for the wrong reason forever.
        from apps.integrations import signals

        with mock.patch.object(signals, "bump") as bump:
            with self.captureOnCommitCallbacks(execute=True):
                make_account()
        bump.assert_any_call("settings")

    def test_the_settings_payload_reports_it(self):
        ensure_role_groups()
        User = get_user_model()
        manager = User.objects.create_user(username="mgr9", password="x")
        manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        client = APIClient()
        client.force_authenticate(manager)

        self.assertEqual(
            client.get("/api/shop-settings/").data["connected_integrations"], []
        )
        make_account()
        # The till needs to know WHICH, not just whether: one provider draws a
        # named button, several draw a menu.
        self.assertEqual(
            client.get("/api/shop-settings/").data["connected_integrations"],
            ["hdbox"],
        )


# --- the write path ---------------------------------------------------------
RENEW_OK = '{"balance":"0.00","id":"558032","message":"Success !","status":"success"}'
RENEW_BROKE = '{"message":"Balance not sufficient !","status":"failure"}'
# The real receipt modal, keeping the two things that caught the first parser
# out: the Total row is COMMENTED OUT by the provider, and the dates are a
# label row above a value row rather than beside it.
RECEIPT_PAGE = """
<div id="printForm"><table>
  <tr><td>CardNo</td><td>210906803499</td></tr>
  <tr><td class='print-left-info'>Package price</td><td class='print-rigth-info'>10.00</td></tr>
  <tr><td class='print-left-info'>Months</td><td class='print-rigth-info'>1</td></tr>
  <tr><td class='print-left-info'>Day</td><td class='print-rigth-info'>0</td></tr>
  <!-- <tr><td class='print-left-info'>Total</td><td class='print-rigth-info'>25.00</td></tr> -->
  <tr><td colspan=2>Start Date</td></tr>
  <tr><td colspan=2>&nbsp;&nbsp;&nbsp;&nbsp;2026-09-20</td></tr>
  <tr><td colspan=2>End Date</td></tr>
  <tr><td colspan=2>&nbsp;&nbsp;&nbsp;&nbsp;2026-10-20</td></tr>
</table></div>
"""


class _WriteSession(_FakeSession):
    """A fake session that can answer the renew POST, not just the login."""

    def __init__(self, login_response, get_responses, *, renew=None, renew_raises=None):
        super().__init__(login_response, get_responses)
        self._renew = renew
        self._renew_raises = renew_raises
        self.renew_calls = []

    def post(self, url, **kwargs):
        if url.endswith("/card/renew"):
            self.renew_calls.append(kwargs.get("data"))
            if self._renew_raises is not None:
                raise self._renew_raises
            return self._renew
        return super().post(url, **kwargs)


class HdBoxRenewPayloadTests(TestCase):
    """The body must be what the provider's own page would have submitted."""

    def _payload(self, months=1, body=RENEW_FORM):
        return hdbox._renew_payload(body, "210906803499", months)

    def test_builds_every_field_the_form_would_have_sent(self):
        payload, error = self._payload()
        self.assertEqual(error, "")
        self.assertEqual(
            payload,
            {
                "token": "eb1c2a63-25d2-4b6f-9091-c0b4a85238d8",
                "changePackage": "0",
                "dealerId": "265",
                "cardNo": "210906803499",
                # The first option of the hidden select — what a browser sends.
                "pid": "1",
                "month": "1",
                # data-expiration + 1 month, in the provider's own timezone.
                "expireDay": "2026/10/20",
                "pay": "25.00",
                "buyDay": "30",
            },
        )

    def test_a_longer_term_moves_the_date_and_the_day_count(self):
        payload, _ = self._payload(months=12)
        self.assertEqual(payload["expireDay"], "2027/09/20")
        self.assertEqual(payload["pay"], "220.00")
        self.assertEqual(payload["buyDay"], "365")

    def test_refuses_a_term_the_form_is_not_offering(self):
        payload, error = self._payload(months=6)
        self.assertIsNone(payload)
        self.assertIn("6 months", error)

    def test_refuses_the_error_page(self):
        payload, error = self._payload(body=ERROR_PAGE)
        self.assertIsNone(payload)
        self.assertIn("error page", error)

    def test_refuses_a_form_with_no_token(self):
        payload, error = self._payload(
            body=RENEW_FORM.replace('name="token"', 'name="nothing"')
        )
        self.assertIsNone(payload)
        self.assertIn("token", error)


class HdBoxRenewReplyTests(TestCase):
    """Three outcomes, and the third one is the whole point."""

    def _classify(self, text, status_code=200):
        return hdbox._classify_renew_reply(_FakeResponse(text, status_code))

    def test_success_carries_the_reference_and_the_new_float(self):
        result = self._classify(RENEW_OK)
        self.assertTrue(result.ok)
        self.assertFalse(result.indeterminate)
        self.assertEqual(result.reference, "558032")
        self.assertEqual(result.balance_after, Decimal("0.00"))

    def test_insufficient_balance_gets_its_own_code(self):
        result = self._classify(RENEW_BROKE)
        self.assertTrue(result.is_definite_failure)
        self.assertEqual(result.error_code, "insufficient_float")

    def test_another_refusal_is_a_provider_error(self):
        result = self._classify('{"status":"failure","message":"Card is locked"}')
        self.assertTrue(result.is_definite_failure)
        self.assertEqual(result.error_code, "provider_error")
        self.assertEqual(result.error_detail, "Card is locked")

    def test_the_html_error_page_is_unknown_not_failed(self):
        # This endpoint answers JSON for both success and refusal, so HTML here
        # is territory we have never seen — and on a money path that is not
        # the same as "it did not happen".
        result = self._classify(ERROR_PAGE)
        self.assertTrue(result.indeterminate)
        self.assertFalse(result.is_definite_failure)

    def test_an_unreadable_reply_is_unknown(self):
        result = self._classify("<h1>502 Bad Gateway</h1>", status_code=502)
        self.assertTrue(result.indeterminate)

    def test_an_unrecognised_status_is_unknown(self):
        result = self._classify('{"status":"maybe","message":"?"}')
        self.assertTrue(result.indeterminate)

    def test_the_login_form_is_a_definite_failure(self):
        # Bounced by the auth filter, which runs before the handler, so this
        # is the one unparseable reply that proves nothing was charged.
        result = self._classify(LOGIN_PAGE)
        self.assertTrue(result.is_definite_failure)
        self.assertEqual(result.error_code, "unauthorized")


class RechargeGuardTests(TransactionTestCase):
    """At most once, ever — including when we never learn what happened.

    TransactionTestCase rather than TestCase on purpose: the guard refuses to
    run inside an open transaction, because a claim that can be rolled back is
    not a claim. TestCase wraps every test in exactly that.
    """

    reset_sequences = True

    def setUp(self):
        ensure_role_groups()
        self.user = get_user_model().objects.create_user(username="till", password="x")
        self.user.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.register = RegisterSession.objects.create(
            owner=self.user, owner_key=f"user:{self.user.pk}"
        )
        self.account = make_account()
        self.variant = service_variant_for("hdbox")

    def _fulfillment(self, cost="25.00", code="renew:1"):
        resolved = resolve_line_integration(
            {
                "provider": "hdbox",
                "subscriber_ref": "210906803499",
                "option_code": code,
                "option_label": "1 month",
                "months": 1,
                "cost": Decimal(cost),
            },
            self.variant,
        )
        order = checkout_order(
            register_session=self.register,
            lines_data=[
                {
                    "variant": self.variant,
                    "quantity": Decimal("1"),
                    "effective_unit_price": resolved["price"],
                    "integration": resolved,
                }
            ],
            payments_data=[{"method": "cash", "amount": resolved["price"]}],
            request=None,
        )
        return IntegrationFulfillment.objects.get(order_line=order.lines.get())

    def _session(self, **kwargs):
        return _WriteSession(
            _FakeResponse(AUTHED_PAGE), [_FakeResponse(RENEW_FORM)], **kwargs
        )

    def test_a_charge_confirms_and_records_what_the_provider_said(self):
        fulfillment = self._fulfillment()
        session = self._session(renew=_FakeResponse(RENEW_OK))
        with patch_session(session):
            outcome = recharge.charge(fulfillment.pk)

        self.assertEqual(outcome.outcome, recharge.OUTCOME_CHARGED)
        fulfillment.refresh_from_db()
        self.assertEqual(fulfillment.status, IntegrationFulfillment.Status.CONFIRMED)
        self.assertEqual(fulfillment.provider_reference, "558032")
        self.assertEqual(fulfillment.attempt_count, 1)
        self.assertIsNotNone(fulfillment.confirmed_at)
        # The write told us the new float, so no second probe was needed.
        self.account.refresh_from_db()
        self.assertEqual(self.account.balance, Decimal("0.00"))

    def test_a_confirmed_row_is_never_charged_again(self):
        fulfillment = self._fulfillment()
        with patch_session(self._session(renew=_FakeResponse(RENEW_OK))):
            recharge.charge(fulfillment.pk)

        second = self._session(renew=_FakeResponse(RENEW_OK))
        with patch_session(second):
            outcome = recharge.charge(fulfillment.pk)

        self.assertEqual(outcome.outcome, recharge.OUTCOME_NOT_CLAIMABLE)
        # Not "it was refused" — nothing was sent at all.
        self.assertEqual(second.renew_calls, [])
        fulfillment.refresh_from_db()
        self.assertEqual(fulfillment.attempt_count, 1)

    def test_an_unknown_outcome_stays_submitted_and_blocks_every_retry(self):
        """The case the whole module exists for."""
        fulfillment = self._fulfillment()
        session = self._session(
            renew_raises=hdbox.requests.ConnectionError("connection reset")
        )
        with patch_session(session):
            outcome = recharge.charge(fulfillment.pk)

        self.assertEqual(outcome.outcome, recharge.OUTCOME_UNKNOWN)
        self.assertTrue(outcome.needs_attention)
        fulfillment.refresh_from_db()
        self.assertEqual(fulfillment.status, IntegrationFulfillment.Status.SUBMITTED)
        self.assertEqual(fulfillment.last_error_code, "indeterminate")
        # The request did leave, so the money may well have moved.
        self.assertEqual(len(session.renew_calls), 1)

        # And now nothing may send a second one.
        again = self._session(renew=_FakeResponse(RENEW_OK))
        with patch_session(again):
            retry = recharge.charge(fulfillment.pk)
        self.assertEqual(retry.outcome, recharge.OUTCOME_NOT_CLAIMABLE)
        self.assertEqual(again.renew_calls, [])

    def test_a_definite_refusal_frees_the_row_to_be_tried_again(self):
        # An empty float is the one failure a shop can fix itself, and the
        # provider proved it took nothing — so this must not strand the sale.
        fulfillment = self._fulfillment()
        with patch_session(self._session(renew=_FakeResponse(RENEW_BROKE))):
            outcome = recharge.charge(fulfillment.pk)

        self.assertEqual(outcome.outcome, recharge.OUTCOME_REFUSED)
        self.assertEqual(outcome.error_code, "insufficient_float")
        fulfillment.refresh_from_db()
        self.assertEqual(fulfillment.status, IntegrationFulfillment.Status.PENDING)

        # Topped up, it goes through — and the attempt count remembers both.
        session = self._session(renew=_FakeResponse(RENEW_OK))
        with patch_session(session):
            self.assertTrue(recharge.charge(fulfillment.pk).ok)
        fulfillment.refresh_from_db()
        self.assertEqual(fulfillment.attempt_count, 2)

    def test_a_driver_that_raises_is_unknown_not_failed(self):
        fulfillment = self._fulfillment()
        with mock.patch(
            "apps.integrations.recharge.provider_for"
        ) as provider:
            provider.return_value.recharge.side_effect = RuntimeError("boom")
            outcome = recharge.charge(fulfillment.pk)

        self.assertEqual(outcome.outcome, recharge.OUTCOME_UNKNOWN)
        fulfillment.refresh_from_db()
        self.assertEqual(fulfillment.status, IntegrationFulfillment.Status.SUBMITTED)

    def test_a_price_that_moved_since_the_quote_is_refused_unsent(self):
        # The customer paid against a quote. Spending a different amount of
        # the shop's money than it agreed to is not ours to decide.
        fulfillment = self._fulfillment(cost="20.00")
        session = self._session(renew=_FakeResponse(RENEW_OK))
        with patch_session(session):
            outcome = recharge.charge(fulfillment.pk)

        self.assertEqual(outcome.outcome, recharge.OUTCOME_REFUSED)
        self.assertIn("price moved", outcome.error_detail)
        self.assertEqual(session.renew_calls, [])

    def test_charging_inside_a_transaction_is_a_programming_error(self):
        fulfillment = self._fulfillment()
        with self.assertRaises(recharge.AtomicBlockError):
            with transaction.atomic():
                recharge.charge(fulfillment.pk)


class IntegrationChargeApiTests(TransactionTestCase):
    """The till's one call after a sale, and the guard behind it."""

    reset_sequences = True

    def setUp(self):
        ensure_role_groups()
        self.user = get_user_model().objects.create_user(username="till", password="x")
        self.user.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.client = APIClient()
        self.client.force_authenticate(self.user)
        self.register = RegisterSession.objects.create(
            owner=self.user, owner_key=f"user:{self.user.pk}"
        )
        self.account = make_account()
        self.variant = service_variant_for("hdbox")

    def _order(self, cards=("210906803499",)):
        lines = []
        for card in cards:
            resolved = resolve_line_integration(
                {
                    "provider": "hdbox",
                    "subscriber_ref": card,
                    "option_code": "renew:1",
                    "option_label": "1 month",
                    "months": 1,
                    "cost": Decimal("25.00"),
                },
                self.variant,
            )
            lines.append(
                {
                    "variant": self.variant,
                    "quantity": Decimal("1"),
                    "effective_unit_price": resolved["price"],
                    "integration": resolved,
                }
            )
        return checkout_order(
            register_session=self.register,
            lines_data=lines,
            payments_data=[
                {"method": "cash", "amount": Decimal("25.00") * len(lines)}
            ],
            request=None,
        )

    def _session(self, **kwargs):
        return _WriteSession(
            _FakeResponse(AUTHED_PAGE),
            [_FakeResponse(RENEW_FORM), _FakeResponse(RECEIPT_PAGE)],
            **kwargs,
        )

    def test_charging_an_order_performs_its_recharges(self):
        order = self._order()
        with patch_session(self._session(renew=_FakeResponse(RENEW_OK))):
            response = self.client.post(
                "/api/integrations/fulfillments/charge/", {"order": order.pk}, format="json"
            )

        self.assertEqual(response.status_code, 200)
        result = response.data["results"][0]
        self.assertEqual(result["outcome"], "charged")
        self.assertEqual(result["provider_reference"], "558032")
        self.assertFalse(result["needs_attention"])
        # The provider's own slip came back with it, ready to print.
        self.assertEqual(result["receipt"]["end_date"], "2026-10-20")

    def test_calling_it_twice_charges_nothing_twice(self):
        order = self._order()
        with patch_session(self._session(renew=_FakeResponse(RENEW_OK))):
            self.client.post(
                "/api/integrations/fulfillments/charge/", {"order": order.pk}, format="json"
            )
        second = self._session(renew=_FakeResponse(RENEW_OK))
        with patch_session(second):
            response = self.client.post(
                "/api/integrations/fulfillments/charge/", {"order": order.pk}, format="json"
            )

        # Nothing claimable is not an error — a till that re-sends a finished
        # sale should hear "nothing to do", not see a second charge.
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data["results"], [])
        self.assertEqual(second.renew_calls, [])

    def test_an_empty_float_reaches_the_till_as_its_own_code(self):
        order = self._order()
        with patch_session(self._session(renew=_FakeResponse(RENEW_BROKE))):
            response = self.client.post(
                "/api/integrations/fulfillments/charge/", {"order": order.pk}, format="json"
            )

        result = response.data["results"][0]
        self.assertEqual(result["outcome"], "refused")
        self.assertEqual(result["error_code"], "insufficient_float")
        # Still sold, still retryable once the shop tops up.
        self.assertEqual(result["status"], "pending")

    def test_one_line_can_be_retried_on_its_own(self):
        order = self._order()
        with patch_session(self._session(renew=_FakeResponse(RENEW_BROKE))):
            self.client.post(
                "/api/integrations/fulfillments/charge/", {"order": order.pk}, format="json"
            )
        fulfillment = IntegrationFulfillment.objects.get()
        with patch_session(self._session(renew=_FakeResponse(RENEW_OK))):
            response = self.client.post(
                "/api/integrations/fulfillments/charge/",
                {"fulfillment": fulfillment.pk},
                format="json",
            )
        self.assertEqual(response.data["results"][0]["outcome"], "charged")

    def test_naming_neither_an_order_nor_a_line_is_a_bad_request(self):
        response = self.client.post(
            "/api/integrations/fulfillments/charge/", {}, format="json"
        )
        self.assertEqual(response.status_code, 400)


class UnresolvedRechargeNotificationTests(TestCase):
    """The state nobody may retry has to be the one somebody is told about."""

    def setUp(self):
        ensure_role_groups()
        self.user = get_user_model().objects.create_user(username="till", password="x")
        self.register = RegisterSession.objects.create(
            owner=self.user, owner_key=f"user:{self.user.pk}"
        )
        self.account = make_account()
        self.variant = service_variant_for("hdbox")

    def test_a_submitted_row_raises_a_critical_notification(self):
        resolved = resolve_line_integration(
            {
                "provider": "hdbox",
                "subscriber_ref": "210906803499",
                "option_code": "renew:1",
                "option_label": "1 month",
                "months": 1,
                "cost": Decimal("25.00"),
            },
            self.variant,
        )
        order = checkout_order(
            register_session=self.register,
            lines_data=[
                {
                    "variant": self.variant,
                    "quantity": Decimal("1"),
                    "effective_unit_price": resolved["price"],
                    "integration": resolved,
                }
            ],
            payments_data=[{"method": "cash", "amount": resolved["price"]}],
            request=None,
        )
        fulfillment = IntegrationFulfillment.objects.get(order_line=order.lines.get())
        fulfillment.status = IntegrationFulfillment.Status.SUBMITTED
        fulfillment.submitted_at = timezone.now()
        fulfillment.last_error_code = "indeterminate"
        fulfillment.save()

        sync_business_notifications()
        notification = BusinessNotification.objects.get(
            code="integrations.unresolved_recharge"
        )
        self.assertEqual(notification.severity, BusinessNotification.Severity.CRITICAL)
        self.assertEqual(notification.payload["card_no"], "210906803499")
        self.assertEqual(notification.payload["reason"], "indeterminate")

        # Once it is resolved, the feed stops saying so without anyone clearing it.
        fulfillment.status = IntegrationFulfillment.Status.CONFIRMED
        fulfillment.save()
        sync_business_notifications()
        self.assertFalse(
            BusinessNotification.objects.filter(
                code="integrations.unresolved_recharge",
                status=BusinessNotification.Status.ACTIVE,
            ).exists()
        )


# --------------------------------------------------------------------------
# LNET
#
# The fixtures below are trimmed from a real reseller session captured on
# 2026-09-20, and they keep the two things that make this portal hostile to
# parse: tables whose unused columns ship as HTML **comments** that do not line
# up between header and body, and JSON answers served as ``text/html``.
# Synthesising tidier markup would test a portal we do not have.
# --------------------------------------------------------------------------
from .providers import lnet as lnet_module  # noqa: E402
from .providers.lnet import LnetProvider  # noqa: E402

LNET_LOGIN_PAGE = """
<form action="/lnet-billing/public/login" method="post">
  <div style="display:none">
  <input type="hidden" name="ci_csrf_token" value="tok-from-login" /></div>
  <input type="text" name="login" /><input type="password" name="password" />
</form>
"""

LNET_HOME_PAGE = "<h1>Welcome Back النسيم للهاتف المحمول !</h1>"


def _lnet_user_row(username, user_id, *, start, finish, status, plan, money="0"):
    """One result row, commented-out cells and all — exactly as served."""
    return f"""
    <tr>
      <td class="column-check"><input type="checkbox" name="checked[]" value="{user_id}" /></td>
      <td><a href="https://b/lnet-billing/public/admin/settings/users/edit/{user_id}">{username}</a> </td>
      <!--<td></td>-->
      <td>{start}</td>
      <!--<td></td>-->
      <td>{finish}</td>
      <td></td>
      <td class="u_d_balance" data-username="{username}" data-custid="{user_id}"><img src="x"></td>
      <td class='last-login'>{money}</td>
      <!--<td></td>-->
      <td class='status'> <span class="label label-success">{status}</span> </td>
      <td></td>
      <td><a href="https://b/lnet-billing/public/admin/settings/users/statistics/{user_id}?refresh-records=true">Show Statistics</a></td>
      <td><a href="https://b/lnet-billing/public/admin/settings/users/recharge/{user_id}"
             data-toggle="popover" title="Service Plan Name" data-content="{plan}" >Recharge</a></td>
    </tr>"""


def lnet_users_page(*rows) -> str:
    """The user-search result table. ``rows`` may be empty (no match)."""
    return f"""
    <table class="table">
      <thead><tr>
        <th></th><th>Username</th>
        <!--<th>Display Name</th>-->
        <th>Service Start Date</th>
        <!--<th>Email</th>-->
        <th>Service Finish Date</th><th>Role</th><th>Up/Down Balance</th>
        <th>Money Balance</th>
        <!--<th>Rent Debt</th>-->
        <th>Service Status</th><th>Expiry Date</th>
        <th>Statistics</th><th>Recharge</th>
      </tr></thead>
      <tbody>{"".join(rows)}</tbody>
    </table>"""


LNET_ONE_LINE = lnet_users_page(
    _lnet_user_row(
        "alhussainbasheir", "214737",
        start="2026-08-24", finish="2026-09-23",
        status="Active", plan="Unlimited Home Basic",
    )
)

# One phone, three lines — the shape the field warned about.
LNET_THREE_LINES = lnet_users_page(
    _lnet_user_row(
        "basheir.home", "214737", start="2026-08-24", finish="2026-09-23",
        status="Active", plan="Unlimited Home Basic", money="12.50",
    ),
    _lnet_user_row(
        "basheir.shop", "214740", start="2026-01-02", finish="2026-02-02",
        status="Expired", plan="Unlimited Home Basic Plus",
    ),
    _lnet_user_row(
        "basheir.old", "214741", start="2025-01-02", finish="2025-02-02",
        status="Suspended", plan="WIFI-Home Basic",
    ),
)

LNET_RECHARGE_FORM = """
<form action="https://b/lnet-billing/public/admin/settings/users/recharge/214737" method="post">
  <div style="display:none">
  <input type="hidden" name="ci_csrf_token" value="tok-from-form" /></div>
  <input type="text" id="recharge_amount" name="recharge_amount" />
  <select id="recharge_type" name="recharge_type">
    <option value="1">Cash</option><option value="2">Cheque</option></select>
  <input type="text" id="extra_gb" name="extra_gb" value="0" />
  <input value="214737" type="hidden" id="user_id" name="user_id" />
</form>
"""

def lnet_payments_report(rows=None) -> str:
    """The agency payments report.

    Rows are built relative to *now* rather than frozen, because the resolver
    reasons about how far back the page reaches — a fixture with hardcoded
    dates would quietly stop covering "an hour ago" the day after it was
    written. Times are printed in the portal's own clock (shop-local), which
    is what the parser converts back out of.
    """
    from apps.core.timeutils import business_timezone

    if rows is None:
        now = timezone.now()
        rows = [
            ("4300578", Decimal("25"), Decimal("518.8"), "alhussainbasheir",
             now - timedelta(hours=2)),
            ("4300494", Decimal("45"), Decimal("542.55"), "someone.else",
             now - timedelta(hours=4)),
        ]
    body = []
    for serial, amount, final, customer, at in rows:
        local = at.astimezone(business_timezone()).strftime("%Y-%m-%d %H:%M:%S")
        body.append(
            f"""
<tr><td>{serial}</td><td>{local}</td><td>{amount}</td><td>Cash</td><td></td>
    <td></td><td>{final}</td><td>0</td><td></td><td> verified </td>
    <td>{local}</td><td>{customer}</td><td>lnet_r67</td>
    <!-- <td>x</td> <td>y</td>-->
    <td></td><td>Reprint</td></tr>"""
        )
    return """
<table class="table table-striped"><thead><tr>
  <th>S/N</th><th>Payment Date</th><th>Payment Amount</th><th>Payment Type</th>
  <th>Bank</th><th>Cheque Number</th><th>Final Balance</th><th>Extra Gb</th>
  <th>Comment</th><th>Status</th><th>Final Date</th><th>Customer Name</th>
  <th>Recharged By</th>
  <!-- <th>Created At</th> <th>Updated At</th>-->
  <th>Cancel Payment</th><th>Reprint</th>
</tr></thead><tbody>""" + "".join(body) + "</tbody></table>"


# The portal serves these as text/html; the driver must parse before believing.
LNET_VALIDATE_OK = (
    '{"status":"success","message":"Payment is ready for recharge.",'
    '"data":{"payment_date":"2026-09-20 17:40:44","serial_number":4300665,'
    '"payment_amount":45,"extra_gb":"0","current_user_id":203397,'
    '"new_balance":517.85,"recharge_type":"1","bank":null,'
    '"cheque_number":null,"total":"45"}}'
)
LNET_COMMIT_OK = (
    '{"status":"success","message":"Customer has been successfully recharged '
    'and your balance has been successfully updated."}'
)


class _LnetFakeSession:
    """Routes by URL path, because this driver makes many different calls."""

    def __init__(self, *, pages=None, posts=None, raise_on=None):
        self.pages = dict(pages or {})
        self.posts = dict(posts or {})
        self.raise_on = raise_on or {}
        self.get_calls = []
        self.post_calls = []
        # See _FakeSession.cookies.
        self.cookies = {}

    def _match(self, table, url):
        for fragment, value in table.items():
            if fragment in url:
                return value
        return None

    def get(self, url, **kwargs):
        self.get_calls.append((url, kwargs))
        if self._match(self.raise_on, url) == "get":
            raise lnet_module.requests.RequestException("boom")
        found = self._match(self.pages, url)
        if found is None:
            raise AssertionError(f"unscripted GET {url}")
        return found

    def post(self, url, **kwargs):
        self.post_calls.append((url, kwargs))
        if self._match(self.raise_on, url) == "post":
            raise lnet_module.requests.RequestException("boom")
        found = self._match(self.posts, url)
        if found is None:
            raise AssertionError(f"unscripted POST {url}")
        return found

    def mount(self, prefix, adapter):
        """A real Session has one; the drivers mount a shared pool on it."""


class _LnetResponse(_FakeResponse):
    def __init__(self, text, status_code=200, url="https://b/lnet-billing/public/"):
        super().__init__(text, status_code)
        self.url = url


def lnet_account(**kwargs) -> IntegrationAccount:
    defaults = {
        "provider": "lnet",
        "base_url": "https://b/lnet-billing/public",
        "username": "lnet_r67",
    }
    defaults.update(kwargs)
    return make_account(**defaults)


def patch_lnet(session):
    return mock.patch(
        "apps.integrations.providers.lnet.requests.Session", return_value=session
    )


def lnet_session(*, users=LNET_ONE_LINE, **overrides):
    """A session that can log in, search, and render the recharge form."""
    pages = {
        "/login": _LnetResponse(LNET_LOGIN_PAGE),
        "/admin/settings/users/recharge/": _LnetResponse(LNET_RECHARGE_FORM),
        "/admin/reports/payments": _LnetResponse(lnet_payments_report()),
        "/admin/settings/users": _LnetResponse(users),
    }
    pages.update(overrides.pop("pages", {}))
    posts = {"/login": _LnetResponse(LNET_HOME_PAGE)}
    posts.update(overrides.pop("posts", {}))
    return _LnetFakeSession(pages=pages, posts=posts, **overrides)


class LnetAuthTests(TestCase):
    def test_probe_reads_the_float_from_the_newest_payment(self):
        # The portal renders no balance anywhere; Final Balance is all there is.
        with patch_lnet(lnet_session()):
            result = LnetProvider(lnet_account()).probe()
        self.assertTrue(result.ok)
        self.assertEqual(result.balance, Decimal("518.8"))

    def test_login_form_coming_back_is_unauthorized(self):
        session = lnet_session(posts={"/login": _LnetResponse(LNET_LOGIN_PAGE)})
        with patch_lnet(session):
            result = LnetProvider(lnet_account()).probe()
        self.assertFalse(result.ok)
        self.assertEqual(result.error_code, ERROR_UNAUTHORIZED)

    def test_landing_back_on_the_login_url_is_unauthorized(self):
        # Some builds answer a bad password with a bare redirect back.
        session = lnet_session(
            posts={"/login": _LnetResponse("", url="https://b/lnet-billing/public/login")}
        )
        with patch_lnet(session):
            result = LnetProvider(lnet_account()).probe()
        self.assertFalse(result.ok)
        self.assertEqual(result.error_code, ERROR_UNAUTHORIZED)

    def test_waf_403_is_unreachable_not_a_bad_password(self):
        # Telling an owner their password is wrong when their network is
        # blocked sends them to reset a credential that was fine.
        session = lnet_session(pages={"/login": _LnetResponse("denied", 403)})
        with patch_lnet(session):
            result = LnetProvider(lnet_account()).probe()
        self.assertFalse(result.ok)
        self.assertEqual(result.error_code, ERROR_UNREACHABLE)

    def test_probe_survives_an_unreadable_payments_report(self):
        # Credentials proved good at login; a missing report is a missing
        # balance, not a failed probe.
        session = lnet_session(pages={"/admin/reports/payments": _LnetResponse("", 500)})
        with patch_lnet(session):
            result = LnetProvider(lnet_account()).probe()
        self.assertTrue(result.ok)
        self.assertIsNone(result.balance)

    def test_login_posts_the_page_csrf_token(self):
        session = lnet_session()
        with patch_lnet(session):
            LnetProvider(lnet_account()).probe()
        _url, kwargs = session.post_calls[0]
        self.assertEqual(kwargs["data"]["ci_csrf_token"], "tok-from-login")
        self.assertEqual(kwargs["data"]["login"], "lnet_r67")


class _StaleThenFreshLnetSession(_LnetFakeSession):
    """One path answers dead-then-alive; every other path is scripted as usual.

    ``_LnetFakeSession`` maps a URL fragment to a single, fixed response,
    which cannot express "the first call to this path finds a dead session,
    the retry after a relogin finds a live one" — exactly the sequence the
    one-shot retry in ``_get`` exists to survive. This layers a small queue
    over ONE path for that, and falls back to the normal fixture for
    everything else, including the forced relogin itself.
    """

    def __init__(self, *, stale_path, stale_response, fresh_response, **kwargs):
        super().__init__(**kwargs)
        self._stale_path = stale_path
        self._queue = [stale_response, fresh_response]

    def get(self, url, **kwargs):
        if self._stale_path in url and self._queue:
            self.get_calls.append((url, kwargs))
            return self._queue.pop(0)
        return super().get(url, **kwargs)


@CACHED_PROVIDER_SESSIONS
class LnetSessionReuseTests(TestCase):
    """LNET's login is the more expensive of the two apps drive: a GET for a
    CSRF token, then a POST — twice the round trips HD Box's login costs, on
    top of a search that can itself take up to three tries (see
    ``LnetResolvedCardTests``). These prove the login half of that is spent
    once, not once per capability call and not once per search in a shift.
    """

    def setUp(self):
        cache.clear()

    def test_one_login_serves_lookup_offers_and_profile(self):
        session = lnet_session()
        with patch_lnet(session):
            driver = LnetProvider(lnet_account())
            lookup = driver.lookup("alhussainbasheir")
            self.assertTrue(lookup.ok, lookup.error_detail)
            offers = driver.offers("alhussainbasheir")
            self.assertTrue(offers.ok, offers.error_detail)
            profile = driver.subscriber_profile("alhussainbasheir")
            self.assertTrue(profile.ok, profile.error_detail)

        login_gets = [u for u, _k in session.get_calls if u.endswith("/login")]
        login_posts = [u for u, _k in session.post_calls if u.endswith("/login")]
        self.assertEqual(len(login_gets), 1)
        self.assertEqual(len(login_posts), 1)

    def test_a_second_driver_instance_reuses_the_warm_cache_too(self):
        account = lnet_account()
        with patch_lnet(lnet_session()):
            self.assertTrue(LnetProvider(account).probe().ok)

        second = lnet_session()
        with patch_lnet(second):
            self.assertTrue(LnetProvider(account).probe().ok)
        # No login page GET and no login POST at all — the cached cookie was
        # used straight away.
        self.assertEqual([u for u, _k in second.get_calls if u.endswith("/login")], [])
        self.assertEqual(second.post_calls, [])

    def test_a_stale_cached_session_is_retried_once_not_reported_as_a_failure(self):
        account = lnet_account()
        with patch_lnet(lnet_session()):
            self.assertTrue(LnetProvider(account).probe().ok)

        session = _StaleThenFreshLnetSession(
            stale_path="/admin/reports/payments",
            stale_response=_LnetResponse(
                LNET_LOGIN_PAGE, url="https://b/lnet-billing/public/login"
            ),
            fresh_response=_LnetResponse(lnet_payments_report()),
            pages={"/login": _LnetResponse(LNET_LOGIN_PAGE)},
            posts={"/login": _LnetResponse(LNET_HOME_PAGE)},
        )
        with patch_lnet(session):
            result = LnetProvider(account).probe()

        self.assertTrue(result.ok, result.error_detail)
        login_posts = [u for u, _k in session.post_calls if u.endswith("/login")]
        self.assertEqual(len(login_posts), 1)

    def test_a_session_that_was_never_cached_gets_no_retry_on_expiry(self):
        session = lnet_session(posts={"/login": _LnetResponse(LNET_LOGIN_PAGE)})
        with patch_lnet(session):
            result = LnetProvider(lnet_account()).probe()
        self.assertFalse(result.ok)
        self.assertEqual(result.error_code, ERROR_UNAUTHORIZED)
        login_posts = [u for u, _k in session.post_calls if u.endswith("/login")]
        self.assertEqual(len(login_posts), 1)

    def test_a_password_edit_is_not_served_a_replay_of_the_old_login(self):
        account = lnet_account()
        with patch_lnet(lnet_session()):
            self.assertTrue(LnetProvider(account).probe().ok)

        account.set_secret(catalog.FIELD_PASSWORD, "a-new-password")
        account.save()

        second = lnet_session()
        with patch_lnet(second):
            self.assertTrue(LnetProvider(account).probe().ok)
        login_posts = [u for u, _k in second.post_calls if u.endswith("/login")]
        self.assertEqual(len(login_posts), 1)


class LnetLookupTests(TestCase):
    def test_one_match_sets_card_and_reads_every_column(self):
        with patch_lnet(lnet_session()):
            result = LnetProvider(lnet_account()).lookup("0910682854")
        self.assertTrue(result.ok)
        self.assertFalse(result.is_ambiguous)
        card = result.card
        self.assertEqual(card.card_no, "alhussainbasheir")
        self.assertEqual(card.provider_id, "214737")
        # The trap: commented-out cells shift every column left if not stripped.
        self.assertEqual(card.status, "Active")
        self.assertEqual(card.package_name, "Unlimited Home Basic")
        # Stored as UTC, read back in the shop's clock — the portal prints a
        # bare local date, and 2026-09-23 there is 2026-09-22T22:00Z here.
        shop = business_timezone()
        self.assertEqual(
            card.expire_at.astimezone(shop).date().isoformat(), "2026-09-23"
        )
        self.assertEqual(
            card.start_at.astimezone(shop).date().isoformat(), "2026-08-24"
        )

    def test_one_phone_with_several_lines_returns_all_of_them(self):
        with patch_lnet(lnet_session(users=LNET_THREE_LINES)):
            result = LnetProvider(lnet_account()).lookup("0910682854")
        self.assertTrue(result.ok)
        self.assertTrue(result.is_ambiguous)
        self.assertEqual(
            [c.card_no for c in result.candidates],
            ["basheir.home", "basheir.shop", "basheir.old"],
        )
        self.assertEqual(
            [c.status for c in result.candidates], ["Active", "Expired", "Suspended"]
        )
        # Nothing may be chosen for the customer.
        self.assertIsNone(result.card)

    def test_a_line_carries_the_money_already_on_it(self):
        with patch_lnet(lnet_session(users=LNET_THREE_LINES)):
            result = LnetProvider(lnet_account()).lookup("0910682854")
        self.assertEqual(result.candidates[0].card_balance, Decimal("12.50"))

    def test_no_match_is_not_found(self):
        with patch_lnet(lnet_session(users=lnet_users_page())):
            result = LnetProvider(lnet_account()).lookup("0000000000")
        self.assertFalse(result.ok)
        self.assertEqual(result.error_code, ERROR_NOT_FOUND)

    def test_a_digit_term_tries_mobile_before_username(self):
        session = lnet_session()
        with patch_lnet(session):
            LnetProvider(lnet_account()).lookup("0910682854")
        search = [k for _u, k in session.get_calls if "params" in k][0]
        self.assertEqual(search["params"]["search_by"], "mobile")

    def test_a_lettered_term_never_wastes_a_mobile_search(self):
        session = lnet_session()
        with patch_lnet(session):
            LnetProvider(lnet_account()).lookup("basheir.home")
        modes = [k["params"]["search_by"] for _u, k in session.get_calls if "params" in k]
        self.assertNotIn("mobile", modes)
        self.assertEqual(modes[0], "username")


class LnetResolvedCardTests(TestCase):
    """The bug behind Annaseem's "offers never show up": a search that FOUND
    the line still failed to price it, whenever the search term was not
    itself the exact username.

    Every existing ``LnetOfferTests``/``LnetLookupTests`` fixture searches
    for ``"alhussainbasheir"`` — the username itself — so none of them could
    have caught this: ``offers()`` and ``subscriber_profile()`` re-search for
    whatever they are handed and keep only an EXACT match against it, which
    is correct when the caller already has the username and silently empty
    whenever it does not. A till searches by phone number "almost always"
    (the driver's own docstring), so this was not an edge case — it was
    close to the ordinary path.
    """

    def test_offers_by_the_raw_search_term_alone_finds_nothing(self):
        # The reproduction: a phone-shaped term finds the line (lookup works —
        # "mobile" is tried and LNET_ONE_LINE answers, whatever the term was),
        # but the line's real identifier is a username, not that phone number,
        # so asking offers() for the SAME raw term fails the exact match.
        with patch_lnet(lnet_session()):
            driver = LnetProvider(lnet_account())
            found = driver.lookup("0910682854")
            self.assertTrue(found.ok)
            self.assertEqual(found.card.card_no, "alhussainbasheir")

            offers = driver.offers("0910682854")
        self.assertFalse(offers.ok)
        self.assertEqual(offers.error_code, ERROR_NOT_FOUND)
        self.assertIn("0910682854", offers.error_detail)

    def test_passing_the_resolved_card_finds_it(self):
        with patch_lnet(lnet_session()):
            driver = LnetProvider(lnet_account())
            found = driver.lookup("0910682854")
            offers = driver.offers("0910682854", resolved=found.card)
        self.assertTrue(offers.ok, offers.error_detail)
        self.assertTrue(offers.options)

    def test_subscriber_profile_has_the_identical_gap_and_the_identical_fix(self):
        with patch_lnet(lnet_session()):
            driver = LnetProvider(lnet_account())
            found = driver.lookup("0910682854")

            broken = driver.subscriber_profile("0910682854")
            self.assertFalse(broken.ok)

            fixed = driver.subscriber_profile("0910682854", resolved=found.card)
        self.assertTrue(fixed.ok, fixed.error_detail)
        self.assertEqual(fixed.profile.subscriber_ref, "alhussainbasheir")

    def test_the_resolved_card_skips_searching_again_entirely(self):
        """Not just correct — the whole point is one search, not two more."""
        session = lnet_session()
        with patch_lnet(session):
            driver = LnetProvider(lnet_account())
            found = driver.lookup("0910682854")
            searches_after_lookup = len(session.get_calls)
            offers = driver.offers("0910682854", resolved=found.card)
        self.assertTrue(offers.ok)
        # offers() logs in again on its own (session reuse across calls is
        # LnetSessionReuseTests' job, not this one) — what this proves is
        # narrower: of the calls that follow the lookup, none is a SEARCH
        # (the exact-match users page), only the login and the recharge form.
        new_calls = [
            url for url, _kwargs in session.get_calls[searches_after_lookup:]
        ]
        search_calls = [
            url for url in new_calls if url.rstrip("/").endswith("/settings/users")
        ]
        self.assertEqual(search_calls, [])
        self.assertTrue(
            any("/admin/settings/users/recharge/" in url for url in new_calls),
            new_calls,
        )

    def test_recharge_is_unaffected_it_never_receives_a_resolved_card(self):
        """The write path keeps verifying its own exact match, always.

        recharge() is reached from checkout with the card_no the customer's
        line was ADDED TO CART under — already the resolved username, from
        card_payload() — never from a raw search term, and it has no
        ``resolved`` parameter to accept one. This is deliberate: unlike a
        read, a stale or mismatched resolution here would mean spending the
        float against the wrong line, so the write keeps doing its own
        search-and-verify rather than trusting anything a caller hands it.
        """
        self.assertNotIn("resolved", lnet_module.LnetProvider.recharge.__code__.co_varnames)


class LnetOfferTests(TestCase):
    def test_offers_are_shortcuts_over_an_open_amount(self):
        with patch_lnet(lnet_session()):
            result = LnetProvider(lnet_account()).offers("alhussainbasheir")
        self.assertTrue(result.ok)
        self.assertIsNotNone(result.open_amount)
        self.assertEqual(result.open_amount.cost_ratio, Decimal("0.95"))
        self.assertTrue(result.options)

    def test_cost_is_95_percent_and_retail_is_face_value(self):
        with patch_lnet(lnet_session()):
            result = LnetProvider(lnet_account()).offers("alhussainbasheir")
        by_code = {o.code: o for o in result.options}
        option = by_code["topup:45"]
        self.assertEqual(option.cost, Decimal("42.75"))
        self.assertEqual(option.face_value, Decimal("45.00"))
        self.assertEqual(option.kind, lnet_module.RECHARGE_TOPUP)

    def test_a_shop_on_other_terms_can_set_its_own_commission(self):
        # Owner-facing: a shop says it is "on 10%", never that its cost ratio
        # is 0.90. The conversion is the driver's job.
        account = lnet_account(config={catalog.SETTING_COMMISSION_PERCENT: "10"})
        with patch_lnet(lnet_session()):
            result = LnetProvider(account).offers("alhussainbasheir")
        by_code = {o.code: o for o in result.options}
        self.assertEqual(by_code["topup:45"].cost, Decimal("40.50"))

    def test_a_nonsense_commission_falls_back_rather_than_quoting_zero(self):
        account = lnet_account()
        for bad in ("-1", "99", "banana", None, "", [], {"a": 1}):
            account.config = {catalog.SETTING_COMMISSION_PERCENT: bad}
            self.assertEqual(
                LnetProvider(account)._cost_ratio, lnet_module.DEFAULT_COST_RATIO, bad
            )

    def test_a_shop_may_choose_its_own_quick_picks(self):
        account = lnet_account(
            config={catalog.SETTING_DENOMINATIONS: ["15", "35"]}
        )
        with patch_lnet(lnet_session()):
            result = LnetProvider(account).offers("alhussainbasheir")
        self.assertEqual(
            [o.code for o in result.options], ["topup:15", "topup:35"]
        )

    def test_clearing_the_quick_picks_still_leaves_an_open_amount(self):
        # "We always type it" is a real answer, and the provider takes any
        # amount — so no buttons must not read as nothing to sell.
        account = lnet_account(config={catalog.SETTING_DENOMINATIONS: []})
        with patch_lnet(lnet_session()):
            result = LnetProvider(account).offers("alhussainbasheir")
        self.assertTrue(result.ok)
        self.assertEqual(result.options, ())
        self.assertIsNotNone(result.open_amount)


    def test_a_line_that_cannot_be_recharged_is_refused_before_the_customer_pays(self):
        session = lnet_session(
            pages={"/admin/settings/users/recharge/": _LnetResponse("<p>nope</p>")}
        )
        with patch_lnet(session):
            result = LnetProvider(lnet_account()).offers("alhussainbasheir")
        self.assertFalse(result.ok)
        self.assertEqual(result.error_code, ERROR_UNEXPECTED)

    def test_a_near_miss_username_is_never_acted_on(self):
        # Search is a substring match; "basheir" must not resolve to a line.
        with patch_lnet(lnet_session(users=LNET_THREE_LINES)):
            result = LnetProvider(lnet_account()).offers("basheir")
        self.assertFalse(result.ok)
        self.assertEqual(result.error_code, ERROR_NOT_FOUND)

    def test_open_amount_validates_what_a_cashier_may_type(self):
        spec = lnet_module.OpenAmount(
            minimum=Decimal("1"), step=Decimal("1"), cost_ratio=Decimal("0.95")
        )
        self.assertEqual(spec.validate(Decimal("45")), "")
        self.assertIn("positive", spec.validate(Decimal("0")))
        self.assertIn("minimum", spec.validate(Decimal("0.5")))
        self.assertIn("multiple", spec.validate(Decimal("45.5")))


class ProviderSettingsApiTests(TestCase):
    """An owner's commercial terms, set from the settings screen."""

    def setUp(self):
        ensure_role_groups()
        self.manager = get_user_model().objects.create_user(
            username="manager", password="pw"
        )
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client = APIClient()
        self.client.force_authenticate(self.manager)
        lnet_account()

    def _put(self, payload):
        return self.client.put("/api/integrations/lnet/", payload, format="json")

    def test_the_catalog_publishes_what_may_be_set_and_what_it_is(self):
        resp = self.client.get("/api/integrations/")
        lnet = {p["key"]: p for p in resp.data["providers"]}["lnet"]
        by_key = {item["key"]: item for item in lnet["settings"]}
        commission = by_key[catalog.SETTING_COMMISSION_PERCENT]
        self.assertEqual(commission["kind"], catalog.SETTING_KIND_PERCENT)
        self.assertEqual(commission["value"], "5")
        self.assertEqual(commission["maximum"], Decimal("50"))
        self.assertIn(catalog.SETTING_DENOMINATIONS, by_key)

    def test_an_owner_can_change_the_commission(self):
        resp = self._put({"settings": {catalog.SETTING_COMMISSION_PERCENT: "7.5"}})
        self.assertEqual(resp.status_code, 200)
        account = IntegrationAccount.objects.get(provider="lnet")
        self.assertEqual(
            account.setting(catalog.SETTING_COMMISSION_PERCENT), "7.5"
        )
        # And the price a till would quote follows it immediately.
        self.assertEqual(
            LnetProvider(account).quote("topup:100").cost, Decimal("92.50")
        )

    def test_a_commission_out_of_range_is_refused_not_ignored(self):
        # Silently ignoring it would book the wrong margin on every sale until
        # somebody noticed in a profit report a month later.
        resp = self._put({"settings": {catalog.SETTING_COMMISSION_PERCENT: "95"}})
        self.assertEqual(resp.status_code, 400)
        self.assertIn(catalog.SETTING_COMMISSION_PERCENT, resp.data["settings"])
        self.assertEqual(
            IntegrationAccount.objects.get(provider="lnet").setting(
                catalog.SETTING_COMMISSION_PERCENT
            ),
            "5",
            "the stored value must survive a rejected write",
        )

    def test_a_setting_the_provider_does_not_declare_cannot_reach_config(self):
        # config is a JSONField; an endpoint that wrote it verbatim would be an
        # open door into the account's own storage.
        resp = self._put({"settings": {"secrets_encrypted": "nice try"}})
        self.assertEqual(resp.status_code, 400)
        account = IntegrationAccount.objects.get(provider="lnet")
        self.assertNotIn("secrets_encrypted", account.config)

    def test_saving_credentials_leaves_settings_alone(self):
        self._put({"settings": {catalog.SETTING_COMMISSION_PERCENT: "8"}})
        self._put({"username": "lnet_r99"})
        account = IntegrationAccount.objects.get(provider="lnet")
        self.assertEqual(account.username, "lnet_r99")
        self.assertEqual(account.setting(catalog.SETTING_COMMISSION_PERCENT), "8")

    def test_an_unset_setting_reads_as_its_default(self):
        account = IntegrationAccount.objects.get(provider="lnet")
        self.assertEqual(account.config, {})
        self.assertEqual(account.setting(catalog.SETTING_COMMISSION_PERCENT), "5")
        self.assertEqual(
            account.settings_map()[catalog.SETTING_DENOMINATIONS][0], "10"
        )

    def test_a_stored_value_the_catalog_now_rejects_falls_back(self):
        # Bounds can tighten after a value was stored; honouring a number the
        # catalog says is impossible is worse than falling back.
        account = IntegrationAccount.objects.get(provider="lnet")
        account.config = {catalog.SETTING_COMMISSION_PERCENT: "80"}
        account.save()
        self.assertEqual(account.setting(catalog.SETTING_COMMISSION_PERCENT), "5")

class LnetQuoteTests(TestCase):
    """Pricing that must hold without touching the network."""

    def test_quote_derives_cost_and_face_value_from_the_code_alone(self):
        quote = LnetProvider(lnet_account()).quote("topup:45")
        self.assertEqual(quote.cost, Decimal("42.75"))
        self.assertEqual(quote.face_value, Decimal("45.00"))

    def test_quote_refuses_anything_it_does_not_recognise(self):
        driver = LnetProvider(lnet_account())
        for code in ("renew:12", "topup:0", "topup:-5", "topup:", "", "junk"):
            self.assertIsNone(driver.quote(code), code)

    def test_stored_value_is_never_sold_below_its_face_value(self):
        # The default markup is "sell at cost". Without a floor that would
        # sell 45 dinars of credit for 42.75 — a loss on every single sale.
        account = lnet_account()
        self.assertEqual(account.markup_kind, IntegrationAccount.Markup.NONE)
        self.assertEqual(
            account.selling_price(Decimal("42.75"), "topup:45", floor=Decimal("45.00")),
            Decimal("45.00"),
        )

    def test_a_markup_may_still_sit_above_the_face_value(self):
        account = lnet_account(
            markup_kind=IntegrationAccount.Markup.AMOUNT, markup_value=Decimal("5.00")
        )
        self.assertEqual(
            account.selling_price(Decimal("42.75"), "topup:45", floor=Decimal("45.00")),
            Decimal("47.75"),
        )


class LnetRechargeTests(TransactionTestCase):
    """The write path, and the three outcomes it has to tell apart."""

    def _session(self, **overrides):
        posts = {
            "/login": _LnetResponse(LNET_HOME_PAGE),
            "validatePaymentAJAX": _LnetResponse(LNET_VALIDATE_OK),
            "rechargeOperatorPaymentAJAX": _LnetResponse(LNET_COMMIT_OK),
        }
        posts.update(overrides.pop("posts", {}))
        return lnet_session(posts=posts, **overrides)

    def test_a_successful_recharge_reports_the_serial_and_the_new_float(self):
        session = self._session()
        with patch_lnet(session):
            result = LnetProvider(lnet_account()).recharge(
                "alhussainbasheir", "topup:45", expected_cost=Decimal("42.75")
            )
        self.assertTrue(result.ok)
        self.assertEqual(result.reference, "4300665")
        self.assertEqual(result.balance_after, Decimal("517.85"))
        self.assertEqual(result.receipt["username"], "alhussainbasheir")

    def test_it_always_declares_cash_and_never_a_cheque(self):
        session = self._session()
        with patch_lnet(session):
            LnetProvider(lnet_account()).recharge("alhussainbasheir", "topup:45")
        sent = [k for u, k in session.post_calls if "validatePaymentAJAX" in u][0]
        self.assertEqual(sent["data"]["recharge_type"], lnet_module.RECHARGE_TYPE_CASH)
        self.assertEqual(sent["data"]["bank"], lnet_module.BANK_PLACEHOLDER)
        self.assertEqual(sent["data"]["cheque_number"], "")
        self.assertEqual(sent["data"]["extra_gb"], "0")
        self.assertEqual(sent["data"]["recharge_amount"], "45")

    def test_it_posts_the_token_from_the_recharge_form_not_the_login_page(self):
        session = self._session()
        with patch_lnet(session):
            LnetProvider(lnet_account()).recharge("alhussainbasheir", "topup:45")
        sent = [k for u, k in session.post_calls if "validatePaymentAJAX" in u][0]
        self.assertEqual(sent["data"]["ci_csrf_token"], "tok-from-form")

    def test_the_commit_echoes_back_exactly_what_the_server_computed(self):
        session = self._session()
        with patch_lnet(session):
            LnetProvider(lnet_account()).recharge("alhussainbasheir", "topup:45")
        sent = [k for u, k in session.post_calls if "rechargeOperator" in u][0]
        self.assertEqual(sent["data"]["serial_number"], "4300665")
        self.assertEqual(sent["data"]["current_user_id"], "203397")
        # Not "517.8500" — the portal's own wire form, unchanged.
        self.assertEqual(sent["data"]["new_balance"], "517.85")

    def test_a_moved_cost_is_refused_before_anything_is_sent(self):
        session = self._session()
        with patch_lnet(session):
            result = LnetProvider(lnet_account()).recharge(
                "alhussainbasheir", "topup:45", expected_cost=Decimal("40.00")
            )
        self.assertTrue(result.is_definite_failure)
        self.assertFalse(
            [u for u, _k in session.post_calls if "validatePaymentAJAX" in u]
        )

    def test_a_refused_payment_is_a_definite_failure(self):
        # The one outcome where the float and the customer are both untouched.
        session = self._session(
            posts={
                "validatePaymentAJAX": _LnetResponse(
                    '{"status":"error","message":"Balance not sufficient"}'
                )
            }
        )
        with patch_lnet(session):
            result = LnetProvider(lnet_account()).recharge(
                "alhussainbasheir", "topup:45"
            )
        self.assertTrue(result.is_definite_failure)
        self.assertEqual(result.error_code, ERROR_PROVIDER_ERROR)
        self.assertIn("Balance not sufficient", result.error_detail)

    def test_a_lost_answer_to_the_payment_call_is_indeterminate(self):
        session = self._session(raise_on={"validatePaymentAJAX": "post"})
        with patch_lnet(session):
            result = LnetProvider(lnet_account()).recharge(
                "alhussainbasheir", "topup:45"
            )
        self.assertFalse(result.ok)
        self.assertTrue(result.indeterminate)
        self.assertEqual(result.error_code, ERROR_INDETERMINATE)

    def test_an_unreadable_answer_to_the_payment_call_is_indeterminate(self):
        # A 500 here may still have written the payment row.
        session = self._session(
            posts={"validatePaymentAJAX": _LnetResponse("<html>oops</html>", 500)}
        )
        with patch_lnet(session):
            result = LnetProvider(lnet_account()).recharge(
                "alhussainbasheir", "topup:45"
            )
        self.assertTrue(result.indeterminate)

    def test_a_failed_float_debit_is_indeterminate_and_keeps_the_serial(self):
        # THE case this driver exists to get right: the customer has already
        # been credited, so this is never a failure a caller may retry — and
        # the serial number is the only thing that makes it reconcilable.
        session = self._session(
            posts={
                "rechargeOperatorPaymentAJAX": _LnetResponse(
                    '{"status":"error","message":"session expired"}'
                )
            }
        )
        with patch_lnet(session):
            result = LnetProvider(lnet_account()).recharge(
                "alhussainbasheir", "topup:45"
            )
        self.assertFalse(result.ok)
        self.assertTrue(result.indeterminate)
        self.assertFalse(result.is_definite_failure)
        self.assertEqual(result.reference, "4300665")
        self.assertEqual(result.receipt["serial_number"], "4300665")

    def test_a_lost_answer_to_the_float_debit_is_indeterminate(self):
        session = self._session(raise_on={"rechargeOperatorPaymentAJAX": "post"})
        with patch_lnet(session):
            result = LnetProvider(lnet_account()).recharge(
                "alhussainbasheir", "topup:45"
            )
        self.assertTrue(result.indeterminate)
        self.assertEqual(result.reference, "4300665")

    def test_an_unknown_option_never_reaches_the_provider(self):
        session = self._session()
        with patch_lnet(session):
            result = LnetProvider(lnet_account()).recharge("alhussainbasheir", "renew:12")
        self.assertTrue(result.is_definite_failure)
        self.assertFalse(session.post_calls)


class LnetHistoryTests(TestCase):
    def test_history_keeps_only_this_line_and_prices_it_at_cost(self):
        with patch_lnet(lnet_session()):
            result = LnetProvider(lnet_account()).purchase_history("alhussainbasheir")
        self.assertTrue(result.ok)
        self.assertEqual(result.total, 1)
        entry = result.purchases[0]
        self.assertEqual(entry.reference, "4300578")
        # Face value 25 cost the float 23.75 — the reconcilable number.
        self.assertEqual(entry.cost, Decimal("23.75"))
        self.assertTrue(entry.is_ours)


class LnetCheckoutTests(TestCase):
    """What the till may and may not decide for itself."""

    def test_the_server_derives_cost_and_price_and_ignores_a_lying_till(self):
        account = lnet_account()
        variant = service_variant_for("lnet")
        resolved = resolve_line_integration(
            {
                "provider": "lnet",
                "subscriber_ref": "alhussainbasheir",
                "option_code": "topup:45",
                # A client claiming this cost almost nothing.
                "cost": "1.00",
            },
            variant,
        )
        self.assertEqual(resolved["cost"], Decimal("42.75"))
        self.assertEqual(resolved["price"], Decimal("45.00"))
        self.assertEqual(resolved["account"], account)

    def test_an_open_amount_the_till_invented_is_still_priced_correctly(self):
        lnet_account()
        variant = service_variant_for("lnet")
        resolved = resolve_line_integration(
            {
                "provider": "lnet",
                "subscriber_ref": "alhussainbasheir",
                "option_code": "topup:37",
                "cost": "0",
            },
            variant,
        )
        self.assertEqual(resolved["cost"], Decimal("35.15"))
        self.assertEqual(resolved["price"], Decimal("37.00"))

    def test_hdbox_still_takes_its_cost_from_the_quote(self):
        # The offline-quote path must not change a driver that cannot price
        # itself: HD Box's ladder is only knowable from the provider.
        make_account(provider="hdbox")
        variant = service_variant_for("hdbox")
        resolved = resolve_line_integration(
            {
                "provider": "hdbox",
                "subscriber_ref": "12345",
                "option_code": "renew:12",
                "cost": "220.00",
            },
            variant,
        )
        self.assertEqual(resolved["cost"], Decimal("220.00"))

    def test_open_amounts_never_become_rows_in_the_shops_price_list(self):
        account = lnet_account()
        with patch_lnet(lnet_session()):
            offers = LnetProvider(account).offers("alhussainbasheir")
        record_seen_offers(account, offers.options)
        self.assertEqual(account.option_prices.count(), 0)


class SubmittedResolutionTests(TestCase):
    """Settling a charge that was sent and never answered.

    This is the half of the at-most-once guard that lets a shop recover.
    `recharge.py` refuses to touch a `submitted` row ever again, so without
    these paths one stuck row is stuck for good — and the cost of getting them
    wrong is a customer charged twice.
    """

    def setUp(self):
        self.account = lnet_account()
        self.variant = service_variant_for("lnet")

    def _submitted(self, *, cost="42.75", reference="", sent_ago_hours=1, card="alhussainbasheir"):
        order = Order.objects.create()
        line = OrderLine.objects.create(
            order=order, variant=self.variant, quantity=Decimal("1"),
            unit_price=Decimal("45.00"), unit_cost=Decimal(cost),
        )
        row = IntegrationFulfillment.objects.create(
            order_line=line, account=self.account, provider="lnet",
            subscriber_ref=card, option_code="topup:45", option_label="45 LYD",
            cost=Decimal(cost),
            status=IntegrationFulfillment.Status.SUBMITTED,
            submitted_at=timezone.now() - timedelta(hours=sent_ago_hours),
            provider_reference=reference,
            last_error_code=ERROR_INDETERMINATE,
        )
        IntegrationFulfillment.objects.filter(pk=row.pk).update(
            created_at=timezone.now() - timedelta(hours=sent_ago_hours)
        )
        row.refresh_from_db()
        return row

    def _reconcile(self):
        with patch_lnet(lnet_session()):
            return reconcile_account(self.account)

    def test_a_held_reference_found_in_the_log_confirms_the_sale(self):
        # LNET hands back a serial even when the float debit fails, so this is
        # the ordinary ending for its two-step write.
        row = self._submitted(cost="23.75", reference="4300578")
        result = self._reconcile()
        row.refresh_from_db()
        self.assertEqual(row.status, IntegrationFulfillment.Status.CONFIRMED)
        self.assertEqual(row.provider_receipt["reference"], "4300578")
        self.assertEqual(result["resolved"]["confirmed"], 1)

    def test_a_held_reference_is_never_returned_to_retryable(self):
        # The provider told us a payment existed. Even with the log reaching
        # back past the attempt, retrying would credit the customer twice.
        row = self._submitted(cost="23.75", reference="no-such-serial")
        result = self._reconcile()
        row.refresh_from_db()
        self.assertEqual(row.status, IntegrationFulfillment.Status.SUBMITTED)
        self.assertEqual(result["resolved"]["retryable"], 0)
        self.assertEqual(len(result["resolved"]["unknown"]), 1)

    def test_absence_from_a_log_that_reaches_back_makes_it_retryable(self):
        # No reference was ever handed back, and the report covers the attempt,
        # so the provider demonstrably never performed it.
        row = self._submitted(cost="99.99", sent_ago_hours=1)
        result = self._reconcile()
        row.refresh_from_db()
        self.assertEqual(row.status, IntegrationFulfillment.Status.PENDING)
        self.assertEqual(result["resolved"]["retryable"], 1)
        # Re-armed: the guard will now allow exactly one more attempt.
        self.assertEqual(row.last_error_code, "")

    def test_absence_from_a_log_that_does_not_reach_back_proves_nothing(self):
        # Sent before the oldest row the report still shows — a busy agency
        # pushes older payments off the page. Absence here is ignorance, not
        # proof, so it must not become a second charge.
        row = self._submitted(cost="99.99", sent_ago_hours=72)
        result = self._reconcile()
        row.refresh_from_db()
        self.assertEqual(row.status, IntegrationFulfillment.Status.SUBMITTED)
        self.assertEqual(result["resolved"]["retryable"], 0)
        self.assertEqual(len(result["resolved"]["unknown"]), 1)

    def test_an_unreadable_log_settles_nothing(self):
        row = self._submitted(cost="99.99")
        session = lnet_session(
            pages={"/admin/reports/payments": _LnetResponse("", 500)}
        )
        with patch_lnet(session):
            result = reconcile_account(self.account)
        row.refresh_from_db()
        self.assertEqual(row.status, IntegrationFulfillment.Status.SUBMITTED)
        self.assertEqual(result["resolved"]["confirmed"], 0)
        self.assertEqual(result["resolved"]["retryable"], 0)

    def test_one_provider_entry_cannot_settle_two_sales(self):
        # Otherwise a genuine unperformed row hides behind a real payment.
        first = self._submitted(cost="23.75")
        second = self._submitted(cost="23.75")
        self._reconcile()
        first.refresh_from_db()
        second.refresh_from_db()
        settled = [
            r.status for r in (first, second)
            if r.status == IntegrationFulfillment.Status.CONFIRMED
        ]
        self.assertEqual(len(settled), 1)

    def test_a_resolved_row_stops_raising_the_critical_notification(self):
        row = self._submitted(cost="23.75", reference="4300578")
        sync_business_notifications()
        self.assertTrue(
            BusinessNotification.objects.filter(
                code="integrations.unresolved_recharge"
            ).exists()
        )
        self._reconcile()
        row.refresh_from_db()
        self.assertEqual(row.status, IntegrationFulfillment.Status.CONFIRMED)
        sync_business_notifications()
        self.assertFalse(
            BusinessNotification.objects.filter(
                code="integrations.unresolved_recharge",
                status=BusinessNotification.Status.ACTIVE,
            ).exists()
        )


class ProviderTimestampTests(TestCase):
    """Timestamps a driver returns are compared against ``timezone.now()``."""

    def test_lnet_history_timestamps_are_timezone_aware(self):
        # A naive datetime here does not read oddly — it makes reconciliation
        # raise TypeError the moment it filters the log by time, which is how
        # the whole sweep silently reports itself as unreachable.
        with patch_lnet(lnet_session()):
            history = LnetProvider(lnet_account()).purchase_history(
                "alhussainbasheir"
            )
        entry = history.purchases[0]
        self.assertIsNotNone(entry.at.tzinfo)
        self.assertLess(entry.at, timezone.now() + timedelta(days=365))

    def test_lnet_reads_the_portal_clock_as_shop_local(self):
        # The portal prints a bare wall clock in Africa/Tripoli (UTC+2), so
        # 16:38:59 on its screen is 14:38:59 in the database.
        parsed = lnet_module._parse_datetime("2026-09-20 16:38:59")
        self.assertEqual(parsed.astimezone(dt_timezone.utc).hour, 14)

    def test_lnet_card_dates_are_aware_too(self):
        with patch_lnet(lnet_session()):
            card = LnetProvider(lnet_account()).lookup("0910682854").card
        self.assertIsNotNone(card.expire_at.tzinfo)

    def test_a_page_says_how_far_back_it_is_complete(self):
        with patch_lnet(lnet_session()):
            history = LnetProvider(lnet_account()).purchase_history(
                "alhussainbasheir"
            )
        # The report is account-wide and newest-first, so having read it we
        # have seen every payment back to its oldest row.
        self.assertIsNotNone(history.complete_since)
        self.assertTrue(history.covers(timezone.now()))
        self.assertFalse(history.covers(timezone.now() - timedelta(days=300)))

    def test_a_driver_making_no_claim_never_lets_absence_count_as_proof(self):
        blank = HistoryResult(ok=True)
        self.assertFalse(blank.covers(timezone.now()))
        self.assertFalse(blank.covers(None))


class IntegrationTelemetryTests(TestCase):
    """Rows that say WHERE a provider broke, not merely that it did.

    These drive somebody else's website; nobody versions it and nobody
    announces a change. What makes a row worth writing is the step it reached.
    """

    def setUp(self):
        integ_telemetry.reset()
        # The analytics buffer is process-global and deliberately outlives a
        # request, so rows another test enqueued and never flushed are still
        # sitting in it — and this class counts rows. Django rolls back the
        # database between tests; it cannot roll back a module-level list.
        analytics_buffer.reset()
        self.addCleanup(analytics_buffer.reset)
        # One row per provider, so a test that loops must reuse this one.
        self.account = lnet_account()

    def _events(self):
        from apps.analytics.models import AnalyticsEvent

        return AnalyticsEvent.objects.filter(name=integ_telemetry.EVENT_NAME)

    def _flush(self):
        from apps.analytics import buffer

        buffer.flush()

    def test_a_good_lookup_records_the_operation_and_its_shape(self):
        with patch_lnet(lnet_session()):
            LnetProvider(self.account).lookup("0910682854")
        self._flush()
        row = self._events().get()
        self.assertEqual(row.attributes["provider"], "lnet")
        self.assertEqual(row.attributes["operation"], "lookup")
        self.assertEqual(row.attributes["outcome"], "ok")
        self.assertTrue(row.attributes["shape_ok"])
        self.assertEqual(row.metrics["matches"], 1)

    def test_a_blocked_network_is_named_at_the_login_page(self):
        # The row has to distinguish this from a wrong password, because the
        # fix is a different person's job.
        session = lnet_session(pages={"/login": _LnetResponse("denied", 403)})
        with patch_lnet(session):
            LnetProvider(self.account).probe()
        self._flush()
        row = self._events().get()
        self.assertEqual(row.attributes["outcome"], ERROR_UNREACHABLE)
        self.assertEqual(row.attributes["step"], integ_telemetry.STEP_LOGIN_PAGE)
        self.assertEqual(row.attributes["http_status"], 403)

    def test_a_bad_password_is_named_at_the_login_post(self):
        session = lnet_session(posts={"/login": _LnetResponse(LNET_LOGIN_PAGE)})
        with patch_lnet(session):
            LnetProvider(self.account).probe()
        self._flush()
        row = self._events().get()
        self.assertEqual(row.attributes["outcome"], ERROR_UNAUTHORIZED)
        self.assertEqual(row.attributes["step"], integ_telemetry.STEP_LOGIN)

    def test_changed_markup_is_told_apart_from_a_missing_customer(self):
        # Both arrive as not_found. Only one of them is a bug we must fix, and
        # without shape_ok the two are indistinguishable in an export.
        with patch_lnet(lnet_session(users=lnet_users_page())):
            LnetProvider(self.account).lookup("0000000000")
        self._flush()
        absent = self._events().get()
        self.assertEqual(absent.attributes["outcome"], ERROR_NOT_FOUND)
        self.assertTrue(absent.attributes["shape_ok"], "the table was there")

        integ_telemetry.reset()
        self._events().delete()
        with patch_lnet(lnet_session(users="<p>redesigned</p>")):
            LnetProvider(self.account).lookup("0910682854")
        self._flush()
        broken = self._events().get()
        self.assertEqual(broken.attributes["outcome"], ERROR_NOT_FOUND)
        self.assertFalse(broken.attributes["shape_ok"], "our parser went blind")

    def test_a_login_page_without_its_token_reports_a_changed_page(self):
        session = lnet_session(pages={"/login": _LnetResponse("<form></form>")})
        with patch_lnet(session):
            LnetProvider(self.account).probe()
        self._flush()
        row = self._events().get()
        self.assertEqual(row.attributes["step"], integ_telemetry.STEP_LOGIN_PAGE)
        self.assertFalse(row.attributes["shape_ok"])

    def test_repeated_read_failures_are_folded_into_a_count(self):
        # A portal that is down is one fact, however many times a till of
        # cashiers rediscovers it. Telemetry has taken this product down once
        # already by writing a row per attempt.
        session = lnet_session(pages={"/login": _LnetResponse("denied", 403)})
        with patch_lnet(session):
            for _ in range(5):
                LnetProvider(self.account).probe()
        self._flush()
        self.assertEqual(self._events().count(), 1)

        # The four it swallowed are reported on the next row out of the fold,
        # so the count is carried rather than lost.
        with self.settings(POINTY_INTEGRATION_TELEMETRY_FAILURE_WINDOW=0):
            with patch_lnet(session):
                LnetProvider(self.account).probe()
        self._flush()
        latest = self._events().order_by("-id").first()
        self.assertEqual(latest.metrics["suppressed_repeats"], 4)

    def test_every_recharge_attempt_writes_its_own_row(self):
        # Money. Folding two indeterminate charges into a count would erase
        # the evidence for a second customer's money.
        session = lnet_session(
            posts={
                "validatePaymentAJAX": _LnetResponse(LNET_VALIDATE_OK),
                "rechargeOperatorPaymentAJAX": _LnetResponse(
                    '{"status":"error","message":"nope"}'
                ),
            }
        )
        with patch_lnet(session):
            for _ in range(3):
                LnetProvider(self.account).recharge(
                    "alhussainbasheir", "topup:45"
                )
        self._flush()
        writes = self._events().filter(attributes__operation="recharge")
        self.assertEqual(writes.count(), 3)

    def test_an_unknown_charge_is_critical_and_keeps_its_serial(self):
        session = lnet_session(
            posts={
                "validatePaymentAJAX": _LnetResponse(LNET_VALIDATE_OK),
                "rechargeOperatorPaymentAJAX": _LnetResponse(
                    '{"status":"error","message":"session expired"}'
                ),
            }
        )
        with patch_lnet(session):
            LnetProvider(self.account).recharge("alhussainbasheir", "topup:45")
        self._flush()
        row = self._events().filter(attributes__operation="recharge").get()
        from apps.analytics.models import AnalyticsEvent

        self.assertEqual(row.severity, AnalyticsEvent.Severity.CRITICAL)
        # It got past the customer credit and failed on the float debit.
        self.assertEqual(row.attributes["step"], integ_telemetry.STEP_COMMIT)
        self.assertEqual(row.attributes["provider_reference"], "4300665")

    def test_a_refused_charge_is_an_error_not_a_crisis(self):
        session = lnet_session(
            posts={
                "validatePaymentAJAX": _LnetResponse(
                    '{"status":"error","message":"Balance not sufficient"}'
                )
            }
        )
        with patch_lnet(session):
            LnetProvider(self.account).recharge("alhussainbasheir", "topup:45")
        self._flush()
        row = self._events().filter(attributes__operation="recharge").get()
        from apps.analytics.models import AnalyticsEvent

        self.assertEqual(row.severity, AnalyticsEvent.Severity.ERROR)
        self.assertEqual(row.attributes["step"], integ_telemetry.STEP_SUBMIT)

    def test_no_row_ever_carries_a_customer_identifier(self):
        # Analytics rows leave the shop. A card number is a subscriber and an
        # LNET username is a person; neither may ride along.
        with patch_lnet(lnet_session()):
            driver = LnetProvider(self.account)
            driver.lookup("0910682854")
            driver.offers("alhussainbasheir")
            driver.purchase_history("alhussainbasheir")
        self._flush()
        blob = json.dumps(
            [
                {"a": row.attributes, "m": row.metrics, "e": row.entity_id}
                for row in self._events()
            ]
        )
        self.assertNotIn("alhussainbasheir", blob)
        self.assertNotIn("0910682854", blob)

    def test_telemetry_never_breaks_the_call_it_is_measuring(self):
        with mock.patch.object(
            integ_telemetry, "_record", side_effect=RuntimeError("boom")
        ):
            with patch_lnet(lnet_session()):
                result = LnetProvider(self.account).lookup("0910682854")
        self.assertTrue(result.ok, "a telemetry fault must not fail a lookup")

    def test_hdbox_is_instrumented_by_the_same_vocabulary(self):
        # Registration instruments a driver, so a provider added later is
        # measured whether or not its author thought about it.
        session = _FakeSession(_FakeResponse(LOGIN_PAGE), [])
        with patch_session(session):
            HdBoxProvider(make_account()).probe()
        self._flush()
        row = self._events().get()
        self.assertEqual(row.attributes["provider"], "hdbox")
        self.assertEqual(row.attributes["step"], integ_telemetry.STEP_LOGIN)
        self.assertEqual(row.attributes["outcome"], ERROR_UNAUTHORIZED)

    def test_every_registered_driver_is_observed(self):
        for key in ("hdbox", "lnet", "qareeb"):
            driver = provider_for(IntegrationAccount(provider=key))
            for method in integ_telemetry.OPERATIONS:
                self.assertTrue(
                    getattr(getattr(type(driver), method), "_observed", False),
                    f"{key}.{method} is unobserved",
                )


# --- how long a cashier waits ------------------------------------------------


class _PathRoutedHdBoxSession:
    """An HD Box session that routes by URL and can be made to block.

    ``_FakeSession`` hands out its canned GETs with ``pop(0)``, which is fine
    for a driver that talks in a fixed order and useless for one that makes
    two calls at once. This routes on the path instead, and optionally waits
    on a barrier so a test can tell "at the same time" from "one after the
    other" rather than trusting a stopwatch.
    """

    def __init__(self, pages, *, barrier=None, barrier_paths=()):
        self.pages = dict(pages)
        self.barrier = barrier
        self.barrier_paths = tuple(barrier_paths)
        self.get_calls = []
        self.post_calls = []
        self.cookies = {}
        self.barrier_broken = False

    def post(self, url, **kwargs):
        self.post_calls.append((url, kwargs))
        return _FakeResponse(AUTHED_PAGE)

    def mount(self, prefix, adapter):
        """A real Session has one; the drivers mount a shared pool on it."""

    def get(self, url, **kwargs):
        self.get_calls.append((url, kwargs))
        if self.barrier is not None and any(p in url for p in self.barrier_paths):
            try:
                self.barrier.wait()
            except threading.BrokenBarrierError:
                self.barrier_broken = True
        for fragment, response in self.pages.items():
            if fragment in url:
                return response
        raise AssertionError(f"unscripted GET {url}")


@CACHED_PROVIDER_SESSIONS
class ProviderConnectionReuseTests(TestCase):
    """One card lookup, one connection.

    The session cache stopped a card lookup paying for three *logins*. It did
    not stop it paying for three *connections*: every ``_login()`` built a
    fresh ``requests.Session`` from the cached cookies, and a fresh Session is
    a fresh connection pool — so lookup, offers and profile each opened their
    own socket and paid their own TLS handshake to a portal on the far side of
    a Libyan uplink. The field export (2026-09-22) shows a floor of roughly
    0.6-1.5s on calls that transfer almost nothing, which is what that looks
    like from the outside.
    """

    def setUp(self):
        cache.clear()
        self.addCleanup(analytics_buffer.reset)

    def test_hdbox_keeps_one_session_across_the_whole_chain(self):
        card_json = (
            '{"status":"success","total":1,"rows":[{"cardNo":"210906803499",'
            '"status":"Active","statusId":3}]}'
        )
        session = _FakeSession(
            _FakeResponse(AUTHED_PAGE),
            [
                _FakeResponse(card_json),
                _FakeResponse(RENEW_FORM),
                _FakeResponse(DETAIL_FORM),
            ],
        )
        with patch_session(session) as session_class:
            driver = HdBoxProvider(make_account())
            self.assertTrue(driver.lookup("210906803499").ok)
            self.assertTrue(driver.offers("210906803499").ok)
            self.assertTrue(driver.subscriber_profile("210906803499").ok)

        # One Session constructed means one connection pool means one
        # handshake, not three.
        self.assertEqual(session_class.call_count, 1)

    def test_lnet_keeps_one_session_across_the_whole_chain(self):
        session = lnet_session()
        with patch_lnet(session) as session_class:
            driver = LnetProvider(lnet_account())
            lookup = driver.lookup("alhussainbasheir")
            self.assertTrue(lookup.ok, lookup.error_detail)
            self.assertTrue(
                driver.offers("alhussainbasheir", resolved=lookup.card).ok
            )

        self.assertEqual(session_class.call_count, 1)

    def test_a_reused_session_still_carries_its_csrf_token(self):
        # The token travels with the session it belongs to. Handing back an
        # empty one would not break a write — every write re-reads its own
        # page's token — but it would quietly drop the fallback.
        with patch_lnet(lnet_session()):
            driver = LnetProvider(lnet_account())
            _first, first_token, code, _detail = driver._login()
            self.assertEqual(code, "")
            _second, second_token, _code, _detail = driver._login()

        self.assertTrue(first_token)
        self.assertEqual(second_token, first_token)


class CardViewConcurrencyTests(TestCase):
    """The offer ladder and the detail page are read at the same time.

    They are two different pages about one line and neither needs the other's
    answer, so reading them one after the other spends a cashier both waits.
    Proved with a barrier rather than a clock: if the two reads are sequential
    the second never arrives, the first times out waiting, and this fails.
    """

    def setUp(self):
        ensure_role_groups()
        User = get_user_model()
        self.cashier = User.objects.create_user(username="csh2", password="x")
        self.cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.client = APIClient()
        self.client.force_authenticate(self.cashier)
        make_account()
        self.addCleanup(analytics_buffer.reset)

    def test_offers_and_profile_are_read_together(self):
        card_json = (
            '{"status":"success","total":1,"rows":[{"cardNo":"210906803499",'
            '"status":"Active","statusId":3}]}'
        )
        barrier = threading.Barrier(2, timeout=10)
        session = _PathRoutedHdBoxSession(
            {
                LIST_PATH: _FakeResponse(card_json),
                RENEW_VIEW_PATH: _FakeResponse(RENEW_FORM),
                DETAIL_VIEW_PATH: _FakeResponse(DETAIL_FORM),
            },
            barrier=barrier,
            barrier_paths=(RENEW_VIEW_PATH, DETAIL_VIEW_PATH),
        )
        with patch_session(session):
            resp = self.client.get(
                "/api/integrations/hdbox/card/?card_no=210906803499"
            )

        self.assertEqual(resp.status_code, 200)
        self.assertTrue(resp.data["ok"], resp.data)
        # Both arms reached the barrier, so both were in flight at once.
        self.assertFalse(session.barrier_broken)
        self.assertTrue(resp.data["offers"])
        self.assertTrue(resp.data["subscriber"])


class _LnetSearchSession(_LnetFakeSession):
    """An LNET session that answers per search mode, and can block.

    Every search is the same URL with different query parameters, so routing
    by path — which is all ``_LnetFakeSession`` does — cannot tell a phone
    search from a contract search. This can, which is what it takes to say
    anything about which searches were issued and when.
    """

    def __init__(self, by_mode, *, barrier=None, barrier_modes=(), **kwargs):
        super().__init__(
            pages={
                "/login": _LnetResponse(LNET_LOGIN_PAGE),
                "/admin/settings/users/recharge/": _LnetResponse(LNET_RECHARGE_FORM),
            },
            posts={"/login": _LnetResponse(LNET_HOME_PAGE)},
            **kwargs,
        )
        self.by_mode = dict(by_mode)
        self.barrier = barrier
        self.barrier_modes = tuple(barrier_modes)
        self.barrier_broken = False

    @property
    def search_modes(self):
        return [
            k["params"]["search_by"] for _u, k in self.get_calls if "params" in k
        ]

    def get(self, url, **kwargs):
        mode = (kwargs.get("params") or {}).get("search_by")
        if mode is None:
            return super().get(url, **kwargs)
        self.get_calls.append((url, kwargs))
        if self.barrier is not None and mode in self.barrier_modes:
            try:
                self.barrier.wait()
            except threading.BrokenBarrierError:
                self.barrier_broken = True
        return _LnetResponse(self.by_mode.get(mode, lnet_users_page()))


@CACHED_PROVIDER_SESSIONS
class LnetSearchFanOutTests(TestCase):
    """Three searches, one wait.

    The portal can be asked by phone number, by username or by contract
    number, and a term made of digits could be any of them. Asking in turn
    meant a term it does not know by phone paid for that search in full
    before the username search had even started: the field export
    (2026-09-22) has the same lookup landing at ~1.4s when one mode answered
    and 4.4s when the third one did.
    """

    def setUp(self):
        cache.clear()
        self.addCleanup(analytics_buffer.reset)

    def test_the_mode_a_till_types_most_still_costs_one_request(self):
        # A phone number the portal knows by phone number. Nothing is fanned
        # out, because nothing needed to be: this is the ordinary counter
        # search and it must not send the portal two requests it cannot use.
        session = _LnetSearchSession({"mobile": LNET_ONE_LINE})
        with patch_lnet(session):
            result = LnetProvider(lnet_account()).lookup("0910682854")

        self.assertTrue(result.ok, result.error_detail)
        self.assertEqual(session.search_modes, ["mobile"])

    def test_the_modes_left_after_a_miss_go_together(self):
        # Proved with a barrier, not a clock: if username and contract are
        # searched one after the other, the first waits alone and times out.
        barrier = threading.Barrier(2, timeout=10)
        session = _LnetSearchSession(
            {"contract_number": LNET_ONE_LINE},
            barrier=barrier,
            barrier_modes=("username", "contract_number"),
        )
        with patch_lnet(session):
            result = LnetProvider(lnet_account()).lookup("0910682854")

        self.assertTrue(result.ok, result.error_detail)
        self.assertFalse(session.barrier_broken)
        self.assertEqual(sorted(session.search_modes[1:]), ["contract_number", "username"])
        # The leading mode still went first, and alone.
        self.assertEqual(session.search_modes[0], "mobile")

    def test_a_term_two_modes_both_know_answers_by_priority_not_by_speed(self):
        # The whole reason the old loop stopped at the first hit: a term that
        # is one household's username and another's contract number must not
        # come back as two unrelated households. Running the searches together
        # must not turn that into "whichever thread finished first".
        session = _LnetSearchSession(
            {"username": LNET_ONE_LINE, "contract_number": LNET_THREE_LINES}
        )
        with patch_lnet(session):
            result = LnetProvider(lnet_account()).lookup("0910682854")

        self.assertTrue(result.ok, result.error_detail)
        self.assertEqual(len(result.candidates), 1)
        self.assertEqual(result.card.card_no, "alhussainbasheir")

    def test_nothing_anywhere_is_still_not_found(self):
        session = _LnetSearchSession({})
        with patch_lnet(session):
            result = LnetProvider(lnet_account()).lookup("0000000000")

        self.assertFalse(result.ok)
        self.assertEqual(result.error_code, ERROR_NOT_FOUND)
        self.assertEqual(sorted(session.search_modes), ["contract_number", "mobile", "username"])

    def test_a_lettered_term_never_wastes_a_mobile_search(self):
        session = _LnetSearchSession({"contract_number": LNET_ONE_LINE})
        with patch_lnet(session):
            result = LnetProvider(lnet_account()).lookup("basheir.home")

        self.assertTrue(result.ok, result.error_detail)
        self.assertNotIn("mobile", session.search_modes)
        self.assertEqual(session.search_modes[0], "username")


class ParallelCallIdentityTests(TestCase):
    """A row written by a worker thread still names the till that asked.

    ``apps.analytics.context`` keeps identity in ``ContextVar``s, and a
    ``ThreadPoolExecutor`` thread starts with an **empty** context — so
    reading the offer ladder on a worker would quietly have written an
    anonymous row for every card lookup in the shop. An integration row that
    cannot be joined to a register session is most of the reason this
    telemetry is collected at all.
    """

    def _rows_written_by(self, calls):
        written = []
        with mock.patch(
            "apps.analytics.buffer.enqueue", side_effect=written.append
        ):
            answers = in_parallel(calls)
        return answers, written

    def _report(self, operation):
        def call():
            integ_telemetry.record(
                integ_telemetry.CallReport(provider="lnet", operation=operation)
            )
            return operation

        return call

    def test_a_parallel_call_keeps_the_register_session(self):
        with analytics_context.request_identity(
            {"device_id": "till-7", "register_session_id": "4"}
        ):
            answers, written = self._rows_written_by(
                [self._report("offers"), self._report("profile")]
            )

        # Answers come back in the order they were asked for, not the order
        # the threads happened to finish in.
        self.assertEqual(answers, ["offers", "profile"])
        self.assertEqual(len(written), 2)
        for event in written:
            self.assertEqual(event.attributes.get("register_session_id"), "4")
            self.assertEqual(event.device_id, "till-7")

    def test_the_same_holds_when_there_is_nothing_to_parallelise(self):
        # One call runs inline, and must not be a different animal.
        with analytics_context.request_identity({"register_session_id": "9"}):
            _answers, written = self._rows_written_by([self._report("offers")])

        self.assertEqual(written[0].attributes.get("register_session_id"), "9")

    def test_a_worker_never_writes_the_row_itself(self):
        # A worker has its own connection, so an insert there commits outside
        # the request's transaction: it escapes a rollback in production and
        # survives the whole test run under a TestCase. The row must be
        # queued by the worker and written by somebody allowed to write.
        from apps.analytics.models import AnalyticsEvent

        analytics_buffer.reset()
        self.addCleanup(analytics_buffer.reset)
        before = AnalyticsEvent.objects.filter(
            name=integ_telemetry.EVENT_NAME
        ).count()

        with analytics_context.request_identity({"register_session_id": "4"}):
            in_parallel([self._report("offers"), self._report("profile")])

        self.assertEqual(
            AnalyticsEvent.objects.filter(name=integ_telemetry.EVENT_NAME).count(),
            before,
            "a worker thread inserted a row on its own connection",
        )
        analytics_buffer.flush()
        self.assertEqual(
            AnalyticsEvent.objects.filter(name=integ_telemetry.EVENT_NAME).count(),
            before + 2,
        )


class ProviderConnectionPoolTests(TestCase):
    """A connection that outlives the request that opened it.

    Reusing a driver's session removed two of the three handshakes one card
    lookup paid for. This removes the third from every lookup after the
    first: the sockets live in a pool belonging to the portal, not to the
    request, so a cashier's second search of the shift starts with the
    connection already open.
    """

    def setUp(self):
        connection_pool.reset()
        self.addCleanup(connection_pool.reset)

    def test_two_sessions_for_one_portal_share_its_pool(self):
        first = connection_pool.warm(requests.Session(), "https://portal.example")
        second = connection_pool.warm(requests.Session(), "https://portal.example")

        # The same adapter object means the same urllib3 pools underneath —
        # which is the only part that is safe to share, and the only part
        # worth sharing.
        self.assertIs(first.get_adapter("https://portal.example/x"),
                      second.get_adapter("https://portal.example/x"))
        self.assertIsNot(first, second)

    def test_two_portals_never_share_a_pool(self):
        one = connection_pool.warm(requests.Session(), "https://a.example")
        two = connection_pool.warm(requests.Session(), "https://b.example")

        self.assertIsNot(one.get_adapter("https://a.example/x"),
                         two.get_adapter("https://b.example/x"))
        self.assertEqual(connection_pool.pooled_hosts(),
                         ["https://a.example", "https://b.example"])

    def test_a_portal_with_no_url_is_simply_not_pooled(self):
        session = connection_pool.warm(requests.Session(), "")
        self.assertEqual(connection_pool.pooled_hosts(), [])
        self.assertIsNotNone(session)

    def test_a_write_is_never_retried_after_it_has_been_sent(self):
        """The money rule, as a regression guard.

        A pooled connection can be dead, so one retry is allowed. A read
        failure means the request DID leave this machine and the portal may
        already have acted on it — and ``recharge`` is a POST that credits a
        customer. Sending it twice is two top-ups and one payment. If anyone
        ever widens this policy, this test is what should stop them.
        """
        policy = connection_pool._RETRY

        self.assertEqual(policy.read, 0, "a sent request must never be replayed")
        self.assertNotIn("POST", policy.allowed_methods)
        self.assertIn("GET", policy.allowed_methods)
        # A connect failure never reached the portal, so it is safe to retry
        # for anything — that is the retry this pool actually exists to spend.
        self.assertEqual(policy.connect, 1)

    def test_a_driver_opens_its_portal_pool(self):
        account = lnet_account()
        with patch_lnet(lnet_session()):
            LnetProvider(account).lookup("alhussainbasheir")

        # The fake Session records the mount rather than performing it, so
        # what this proves is that the driver asks for the pool at all.
        self.assertEqual(
            connection_pool.pooled_hosts(), [account.resolved_base_url()]
        )


@CACHED_PROVIDER_SESSIONS
class LnetSearchModePickerTests(TestCase):
    """What the cashier says the number is, and what that saves.

    A phone number and a contract number are both digits: nothing on the
    server can tell them apart, so every till search used to be a guess that
    cost a round trip per wrong guess. The picker beside the search box is
    the cheapest possible fix — the person holding the number already knows.
    """

    def setUp(self):
        cache.clear()
        self.addCleanup(analytics_buffer.reset)
        connection_pool.reset()
        self.addCleanup(connection_pool.reset)
        ensure_role_groups()
        User = get_user_model()
        self.cashier = User.objects.create_user(username="csh3", password="x")
        self.cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.client = APIClient()
        self.client.force_authenticate(self.cashier)
        self.account = lnet_account()

    def test_a_contract_number_named_as_one_costs_a_single_search(self):
        # The case the old code was worst at: digits the portal does not know
        # by phone, so it walked mobile, then username, then contract — three
        # round trips, ~4.4s on the Annaseem till. Named, it is one.
        session = _LnetSearchSession({"contract_number": LNET_ONE_LINE})
        with patch_lnet(session):
            result = LnetProvider(self.account).lookup(
                "214737", search_by="contract_number"
            )

        self.assertTrue(result.ok, result.error_detail)
        self.assertEqual(session.search_modes, ["contract_number"])

    def test_the_default_pick_is_still_the_phone_search(self):
        session = _LnetSearchSession({"mobile": LNET_ONE_LINE})
        with patch_lnet(session):
            LnetProvider(self.account).lookup("0910682854", search_by="mobile")

        self.assertEqual(session.search_modes, ["mobile"])

    def test_a_wrong_pick_still_finds_the_line(self):
        # The picker orders the search; it must never fence it. A cashier who
        # leaves it on the wrong entry waits a second longer — they do not
        # get told the customer does not exist.
        session = _LnetSearchSession({"mobile": LNET_ONE_LINE})
        with patch_lnet(session):
            result = LnetProvider(self.account).lookup(
                "0910682854", search_by="contract_number"
            )

        self.assertTrue(result.ok, result.error_detail)
        self.assertEqual(session.search_modes[0], "contract_number")
        self.assertIn("mobile", session.search_modes)

    def test_a_pick_the_portal_does_not_offer_is_ignored(self):
        session = _LnetSearchSession({"mobile": LNET_ONE_LINE})
        with patch_lnet(session):
            result = LnetProvider(self.account).lookup(
                "0910682854", search_by="iris-scan"
            )

        self.assertTrue(result.ok, result.error_detail)
        self.assertEqual(session.search_modes[0], "mobile")

    def test_a_lettered_term_never_leads_with_a_phone_search(self):
        # Whatever the picker says. A username has letters in it and the
        # phone search cannot match one, so leading with it is a wasted trip.
        session = _LnetSearchSession({"username": LNET_ONE_LINE})
        with patch_lnet(session):
            LnetProvider(self.account).lookup("basheir.home", search_by="mobile")

        self.assertNotIn("mobile", session.search_modes)

    def test_the_till_passes_the_pick_through_to_the_portal(self):
        session = _LnetSearchSession({"contract_number": LNET_ONE_LINE})
        with patch_lnet(session):
            resp = self.client.get(
                "/api/integrations/lnet/card/"
                "?card_no=214737&search_by=contract_number"
            )

        self.assertEqual(resp.status_code, 200)
        self.assertTrue(resp.data["ok"], resp.data)
        self.assertEqual(session.search_modes, ["contract_number"])
