from __future__ import annotations

from datetime import timedelta
from datetime import timezone as dt_timezone
from decimal import Decimal
from unittest import mock

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.conf import settings
from django.db import transaction
from django.test import TestCase, TransactionTestCase
from django.utils import timezone

from rest_framework import serializers
from rest_framework.test import APIClient

from apps.catalog.testing import create_product_with_default_variant
from apps.core.roles import (
    ACCOUNTANT_GROUP,
    CASHIER_GROUP,
    MANAGER_GROUP,
    ensure_role_groups,
)
from apps.customers.models import Customer
from apps.expenses.models import Expense
from apps.notifications.models import BusinessNotification
from apps.notifications.services import sync_business_notifications
from apps.inventory.models import StockMovement
from apps.sales.models import Order, OrderLine, RegisterSession
from apps.sales.services import checkout_order
from apps.treasury.models import MoneyAccount, MoneyTransfer
from apps.treasury.position import treasury_position

from . import catalog
from . import float_ledger
from . import recharge
from .fulfillment import resolve_line_integration
from .reconciliation import reconcile_account
from .models import (
    IntegrationAccount,
    IntegrationFulfillment,
    IntegrationSubscriber,
)
from .providers import is_implemented, provider_for
from .providers.base import (
    ERROR_NOT_CONFIGURED,
    ERROR_NOT_FOUND,
    ERROR_UNAUTHORIZED,
    ERROR_UNAVAILABLE,
    ERROR_UNEXPECTED,
    ProbeResult,
)
from .providers.base import RechargeOption
from .providers import hdbox
from .providers.hdbox import HdBoxProvider
from .provisioning import service_variant_for
from .services import probe_account, record_seen_offers, record_subscriber

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
    """Stands in for requests.Session: canned POST login + scripted GETs."""

    def __init__(self, login_response, get_responses):
        self._login_response = login_response
        self._get_responses = list(get_responses)
        self.get_calls = []

    def post(self, url, **kwargs):
        return self._login_response

    def get(self, url, **kwargs):
        self.get_calls.append((url, kwargs))
        return self._get_responses.pop(0)


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
        self.assertFalse(is_implemented("lnet"))
        self.assertFalse(is_implemented("qareeb"))

    def test_planned_providers_say_why(self):
        self.assertEqual(
            catalog.LNET.blocked_reason, catalog.BLOCKED_DRIVER_IN_PROGRESS
        )
        self.assertEqual(catalog.QAREEB.blocked_reason, catalog.BLOCKED_AWAITING_ACCESS)

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
        account = IntegrationAccount.objects.create(provider="lnet")
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
        self.assertFalse(by_key["lnet"]["is_configurable"])
        self.assertEqual(by_key["lnet"]["blocked_reason"], "driver_in_progress")
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
            "/api/integrations/lnet/", {"username": "x", "password": "y"}, format="json"
        )
        self.assertEqual(resp.status_code, 409)
        self.assertFalse(IntegrationAccount.objects.filter(provider="lnet").exists())

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
        session = _FakeSession(
            _FakeResponse(AUTHED_PAGE),
            # login → lookup, → renew form, → card detail
            [
                _FakeResponse(card_json),
                _FakeResponse(RENEW_FORM),
                _FakeResponse(DETAIL_FORM),
            ],
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
            [
                _FakeResponse(card_json),
                _FakeResponse(RENEW_FORM),
                _FakeResponse(DETAIL_FORM),
            ],
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
