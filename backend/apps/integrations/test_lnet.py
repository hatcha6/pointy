"""LNET on Splynx: reads through the API, pays through the Cashdesk.

Driven against :mod:`apps.integrations.testing_lnet`, a stand-in built from a
real agency session (2026-11-11). The money tests hold the driver to the
three honest endings of a write: performed, definitely refused (nothing left
the machine, or the page refused in words and history proves it), and
indeterminate — never a refusal a caller could retry into a second payment.
"""

from __future__ import annotations

from datetime import timedelta
from decimal import Decimal
from unittest import mock

import requests
from django.test import TestCase
from django.utils import timezone

from .providers import lnet as lnet_module
from .providers.base import (
    ERROR_INDETERMINATE,
    ERROR_INSUFFICIENT_FLOAT,
    ERROR_NOT_FOUND,
    ERROR_PROVIDER_ERROR,
    ERROR_UNAUTHORIZED,
    ERROR_UNEXPECTED,
    ERROR_UNREACHABLE,
    PAYMENT_VERIFIED,
)
from .providers.lnet import LnetProvider
from .testing_lnet import (
    HOUSEHOLD,
    ONE_LINE,
    Reply,
    SplynxFake,
    at_local,
    billing_info,
    internet_service,
    deposit_opened,
    local_stamp,
    lnet_account,
    paid,
    patch_lnet,
)

LINE = ONE_LINE[0]


def _form(fake):
    """The fields of the one add-funds POST, as sent."""
    [(_method, _url, kwargs)] = fake.requests_to("/cabinet/add-funds", "POST")
    return {name: value[1] for name, value in kwargs["files"]}, kwargs


class LnetAuthTests(TestCase):
    def test_probe_logs_in_at_both_doors_and_reads_the_deposit_live(self):
        fake = SplynxFake(deposit="33.00")
        with patch_lnet(fake):
            result = LnetProvider(lnet_account()).probe()
        self.assertTrue(result.ok, result)
        self.assertEqual(result.balance, Decimal("33.00"))
        self.assertEqual(result.account_label, "lnet_r67")
        [(_m, _u, login)] = fake.requests_to("/cashdesk/login", "POST")
        sent = dict(login["data"])
        self.assertEqual(sent["_csrf"], "tok-login==")
        self.assertEqual(sent["LoginForm[login]"], "lnet_r67")
        [(_m, _u, token)] = fake.requests_to("/auth/tokens", "POST")
        self.assertEqual(token["json"]["auth_type"], "admin")

    def test_a_rejected_cashdesk_password_is_unauthorized(self):
        with patch_lnet(SplynxFake(cashdesk_login_ok=False)):
            result = LnetProvider(lnet_account()).probe()
        self.assertFalse(result.ok)
        self.assertEqual(result.error_code, ERROR_UNAUTHORIZED)

    def test_a_rejected_api_login_is_unauthorized(self):
        with patch_lnet(SplynxFake(api_login_ok=False)):
            result = LnetProvider(lnet_account()).lookup("0910682854")
        self.assertFalse(result.ok)
        self.assertEqual(result.error_code, ERROR_UNAUTHORIZED)

    def test_an_unreachable_host_is_unreachable(self):
        with patch_lnet(SplynxFake(fail={"/cashdesk/login": requests.ConnectionError})):
            result = LnetProvider(lnet_account()).probe()
        self.assertEqual(result.error_code, ERROR_UNREACHABLE)

    def test_one_driver_logs_in_once_however_many_calls_it_makes(self):
        fake = SplynxFake()
        with patch_lnet(fake):
            driver = LnetProvider(lnet_account())
            card = driver.lookup("0910682854").card
            driver.offers(card.card_no, resolved=card)
            driver.subscriber_profile(card.card_no, resolved=card)
        self.assertEqual(len(fake.requests_to("/auth/tokens")), 1)
        self.assertEqual(len(fake.requests_to("/cashdesk/login", "POST")), 1)

    def test_a_cached_cashdesk_session_that_died_is_retried_once(self):
        account = lnet_account()
        fake = SplynxFake()
        login_bounce = Reply('<input name="LoginForm[password]">', url="https://lnet.test/cashdesk/login")
        calls = {"n": 0}
        original = fake._route

        def route(method, url, kwargs):
            if "/cabinet/balance" in url and calls["n"] == 0:
                calls["n"] += 1
                fake.calls.append((method, url, kwargs))
                return login_bounce
            return original(method, url, kwargs)

        fake._route = route
        with (
            patch_lnet(fake),
            mock.patch.object(lnet_module.session_cache, "load", return_value={"cookies": {"PHPSESSID": "old"}}),
        ):
            result = LnetProvider(account).probe()
        self.assertTrue(result.ok, result)
        self.assertEqual(result.balance, Decimal("33.00"))
        self.assertEqual(len(fake.requests_to("/cashdesk/login", "POST")), 1)


class LnetLookupTests(TestCase):
    def setUp(self):
        self.account = lnet_account()

    def _lookup(self, term, fake=None, **kwargs):
        fake = fake or SplynxFake()
        with patch_lnet(fake):
            return LnetProvider(self.account).lookup(term, **kwargs), fake

    def test_a_phone_finds_its_line_through_the_api(self):
        result, fake = self._lookup("0910682854", search_by="mobile")
        self.assertTrue(result.ok, result)
        self.assertEqual(result.card.card_no, "alhussainbasheir")
        self.assertEqual(result.card.provider_id, "214737")
        self.assertEqual(result.card.holder_name, "الحسين بشير")
        self.assertEqual(result.card.status, "active")
        [(_m, _u, kwargs)] = fake.requests_to("/admin/customers/customer")
        # The national number, so 091…, +218 91… and 91… all match.
        self.assertEqual(kwargs["params"]["main_attributes[phone][1]"], "910682854")
        self.assertEqual(fake.requests_to("/cashdesk/"), [])

    def test_every_spelling_of_a_libyan_number_is_the_same_number(self):
        for typed in ("+218910682854", "218910682854", "00218910682854", "910682854"):
            result, _fake = self._lookup(typed)
            self.assertTrue(result.ok, typed)

    def test_a_household_is_offered_as_a_choice(self):
        result, _fake = self._lookup("0910682854", fake=SplynxFake(customers=HOUSEHOLD))
        self.assertTrue(result.ok)
        self.assertIsNone(result.card)
        self.assertTrue(result.is_ambiguous)
        self.assertEqual(
            [c.card_no for c in result.candidates],
            ["alhussainbasheir", "basheir.shop", "basheir2"],
        )

    def test_a_username_is_searched_as_a_login(self):
        result, fake = self._lookup("alhussainbasheir")
        self.assertTrue(result.ok)
        [(_m, _u, kwargs)] = fake.requests_to("/admin/customers/customer")
        self.assertEqual(kwargs["params"]["main_attributes[login][1]"], "alhussainbasheir")

    def test_digits_that_are_no_phone_are_tried_as_a_login_next(self):
        customers = ({**LINE, "login": "77001", "phone": ""},)
        result, fake = self._lookup("77001", fake=SplynxFake(customers=customers))
        self.assertTrue(result.ok)
        self.assertEqual(result.card.card_no, "77001")
        self.assertEqual(len(fake.requests_to("/admin/customers/customer")), 2)

    def test_a_contract_number_goes_to_the_cashdesk_search(self):
        result, fake = self._lookup("7781", fake=SplynxFake(customers=({**LINE, "contract": "7781", "phone": ""},)), search_by="contract_number")
        self.assertTrue(result.ok, result)
        self.assertEqual(result.card.card_no, "alhussainbasheir")
        [(_m, _u, kwargs)] = fake.requests_to("/cashdesk/cabinet", "POST")
        self.assertEqual(kwargs["data"]["CustomerSearchForm[contract_number]"], "7781")

    def test_nothing_found_is_not_found(self):
        result, _fake = self._lookup("0920000000")
        self.assertFalse(result.ok)
        self.assertEqual(result.error_code, ERROR_NOT_FOUND)

    def test_a_failed_search_is_reported_not_found(self):
        fake = SplynxFake(fail={"/admin/customers/customer": 500})
        result, _fake = self._lookup("alhussainbasheir", fake=fake)
        self.assertFalse(result.ok)
        self.assertEqual(result.error_code, ERROR_PROVIDER_ERROR)


class LnetLineTests(TestCase):
    def test_offers_are_quick_picks_plus_any_amount_once_the_page_renders(self):
        fake = SplynxFake()
        with patch_lnet(fake):
            offers = LnetProvider(lnet_account()).offers("alhussainbasheir")
        self.assertTrue(offers.ok, offers)
        self.assertIsNotNone(offers.open_amount)
        self.assertEqual(offers.open_amount.cost_ratio, Decimal("0.95"))
        option = {o.code: o for o in offers.options}["topup:45"]
        self.assertEqual(option.cost, Decimal("42.75"))
        self.assertEqual(option.face_value, Decimal("45.00"))
        [(_m, _u, page)] = fake.requests_to("/cabinet/add-funds", "GET")
        self.assertEqual(page["params"], {"customer_id": "214737"})

    def test_a_page_that_does_not_render_the_form_blocks_the_sale(self):
        fake = SplynxFake(fail={"/cabinet/add-funds": Reply("<h1>Oops</h1>")})
        with patch_lnet(fake):
            offers = LnetProvider(lnet_account()).offers("alhussainbasheir")
        self.assertFalse(offers.ok)
        self.assertEqual(offers.error_code, ERROR_UNEXPECTED)

    def test_the_commission_is_the_owners_setting(self):
        account = lnet_account()
        account.config = {**(account.config or {}), lnet_module.SETTING_COMMISSION_PERCENT: "3"}
        account.save(update_fields=["config"])
        quote = LnetProvider(account).quote("topup:100")
        self.assertEqual(quote.cost, Decimal("97.00"))

    def test_profile_carries_the_money_already_on_the_line(self):
        with patch_lnet(SplynxFake()):
            result = LnetProvider(lnet_account()).subscriber_profile("alhussainbasheir")
        self.assertTrue(result.ok)
        self.assertEqual(result.profile.card_balance, Decimal("12.50"))
        self.assertEqual(result.profile.display_name, "الحسين بشير")

    def test_only_an_exact_login_is_the_line(self):
        customers = ({**LINE, "login": "basheir.shop"},)
        with patch_lnet(SplynxFake(customers=customers)):
            result = LnetProvider(lnet_account()).offers("basheir")
        self.assertFalse(result.ok)
        self.assertEqual(result.error_code, ERROR_NOT_FOUND)

    def test_quote_needs_no_network(self):
        driver = LnetProvider(lnet_account())
        quote = driver.quote("topup:45")
        self.assertEqual(quote.cost, Decimal("42.75"))
        self.assertEqual(quote.face_value, Decimal("45.00"))
        self.assertIsNone(driver.quote("renew:1"))


class LnetRechargeTests(TestCase):
    def _charge(self, fake, *, amount="45", key="17-20261111140650000000-1", expected="42.75"):
        with patch_lnet(fake):
            return LnetProvider(lnet_account()).recharge(
                "alhussainbasheir", f"topup:{amount}", expected_cost=Decimal(expected), attempt_key=key
            )

    def test_a_payment_is_one_post_of_the_cashdesk_form(self):
        fake = SplynxFake(deposit="100.00")
        result = self._charge(fake)
        self.assertTrue(result.ok, result)
        form, kwargs = _form(fake)
        self.assertEqual(form["_csrf"], "tok-funds==")
        self.assertEqual(form["AddFundsForm[amount]"], "45")
        self.assertEqual(form["AddFundsForm[paymentType]"], "1")
        self.assertEqual(form["AddFundsForm[payInvoiceOrRequest]"], "0")
        self.assertEqual(form["AddFundsForm[comment]"], "pointy:17-20261111140650000000-1")
        self.assertEqual(form["AddFundsForm[date]"], lnet_module._local_today().isoformat())
        self.assertEqual(kwargs["headers"]["X-PJAX"], "true")
        self.assertIn("customer_id=214737", fake.requests_to("/cabinet/add-funds", "POST")[0][1])

    def test_a_performed_payment_carries_lnets_own_payment_id_and_the_deposit(self):
        fake = SplynxFake(deposit="100.00")
        result = self._charge(fake)
        self.assertEqual(result.reference, "6741")
        self.assertEqual(result.balance_after, Decimal("55.00"))
        self.assertEqual(result.receipt["printed"]["serial"], "6741")
        self.assertEqual(result.receipt["printed"]["username"], "alhussainbasheir")
        self.assertEqual(result.receipt["customer_balance"], "57.5")

    def test_a_deposit_that_cannot_cover_it_is_refused_before_anything_is_sent(self):
        fake = SplynxFake(deposit="20.00")
        result = self._charge(fake)
        self.assertFalse(result.ok)
        self.assertFalse(result.indeterminate)
        self.assertEqual(result.error_code, ERROR_INSUFFICIENT_FLOAT)
        self.assertEqual(fake.requests_to("/cabinet/add-funds", "POST"), [])

    def test_a_moved_cost_is_refused_before_anything_is_sent(self):
        fake = SplynxFake(deposit="100.00")
        result = self._charge(fake, expected="45.00")
        self.assertTrue(result.is_definite_failure)
        self.assertEqual(fake.calls, [])

    def test_an_unknown_line_is_refused_before_anything_is_sent(self):
        fake = SplynxFake(customers=HOUSEHOLD[1:], deposit="100.00")
        result = self._charge(fake)
        self.assertTrue(result.is_definite_failure)
        self.assertEqual(result.error_code, ERROR_NOT_FOUND)
        self.assertEqual(fake.requests_to("/cabinet/add-funds", "POST"), [])

    def test_a_page_for_somebody_else_is_never_paid_on(self):
        other = {**HOUSEHOLD[1], "id": "214737"}
        fake = SplynxFake(deposit="100.00")
        original = fake._route

        def route(method, url, kwargs):
            if method == "GET" and "/cabinet/add-funds" in url:
                fake.calls.append((method, url, kwargs))
                from .testing_lnet import add_funds_page

                return Reply(add_funds_page(other, deposit="100.00"))
            return original(method, url, kwargs)

        fake._route = route
        result = self._charge(fake)
        self.assertTrue(result.is_definite_failure)
        self.assertEqual(fake.requests_to("/cabinet/add-funds", "POST"), [])

    def test_a_lost_reply_is_settled_by_finding_our_marker_in_history(self):
        fake = SplynxFake(deposit="100.00", add_funds="perform-then-raise")
        result = self._charge(fake)
        self.assertTrue(result.ok, result)
        self.assertEqual(result.reference, "6741")
        self.assertEqual(len(fake.payments), 1)

    def test_a_lost_reply_with_no_marker_in_history_is_indeterminate(self):
        fake = SplynxFake(deposit="100.00", fail={"/cabinet/add-funds?": requests.ConnectionError})
        # GET of the page goes through params, the POST through the full URL.
        result = self._charge(fake)
        self.assertFalse(result.ok)
        self.assertTrue(result.indeterminate)
        self.assertEqual(result.error_code, ERROR_INDETERMINATE)
        self.assertEqual(result.receipt["marker"], "pointy:17-20261111140650000000-1")

    def test_a_reply_without_done_and_without_words_is_indeterminate(self):
        fake = SplynxFake(deposit="100.00", add_funds=Reply("<html>?</html>"))
        result = self._charge(fake)
        self.assertTrue(result.indeterminate)

    def test_a_refusal_in_words_with_nothing_in_history_is_a_definite_failure(self):
        refused = Reply(add_funds_page_with_alert("Amount must be no greater than deposit."))
        fake = SplynxFake(deposit="100.00", add_funds=refused)
        result = self._charge(fake)
        self.assertTrue(result.is_definite_failure, result)
        self.assertEqual(result.error_code, ERROR_PROVIDER_ERROR)
        self.assertIn("deposit", result.error_detail)

    def test_an_insufficient_deposit_in_words_says_so(self):
        refused = Reply(add_funds_page_with_alert("Your deposit balance is not enough"))
        fake = SplynxFake(deposit="100.00", add_funds=refused)
        result = self._charge(fake)
        self.assertEqual(result.error_code, ERROR_INSUFFICIENT_FLOAT)

    def test_a_refusal_in_words_while_history_is_unreadable_is_indeterminate(self):
        refused = Reply(add_funds_page_with_alert("Something went wrong"))
        fake = SplynxFake(deposit="100.00", add_funds=refused, fail={"/cabinet/history": 500})
        result = self._charge(fake)
        self.assertTrue(result.indeterminate)

    def test_a_page_that_said_no_but_whose_payment_is_in_history_was_performed(self):
        fake = SplynxFake(deposit="100.00")
        fake.history.insert(0, paid(LINE, at=local_stamp(), amount="45.00", payment_id="9001",
                                   comment="pointy:17-20261111140650000000-1", after="55.00"))
        fake.add_funds = Reply(add_funds_page_with_alert("Request timed out"))
        result = self._charge(fake)
        self.assertTrue(result.ok)
        self.assertEqual(result.reference, "9001")

    def test_a_reply_that_was_not_done_is_kept_for_telemetry(self):
        refused = Reply(add_funds_page_with_alert("Amount is invalid"))
        fake = SplynxFake(deposit="100.00", add_funds=refused)
        with (
            patch_lnet(fake),
            mock.patch.object(LnetProvider, "_observe", autospec=True) as observe,
        ):
            LnetProvider(lnet_account()).recharge("alhussainbasheir", "topup:45", expected_cost=Decimal("42.75"))
        messages = [c.kwargs.get("reply_message") for c in observe.call_args_list if "reply_message" in c.kwargs]
        self.assertEqual(messages, ["Amount is invalid"])


def add_funds_page_with_alert(message):
    from .testing_lnet import add_funds_page

    return add_funds_page(LINE, nav=False, alert=message)


class LnetHistoryTests(TestCase):
    def _history(self, rows):
        fake = SplynxFake(history=rows)
        with patch_lnet(fake):
            return LnetProvider(lnet_account()).purchase_history("alhussainbasheir"), fake

    def test_a_lines_payments_come_from_this_logins_history(self):
        now = timezone.now()
        rows = [
            paid(LINE, at=local_stamp(now - timedelta(hours=1)), payment_id="6741", amount="20.00"),
            paid(HOUSEHOLD[1], at=local_stamp(now - timedelta(hours=2)), payment_id="6740"),
            deposit_opened(at=local_stamp(now - timedelta(days=1))),
        ]
        history, _fake = self._history(rows)
        self.assertTrue(history.ok)
        self.assertEqual(history.total, 1)
        [entry] = history.purchases
        self.assertEqual(entry.reference, "6741")
        self.assertEqual(entry.amount, Decimal("20.00"))
        self.assertEqual(entry.cost, Decimal("19.00"))
        self.assertEqual(entry.status, PAYMENT_VERIFIED)
        self.assertTrue(entry.is_ours)
        self.assertIsNotNone(entry.at.tzinfo)

    def test_history_is_complete_back_to_the_range_it_read(self):
        floor = lnet_module._local_today() - timedelta(days=400)
        with mock.patch.object(lnet_module, "HISTORY_FLOOR", floor):
            history, _fake = self._history([])
        self.assertTrue(history.covers(timezone.now() - timedelta(days=1)))
        self.assertFalse(history.covers(timezone.now() - timedelta(days=400)))

    def test_the_cashdesk_clock_is_shop_local(self):
        self.assertEqual(
            lnet_module._parse_datetime("2026-11-11 16:01:49"), at_local("2026-11-11 16:01:49")
        )
        self.assertEqual(at_local("2026-11-11 16:01:49").hour, 14)


    def test_history_is_never_complete_before_the_deposit_was_opened(self):
        # A sale sent before this login's deposit existed went to the OLD
        # portal; the Cashdesk's silence about it proves nothing.
        opened = timezone.now() - timedelta(hours=3)
        floor = lnet_module._local_today() - timedelta(days=400)
        with mock.patch.object(lnet_module, "HISTORY_FLOOR", floor):
            history, _fake = self._history([deposit_opened(at=local_stamp(opened))])
        self.assertTrue(history.covers(timezone.now() - timedelta(hours=1)))
        self.assertFalse(history.covers(timezone.now() - timedelta(hours=4)))

    def test_the_move_to_splynx_is_the_floor_of_what_history_can_prove(self):
        history, _fake = self._history([])
        before_the_move = at_local("2026-11-10 12:00:00")
        self.assertFalse(history.covers(before_the_move))


class LnetReportTests(TestCase):
    def test_a_window_lists_payments_and_never_the_deposit_itself(self):
        now = timezone.now()
        rows = [
            paid(LINE, at=local_stamp(now - timedelta(hours=1)), payment_id="6741", after="32.00", before="33.00"),
            deposit_opened(at=local_stamp(now - timedelta(days=2))),
        ]
        with patch_lnet(SplynxFake(history=rows)):
            page = LnetProvider(lnet_account()).payment_report_page()
        self.assertTrue(page.ok)
        [payment] = page.payments
        self.assertEqual(payment.reference, "6741")
        self.assertEqual(payment.subscriber_ref, "alhussainbasheir")
        self.assertEqual(payment.operator_name, "lnet_r67")
        self.assertEqual(payment.balance_after, Decimal("32.00"))
        self.assertEqual(payment.status, PAYMENT_VERIFIED)
        # The deposit was opened inside this window: nothing is older.
        self.assertIsNone(page.next_offset)

    def test_windows_tile_back_without_a_gap(self):
        fake = SplynxFake(history=[paid(LINE, at=local_stamp(), payment_id="1")])
        account = lnet_account()
        with patch_lnet(fake), mock.patch.object(lnet_module, "HISTORY_FLOOR", lnet_module._local_today() - timedelta(days=400)):
            first = LnetProvider(account).payment_report_page(offset=0)
        self.assertEqual(first.next_offset, 1)
        [(_m, _u, kwargs)] = fake.requests_to("/cabinet/history")
        start, end = kwargs["params"]["from"], kwargs["params"]["to"]
        with patch_lnet(fake), mock.patch.object(lnet_module, "HISTORY_FLOOR", lnet_module._local_today() - timedelta(days=400)):
            # Window 1 is empty, so the page looks further back on its own.
            LnetProvider(account).payment_report_page(offset=1)
        second = fake.requests_to("/cabinet/history")[1][2]["params"]
        from datetime import date

        self.assertEqual(date.fromisoformat(second["to"]) + timedelta(days=1), date.fromisoformat(start))
        self.assertEqual((date.fromisoformat(end) - date.fromisoformat(start)).days, 30)

    def test_an_unreadable_history_is_not_an_empty_one(self):
        with patch_lnet(SplynxFake(fail={"/cabinet/history": Reply("<html>")})):
            page = LnetProvider(lnet_account()).payment_report_page()
        self.assertFalse(page.ok)
        self.assertEqual(page.error_code, ERROR_UNEXPECTED)


class LnetLineServiceTests(TestCase):
    """Plan, price, start and cut-off day come from the API replies checked on
    a live line on 2026-11-12, which the admin page showed as: Plan «Unlimited
    Home Basic Plus», Price 80.00, Billing start 10/10/2026, Invoiced until
    09/12/2026 (blocked from 2026-12-10)."""

    LIVE = {"services": {"214737": [internet_service()]}, "billing": {"214737": billing_info()}}

    def setUp(self):
        self.account = lnet_account()

    def _profile(self, **fake_kwargs):
        with patch_lnet(SplynxFake(**fake_kwargs)):
            result = LnetProvider(self.account).subscriber_profile("alhussainbasheir")
        self.assertTrue(result.ok)
        return result.profile

    def _local_day(self, stamp):
        return stamp.astimezone(lnet_module.business_timezone()).date().isoformat()

    def test_the_profile_shows_plan_price_start_and_cut_off(self):
        profile = self._profile(**self.LIVE)
        self.assertEqual(profile.package_name, "Unlimited Home Basic Plus")
        self.assertEqual(profile.price_per_month, Decimal("80.00"))
        self.assertEqual(self._local_day(profile.started_at), "2026-10-10")
        self.assertEqual(self._local_day(profile.expire_at), "2026-12-10")
        self.assertEqual(profile.card_balance, Decimal("12.50"))

    def test_the_plan_is_matched_by_number_not_by_price(self):
        # 71 is also 80.00; only the service's own tariff_id names the plan.
        profile = self._profile(
            services={"214737": [internet_service(tariff_id=71)]}, billing=self.LIVE["billing"]
        )
        self.assertEqual(profile.package_name, "Unlimited Home Basic Plus 1month")

    def test_a_plan_missing_from_the_list_stays_blank(self):
        profile = self._profile(services={"214737": [internet_service(tariff_id=999)]})
        self.assertEqual(profile.package_name, "")
        self.assertEqual(profile.price_per_month, Decimal("80.00"))

    def test_only_the_active_service_counts(self):
        stopped = internet_service(status="stopped", tariff_id=62, unit_price="45.0000")
        profile = self._profile(
            services={"214737": [stopped, internet_service()]}, billing=self.LIVE["billing"]
        )
        self.assertEqual(profile.package_name, "Unlimited Home Basic Plus")
        self.assertEqual(profile.price_per_month, Decimal("80.00"))

    def test_no_blocking_date_means_no_expiry(self):
        for blank in ("", "0000-00-00", None):
            with self.subTest(blocking_date=blank):
                profile = self._profile(
                    services=self.LIVE["services"],
                    billing={"214737": billing_info(blocking_date=blank)},
                )
                self.assertIsNone(profile.expire_at)
                self.assertEqual(profile.package_name, "Unlimited Home Basic Plus")

    def test_a_refused_detail_leaves_only_that_detail_blank(self):
        profile = self._profile(**self.LIVE, fail={"customer-tariffs": 403})
        self.assertEqual(profile.package_name, "")
        self.assertEqual(self._local_day(profile.expire_at), "2026-12-10")
        profile = self._profile(**self.LIVE, fail={"billing-info": 403})
        self.assertEqual(profile.package_name, "Unlimited Home Basic Plus")
        self.assertIsNone(profile.expire_at)

    def test_a_line_without_a_service_still_has_a_profile(self):
        profile = self._profile()
        self.assertEqual(profile.package_name, "")
        self.assertIsNone(profile.price_per_month)
        self.assertIsNone(profile.expire_at)
        self.assertEqual(profile.card_balance, Decimal("12.50"))

    def test_failed_reads_never_fail_the_profile(self):
        profile = self._profile(fail={"internet-services": 500, "billing-info": requests.ConnectionError})
        self.assertIsNone(profile.price_per_month)
        self.assertEqual(profile.card_balance, Decimal("12.50"))
