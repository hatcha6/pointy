"""What a provider charges the shop reaches the reporting roles only.

The owner's rule (2026-09-26): profit and cost are for managers, supervisors,
accountants and auditors (``user_has_full_visibility``). Top-ups broke it in
more ways than one — the till was handed every offer's and card's cost, the
open amount's commission ratio, the purchase log's cost, the subscriber's
lifetime agency spend, HD Box's own labels ("12 month 220.00$"), a cashier's
"paid but not performed" alert quoted the cost as what the customer paid, and a
cashier's own shift summary carried the provider's share and the margin.

The till now gets prices, a server-decided "the float cannot cover this" flag,
and — for HD Box, whose checkout used to trust the cost the till sent back — a
sealed quote it can carry but not read. The float balance itself stays visible:
the owner's call.
"""

from datetime import timedelta
from decimal import Decimal
from importlib import import_module
from unittest import mock

from django.apps import apps as django_apps
from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group, Permission
from django.test import TestCase, TransactionTestCase, override_settings
from django.urls import reverse
from django.utils import timezone
from rest_framework import serializers
from rest_framework.test import APIClient

from apps.ai.tools import query_resource
from apps.core.roles import (
    ACCOUNTANT_GROUP,
    CASHIER_GROUP,
    MANAGER_GROUP,
    ensure_role_groups,
)
from apps.notifications.services import sync_business_notifications
from apps.sales.models import Order, OrderLine, RegisterSession
from apps.sales.services import checkout_order

from . import quotes, recharge
from .fulfillment import resolve_line_integration
from .models import (
    IntegrationAccount,
    IntegrationFulfillment,
    IntegrationVoucher,
    IntegrationVoucherBrand,
)
from .providers.base import OpenAmount
from .provisioning import service_variant_for
from .serializers import open_amount_payload
from .test_qareeb import (
    LIBYANA_5,
    PSN,
    _FakeQareeb,
    _listing,
    _Resp,
    _StubDriver,
    buying,
    checkout_ok,
    logged_in,
    patch_qareeb,
    qareeb_account,
    sync,
)
from .tests import (
    AUTHED_PAGE,
    BUY_LOG,
    _FakeResponse,
    _FakeSession,
    hdbox_card_session,
    make_account,
    patch_session,
)

CARD = "210906803499"


def _user(username, group):
    user = get_user_model().objects.create_user(username=username, password="x")
    user.groups.add(Group.objects.get(name=group))
    return user


def _client(user):
    client = APIClient()
    client.force_authenticate(user)
    return client


class _Audiences(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.cashier = _user("costs-cashier", CASHIER_GROUP)
        self.accountant = _user("costs-accountant", ACCOUNTANT_GROUP)
        self.manager = _user("costs-manager", MANAGER_GROUP)


class TillCardCostTests(_Audiences):
    def setUp(self):
        super().setUp()
        self.account = make_account(
            markup_kind=IntegrationAccount.Markup.AMOUNT, markup_value=Decimal("5")
        )
        # Enough for a month, not for a year.
        self.account.balance = Decimal("100.00")
        self.account.save(update_fields=["balance"])

    def _card(self, user):
        with patch_session(hdbox_card_session()):
            response = _client(user).get(
                f"/api/integrations/hdbox/card/?card_no={CARD}"
            )
        self.assertEqual(response.status_code, 200)
        self.assertTrue(response.data["ok"], response.data)
        return response.data

    def test_a_cashier_is_told_prices_and_whether_the_float_covers_them(self):
        card = self._card(self.cashier)
        offers = {offer["code"]: offer for offer in card["offers"]}

        for offer in offers.values():
            self.assertNotIn("cost", offer)
            # HD Box writes its price into its wording; the till never sees it.
            self.assertNotIn("$", offer["label"])
            self.assertNotIn("220", offer["label"])
        self.assertEqual(offers["renew:12"]["label"], "12 month")
        # HD Box's recommended retail for a year.
        self.assertEqual(offers["renew:12"]["price"], Decimal("240.00"))
        self.assertTrue(offers["renew:12"]["exceeds_float"])
        self.assertFalse(offers["renew:1"]["exceeds_float"])
        # The float stays on the till: the owner's call.
        self.assertEqual(card["balance"], Decimal("100.00"))
        # HD Box's «Price/month» and «Total pay» are agency prices.
        self.assertNotIn("lifetime_spend", card["subscriber"])
        self.assertNotIn("price_per_month", card["subscriber"])
        self.assertEqual(card["subscriber"]["purchase_count"], 6)

    def test_the_reporting_roles_keep_the_cost(self):
        # An accountant does not work a till by role; one who was given it
        # still reads costs there, as they do everywhere else.
        self.accountant.user_permissions.add(
            Permission.objects.get(
                content_type__app_label="integrations", codename="use_integrations"
            )
        )
        # A fresh instance, so has_perm() does not read a stale cache.
        accountant = get_user_model().objects.get(pk=self.accountant.pk)
        for user in (self.manager, accountant):
            with self.subTest(user=user.username):
                card = self._card(user)
                offers = {offer["code"]: offer for offer in card["offers"]}
                self.assertEqual(offers["renew:12"]["cost"], Decimal("220.00"))
                self.assertEqual(offers["renew:12"]["label"], "12 month")
                self.assertEqual(
                    card["subscriber"]["lifetime_spend"], Decimal("750.00")
                )

    def test_the_quote_carries_the_cost_without_showing_it(self):
        offer = next(
            offer
            for offer in self._card(self.cashier)["offers"]
            if offer["code"] == "renew:12"
        )
        self.assertNotIn("220", offer["quote"])
        self.assertEqual(
            quotes.open_quote(
                offer["quote"],
                account=self.account,
                subscriber_ref=CARD,
                option_code="renew:12",
            ),
            Decimal("220.00"),
        )

    def test_a_cashier_reads_the_purchase_log_without_its_cost(self):
        def entries(user):
            session = _FakeSession(_FakeResponse(AUTHED_PAGE), [_FakeResponse(BUY_LOG)])
            with patch_session(session):
                response = _client(user).get(
                    f"/api/integrations/hdbox/history/?card_no={CARD}"
                )
            return response.data["entries"]

        for entry in entries(self.cashier):
            self.assertNotIn("cost", entry)
            self.assertIn("months", entry)
        self.assertEqual(entries(self.manager)[0]["cost"], Decimal("25.00"))

    def test_naming_a_card_answers_without_the_agency_figures(self):
        self._card(self.manager)  # the lookup that files the subscriber
        response = _client(self.cashier).put(
            f"/api/integrations/hdbox/subscribers/{CARD}/",
            {"display_name": "أحمد"},
            format="json",
        )
        self.assertEqual(response.status_code, 200, response.data)
        self.assertEqual(response.data["label"], "أحمد")
        self.assertNotIn("lifetime_spend", response.data)
        self.assertNotIn("price_per_month", response.data)


class OpenAmountRuleTests(TestCase):
    """The rule a till prices a typed amount with must not carry the
    commission — and with no markup, or a fixed one, its per-unit rate *is*
    the commission."""

    def setUp(self):
        self.spec = OpenAmount(
            minimum=Decimal("1"), maximum=Decimal("500"), cost_ratio=Decimal("0.95")
        )

    def _account(self, kind, value="0"):
        return IntegrationAccount(
            provider="lnet", markup_kind=kind, markup_value=Decimal(value)
        )

    def test_the_reporting_roles_get_the_rule_as_it_is(self):
        payload = open_amount_payload(
            self.spec, self._account(IntegrationAccount.Markup.NONE)
        )
        self.assertEqual(payload["cost_ratio"], Decimal("0.95"))
        self.assertEqual(payload["price_per_unit"], Decimal("0.95"))

    def test_a_rule_that_never_lifts_a_price_above_face_is_sent_as_face(self):
        for kind, value in (
            (IntegrationAccount.Markup.NONE, "0"),
            (IntegrationAccount.Markup.PERCENT, "3"),  # 0.95 × 1.03 < 1
        ):
            with self.subTest(kind=kind):
                payload = open_amount_payload(
                    self.spec, self._account(kind, value), with_cost=False
                )
                self.assertNotIn("cost_ratio", payload)
                self.assertEqual(payload["price_per_unit"], Decimal("1"))
                self.assertEqual(payload["price_fixed"], Decimal("0"))

    def test_a_rule_that_does_lift_prices_is_what_the_prices_show_anyway(self):
        # 0.95 × 1.10 = 1.045: every amount sells above face, so each price
        # the till shows already states this rate.
        payload = open_amount_payload(
            self.spec,
            self._account(IntegrationAccount.Markup.PERCENT, "10"),
            with_cost=False,
        )
        self.assertNotIn("cost_ratio", payload)
        self.assertEqual(payload["price_per_unit"], Decimal("1.045"))


class SealedQuoteCheckoutTests(_Audiences):
    """HD Box's checkout trusted the cost the till sent back. It now opens
    the sealed quote the lookup handed out, and a till without the cost in
    the clear still sells at it."""

    def setUp(self):
        super().setUp()
        self.account = make_account(
            markup_kind=IntegrationAccount.Markup.AMOUNT, markup_value=Decimal("5")
        )
        self.variant = service_variant_for("hdbox")
        self.register = RegisterSession.objects.create(
            owner=self.cashier, owner_key=f"user:{self.cashier.pk}"
        )

    def _checkout(self, integration):
        return _client(self.cashier).post(
            "/api/orders/checkout/",
            {
                "register_session": self.register.pk,
                "lines": [
                    {
                        "variant": self.variant.pk,
                        "quantity": "1",
                        "integration": {
                            "provider": "hdbox",
                            "subscriber_ref": CARD,
                            "option_code": "renew:12",
                            "option_label": "12 month",
                            "months": 12,
                            **integration,
                        },
                    }
                ],
                "payment_method": "cash",
            },
            format="json",
        )

    def test_a_cashier_sells_a_renewal_from_its_sealed_quote(self):
        with patch_session(hdbox_card_session()):
            card = _client(self.cashier).get(
                f"/api/integrations/hdbox/card/?card_no={CARD}"
            ).data
        offer = next(o for o in card["offers"] if o["code"] == "renew:12")

        response = self._checkout({"quote": offer["quote"]})

        self.assertEqual(response.status_code, 201, response.data)
        line = Order.objects.get(pk=response.data["id"]).lines.get()
        self.assertEqual(line.unit_cost, Decimal("220.00"))
        # Charged what the till showed.
        self.assertEqual(line.unit_price, offer["price"])
        self.assertEqual(line.integration_fulfillment.cost, Decimal("220.00"))
        # The sale answers the cashier the way every order does: no cost.
        self.assertNotIn("cost", response.data["lines"][0]["integration"])

    def test_a_quote_for_another_option_is_refused(self):
        other = quotes.seal_quote(self.account, CARD, "renew:1", Decimal("25.00"))
        response = self._checkout({"quote": other, "cost": "25.00"})
        self.assertEqual(response.status_code, 400, response.data)
        self.assertFalse(Order.objects.exists())

    def test_a_held_cart_from_before_sealed_quotes_still_sells(self):
        # Its line carries the cost in the clear, and a priced label.
        response = self._checkout(
            {"cost": "220.00", "option_label": "12 month 220.00$"}
        )
        self.assertEqual(response.status_code, 201, response.data)
        fulfillment = IntegrationFulfillment.objects.get()
        self.assertEqual(fulfillment.cost, Decimal("220.00"))
        self.assertEqual(fulfillment.option_label, "12 month")

    def test_a_line_with_neither_is_refused(self):
        with self.assertRaises(serializers.ValidationError):
            resolve_line_integration(
                {"provider": "hdbox", "subscriber_ref": CARD, "option_code": "renew:12"},
                self.variant,
            )


class VoucherPickerCostTests(_Audiences):
    def setUp(self):
        super().setUp()
        self.account = logged_in(qareeb_account())
        sync(self.account, _StubDriver(_listing(), {"115": PSN}))
        self.account.balance = Decimal("5.00")
        self.account.save(update_fields=["balance"])
        self.product = IntegrationVoucherBrand.objects.get(code="30").product

    def _cards(self, user):
        with mock.patch(
            "apps.integrations.vouchers.provider_for",
            return_value=_StubDriver(_listing()),
        ):
            response = _client(user).get(
                f"/api/integrations/vouchers/{self.product.pk}/"
            )
        self.assertTrue(response.data["ok"], response.data)
        return {card["code"]: card for card in response.data["cards"]}

    def test_the_picker_warns_without_the_cost(self):
        from .test_qareeb import LIBYANA_5, LIBYANA_10

        cards = self._cards(self.cashier)
        for card in cards.values():
            self.assertNotIn("cost", card)
        # 4.85 fits in a float of 5.00; 9.70 does not.
        self.assertFalse(cards[LIBYANA_5]["exceeds_float"])
        self.assertTrue(cards[LIBYANA_10]["exceeds_float"])

        owner = self._cards(self.manager)
        self.assertEqual(owner[LIBYANA_5]["cost"], Decimal("4.85"))


class UnperformedRechargeAlertTests(_Audiences):
    """The alert reaches the cashier who has to fix it, and says the customer
    paid its amount — which is the price, not the provider's cost."""

    def setUp(self):
        super().setUp()
        account = make_account()
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
            account=account,
            provider="hdbox",
            subscriber_ref=CARD,
            option_code="renew:12",
            option_label="12 month",
            cost=Decimal("220.00"),
        )
        IntegrationFulfillment.objects.filter(pk=row.pk).update(
            created_at=timezone.now() - timedelta(days=1)
        )
        sync_business_notifications()

    def test_the_cashier_is_told_what_the_customer_paid(self):
        response = _client(self.cashier).get("/api/business-notifications/")
        self.assertEqual(response.status_code, 200)
        rows = response.data["results"] if "results" in response.data else response.data
        alert = next(
            row for row in rows if row["code"] == "integrations.unperformed_recharge"
        )
        self.assertEqual(alert["payload"]["amount"], "240.00")
        self.assertNotIn("220.00", str(alert["payload"]))

        seen = query_resource(user=self.cashier, resource="business-notifications")
        self.assertTrue(seen["ok"], seen)
        self.assertNotIn("220.00", str(seen["data"]))


class ShiftSummaryCostTests(_Audiences):
    """The summary is cached shop-wide, so who reads it is decided after the
    cache — and one reader's view must never become another's."""

    def setUp(self):
        super().setUp()
        make_account(
            markup_kind=IntegrationAccount.Markup.AMOUNT, markup_value=Decimal("5")
        )
        self.session = RegisterSession.objects.create(
            owner=self.cashier, owner_key=f"user:{self.cashier.pk}"
        )
        resolved = resolve_line_integration(
            {
                "provider": "hdbox",
                "subscriber_ref": CARD,
                "option_code": "renew:1",
                "option_label": "1 month",
                "months": 1,
                "cost": Decimal("25.00"),
            },
            service_variant_for("hdbox"),
        )
        checkout_order(
            register_session=self.session,
            lines_data=[
                {
                    "variant": service_variant_for("hdbox"),
                    "quantity": Decimal("1"),
                    "effective_unit_price": resolved["price"],
                    "integration": resolved,
                }
            ],
            payments_data=[{"method": "cash", "amount": resolved["price"]}],
            request=None,
        )
        # Closed, so the summary is served from the shop-wide cache.
        RegisterSession.objects.filter(pk=self.session.pk).update(
            status=RegisterSession.Status.CLOSED
        )

    def _integrations(self, user):
        response = _client(user).get(
            reverse("register-session-summary", args=[self.session.pk])
        )
        self.assertEqual(response.status_code, 200, response.data)
        return response.data["integrations"]

    def assert_no_cost(self, payload):
        for figures in (*payload["providers"], payload["totals"]):
            self.assertNotIn("cost", figures)
            self.assertNotIn("margin", figures)
            for bucket in ("delivered", "awaiting", "unknown", "refunded"):
                self.assertNotIn("cost", figures[bucket])
                self.assertIn("amount", figures[bucket])
            self.assertNotIn("cost", figures["refunded_after_delivery"])
            self.assertIn("count", figures["refunded_after_delivery"])
        for row in payload["transactions"]:
            self.assertNotIn("cost", row)
            self.assertEqual(row["price"], "30.00")
        self.assertEqual(payload["totals"]["sold"], "30.00")

    def assert_cost(self, payload):
        self.assertEqual(payload["totals"]["cost"], "25.00")
        self.assertEqual(payload["totals"]["margin"], "5.00")
        self.assertEqual(payload["transactions"][0]["cost"], "25.00")

    @override_settings(
        POINTY_REGISTER_SUMMARY_CACHE_TTL=60,
        CACHES={
            "default": {
                "BACKEND": "django.core.cache.backends.locmem.LocMemCache",
                "LOCATION": "shift-summary-cost-tests",
            }
        },
    )
    def test_each_reader_gets_their_own_view_of_one_cached_summary(self):
        from django.core.cache import cache

        cache.clear()
        self.assert_no_cost(self._integrations(self.cashier))
        self.assert_cost(self._integrations(self.manager))
        self.assert_no_cost(self._integrations(self.cashier))
        self.assert_cost(self._integrations(self.accountant))


class HdBoxLabelMigrationTests(TestCase):
    """The top-ups sold before the driver learned to leave the price out."""

    def test_old_labels_lose_the_agency_price_and_nothing_else(self):
        hdbox = make_account()
        order = Order.objects.create()

        def row(provider, account, label):
            line = OrderLine.objects.create(
                order=order,
                variant=service_variant_for("hdbox"),
                quantity=Decimal("1"),
                unit_price=Decimal("1.00"),
            )
            return IntegrationFulfillment.objects.create(
                order_line=line,
                account=account,
                provider=provider,
                subscriber_ref=CARD,
                option_code="renew:12",
                option_label=label,
                cost=Decimal("1.00"),
            )

        priced = row("hdbox", hdbox, "12 month 220.00$")
        plain = row("hdbox", hdbox, "3 month")
        qareeb = logged_in(qareeb_account())
        voucher = row("qareeb", qareeb, "ليبيانا 10.00$")

        migration = import_module(
            "apps.integrations.migrations.0014_hdbox_labels_without_price"
        )
        migration.strip_prices(django_apps, None)

        for fulfillment in (priced, plain, voucher):
            fulfillment.refresh_from_db()
        self.assertEqual(priced.option_label, "12 month")
        self.assertEqual(plain.option_label, "3 month")
        # Another provider's words are its own.
        self.assertEqual(voucher.option_label, "ليبيانا 10.00$")


class VoucherInvoiceCostTests(TransactionTestCase):
    """A sold card's invoice keeps the provider's record of it from a cashier.

    Qareeb answers a checkout with each card's ``purchase_price`` — what the
    card cost the shop — and the fulfillment keeps that answer whole. The
    invoice already dropped the line's ``cost`` for a cashier, then handed the
    same figure over one key further down. A transaction test, because a charge
    refuses to run inside a transaction and a ``TestCase`` is one.
    """

    def setUp(self):
        ensure_role_groups()
        self.cashier = _user("card-cashier", CASHIER_GROUP)
        self.manager = _user("card-manager", MANAGER_GROUP)
        sync(logged_in(qareeb_account()), _StubDriver(_listing(), {"115": PSN}))
        till = _client(self.cashier)
        register = RegisterSession.objects.create(
            owner=self.cashier, owner_key=f"user:{self.cashier.pk}"
        )
        card = IntegrationVoucher.objects.get(code=LIBYANA_5)
        sold = till.post(
            "/api/orders/checkout/",
            {
                "register_session": register.pk,
                "lines": [{"variant": card.variant_id, "quantity": "1"}],
                "payment_method": "cash",
            },
            format="json",
        )
        self.assertEqual(sold.status_code, 201, sold.data)
        self.order_id = sold.data["id"]
        # The card cost the shop 4.85, and the provider's answer says so.
        answer = checkout_ok()
        answer["result"][0]["purchase_price"] = "4.850"
        with patch_qareeb(buying(_FakeQareeb(), checkout=_Resp(200, answer))):
            charged = till.post(
                "/api/integrations/fulfillments/charge/",
                {"order": self.order_id},
                format="json",
            )
        self.assertEqual(
            charged.data["results"][0]["outcome"],
            recharge.OUTCOME_CHARGED,
            charged.data,
        )

    def _invoice(self, user):
        response = _client(user).get(f"/api/orders/{self.order_id}/")
        self.assertEqual(response.status_code, 200, response.data)
        return response

    def test_a_cashier_reads_the_card_but_not_what_it_cost(self):
        response = self._invoice(self.cashier)
        integration = response.data["lines"][0]["integration"]

        self.assertNotIn("provider_receipt", integration)
        self.assertNotIn("cost", integration)
        self.assertNotIn("purchase_price", response.content.decode())
        # What the customer is handed is all still there.
        self.assertEqual(integration["status"], "confirmed")
        self.assertEqual(
            integration["provider_reference"], "dc94d6b1-6861-492e-9951-ee9314d56dac"
        )
        self.assertEqual(integration["receipt"]["code"], "1111222233334")
        self.assertEqual(integration["receipt"]["serial"], "123456789012345")

    def test_a_manager_reads_the_providers_record_with_its_price(self):
        integration = self._invoice(self.manager).data["lines"][0]["integration"]

        self.assertEqual(integration["provider_receipt"]["purchase_price"], "4.850")
        self.assertEqual(integration["cost"], Decimal("4.85"))
