"""Cards sent to an account (a game topped up by its player ID): the shop's side.

The relay is faked at the client, as in :mod:`.test_pointy`; the driver, the
mirror, the checkout and the charge run for real against it.
"""

from __future__ import annotations

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import SimpleTestCase, TestCase, TransactionTestCase, override_settings
from rest_framework import serializers
from rest_framework.test import APIClient

from apps.core.roles import CASHIER_GROUP, ensure_role_groups
from apps.printing.services import build_receipt_payload
from apps.sales.models import Order, RegisterSession

from . import recharge, voucher_accounts
from .models import IntegrationFulfillment, IntegrationVoucherBrand
from .providers.pointy import NOTICE_SENT_TO_ACCOUNT
from .test_pointy import FakeRelay, PointyMixin, card, itunes, libyana, purchase, shelf

PUBG_TARGET = {
    "kind": "game_account",
    "check": "pubg_mobile",
    "hint": "من الملف الشخصي داخل اللعبة",
    "fields": [{"key": "player_id", "label": "معرّف اللاعب"}],
}
ML_TARGET = {
    "kind": "game_account",
    "fields": [
        {"key": "user_id", "label": "معرّف المستخدم"},
        {
            "key": "server",
            "label": "الخادم",
            "type": "select",
            "options": [{"value": "1001", "label": "Asia"}, {"value": "2002", "label": "Europe"}],
        },
    ],
}
TELEGRAM_TARGET = {"kind": "telegram_username", "fields": [{"key": "username", "label": "اسم المستخدم"}]}


def pubg(**overrides):
    brand = {
        "key": "pubg-topup",
        "name": "ببجي موبايل",
        "aliases": ["PUBG"],
        "category": "game_topup",
        "rank": 2,
        "featured": False,
        "badge": "",
        "redeem_hint": "",
        "logo": "",
        "print_logo": "",
        "target": PUBG_TARGET,
        "items": [card("pubg-60", label="60 UC", face="", currency="", cost="9.00", price="11.00")],
    }
    brand.update(overrides)
    return brand


def account_shelf(*brands):
    document = shelf(brands=[itunes(), libyana(), *brands])
    document["categories"].append({"key": "game_topup", "name": "شحن الألعاب", "rank": 2})
    return document


def account_purchase(key="", *, target="51•••••789", test_mode=False):
    row = purchase(key, item="pubg-60", unit_price="9.00", codes=[], test_mode=test_mode)
    row.update(brand="pubg-topup", name="ببجي موبايل · 60 UC", delivery="account", target=target)
    return row


class AccountRelay(FakeRelay):
    """The fake relay, as a relay that knows cards sent to an account."""

    def __init__(self, document=None):
        super().__init__(document if document is not None else account_shelf(pubg()))
        self.accounts_asked = []
        self.checks = []
        self.check_answer = {"status": "valid", "name": "Sniper", "region": "", "account": "5123456789"}

    def get_voucher_catalog(self, *, access_token, etag="", timeout=None, fresh_brand="", accounts=False):
        self.accounts_asked.append(accounts)
        document = self.document
        if not accounts:
            # As the relay: a shop that does not ask is not shown them.
            document = dict(document, brands=[b for b in document["brands"] if not b.get("target")])
        self.etags_sent.append(etag)
        self.fresh_brands.append(fresh_brand)
        return document, self.etag() + ("" if accounts else "-c")

    def check_voucher_account(self, *, access_token, item, account, timeout=None):
        self.checks.append((item, dict(account)))
        if isinstance(self.check_answer, Exception):
            raise self.check_answer
        return self.check_answer


class ReadAccountTests(SimpleTestCase):
    def refused(self, target, values):
        with self.assertRaises(serializers.ValidationError) as caught:
            voucher_accounts.read_account(target, values)
        return caught.exception.detail

    def test_every_field_is_required_and_no_other_is_taken(self):
        self.assertIn("integration", self.refused(PUBG_TARGET, {}))
        self.assertIn("integration", self.refused(PUBG_TARGET, {"player_id": " "}))
        detail = self.refused(PUBG_TARGET, {"player_id": "5123", "zone": "1"})
        self.assertEqual(str(detail["account_field"]), "zone")
        self.assertEqual(
            voucher_accounts.read_account(PUBG_TARGET, {"player_id": " 5123456789 "}),
            {"player_id": "5123456789"},
        )

    def test_a_player_id_has_no_spaces_and_a_choice_is_one_of_its_options(self):
        self.assertEqual(str(self.refused(PUBG_TARGET, {"player_id": "51 23"})["account_field"]), "player_id")
        self.assertEqual(
            str(self.refused(ML_TARGET, {"user_id": "77", "server": "9999"})["account_field"]), "server"
        )
        account = voucher_accounts.read_account(ML_TARGET, {"user_id": "77", "server": "2002"})
        self.assertEqual(voucher_accounts.account_line(ML_TARGET, account), "77 · 2002")

    def test_a_telegram_username_loses_its_at_and_keeps_its_shape(self):
        self.refused(TELEGRAM_TARGET, {"username": "@bad name"})
        account = voucher_accounts.read_account(TELEGRAM_TARGET, {"username": "@daftar_ly"})
        self.assertEqual(account, {"username": "daftar_ly"})
        self.assertEqual(voucher_accounts.account_line(TELEGRAM_TARGET, account), "@daftar_ly")

    def test_a_steam_invite_link_is_read_as_the_relay_reads_it(self):
        target = {"kind": "steam_invite", "fields": [{"key": "invite_url", "label": "رابط الدعوة"}]}
        for typed in ("https://s.team/p/gkcp-mvn/CWQDTMJF", " s.team/p/GKCP-MVN/CWQDTMJF/ "):
            self.assertEqual(
                voucher_accounts.read_account(target, {"invite_url": typed}),
                {"invite_url": "https://s.team/p/gkcp-mvn/CWQDTMJF"},
            )
        for bad in ("gkcp-mvn", "https://steamcommunity.com/id/someone", "https://s.team.evil.com/p/gkcp-mvn/X"):
            self.assertEqual(str(self.refused(target, {"invite_url": bad})["account_field"]), "invite_url")


class AccountShelfTests(PointyMixin, TestCase):
    def setUp(self):
        self.link_relay()
        self.relay = self.use_relay(AccountRelay())
        self.account = self.pointy_account()

    @override_settings(POINTY_VOUCHER_ACCOUNT_CARDS=False)
    def test_the_till_is_not_given_account_cards_until_it_can_ask(self):
        self.sync(self.account)
        self.assertEqual(self.relay.accounts_asked, [False])
        self.assertFalse(IntegrationVoucherBrand.objects.filter(code="pubg-topup").exists())

    @override_settings(POINTY_VOUCHER_ACCOUNT_CARDS=True)
    def test_an_account_card_is_mirrored_with_what_the_buyer_types(self):
        self.sync(self.account)
        self.assertEqual(self.relay.accounts_asked, [True])
        brand = IntegrationVoucherBrand.objects.get(code="pubg-topup")
        self.assertEqual(brand.target["kind"], "game_account")
        self.assertEqual(brand.target["fields"], [{"key": "player_id", "label": "معرّف اللاعب", "type": "text"}])
        self.assertEqual(brand.target["check"], "pubg_mobile")
        self.assertEqual(IntegrationVoucherBrand.objects.get(code="itunes").target, {})

    @override_settings(POINTY_VOUCHER_ACCOUNT_CARDS=True)
    def test_a_target_this_build_cannot_read_is_never_sold_as_a_code(self):
        self.relay.document = account_shelf(pubg(target={"kind": "smart_meter", "fields": []}))
        self.sync(self.account)
        self.assertFalse(IntegrationVoucherBrand.objects.filter(code="pubg-topup").exists())
        self.assertTrue(IntegrationVoucherBrand.objects.filter(code="itunes").exists())


@override_settings(POINTY_VOUCHER_ACCOUNT_CARDS=True)
class AccountChargeTests(PointyMixin, TransactionTestCase):
    """Checkout, charge and slip of a card sent to an account."""

    reset_sequences = True

    def setUp(self):
        ensure_role_groups()
        self.link_relay()
        self.relay = self.use_relay(AccountRelay())
        self.account = self.pointy_account()
        self.sync(self.account)
        user = get_user_model().objects.create_user(username="till", password="x")
        user.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.register = RegisterSession.objects.create(owner=user, owner_key=f"user:{user.pk}")
        self.client = APIClient()
        self.client.force_authenticate(user)

    def checkout(self, code, account=None):
        line = {"variant": self.voucher(code).variant_id, "quantity": "1"}
        if account is not None:
            line["integration"] = {
                "provider": "pointy",
                "subscriber_ref": "-",
                "option_code": code,
                "account_target": account,
            }
        return self.client.post(
            "/api/orders/checkout/",
            {"register_session": self.register.pk, "payment_method": "cash", "lines": [line]},
            format="json",
        )

    def test_a_card_sent_to_an_account_needs_the_account(self):
        response = self.checkout("pubg-60")
        self.assertEqual(response.status_code, 400, response.data)
        response = self.checkout("pubg-60", {"player_id": "51 23"})
        self.assertEqual(response.status_code, 400, response.data)
        self.assertFalse(Order.objects.exists())

    def test_a_code_card_takes_no_account(self):
        response = self.checkout("itunes-us-10", {"player_id": "5123"})
        self.assertEqual(response.status_code, 400, response.data)

    def test_the_sale_sends_the_account_and_the_slip_says_whose_it_is(self):
        response = self.checkout("pubg-60", {"player_id": " 5123456789 "})
        self.assertEqual(response.status_code, 201, response.data)
        order = Order.objects.get(pk=response.data["id"])
        row = order.lines.get().integration_fulfillment
        self.assertEqual(row.account_target, {"player_id": "5123456789"})
        self.assertEqual(row.subscriber_ref, "5123456789")
        self.assertIsNone(row.subscriber)

        self.relay.purchase = (201, {"purchase": account_purchase(), "balance": "191.00", "replayed": False})
        result = self.client.post(
            "/api/integrations/fulfillments/charge/", {"order": order.pk}, format="json"
        ).data["results"][0]
        self.assertEqual(result["outcome"], recharge.OUTCOME_CHARGED, result)
        sent = self.relay.purchases_sent[0]
        self.assertEqual(sent["account"], {"player_id": "5123456789"})
        self.assertEqual(sent["item"], "pubg-60")
        row.refresh_from_db()
        self.assertEqual(row.status, IntegrationFulfillment.Status.CONFIRMED)
        printed = build_receipt_payload(order)["order"]["lines"][0]["integration"]["printed"]
        self.assertEqual(printed["account"], "51•••••789")
        self.assertEqual(printed["notice"], NOTICE_SENT_TO_ACCOUNT)
        self.assertNotIn("code", printed)

    def test_a_lost_answer_is_read_back_without_waiting_for_a_code(self):
        response = self.checkout("pubg-60", {"player_id": "5123456789"})
        order = Order.objects.get(pk=response.data["id"])
        from apps.core.relay import RelayControlError

        from .reconciliation import settle_relay_attempts

        self.relay.purchase = RelayControlError("timed out", request_sent=True)
        self.client.post("/api/integrations/fulfillments/charge/", {"order": order.pk}, format="json")
        row = IntegrationFulfillment.objects.get()
        key = self.relay.purchases_sent[0]["idempotency_key"]
        self.relay.outcomes[key] = {"purchase": account_purchase(key), "balance": "191.00"}
        settle_relay_attempts()
        row.refresh_from_db()
        self.assertEqual(row.status, IntegrationFulfillment.Status.CONFIRMED)
        self.assertEqual(row.provider_receipt["delivery"], "account")

    def test_the_till_checks_the_account_before_selling(self):
        variant_id = self.voucher("pubg-60").variant_id
        url = "/api/integrations/vouchers/check-account/"
        answer = self.client.post(url, {"variant_id": variant_id, "account": {"player_id": "5123456789"}}, format="json")
        self.assertEqual(answer.status_code, 200)
        self.assertEqual(answer.data, {"ok": True, "status": "valid", "name": "Sniper", "region": "", "account": "5123456789"})
        self.assertEqual(self.relay.checks, [("pubg-60", {"player_id": "5123456789"})])

        refused = self.client.post(url, {"variant_id": variant_id, "account": {"player_id": "51 23"}}, format="json").data
        self.assertEqual((refused["ok"], refused["error_code"], refused["field"]), (False, "invalid_account", "player_id"))
        self.assertTrue(refused["detail"])
        empty = self.client.post(url, {"variant_id": variant_id, "account": {"player_id": ""}}, format="json").data
        self.assertEqual((empty["ok"], empty["error_code"]), (False, "invalid_account"))
        code_card = self.client.post(
            url, {"variant_id": self.voucher("itunes-us-10").variant_id, "account": {"player_id": "1"}}, format="json"
        ).data
        self.assertEqual(code_card["error_code"], "not_an_account_card")
        self.assertEqual(len(self.relay.checks), 1)
