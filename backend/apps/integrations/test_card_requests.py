"""The till's requests panel and account book, against a faked relay."""

from __future__ import annotations

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.core.cache import cache
from django.test import TransactionTestCase, override_settings
from rest_framework.test import APIClient

from apps.core.relay import RelayControlError
from apps.core.roles import CASHIER_GROUP, ensure_role_groups
from apps.customers.models import Customer
from apps.sales.models import Order, RegisterSession

from . import recharge
from .models import IntegrationFulfillment, IntegrationSavedAccount
from .test_pointy import PointyMixin, card
from .test_voucher_accounts import AccountRelay, account_purchase, account_shelf, pubg

CHARGE = "/api/integrations/fulfillments/charge/"
REQUESTS = "/api/integrations/card-requests/"
SETTLE = "/api/integrations/card-requests/settle/"
BOOK = "/api/integrations/vouchers/saved-accounts/"


def pending_purchase(key="k"):
    return {**account_purchase(key), "status": "pending"}


class Harness(PointyMixin, TransactionTestCase):
    reset_sequences = True

    def setUp(self):
        cache.clear()
        ensure_role_groups()
        self.link_relay()
        self.relay = self.use_relay(AccountRelay())
        self.account = self.pointy_account()
        self.sync(self.account)
        self.user = self.cashier("till")
        self.register = RegisterSession.objects.create(owner=self.user, owner_key=f"user:{self.user.pk}")
        self.client = APIClient()
        self.client.force_authenticate(self.user)

    def cashier(self, name):
        user = get_user_model().objects.create_user(username=name, password="x")
        user.groups.add(Group.objects.get(name=CASHIER_GROUP))
        return user

    def sell(self, account=None, *, name="", customer=None, code="pubg-60"):
        body = {
            "register_session": self.register.pk,
            "payment_method": "cash",
            "lines": [
                {
                    "variant": self.voucher(code).variant_id,
                    "quantity": "1",
                    "integration": {
                        "provider": "pointy",
                        "subscriber_ref": "-",
                        "option_code": code,
                        "account_target": account or {"player_id": "5123456789"},
                        "account_name": name,
                    },
                }
            ],
        }
        if customer is not None:
            body["customer"] = customer.pk
        answer = self.client.post("/api/orders/checkout/", body, format="json")
        self.assertEqual(answer.status_code, 201, answer.data)
        return Order.objects.get(pk=answer.data["id"])

    def line_of(self, order):
        return order.lines.get().pk


@override_settings(POINTY_VOUCHER_ACCOUNT_CARDS=True)
class FollowingARequestTests(Harness):
    def charge_pending(self, order):
        self.relay.purchase = (202, {"purchase": pending_purchase(), "balance": "191.00", "replayed": False})
        return self.client.post(CHARGE, {"order": order.pk, "no_wait": True}, format="json").data["results"][0]

    def test_a_till_that_follows_the_order_asks_the_relay_not_to_wait(self):
        order = self.sell()
        result = self.charge_pending(order)
        self.assertEqual(self.relay.purchases_sent[0]["no_wait"], True)
        self.assertEqual(result["outcome"], recharge.OUTCOME_UNKNOWN)
        self.assertTrue(result["in_progress"])

    def test_an_older_till_is_answered_as_it_always_was(self):
        order = self.sell()
        self.relay.purchase = (202, {"purchase": pending_purchase(), "balance": "191.00", "replayed": False})
        self.client.post(CHARGE, {"order": order.pk}, format="json")
        self.assertNotIn("no_wait", self.relay.purchases_sent[0])

    def test_the_panel_follows_it_to_success(self):
        order = self.sell(name="Sniper")
        self.charge_pending(order)
        row = self.client.get(REQUESTS).data["results"][0]
        self.assertEqual(row["state"], "working")
        self.assertTrue(row["in_progress"])
        self.assertEqual(row["account"], "5123456789")
        self.assertEqual(row["account_name"], "Sniper")
        self.assertEqual(row["receipt_number"], order.receipt_number)
        key = self.relay.purchases_sent[0]["idempotency_key"]
        self.relay.outcomes[key] = {"purchase": pending_purchase(key), "balance": "191.00"}
        row = self.client.post(SETTLE, {"lines": [self.line_of(order)]}, format="json").data["results"][0]
        self.assertEqual(row["state"], "working")

        cache.clear()
        self.relay.outcomes[key] = {"purchase": account_purchase(key), "balance": "191.00"}
        row = self.client.post(SETTLE, {"lines": [self.line_of(order)]}, format="json").data["results"][0]
        self.assertEqual(row["state"], "succeeded")
        self.assertTrue(row["finished_at"])
        self.assertEqual(IntegrationFulfillment.objects.get().status, IntegrationFulfillment.Status.CONFIRMED)

    def test_a_failure_gives_the_money_back_at_once_and_says_how_much(self):
        order = self.sell()
        self.charge_pending(order)
        key = self.relay.purchases_sent[0]["idempotency_key"]
        failed = {**account_purchase(key), "status": "failed", "error_code": "out_of_stock"}
        self.relay.outcomes[key] = {"purchase": failed, "balance": "200.00"}
        row = self.client.post(SETTLE, {"lines": [self.line_of(order)]}, format="json").data["results"][0]
        self.assertEqual(row["state"], "failed")
        self.assertTrue(row["refunded"])
        self.assertEqual(row["refund_amount"], order.lines.get().line_total)
        self.assertEqual(row["amount"], order.lines.get().line_total)

    def test_a_relay_that_never_heard_of_it_is_not_closed_while_young(self):
        order = self.sell()
        self.charge_pending(order)
        row = self.client.post(SETTLE, {"lines": [self.line_of(order)]}, format="json").data["results"][0]
        self.assertEqual(row["state"], "working")

    def test_a_line_is_read_from_the_relay_once_however_many_tills_ask(self):
        order = self.sell()
        self.charge_pending(order)
        key = self.relay.purchases_sent[0]["idempotency_key"]
        self.relay.outcomes[key] = {"purchase": pending_purchase(key), "balance": "191.00"}
        for _ in range(3):
            self.client.post(SETTLE, {"lines": [self.line_of(order)]}, format="json")
        self.assertEqual(self.relay.outcome_reads.count(key), 1)

    def test_a_late_answer_does_not_undo_what_a_read_back_settled(self):
        order = self.sell()
        row = IntegrationFulfillment.objects.get()
        claimed = recharge._claim(row.pk)
        key = recharge.attempt_key(claimed)
        self.relay.outcomes[key] = {"purchase": account_purchase(key), "balance": "191.00"}
        self.client.post(SETTLE, {"lines": [self.line_of(order)]}, format="json")
        outcome = recharge._record(
            claimed,
            recharge.RechargeResult(ok=False, indeterminate=True, error_code="indeterminate"),
        )
        self.assertEqual(outcome.outcome, recharge.OUTCOME_CHARGED)
        row.refresh_from_db()
        self.assertEqual(row.status, IntegrationFulfillment.Status.CONFIRMED)

    def test_a_cashier_follows_only_their_own(self):
        order = self.sell()
        self.charge_pending(order)
        other = APIClient()
        other.force_authenticate(self.cashier("other"))
        self.assertEqual(other.get(REQUESTS).data["results"], [])
        answer = other.post(SETTLE, {"lines": [self.line_of(order)]}, format="json")
        self.assertEqual(answer.data["results"], [])

    def test_the_panel_never_shows_a_cashier_a_figure_from_a_refusal(self):
        order = self.sell()
        self.relay.purchase = RelayControlError(
            "no",
            status_code=402,
            body='{"code": "insufficient_balance", "balance": "3.00", "amount": "9.00"}',
        )
        self.client.post(CHARGE, {"order": order.pk, "no_wait": True}, format="json")
        row = self.client.get(REQUESTS).data["results"][0]
        self.assertEqual(row["state"], "failed")
        self.assertNotIn("3.00", row["error_detail"])
        self.assertTrue(row["refunded"])


@override_settings(POINTY_VOUCHER_ACCOUNT_CARDS=True)
class AccountBookTests(Harness):
    def test_the_sale_writes_the_book_and_a_repeat_is_one_row(self):
        self.sell(name="Sniper")
        self.sell(name="Sniper2")
        row = IntegrationSavedAccount.objects.get()
        self.assertEqual(row.ref, "5123456789")
        self.assertEqual(row.values, {"player_id": "5123456789"})
        self.assertEqual(row.player_name, "Sniper2")
        self.assertEqual(row.use_count, 2)

    def test_many_accounts_are_found_by_typing(self):
        self.sell({"player_id": "111"}, name="Alpha")
        self.sell({"player_id": "222"}, name="Beta")
        brand = IntegrationSavedAccount.objects.first().brand_code
        rows = self.client.get(BOOK, {"brand": brand}).data["results"]
        self.assertEqual([row["ref"] for row in rows], ["222", "111"])
        rows = self.client.get(BOOK, {"brand": brand, "search": "alp"}).data["results"]
        self.assertEqual([row["ref"] for row in rows], ["111"])
        rows = self.client.get(BOOK, {"brand": brand, "search": "11"}).data["results"]
        self.assertEqual([row["ref"] for row in rows], ["111"])

    def test_the_sales_customer_comes_first_and_is_found_by_name(self):
        ahmed = Customer.objects.create(full_name="أحمد", phone="0911111111")
        self.sell({"player_id": "111"}, customer=ahmed)
        self.sell({"player_id": "222"})
        brand = IntegrationSavedAccount.objects.first().brand_code
        rows = self.client.get(BOOK, {"brand": brand, "customer": ahmed.pk}).data["results"]
        self.assertEqual([row["ref"] for row in rows], ["111", "222"])
        self.assertEqual(rows[0]["customer_name"], "أحمد")
        rows = self.client.get(BOOK, {"brand": brand, "search": "أحمد"}).data["results"]
        self.assertEqual([row["ref"] for row in rows], ["111"])

    def test_naming_and_forgetting(self):
        self.sell()
        row = IntegrationSavedAccount.objects.get()
        answer = self.client.patch(f"{BOOK}{row.pk}/", {"label": "جار الدكان"}, format="json")
        self.assertEqual(answer.data["label"], "جار الدكان")
        self.sell()
        row.refresh_from_db()
        self.assertEqual(row.label, "جار الدكان")
        self.assertEqual(self.client.delete(f"{BOOK}{row.pk}/").status_code, 204)
        self.assertFalse(IntegrationSavedAccount.objects.exists())

    def test_a_brand_needs_naming(self):
        self.assertEqual(self.client.get(BOOK).status_code, 400)


@override_settings(POINTY_VOUCHER_ACCOUNT_CARDS=True)
class MenuTests(Harness):
    def test_only_a_till_that_asks_is_shown_what_needs_an_account(self):
        menu = self.client.get("/api/integrations/vouchers/menu/").data
        self.assertNotIn("pubg-topup", [brand["key"] for brand in menu["brands"]])
        menu = self.client.get("/api/integrations/vouchers/menu/", {"accounts": "1"}).data
        brand = next(brand for brand in menu["brands"] if brand["key"] == "pubg-topup")
        self.assertEqual(brand["target"]["kind"], "game_account")
        plain = next(brand for brand in menu["brands"] if brand["key"] != "pubg-topup")
        self.assertNotIn("target", plain)

    def test_a_till_that_asks_is_sent_each_cards_own_line_and_no_variants(self):
        menu = self.client.get("/api/integrations/vouchers/menu/", {"accounts": "1"}).data
        brand = next(brand for brand in menu["brands"] if brand["key"] == "pubg-topup")
        self.assertNotIn("variants", brand["product"])
        self.assertEqual(brand["product"]["system_kind"], "voucher")
        card = brand["items"][0]
        self.assertTrue(card["sku"])
        self.assertEqual(card["variant_id"], self.voucher("pubg-60").variant_id)

    def test_the_slim_menu_costs_the_same_queries_however_big_the_shelf(self):
        from django.db import connection
        from django.test.utils import CaptureQueriesContext

        with CaptureQueriesContext(connection) as small:
            self.client.get("/api/integrations/vouchers/menu/", {"accounts": "1"})
        self.relay.document = account_shelf(
            pubg(),
            *[pubg(key=f"game-{n}", items=[card(f"game-{n}-1", label="1", face="", currency="", cost="1.00", price="2.00")]) for n in range(8)],
        )
        self.sync(self.account)
        with CaptureQueriesContext(connection) as big:
            answer = self.client.get("/api/integrations/vouchers/menu/", {"accounts": "1"})
        self.assertGreater(len(answer.data["brands"]), 8)
        self.assertLessEqual(len(big), len(small) + 2)
