"""«الشحن المباشر» and «دفع الفواتير»: from the quote to the slip.

A top-up or a bill is a service line whose price is the relay's, sealed in a
quote; checkout opens the seal and believes nothing else. The charge then goes
through the same at-most-once guard as a card, to the relay's service orders, and
what the customer is handed is a slip composed in Arabic on the shop's side.
"""

from __future__ import annotations

from datetime import timedelta
from decimal import Decimal
from unittest import mock

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.db import connection
from django.test import TestCase, TransactionTestCase, override_settings
from django.test.utils import CaptureQueriesContext
from django.utils import timezone
from django.utils.dateparse import parse_datetime
from rest_framework.exceptions import ValidationError
from rest_framework.test import APIClient

from apps.catalog.models import Product
from apps.catalog.testing import create_product_with_default_variant
from apps.core.models import RelayInstallation, ShopSettings
from apps.core.relay import RelayControlError
from apps.core.roles import CASHIER_GROUP, MANAGER_GROUP, ensure_role_groups
from apps.discounts.models import DiscountRule
from apps.notifications.services import _integration_notifications
from apps.printing.services import build_receipt_payload
from apps.sales.models import Order, RegisterSession
from apps.sales.serializers import CheckoutLineSerializer
from apps.sales.services import checkout_order, return_order_items, void_order

from . import float_ledger, quotes, recharge, services_mirror
from .fulfillment import fulfillment_kind
from .models import (
    IntegrationAccount,
    IntegrationFulfillment,
    IntegrationServiceCountry,
    IntegrationSubscriber,
)
from .providers.base import (
    ERROR_INDETERMINATE,
    ERROR_INSUFFICIENT_FLOAT,
    ERROR_NOT_FOUND,
    ERROR_OUT_OF_STOCK,
    ERROR_PRICE_CHANGED,
    ERROR_PROVIDER_ERROR,
    ERROR_UNAVAILABLE,
    ERROR_UNEXPECTED,
    ERROR_UNREACHABLE,
)
from .providers.pointy import PointyProvider
from .provisioning import service_variant_for
from .reconciliation import ATTEMPT_SETTLE_AFTER, reconcile_account, settle_relay_attempts
from .test_pointy import purchase, refusal
from .test_services import (
    AIRTIME_RECEIPT,
    BILL_RECEIPT,
    ServicesMixin,
    country,
    failed_purchase,
    mali,
    niger,
    nigeria,
    operator,
    relay_quote,
    senegal,
    service_purchase,
    services_directory,
)

AIRTIME_SLIP = {
    "title": "شحن مباشر",
    "rows": [
        ["الشبكة", "أورنج مالي"],
        ["الرقم", "+223 70123456"],
        ["المبلغ المرسل", "5,000 فرنك أفريقي"],
        ["رقم العملية", "4602843"],
    ],
    "pin": "",
    "pin_label": "رمز الشحن",
    "notice": "تم إرسال الرصيد إلى الرقم المذكور، ولا يمكن استرداده.",
}
ELECTRICITY_SLIP = {
    "title": "دفع فاتورة كهرباء",
    "rows": [
        ["الجهة", "كهرباء إيكيجا (مسبقة الدفع)"],
        ["النوع", "كهرباء"],
        ["رقم العدّاد", "04223568280"],
        ["المبلغ", "5,000 نيرة نيجيرية"],
        ["الوحدات", "10.7 kWh"],
        ["رقم العملية", "36"],
    ],
    "pin": "2737-6032-5315-7183-0856",
    "pin_label": "رمز الشحن",
    "notice": "أدخل رمز الشحن في العدّاد.",
}
INVOICE_RECEIPT = {
    "transaction_id": "88",
    "biller": "Sen-Eau",
    "account": "77123456",
    "amount": "15000",
    "currency": "XOF",
}


class ServicesSaleMixin(ServicesMixin):
    """A cashier at an open register, a shop linked to the relay with 1,000 dinars
    in its voucher balance, and the directory (and the shelf) mirrored."""

    def setUp(self):
        ensure_role_groups()
        self.link_relay()
        self.relay = self.services_relay()
        self.account = self.pointy_account(balance=Decimal("1000.00"), balance_at=timezone.now())
        self.sync(self.account)
        self.sync_services()
        User = get_user_model()
        cashier = User.objects.create_user(username="till", password="x")
        cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))
        manager = User.objects.create_user(username="mgr", password="x")
        manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.register = RegisterSession.objects.create(
            owner=cashier, owner_key=f"user:{cashier.pk}"
        )
        self.client = APIClient()
        self.client.force_authenticate(cashier)
        self.reader = APIClient()
        self.reader.force_authenticate(manager)

    # --- what the till does ---------------------------------------------------------
    def quoted(self, **body):
        """The quote the till is handed for a top-up of 5,000 francs to a Malian number
        — or, for ``kind="bill"``, for a Nigerian electricity meter."""
        if body.get("kind", "airtime") == "airtime":
            request = {
                "kind": "airtime",
                "country": "ML",
                "operator_id": 289,
                "phone": "70123456",
                "amount": "5000",
                "amount_currency": "XOF",
            }
        else:
            request = {
                "kind": "bill",
                "country": "NG",
                "biller_id": 5,
                "account": "04223568280",
                "amount": "5000",
                "amount_currency": "NGN",
            }
        request.update(body)
        response = self.client.post("/api/integrations/services/quote/", request, format="json")
        self.assertEqual(response.status_code, 200, response.data)
        self.assertTrue(response.data["ok"], response.data)
        return response.data

    def bill_quoted(self, *, cost="26.00", retail="27.50", **body):
        self.relay.quote_answer = relay_quote(
            kind="bill", cost=cost, retail=retail, amount="5000", currency="NGN"
        )
        return self.quoted(kind="bill", **body)

    @staticmethod
    def line(quote, **changes):
        """The cart line a till builds from a quote — and nothing more."""
        integration = {
            "provider": "pointy",
            "subscriber_ref": quote["subscriber_ref"],
            "option_code": quote["option_code"],
            "option_label": quote["option_label"],
            "quote": quote["quote"],
        }
        integration.update(changes.pop("integration", {}))
        return {
            "variant": changes.pop("variant", quote["service_variant_id"]),
            "quantity": "1",
            "integration": integration,
            **changes,
        }

    def checkout(self, *lines, **extra):
        body = {
            "register_session": self.register.pk,
            "payment_method": "cash",
            "lines": list(lines),
            **extra,
        }
        return self.client.post("/api/orders/checkout/", body, format="json")

    def sell(self, quote):
        response = self.checkout(self.line(quote))
        self.assertEqual(response.status_code, 201, response.data)
        return Order.objects.get(pk=response.data["id"])

    def charge(self, order):
        response = self.client.post(
            "/api/integrations/fulfillments/charge/", {"order": order.pk}, format="json"
        )
        self.assertEqual(response.status_code, 200, response.data)
        return response.data

    def row(self, order):
        return order.lines.get().integration_fulfillment

    def voucher(self, code):
        from .models import IntegrationVoucher

        return IntegrationVoucher.objects.select_related("variant").get(code=code)

    def slip_on_both_routes(self, order):
        """The slip as the thermal receipt and the invoice each carry it."""
        thermal = build_receipt_payload(order)["order"]["lines"][0]["integration"]
        document = self.reader.get(f"/api/orders/{order.pk}/").data["lines"][0]["integration"]
        self.assertEqual(thermal["printed"], document["receipt"])
        return thermal, document


# --- checkout ----------------------------------------------------------------------------------------
class ServicesCheckoutTests(ServicesSaleMixin, TestCase):
    def test_an_airtime_line_is_sold_at_the_quoted_price_and_costs_what_the_relay_said(self):
        quote = self.quoted()
        order = self.sell(quote)
        line = order.lines.get()
        self.assertEqual((line.unit_price, line.unit_cost), (Decimal("96.50"), Decimal("91.30")))
        self.assertEqual(order.total, Decimal("96.50"))
        self.assertEqual(line.variant_id, quote["service_variant_id"])
        row = line.integration_fulfillment
        self.assertEqual(
            (
                row.provider,
                row.subscriber_ref,
                row.option_code,
                row.option_label,
                row.months,
                row.cost,
                row.status,
            ),
            (
                "pointy",
                "+22370123456",
                "air:289:5000:XOF",
                "أورنج مالي · 5,000 فرنك أفريقي",
                0,
                Decimal("91.30"),
                IntegrationFulfillment.Status.PENDING,
            ),
        )
        # Where it went, in the shop's words: what the recents and the invoice read.
        self.assertEqual((row.package_id, row.package_name), ("ML", "أورنج مالي"))
        self.assertEqual(fulfillment_kind(row), "airtime")
        self.assertEqual(row.subscriber.subscriber_ref, "+22370123456")
        self.assertEqual(self.relay.orders, [], "nothing is sent until the invoice is paid")

    def test_a_bill_line_is_the_same_thing_for_a_biller(self):
        quote = self.bill_quoted()
        order = self.sell(quote)
        line = order.lines.get()
        self.assertEqual((line.unit_price, line.unit_cost), (Decimal("27.50"), Decimal("26.00")))
        row = line.integration_fulfillment
        self.assertEqual(
            (row.subscriber_ref, row.option_code, row.package_id, row.package_name),
            ("04223568280", "bill:5:5000:NGN", "NG", "كهرباء إيكيجا (مسبقة الدفع)"),
        )
        self.assertEqual(fulfillment_kind(row), "bill")
        self.assertEqual(line.variant.sku, "INTEG-POINTY-BILL")

    def test_an_invoice_travels_in_the_option_code(self):
        self.relay.quote_answer = relay_quote(
            kind="bill", cost="270.00", retail="285.00", amount="15000", currency="XOF"
        )
        quote = self.quoted(
            kind="bill",
            country="SN",
            biller_id=24,
            account="77123456",
            amount="15000",
            amount_currency="XOF",
            invoice_id="2024-118833",
        )
        row = self.row(self.sell(quote))
        self.assertEqual(row.option_code, "bill:24:15000:XOF::2024-118833")
        self.assertEqual(fulfillment_kind(row), "bill")

    def test_a_cart_can_hold_both_kinds_and_cards_beside_them(self):
        top_up = self.quoted()
        bill = self.bill_quoted()
        card = self.voucher("itunes-us-10")
        response = self.checkout(
            self.line(top_up), self.line(bill), {"variant": card.variant_id, "quantity": "1"}
        )
        self.assertEqual(response.status_code, 201, response.data)
        order = Order.objects.get(pk=response.data["id"])
        self.assertEqual(order.total, Decimal("96.50") + Decimal("27.50") + Decimal("60.00"))
        kinds = sorted(fulfillment_kind(line.integration_fulfillment) for line in order.lines.all())
        self.assertEqual(kinds, ["airtime", "bill", "voucher"])

    def test_the_till_can_change_nothing_that_matters(self):
        quote = self.quoted()
        other_amount = self.quoted(amount="2500")
        cases = {
            "another amount": self.line(
                quote, integration={"option_code": other_amount["option_code"]}
            ),
            "another number": self.line(quote, integration={"subscriber_ref": "+22370123457"}),
            "another network": self.line(quote, integration={"option_code": "air:290:5000:XOF"}),
            "a quote for another amount": self.line(
                quote, integration={"quote": other_amount["quote"]}
            ),
            "no quote": self.line(quote, integration={"quote": ""}),
            "a made-up quote": self.line(quote, integration={"quote": "gAAAAA-not-a-token"}),
            "an edited quote": self.line(
                quote, integration={"quote": quote["quote"][:-6] + "AAAAAA"}
            ),
            "a bill's option on a top-up": self.line(
                quote, integration={"option_code": "bill:5:5000:NGN"}
            ),
            "a malformed option": self.line(
                quote, integration={"option_code": "air:289:5000.0:XOF"}
            ),
            "a card's option": self.line(quote, integration={"option_code": "itunes-us-10"}),
            "a bill's product for a top-up": self.line(quote, variant=self.service_variant("bill")),
            "the other provider's product": self.line(quote, variant=self.other_service_variant()),
            "another provider": self.line(quote, integration={"provider": "hdbox"}),
            "no provider": self.line(quote, integration={"provider": ""}),
        }
        for name, line in cases.items():
            with self.subTest(name):
                response = self.checkout(line)
                self.assertEqual(response.status_code, 400, response.data)
        self.assertFalse(Order.objects.exists())
        self.assertFalse(IntegrationFulfillment.objects.exists())

    def test_a_number_that_is_not_one_cannot_be_sold_even_with_a_genuine_seal(self):
        quote = self.quoted()
        for ref in ("0701234", "22370123456", "+223 70123456", "+22"):
            with self.subTest(ref=ref):
                token = quotes.seal_quote(
                    self.account, ref, quote["option_code"], Decimal("91.30"), Decimal("96.50")
                )
                line = self.line(quote, integration={"subscriber_ref": ref, "quote": token})
                self.assertEqual(self.checkout(line).status_code, 400)
        # And a phone number is no account.
        token = quotes.seal_quote(
            self.account, "+22370123456", "bill:5:5000:NGN", Decimal("91.30"), Decimal("96.50")
        )
        line = self.line(
            quote,
            variant=self.service_variant("bill"),
            integration={"option_code": "bill:5:5000:NGN", "quote": token},
        )
        self.assertEqual(self.checkout(line).status_code, 400)

    def test_a_quote_with_no_price_in_it_is_no_quote_for_a_service(self):
        quote = self.quoted()
        old = quotes.seal_quote(
            self.account, quote["subscriber_ref"], quote["option_code"], Decimal("1.00")
        )
        response = self.checkout(self.line(quote, integration={"quote": old}))
        self.assertEqual(response.status_code, 400)

    def test_the_price_in_the_token_is_the_only_price(self):
        quote = self.quoted()
        line = self.line(
            quote,
            integration={
                "cost": "1.00",
                "price": "1.00",
                "unit_price": "1.00",
                "option_label": "مجاني",
            },
            unit_price="1.00",
        )
        response = self.checkout(line)
        self.assertEqual(response.status_code, 400, "repricing a line needs the right to")
        line.pop("unit_price")
        response = self.checkout(line)
        self.assertEqual(response.status_code, 201, response.data)
        order = Order.objects.get(pk=response.data["id"])
        # The payload's own figures are not read at all, and nor are its words:
        # what the line is called is what the quote said it was.
        self.assertEqual(order.lines.get().unit_price, Decimal("96.50"))
        row = self.row(order)
        self.assertEqual(row.cost, Decimal("91.30"))
        self.assertEqual(row.option_label, "أورنج مالي · 5,000 فرنك أفريقي")

    def test_a_token_without_words_of_its_own_takes_the_tills_trimmed(self):
        quote = self.quoted()
        bare = quotes.seal_quote(
            self.account,
            quote["subscriber_ref"],
            quote["option_code"],
            Decimal("91.30"),
            Decimal("96.50"),
        )
        label = "  أورنج \n مالي  " + "ا" * 100
        order = self.sell({**quote, "quote": bare, "option_label": label})
        row = self.row(order)
        self.assertTrue(row.option_label.startswith("أورنج مالي ا"))
        self.assertNotIn("\n", row.option_label)
        self.assertEqual((row.package_id, row.package_name), ("", ""))
        order = self.sell({**quote, "quote": bare, "option_label": ""})
        self.assertEqual(self.row(order).option_label, quote["option_code"])

    def test_a_service_line_without_its_details_is_refused(self):
        quote = self.quoted()
        response = self.checkout({"variant": quote["service_variant_id"], "quantity": "1"})
        self.assertEqual(response.status_code, 400)

    def test_a_provider_that_cannot_sell_refuses_a_cart_built_before(self):
        quote = self.quoted()
        RelayInstallation.objects.update(integrations_disabled=["pointy"])
        self.assertEqual(self.checkout(self.line(quote)).status_code, 400)
        RelayInstallation.objects.update(integrations_disabled=[])
        IntegrationAccount.objects.filter(pk=self.account.pk).update(is_active=False)
        self.assertEqual(self.checkout(self.line(quote)).status_code, 400)
        IntegrationAccount.objects.filter(pk=self.account.pk).update(is_active=True)
        RelayInstallation.objects.all().delete()
        self.assertEqual(self.checkout(self.line(quote)).status_code, 400)
        self.assertFalse(Order.objects.exists())

    def test_the_discount_preview_prices_a_service_and_writes_nothing(self):
        quote = self.quoted()
        response = self.client.post(
            "/api/orders/discount-preview/", {"lines": [self.line(quote)]}, format="json"
        )
        self.assertEqual(response.status_code, 200, response.data)
        self.assertEqual((response.data["subtotal"], response.data["total"]), ("96.50", "96.50"))
        self.assertFalse(IntegrationFulfillment.objects.exists())
        self.assertFalse(IntegrationSubscriber.objects.exists())

    def test_pricing_a_cart_edit_costs_no_query_per_service_line(self):
        quote = self.quoted()
        preview = lambda *lines: self.client.post(  # noqa: E731
            "/api/orders/discount-preview/", {"lines": list(lines)}, format="json"
        )
        preview(self.line(quote))
        with CaptureQueriesContext(connection) as one:
            preview(self.line(quote))
        with CaptureQueriesContext(connection) as three:
            preview(self.line(quote), self.line(quote), self.line(quote))
        # The account, the relay link and the off switch are read once per line
        # (cached in production); the directory — a mirror of hundreds of
        # operators — is not read at all while a cart is priced.
        per_line = (len(three.captured_queries) - len(one.captured_queries)) / 2
        self.assertLessEqual(per_line, 8)
        self.assertFalse(
            [
                q
                for q in three.captured_queries
                if "integrations_integrationservicecountry" in q["sql"]
            ]
        )

    def test_a_credit_sale_carries_a_service_like_any_other(self):
        from apps.customers.models import Customer

        customer = Customer.objects.create(full_name="زبون")
        response = self.checkout(self.line(self.quoted()), customer=customer.pk, sale_type="credit")
        self.assertEqual(response.status_code, 201, response.data)
        order = Order.objects.get(pk=response.data["id"])
        self.assertEqual(order.sale_type, Order.SaleType.CREDIT)
        self.assertEqual(fulfillment_kind(self.row(order)), "airtime")

    # --- helpers ---------------------------------------------------------------------------
    def voucher(self, code):
        from .models import IntegrationVoucher

        return IntegrationVoucher.objects.select_related("variant").get(code=code)

    @staticmethod
    def service_variant(kind):
        return service_variant_for("pointy", kind).pk

    @staticmethod
    def other_service_variant():
        return service_variant_for("hdbox").pk


class ServicesRecentTests(ServicesSaleMixin, TestCase):
    def sold(self, phone, *, amount="5000", status=IntegrationFulfillment.Status.CONFIRMED):
        quote = self.quoted(phone=phone, amount=amount)
        row = self.row(self.sell(quote))
        IntegrationFulfillment.objects.filter(pk=row.pk).update(status=status)
        return row

    def recent(self, kind="airtime"):
        response = self.client.get(f"/api/integrations/services/recent/?kind={kind}")
        self.assertEqual(response.status_code, 200)
        return response.data

    def test_nothing_sold_nothing_recent(self):
        self.assertEqual(self.recent(), {"kind": "airtime", "recent": []})

    def test_the_last_numbers_come_back_newest_first_one_line_each(self):
        first = self.sold("70123456")
        self.sold("70999999", amount="2500")
        self.sold("70123456", amount="2500")
        for index, row in enumerate(IntegrationFulfillment.objects.order_by("pk")):
            IntegrationFulfillment.objects.filter(pk=row.pk).update(
                created_at=timezone.now() - timedelta(hours=10 - index)
            )
        recent = self.recent()["recent"]
        self.assertEqual([entry["phone"] for entry in recent], ["+22370123456", "+22370999999"])
        newest = recent[0]
        self.assertEqual(
            {key: newest[key] for key in newest if key != "at"},
            {
                "phone": "+22370123456",
                "country": "ML",
                "operator_id": 289,
                "operator_name": "أورنج مالي",
                "amount": "2500",
                "currency": "XOF",
            },
        )
        self.assertIsNotNone(parse_datetime(newest["at"]))
        self.assertIsNotNone(first)

    def test_only_what_was_really_sent_is_recent(self):
        self.sold("70123456", status=IntegrationFulfillment.Status.PENDING)
        self.sold("70123457", status=IntegrationFulfillment.Status.SUBMITTED)
        self.sold("70123458", status=IntegrationFulfillment.Status.FAILED)
        self.sold("70123459", status=IntegrationFulfillment.Status.CANCELLED)
        self.assertEqual(self.recent()["recent"], [])
        self.sold("70123460")
        self.assertEqual([e["phone"] for e in self.recent()["recent"]], ["+22370123460"])

    def test_twelve_at_most(self):
        for index in range(15):
            self.sold(f"7012{index:04d}")
        self.assertEqual(len(self.recent()["recent"]), 12)

    def test_bills_are_not_recipients_for_now(self):
        self.relay.quote_answer = relay_quote(
            kind="bill", cost="26.00", retail="27.50", amount="5000", currency="NGN"
        )
        row = self.row(self.sell(self.quoted(kind="bill")))
        IntegrationFulfillment.objects.filter(pk=row.pk).update(
            status=IntegrationFulfillment.Status.CONFIRMED
        )
        self.assertEqual(self.recent("bill"), {"kind": "bill", "recent": []})
        self.assertEqual(self.recent()["recent"], [])
        self.assertEqual(self.recent("anything")["recent"], [])

    def test_a_switched_off_shop_remembers_nobody(self):
        self.sold("70123456")
        RelayInstallation.objects.update(integrations_disabled=["pointy"])
        self.assertEqual(self.recent()["recent"], [])


# --- performing it -----------------------------------------------------------------------------------------
class ServicesChargeTests(ServicesSaleMixin, TransactionTestCase):
    """The till's charge, end to end: checkout, order, slip."""

    reset_sequences = True

    def order_for(self, quote):
        return self.sell(quote)

    def test_a_top_up_is_sent_once_with_its_key_and_ceiling_and_the_slip_is_in_arabic(self):
        order = self.sell(self.quoted())
        row = self.row(order)
        self.relay.order = (
            201,
            {
                "purchase": service_purchase(unit_price="91.30"),
                "balance": "908.70",
                "replayed": False,
            },
        )
        result = self.charge(order)["results"][0]
        self.assertEqual(
            (result["outcome"], result["kind"], result["status"], result["error_code"]),
            (recharge.OUTCOME_CHARGED, "airtime", "confirmed", ""),
        )
        self.assertEqual(result["subscriber_ref"], "+22370123456")
        self.assertEqual(result["provider_reference"], "svc-1")
        self.assertEqual(result["receipt"], AIRTIME_SLIP)
        row.refresh_from_db()
        # The order the relay got: one, with the key of this attempt, the country
        # the shop looked up, the number as E.164 and, as the most it may charge,
        # what the customer pays (the relay's price moves; the sale must not fail
        # for a move the customer's price still covers).
        self.assertEqual(
            self.relay.orders,
            [
                {
                    "kind": "airtime",
                    "country": "ML",
                    "amount": "5000",
                    "amount_currency": "XOF",
                    "idempotency_key": recharge.attempt_key(row),
                    "max_unit_price": "96.50",
                    "operator_id": 289,
                    "phone": "+22370123456",
                }
            ],
        )
        self.assertEqual(row.status, IntegrationFulfillment.Status.CONFIRMED)
        self.assertEqual(row.provider_receipt["kind"], "airtime")
        self.assertEqual(row.provider_receipt["purchase_id"], "svc-1")
        self.assertEqual(row.provider_receipt["unit_price"], "91.30")
        self.assertEqual(row.provider_receipt["transaction_id"], "4602843")
        self.assertEqual(row.provider_receipt["printed"], AIRTIME_SLIP)
        self.account.refresh_from_db()
        self.assertEqual(self.account.balance, Decimal("908.70"))
        # A second charge of the same line sends nothing.
        again = self.charge(order)
        self.assertEqual(again["results"], [])
        self.assertEqual(len(self.relay.orders), 1)

    def test_the_relay_charging_less_than_the_quote_corrects_the_cost(self):
        order = self.sell(self.quoted())
        self.relay.order = (
            201,
            {"purchase": service_purchase(unit_price="90.00"), "balance": "910.00"},
        )
        self.charge(order)
        row = self.row(order)
        row.refresh_from_db()
        self.assertEqual(row.cost, Decimal("90.00"))
        self.assertEqual(row.order_line.unit_cost, Decimal("90.00"))
        self.assertEqual(row.order_line.unit_price, Decimal("96.50"), "the customer's price stands")

    def test_a_bill_prints_its_token_as_the_pin(self):
        order = self.sell(self.bill_quoted())
        self.relay.order = (
            201,
            {"purchase": service_purchase(kind="bill", unit_price="26.00"), "balance": "974.00"},
        )
        result = self.charge(order)["results"][0]
        self.assertEqual((result["outcome"], result["kind"]), (recharge.OUTCOME_CHARGED, "bill"))
        self.assertEqual(result["receipt"], ELECTRICITY_SLIP)
        row = self.row(order)
        row.refresh_from_db()
        self.assertEqual(
            self.relay.orders[0],
            {
                "kind": "bill",
                "country": "NG",
                "amount": "5000",
                "amount_currency": "NGN",
                "idempotency_key": recharge.attempt_key(row),
                "max_unit_price": "27.50",
                "biller_id": 5,
                "account": "04223568280",
                "invoice_id": None,
                "amount_id": None,
            },
        )

    def test_a_bill_with_an_invoice_sends_it_and_prints_it(self):
        self.relay.quote_answer = relay_quote(
            kind="bill", cost="270.00", retail="285.00", amount="15000", currency="XOF"
        )
        quote = self.quoted(
            kind="bill",
            country="SN",
            biller_id=24,
            account="77123456",
            amount="15000",
            amount_currency="XOF",
            invoice_id="2024-118833",
        )
        order = self.sell(quote)
        self.relay.order = (
            201,
            {
                "purchase": service_purchase(
                    kind="bill",
                    item="bill:24:15000:XOF",
                    unit_price="270.00",
                    receipt=INVOICE_RECEIPT,
                ),
                "balance": "730.00",
            },
        )
        result = self.charge(order)["results"][0]
        self.assertEqual(
            result["receipt"],
            {
                "title": "دفع فاتورة مياه",
                "rows": [
                    ["الجهة", "سن إيو (مياه)"],
                    ["النوع", "مياه"],
                    ["رقم الحساب", "77123456"],
                    ["رقم الفاتورة", "2024-118833"],
                    ["المبلغ", "15,000 فرنك أفريقي"],
                    ["رقم العملية", "88"],
                ],
                "pin": "",
                "pin_label": "رمز الشحن",
                "notice": "تم تسديد المبلغ للجهة المذكورة، ولا يمكن استرداده.",
            },
        )
        sent = self.relay.orders[0]
        self.assertEqual(
            (sent["invoice_id"], sent["amount_id"], sent["country"]), ("2024-118833", None, "SN")
        )

    def test_a_plan_is_sent_by_its_id(self):
        self.relay.quote_answer = relay_quote(
            kind="bill", cost="184.00", retail="195.00", amount="10000", currency="XOF"
        )
        quote = self.quoted(
            kind="bill",
            country="ML",
            biller_id=30,
            account="5550011",
            amount="10000",
            amount_currency="XOF",
            amount_id=2,
        )
        order = self.sell(quote)
        receipt = {
            "transaction_id": "91",
            "biller": "Canal+ Mali",
            "account": "5550011",
            "amount": "10000",
            "currency": "XOF",
        }
        self.relay.order = (
            201,
            {
                "purchase": service_purchase(
                    kind="bill", item="bill:30:10000:XOF", unit_price="184.00", receipt=receipt
                ),
                "balance": "816.00",
            },
        )
        result = self.charge(order)["results"][0]
        self.assertEqual(self.relay.orders[0]["amount_id"], 2)
        self.assertEqual(result["receipt"]["title"], "دفع اشتراك تلفزيون")
        self.assertEqual(
            result["receipt"]["rows"][:5],
            [
                ["الجهة", "كانال بلس مالي"],
                ["النوع", "تلفزيون"],
                ["الباقة", "كانال بلس أكسيس إنجليش بيسك – شهر"],
                ["رقم بطاقة الاشتراك", "5550011"],
                ["المبلغ", "10,000 فرنك أفريقي"],
            ],
        )

    def test_a_slip_from_the_relays_test_supplier_says_nothing_was_sent(self):
        order = self.sell(self.quoted())
        self.relay.order = (
            201,
            {"purchase": service_purchase(test_mode=True), "balance": "908.70"},
        )
        result = self.charge(order)["results"][0]
        self.assertEqual(result["receipt"]["notice"], "عملية تجريبية: لم يتم إرسال أي رصيد فعلي.")
        self.assertTrue(self.row(order).provider_receipt["test_mode"])
        order = self.sell(self.bill_quoted())
        self.relay.order = (
            201,
            {
                "purchase": service_purchase(kind="bill", test_mode=True, unit_price="26.00"),
                "balance": "900.00",
            },
        )
        result = self.charge(order)["results"][0]
        self.assertEqual(result["receipt"]["notice"], "عملية تجريبية: لم يتم تسديد أي مبلغ فعلي.")

    def test_both_receipt_routes_carry_the_slip(self):
        order = self.sell(self.quoted())
        self.relay.order = (201, {"purchase": service_purchase(), "balance": "908.70"})
        self.charge(order)
        thermal, document = self.slip_on_both_routes(order)
        self.assertEqual(thermal["printed"], AIRTIME_SLIP)
        self.assertEqual(
            {
                key: thermal[key]
                for key in (
                    "provider",
                    "kind",
                    "status",
                    "subscriber_ref",
                    "reference",
                    "option_label",
                )
            },
            {
                "provider": "pointy",
                "kind": "airtime",
                "status": "confirmed",
                "subscriber_ref": "+22370123456",
                "reference": "svc-1",
                "option_label": "أورنج مالي · 5,000 فرنك أفريقي",
            },
        )
        # The provider's own mark opens the slip: there is no brand to show.
        self.assertTrue(thermal["receipt_logo"])
        self.assertIsNone(thermal["provider_logo"])
        self.assertEqual(
            {
                key: document[key]
                for key in ("provider", "kind", "status", "subscriber_ref", "provider_reference")
            },
            {
                "provider": "pointy",
                "kind": "airtime",
                "status": "confirmed",
                "subscriber_ref": "+22370123456",
                "provider_reference": "svc-1",
            },
        )
        self.assertEqual(document["package_name"], "أورنج مالي")

    def test_a_slip_not_yet_performed_carries_no_rows(self):
        order = self.sell(self.quoted())
        thermal = build_receipt_payload(order)["order"]["lines"][0]["integration"]
        self.assertEqual(
            (thermal["kind"], thermal["status"], thermal["printed"]), ("airtime", "pending", {})
        )

    # --- the relay says no ----------------------------------------------------------------
    def test_every_refusal_the_relay_states_is_definite_and_leaves_the_line_to_try_again(self):
        order = self.sell(self.quoted())
        row = self.row(order)
        cases = {
            "not enough balance": (
                refusal(402, "insufficient_balance", balance="10.00", amount="91.30"),
                ERROR_INSUFFICIENT_FLOAT,
            ),
            "the price moved": (
                refusal(409, "price_changed", unit_price="99.00"),
                ERROR_PRICE_CHANGED,
            ),
            "no services here": (
                refusal(409, "service_unavailable", reason="rate_unset"),
                ERROR_UNAVAILABLE,
            ),
            "no network": (refusal(404, "unknown_operator"), ERROR_OUT_OF_STOCK),
            "no biller": (refusal(404, "unknown_biller"), ERROR_OUT_OF_STOCK),
            "not that amount": (refusal(422, "amount_not_offered"), ERROR_OUT_OF_STOCK),
            "out of range": (
                refusal(422, "amount_out_of_range", min="1", max="2"),
                ERROR_OUT_OF_STOCK,
            ),
            "not that number": (refusal(422, "invalid_phone"), ERROR_NOT_FOUND),
            "not that account": (refusal(422, "invalid_account"), ERROR_NOT_FOUND),
            "no invoice": (refusal(422, "invoice_required"), ERROR_NOT_FOUND),
            "a malformed invoice": (refusal(422, "invalid_invoice"), ERROR_NOT_FOUND),
            "a malformed request": (refusal(422, "invalid_amount"), ERROR_UNEXPECTED),
            "busy": (refusal(429, "rate_limited"), "busy"),
            "not set up": (refusal(503, "services_unconfigured"), ERROR_UNAVAILABLE),
            "no rate": (refusal(503, "services_unpriced"), ERROR_UNAVAILABLE),
            "never reached the relay": (
                RelayControlError("refused", request_sent=False),
                ERROR_UNREACHABLE,
            ),
        }
        for name, (answer, code) in cases.items():
            with self.subTest(name):
                self.relay.order = answer
                result = self.charge(order)["results"][0]
                self.assertEqual(
                    (result["outcome"], result["error_code"], result["status"]),
                    (recharge.OUTCOME_REFUSED, code, "pending"),
                )
                row.refresh_from_db()
                self.assertEqual(row.status, IntegrationFulfillment.Status.PENDING)
        # Every refusal was a separate attempt under a key of its own.
        keys = [sent["idempotency_key"] for sent in self.relay.orders]
        self.assertEqual(len(keys), len(set(keys)))
        self.assertTrue(keys[0].endswith("-1") and keys[1].endswith("-2"))

    def test_an_error_that_repeats_the_number_is_masked_on_the_line_and_to_the_till(self):
        number = "+22370123456"
        order = self.sell(self.quoted())
        row = self.row(order)
        for name, answer in {
            "a refusal that quotes it": refusal(
                502, "supplier_refused", purchase=failed_purchase(number)
            ),
            "a transport error that carries it": RelayControlError(
                f"sent for {number}, no answer", request_sent=True
            ),
        }.items():
            with self.subTest(name):
                IntegrationFulfillment.objects.filter(pk=row.pk).update(
                    status=IntegrationFulfillment.Status.PENDING
                )
                self.relay.order = answer
                result = self.charge(order)["results"][0]
                row.refresh_from_db()
                # What the row keeps is masked; what the cashier is handed is, at
                # most, the same words or only their code word.
                self.assertIn("+223•••••456", row.last_error)
                for detail in (result["error_detail"], row.last_error):
                    self.assertNotIn("70123", detail)

    def charge_as(self, client, order):
        response = client.post(
            "/api/integrations/fulfillments/charge/", {"order": order.pk}, format="json"
        )
        self.assertEqual(response.status_code, 200, response.data)
        return response.data["results"][0]

    def test_the_price_moving_says_so_with_a_code_of_its_own(self):
        order = self.sell(self.quoted())
        self.relay.order = refusal(409, "price_changed", unit_price="99.00")
        result = self.charge(order)["results"][0]
        self.assertEqual(result["error_code"], "price_changed")
        # A cashier is told only that; what the relay now asks is the shop's cost.
        self.assertEqual(result["error_detail"], "price_changed")
        self.assertNotIn("99.00", str(result))
        # A reader who may see cost is told the figure too.
        manager = self.charge_as(self.reader, order)
        self.assertEqual(manager["error_code"], "price_changed")
        self.assertIn("99.00", manager["error_detail"])
        row = self.row(order)
        row.refresh_from_db()
        self.assertIn("99.00", row.last_error, "the row keeps what the relay said")

    def test_an_empty_float_names_its_figures_to_those_who_may_read_them(self):
        order = self.sell(self.quoted())
        self.relay.order = refusal(402, "insufficient_balance", balance="10.00", amount="91.30")
        result = self.charge(order)["results"][0]
        self.assertEqual(result["error_code"], "insufficient_float")
        self.assertEqual(result["error_detail"], "insufficient_balance")
        self.assertNotIn("91.30", str(result))
        manager = self.charge_as(self.reader, order)
        self.assertIn("10.00", manager["error_detail"])
        self.assertIn("91.30", manager["error_detail"])

    def test_a_supplier_sentence_does_not_leak_the_shops_figures_either(self):
        order = self.sell(self.quoted())
        failed = service_purchase(status="failed", error_code="supplier_credit", receipt=None)
        failed["error_detail"] = "account balance 12.34 below 91.30"
        self.relay.order = refusal(502, "supplier_credit", purchase=failed)
        result = self.charge(order)["results"][0]
        self.assertEqual(result["error_detail"], "supplier_credit")
        manager = self.charge_as(self.reader, order)
        self.assertIn("91.30", manager["error_detail"])

    def test_every_supplier_refusal_is_a_definite_refund(self):
        order = self.sell(self.quoted())
        cases = {
            "supplier_out_of_stock": ERROR_OUT_OF_STOCK,
            "supplier_credit": ERROR_UNAVAILABLE,
            "supplier_unauthorized": ERROR_UNAVAILABLE,
            "supplier_unreachable": ERROR_UNREACHABLE,
            "supplier_refused": ERROR_PROVIDER_ERROR,
            "supplier_unavailable": ERROR_PROVIDER_ERROR,
        }
        for code, expected in cases.items():
            with self.subTest(code):
                failed = service_purchase(status="failed", error_code=code, receipt=None)
                self.relay.order = refusal(502, code, purchase=failed, balance="1000.00")
                result = self.charge(order)["results"][0]
                self.assertEqual(
                    (result["outcome"], result["error_code"], result["status"]),
                    (recharge.OUTCOME_REFUSED, expected, "pending"),
                )
        self.account.refresh_from_db()
        self.assertEqual(self.account.balance, Decimal("1000.00"), "the refund the relay did")

    def test_a_supplier_refusal_with_a_purchase_the_relay_still_holds_is_not_proof(self):
        order = self.sell(self.quoted())
        for name, held in {
            "held": service_purchase(status="failed", held=True, receipt=None),
            "still pending": service_purchase(status="pending", receipt=None),
            "done": service_purchase(status="succeeded"),
        }.items():
            with self.subTest(name):
                IntegrationFulfillment.objects.filter(pk=self.row(order).pk).update(
                    status=IntegrationFulfillment.Status.PENDING
                )
                self.relay.order = refusal(502, "supplier_unreachable", purchase=held)
                result = self.charge(order)["results"][0]
                self.assertEqual(result["outcome"], recharge.OUTCOME_UNKNOWN, name)
                self.assertEqual(result["status"], "submitted")

    # --- nobody knows -------------------------------------------------------------------------
    def test_what_may_have_happened_is_never_sent_again(self):
        unknown = {
            "pending (202)": (
                202,
                {"purchase": service_purchase(status="pending", receipt=None), "balance": "908.70"},
            ),
            "in flight": refusal(409, "in_flight"),
            "a proxy's 502": refusal(502),
            "a gateway timeout": refusal(504),
            "the relay's own 500": refusal(500, "internal_error"),
            "sent, no answer": RelayControlError("timed out", request_sent=True),
            "unreadable answer": (201, {"nothing": "useful"}),
            "the wrong kind of purchase": (201, {"purchase": purchase(), "balance": "1.00"}),
            "bought, receipt not readable yet": (
                201,
                {"purchase": service_purchase(receipt_pending=True), "balance": "908.70"},
            ),
            "bought, no receipt": (
                201,
                {"purchase": service_purchase(receipt=None, status="succeeded"), "balance": "1.00"},
            ),
        }
        for name, answer in unknown.items():
            with self.subTest(name):
                order = self.sell(self.quoted())
                self.relay.order = answer
                result = self.charge(order)["results"][0]
                self.assertEqual(result["outcome"], recharge.OUTCOME_UNKNOWN)
                self.assertEqual(result["error_code"], ERROR_INDETERMINATE)
                self.assertEqual(result["status"], "submitted")
                self.assertTrue(result["needs_attention"])
                sent = len(self.relay.orders)
                self.assertEqual(
                    self.charge(order)["results"], [], "nothing claimable: nothing sent"
                )
                self.assertEqual(len(self.relay.orders), sent)

    def test_a_lost_answer_is_settled_by_reading_the_order_back_with_the_slip_in_arabic(self):
        order = self.sell(self.quoted())
        self.relay.order = RelayControlError("timed out", request_sent=True)
        self.charge(order)
        row = self.row(order)
        key = self.relay.orders[0]["idempotency_key"]
        self.assertEqual(key, recharge.attempt_key(row))
        self.relay.outcomes[key] = {"purchase": service_purchase(key), "balance": "908.70"}
        result = settle_relay_attempts()
        self.assertEqual(result["accounts"][0]["confirmed"], 1)
        row.refresh_from_db()
        self.assertEqual(row.status, IntegrationFulfillment.Status.CONFIRMED)
        self.assertEqual(row.provider_reference, "svc-1")
        self.assertEqual(row.provider_receipt["printed"], AIRTIME_SLIP)
        self.assertEqual(row.confirmed_at.isoformat(), "2026-10-08T12:00:03+00:00")
        self.assertEqual(row.cost, Decimal("91.30"))
        self.account.refresh_from_db()
        self.assertEqual(self.account.balance, Decimal("908.70"))
        thermal, _document = self.slip_on_both_routes(order)
        self.assertEqual(thermal["printed"], AIRTIME_SLIP)

    def test_a_settled_bill_still_names_its_invoice(self):
        self.relay.quote_answer = relay_quote(
            kind="bill", cost="270.00", retail="285.00", amount="15000", currency="XOF"
        )
        quote = self.quoted(
            kind="bill",
            country="SN",
            biller_id=24,
            account="77123456",
            amount="15000",
            amount_currency="XOF",
            invoice_id="2024-118833",
        )
        order = self.sell(quote)
        self.relay.order = RelayControlError("timed out", request_sent=True)
        self.charge(order)
        key = self.relay.orders[0]["idempotency_key"]
        # The relay's receipt does not carry the invoice: the option code does.
        self.relay.outcomes[key] = {
            "purchase": service_purchase(
                key,
                kind="bill",
                item="bill:24:15000:XOF",
                unit_price="270.00",
                receipt=INVOICE_RECEIPT,
            ),
            "balance": "730.00",
        }
        settle_relay_attempts()
        rows = dict(self.row(order).provider_receipt["printed"]["rows"])
        self.assertEqual(rows["رقم الفاتورة"], "2024-118833")
        self.assertEqual(rows["الجهة"], "سن إيو (مياه)")

    def test_a_purchase_whose_receipt_cannot_be_read_yet_is_asked_again(self):
        order = self.sell(self.bill_quoted())
        self.relay.order = RelayControlError("timed out", request_sent=True)
        self.charge(order)
        row = self.row(order)
        key = self.relay.orders[0]["idempotency_key"]
        self.relay.outcomes[key] = {
            "purchase": service_purchase(key, kind="bill", receipt_pending=True),
            "balance": "974.00",
        }
        result = settle_relay_attempts()
        self.assertEqual(len(result["accounts"][0]["unknown"]), 1)
        row.refresh_from_db()
        self.assertEqual(row.status, IntegrationFulfillment.Status.SUBMITTED)
        self.relay.outcomes[key] = {
            "purchase": service_purchase(key, kind="bill", unit_price="26.00"),
            "balance": "974.00",
        }
        settle_relay_attempts()
        row.refresh_from_db()
        self.assertEqual(row.status, IntegrationFulfillment.Status.CONFIRMED)
        self.assertEqual(row.provider_receipt["printed"], ELECTRICITY_SLIP)

    def test_a_refunded_or_never_recorded_purchase_goes_back_to_be_tried_again(self):
        order = self.sell(self.quoted())
        self.relay.order = RelayControlError("timed out", request_sent=True)
        self.charge(order)
        row = self.row(order)
        key = self.relay.orders[0]["idempotency_key"]
        IntegrationFulfillment.objects.filter(pk=row.pk).update(
            submitted_at=timezone.now() - ATTEMPT_SETTLE_AFTER - timedelta(seconds=1)
        )
        self.relay.outcomes[key] = {
            "purchase": service_purchase(
                key, status="failed", error_code="supplier_credit", receipt=None
            ),
            "balance": "1000.00",
        }
        settle_relay_attempts()
        row.refresh_from_db()
        self.assertEqual(row.status, IntegrationFulfillment.Status.PENDING)
        self.assertEqual(row.last_error_code, ERROR_UNAVAILABLE)
        # It is sold again under a new key, never the old one.
        self.relay.order = (201, {"purchase": service_purchase(), "balance": "908.70"})
        self.assertEqual(self.charge(order)["results"][0]["outcome"], recharge.OUTCOME_CHARGED)
        self.assertNotEqual(self.relay.orders[1]["idempotency_key"], key)

    def test_the_nightly_reconciliation_reads_a_service_back_never_a_log(self):
        order = self.sell(self.quoted())
        self.relay.order = RelayControlError("timed out", request_sent=True)
        self.charge(order)
        key = self.relay.orders[0]["idempotency_key"]
        self.relay.outcomes[key] = {"purchase": service_purchase(key), "balance": "908.70"}
        with mock.patch.object(PointyProvider, "purchase_history") as history:
            report = reconcile_account(self.account)
        history.assert_not_called()
        self.assertTrue(report["ok"])
        self.assertEqual(report["resolved"]["confirmed"], 1)
        # A service sold and never sent is not matched against a log either.
        pending = self.sell(self.quoted(phone="70999999"))
        with mock.patch.object(PointyProvider, "purchase_history") as history:
            report = reconcile_account(self.account)
        history.assert_not_called()
        self.assertTrue(report["ok"], "nothing to read, nothing unreachable")
        self.assertEqual(self.row(pending).status, IntegrationFulfillment.Status.PENDING)

    def test_an_operator_that_left_the_directory_is_refused_before_anything_is_sent(self):
        order = self.sell(self.quoted())
        IntegrationServiceCountry.objects.filter(code="ML").delete()
        result = self.charge(order)["results"][0]
        self.assertEqual(
            (result["outcome"], result["error_code"], result["status"]),
            (recharge.OUTCOME_REFUSED, ERROR_OUT_OF_STOCK, "pending"),
        )
        self.assertIn("unknown_operator", result["error_detail"])
        self.assertEqual(self.relay.orders, [])

    def test_the_shop_switched_off_by_the_operator_sends_nothing(self):
        order = self.sell(self.quoted())
        RelayInstallation.objects.update(integrations_disabled=["pointy"])
        result = self.charge(order)["results"][0]
        self.assertEqual(
            (result["outcome"], result["error_code"]), (recharge.OUTCOME_REFUSED, "switched_off")
        )
        self.assertEqual(self.relay.orders, [])
        self.assertEqual(self.row(order).attempt_count, 0)

    # --- the driver, called the way the guard calls it --------------------------------------------
    def test_a_service_option_is_never_sent_as_a_card(self):
        driver = PointyProvider(self.account)
        for option in ("air:garbage", "bill:", "air:289:05000:XOF", "bill:5:5000:NGN:"):
            with self.subTest(option=option):
                result = driver.recharge(
                    "+22370123456", option, expected_cost=Decimal("1"), attempt_key="k-1"
                )
                self.assertTrue(result.is_definite_failure)
                self.assertEqual(result.error_code, ERROR_UNEXPECTED)
        self.assertEqual((self.relay.orders, self.relay.purchases_sent), ([], []))

    def test_a_subscriber_that_cannot_be_one_is_refused_before_anything_is_sent(self):
        driver = PointyProvider(self.account)
        for ref in ("", "0701234", "22370123456"):
            result = driver.recharge(
                ref, "air:289:5000:XOF", expected_cost=Decimal("91.30"), attempt_key="k-1"
            )
            self.assertTrue(result.is_definite_failure, ref)
            self.assertEqual(result.error_code, ERROR_NOT_FOUND)
        self.assertEqual(self.relay.orders, [])

    def test_nothing_is_sent_without_a_key_to_read_it_back_by(self):
        result = PointyProvider(self.account).recharge(
            "+22370123456", "air:289:5000:XOF", expected_cost=Decimal("91.30")
        )
        self.assertTrue(result.is_definite_failure)
        self.assertEqual(self.relay.orders, [])

    def test_a_card_is_still_a_card(self):
        card = self.voucher_row("itunes-us-10")
        response = self.checkout({"variant": card.variant_id, "quantity": "1"})
        self.assertEqual(response.status_code, 201, response.data)
        order = Order.objects.get(pk=response.data["id"])
        self.relay.purchase = (201, {"purchase": purchase(unit_price="50.00"), "balance": "950.00"})
        result = self.charge(order)["results"][0]
        self.assertEqual((result["outcome"], result["kind"]), (recharge.OUTCOME_CHARGED, "voucher"))
        self.assertEqual(result["receipt"]["code"], "ABCD-1234-EFGH")
        self.assertEqual((len(self.relay.purchases_sent), self.relay.orders), (1, []))

    def voucher_row(self, code):
        from .models import IntegrationVoucher

        return IntegrationVoucher.objects.select_related("variant").get(code=code)


# --- one to a line, and never under what it costs ----------------------------------------------------------
class ServicesQuantityTests(ServicesSaleMixin, TestCase):
    """One line is one order to the relay: a quantity of anything else is a sale
    the shop pays for once and charges for some other number of times."""

    QUANTITIES = ("0.001", "0.5", "1.5", "2", "10")

    def test_a_service_is_sold_one_to_a_line_never_a_fraction_or_a_pair(self):
        for name, quote in (("a top-up", self.quoted()), ("a bill", self.bill_quoted())):
            for quantity in self.QUANTITIES:
                with self.subTest(name=name, quantity=quantity):
                    response = self.checkout(self.line(quote, quantity=quantity))
                    self.assertEqual(response.status_code, 400, response.data)
                    self.assertEqual(response.data["code"], "integration_quantity")
        self.assertFalse(Order.objects.exists())
        self.assertFalse(IntegrationFulfillment.objects.exists())

    def test_one_of_a_thousand_a_pair_and_the_rest_is_judged_per_line(self):
        top_up, bill = self.quoted(), self.bill_quoted()
        response = self.checkout(self.line(top_up), self.line(bill, quantity="2"))
        self.assertEqual(response.status_code, 400, response.data)
        self.assertEqual(
            [int(entry["variant_id"]) for entry in response.data["variants"]],
            [bill["service_variant_id"]],
        )
        self.assertEqual(self.checkout(self.line(top_up), self.line(bill)).status_code, 201)

    def test_a_card_is_still_one_to_a_line(self):
        card = self.voucher("itunes-us-10")
        response = self.checkout({"variant": card.variant_id, "quantity": "2"})
        self.assertEqual(response.status_code, 400, response.data)
        self.assertEqual(response.data["code"], "voucher_quantity")

    def test_the_discount_preview_refuses_the_same_lines(self):
        quote = self.quoted()
        preview = lambda quantity: self.client.post(  # noqa: E731
            "/api/orders/discount-preview/",
            {"lines": [self.line(quote, quantity=quantity)]},
            format="json",
        )
        for quantity in self.QUANTITIES:
            with self.subTest(quantity=quantity):
                self.assertEqual(preview(quantity).status_code, 400)
        self.assertEqual(preview("1").status_code, 200)

    def test_a_service_call_that_skips_the_serializer_is_refused_too(self):
        serializer = CheckoutLineSerializer(data=[self.line(self.quoted())], many=True, context={})
        serializer.is_valid(raise_exception=True)
        for quantity in (Decimal("0.001"), Decimal("2")):
            lines = [dict(line) for line in serializer.validated_data]
            lines[0]["quantity"] = quantity
            with self.subTest(quantity=quantity), self.assertRaises(ValidationError) as caught:
                checkout_order(
                    register_session=self.register,
                    lines_data=lines,
                    payments_data=[{"method": "cash", "amount": Decimal("965.00")}],
                )
            self.assertEqual(caught.exception.detail["code"], "integration_quantity")
        self.assertFalse(Order.objects.exists())


class ServicesBelowCostTests(ServicesSaleMixin, TestCase):
    """A service costs what the relay quoted for it, not what the warehouse thinks
    a service product is worth (nothing): the guard against selling at a loss has
    to see it, or a discount sells a top-up under what it costs."""

    def setUp(self):
        super().setUp()
        # A thin margin: 96.00 to the relay, 96.50 from the customer.
        self.relay.quote_answer = relay_quote(cost="96.00", retail="96.50")
        self.quote = self.quoted()

    @staticmethod
    def prevent_selling_at_loss(on=True):
        settings = ShopSettings.load()
        settings.prevent_selling_at_loss = on
        settings.save(update_fields=["prevent_selling_at_loss"])

    def test_a_two_percent_invoice_discount_under_the_cost_is_refused(self):
        self.prevent_selling_at_loss()
        response = self.checkout(self.line(self.quote), extra_discount_amount="1.93")
        self.assertEqual(response.status_code, 400, response.data)
        self.assertEqual(response.data["code"], "sale_at_loss_blocked")
        self.assertFalse(Order.objects.exists())
        self.assertFalse(IntegrationFulfillment.objects.exists())

    def test_a_discount_that_keeps_it_at_or_above_the_cost_goes_through(self):
        self.prevent_selling_at_loss()
        response = self.checkout(self.line(self.quote), extra_discount_amount="0.50")
        self.assertEqual(response.status_code, 201, response.data)
        order = Order.objects.get(pk=response.data["id"])
        self.assertEqual(order.total, Decimal("96.00"))

    def test_a_credit_invoice_is_judged_the_same_way(self):
        from apps.customers.models import Customer

        self.prevent_selling_at_loss()
        customer = Customer.objects.create(full_name="زبون")
        response = self.checkout(
            self.line(self.quote),
            customer=customer.pk,
            sale_type="credit",
            extra_discount_amount="1.93",
        )
        self.assertEqual(response.status_code, 400, response.data)
        self.assertEqual(response.data["code"], "sale_at_loss_blocked")
        self.assertFalse(Order.objects.exists())

    def test_a_shop_that_allows_selling_at_a_loss_is_not_stopped(self):
        self.prevent_selling_at_loss(False)
        response = self.checkout(self.line(self.quote), extra_discount_amount="1.93")
        self.assertEqual(response.status_code, 201, response.data)
        order = Order.objects.get(pk=response.data["id"])
        self.assertEqual(order.total, Decimal("94.57"))
        self.assertEqual(order.lines.get().unit_cost, Decimal("96.00"))

    def test_a_coupon_under_the_cost_is_refused_and_allowed_with_the_guard_off(self):
        DiscountRule.objects.create(
            name="اثنان بالمئة",
            channel=DiscountRule.Channel.SALES,
            application_type=DiscountRule.ApplicationType.COUPON_CODE,
            coupon_code="TWO",
            scope=DiscountRule.Scope.DOCUMENT,
            value_type=DiscountRule.ValueType.PERCENTAGE,
            value=Decimal("2"),
        )
        self.prevent_selling_at_loss()
        response = self.checkout(self.line(self.quote), coupon_codes=["TWO"])
        self.assertEqual(response.status_code, 400, response.data)
        self.assertEqual(response.data["code"], "sale_at_loss_blocked")
        self.prevent_selling_at_loss(False)
        response = self.checkout(self.line(self.quote), coupon_codes=["TWO"])
        self.assertEqual(response.status_code, 201, response.data)
        self.assertEqual(Order.objects.get(pk=response.data["id"]).total, Decimal("94.57"))

    def test_the_preview_warns_before_the_sale_is_tried(self):
        self.prevent_selling_at_loss()
        response = self.client.post(
            "/api/orders/discount-preview/",
            {"lines": [self.line(self.quote)], "extra_discount_amount": "1.93"},
            format="json",
        )
        self.assertEqual(response.status_code, 200, response.data)
        self.assertEqual(
            [entry["variant_id"] for entry in response.data["loss_lines"]],
            [self.quote["service_variant_id"]],
        )
        calm = self.client.post(
            "/api/orders/discount-preview/", {"lines": [self.line(self.quote)]}, format="json"
        )
        self.assertEqual(calm.data["loss_lines"], [])

    def test_any_providers_line_is_judged_by_the_cost_it_carries(self):
        from apps.sales.services import checkout_loss_lines

        variant = service_variant_for("hdbox")
        line = {
            "variant": variant,
            "quantity": Decimal("1"),
            "effective_unit_price": Decimal("30.00"),
            "_discount_line_key": "0",
            "integration": {"cost": Decimal("25.00")},
        }
        self.assertEqual(checkout_loss_lines([line]), [])
        loss = checkout_loss_lines([line], extra_discount_amount=Decimal("6.00"))
        self.assertEqual([entry["variant_id"] for entry in loss], [variant.pk])
        self.assertEqual(loss[0]["unit_cost"], "25.00")
        self.assertEqual(checkout_loss_lines([line], extra_discount_amount=Decimal("5.00")), [])
        # Without a cost of its own a line is judged as any other is.
        plain = {key: value for key, value in line.items() if key != "integration"}
        self.assertEqual(checkout_loss_lines([plain], extra_discount_amount=Decimal("6.00")), [])

    def test_a_card_is_judged_against_its_cost_too(self):
        self.prevent_selling_at_loss()
        card = self.voucher("itunes-us-10")
        line = {"variant": card.variant_id, "quantity": "1"}
        price = Decimal("60.00")
        under = price - card.cost + Decimal("0.01")
        response = self.checkout(line, extra_discount_amount=str(under))
        self.assertEqual(response.status_code, 400, response.data)
        self.assertEqual(response.data["code"], "sale_at_loss_blocked")
        at_cost = self.checkout(line, extra_discount_amount=str(price - card.cost))
        self.assertEqual(at_cost.status_code, 201, at_cost.data)


# --- a sale that was voided or returned -----------------------------------------------------------------------
class ServicesWithdrawnSaleTests(ServicesSaleMixin, TransactionTestCase):
    """A sale that came back owes the provider nothing: its top-up must not be
    sendable, alarming or counted against the float."""

    reset_sequences = True

    def void(self, order):
        return void_order(
            order=order, reason="customer changed mind", register_session=self.register
        )

    def give_back(self, order, line, quantity=1):
        return return_order_items(
            order=order,
            lines=[(line, quantity)],
            reason="wrong number",
            register_session=self.register,
        )

    def pending_alerts(self):
        return [
            spec
            for spec in _integration_notifications(timezone.now())
            if spec["code"] == "integrations.unperformed_recharge"
        ]

    def test_voiding_a_sale_withdraws_what_was_never_sent(self):
        order = self.sell(self.quoted())
        row = self.row(order)
        IntegrationFulfillment.objects.filter(pk=row.pk).update(
            created_at=timezone.now() - timedelta(hours=7)
        )
        self.assertEqual(float_ledger.committed(self.account), Decimal("91.30"))
        self.assertEqual(len(self.pending_alerts()), 1)

        self.void(order)

        row.refresh_from_db()
        self.assertEqual(row.status, IntegrationFulfillment.Status.CANCELLED)
        self.assertEqual(float_ledger.committed(self.account), Decimal("0.00"))
        self.assertEqual(self.pending_alerts(), [], "no permanent alarm for a refunded sale")
        # And nobody can send it any more, by the order or by the line.
        self.assertEqual(self.charge(order)["results"], [])
        again = self.client.post(
            "/api/integrations/fulfillments/charge/", {"fulfillment": row.pk}, format="json"
        )
        self.assertEqual(again.data["results"], [])
        self.assertEqual(self.relay.orders, [])

    def test_returning_the_line_in_full_withdraws_it_too(self):
        order = self.sell(self.quoted())
        row = self.row(order)
        self.give_back(order, order.lines.get())
        row.refresh_from_db()
        self.assertEqual(row.status, IntegrationFulfillment.Status.CANCELLED)
        self.assertEqual(self.charge(order)["results"], [])
        self.assertEqual(self.relay.orders, [])

    @staticmethod
    def fee(sku):
        """A fee: a product with no stock to count, so a sale needs no shelf here."""
        product = create_product_with_default_variant(
            sku=sku, name="رسوم", unit_price=Decimal("10.00")
        )
        Product.objects.filter(pk=product.pk).update(is_service=True)
        return product

    def test_returning_something_else_leaves_the_top_up_to_be_sent(self):
        product = self.fee("BESIDE-1")
        quote = self.quoted()
        response = self.checkout(
            self.line(quote), {"variant": product.default_variant.pk, "quantity": "1"}
        )
        self.assertEqual(response.status_code, 201, response.data)
        order = Order.objects.get(pk=response.data["id"])
        bag = order.lines.get(variant=product.default_variant)
        self.give_back(order, bag)
        row = order.lines.exclude(pk=bag.pk).get().integration_fulfillment
        self.assertEqual(row.status, IntegrationFulfillment.Status.PENDING)
        self.relay.order = (
            201,
            {"purchase": service_purchase(unit_price="91.30"), "balance": "908.70"},
        )
        result = self.charge(order)["results"][0]
        self.assertEqual(result["outcome"], recharge.OUTCOME_CHARGED)
        self.assertEqual(len(self.relay.orders), 1)

    def test_what_may_already_have_happened_is_left_alone(self):
        for status in (
            IntegrationFulfillment.Status.SUBMITTED,
            IntegrationFulfillment.Status.CONFIRMED,
            IntegrationFulfillment.Status.FAILED,
        ):
            with self.subTest(status=status):
                order = self.sell(self.quoted())
                row = self.row(order)
                IntegrationFulfillment.objects.filter(pk=row.pk).update(status=status)
                self.void(order)
                row.refresh_from_db()
                self.assertEqual(row.status, status)

    def test_a_row_left_pending_by_an_earlier_void_is_refused_and_retired_when_met(self):
        order = self.sell(self.quoted())
        row = self.row(order)
        self.void(order)
        # What a shop that voided it before this fix still has.
        IntegrationFulfillment.objects.filter(pk=row.pk).update(
            status=IntegrationFulfillment.Status.PENDING
        )
        result = self.charge(order)["results"][0]
        self.assertEqual(result["outcome"], recharge.OUTCOME_NOT_CLAIMABLE)
        self.assertEqual(self.relay.orders, [])
        row.refresh_from_db()
        self.assertEqual(row.status, IntegrationFulfillment.Status.CANCELLED)

    def test_a_line_returned_in_a_sale_that_lives_on_is_refused_too(self):
        product = self.fee("BESIDE-2")
        response = self.checkout(
            self.line(self.quoted()), {"variant": product.default_variant.pk, "quantity": "1"}
        )
        order = Order.objects.get(pk=response.data["id"])
        line = order.lines.exclude(variant=product.default_variant).get()
        row = line.integration_fulfillment
        self.give_back(order, line)
        order.refresh_from_db()
        self.assertNotEqual(order.status, Order.Status.VOID)
        IntegrationFulfillment.objects.filter(pk=row.pk).update(
            status=IntegrationFulfillment.Status.PENDING
        )
        result = self.charge(order)["results"][0]
        self.assertEqual(result["outcome"], recharge.OUTCOME_NOT_CLAIMABLE)
        self.assertEqual(self.relay.orders, [])

    def test_voiding_a_dear_top_up_does_not_make_a_cheap_one_look_like_a_loss(self):
        from apps.inventory.models import StockMovement, StockValuationBin

        dear = self.quoted()  # 5,000 francs: 91.30 to the relay
        order = self.sell(dear)
        self.void(order)
        # Nothing was on a shelf, so nothing goes back onto one; the one variant
        # every top-up shares is not valued at what the voided one cost.
        variant = dear["service_variant_id"]
        self.assertFalse(StockMovement.objects.filter(variant_id=variant).exists())
        self.assertFalse(StockValuationBin.objects.filter(variant_id=variant).exists())
        # ...and a cheaper one, of another amount, is sold, with the guard on.
        self.relay.quote_answer = relay_quote(cost="38.75", retail="41.00", amount="2000")
        cheap = self.quoted(amount="2000")
        response = self.checkout(self.line(cheap))
        self.assertEqual(response.status_code, 201, response.data)
        self.assertEqual(self.row(Order.objects.get(pk=response.data["id"])).cost, Decimal("38.75"))

    def test_the_same_goes_for_a_bill_after_a_dearer_one_is_returned(self):
        dear = self.bill_quoted(cost="270.00", retail="285.00")
        order = self.sell(dear)
        self.give_back(order, order.lines.get())
        self.relay.quote_answer = relay_quote(
            kind="bill", cost="26.00", retail="27.50", amount="5000", currency="NGN"
        )
        cheap = self.quoted(kind="bill")
        self.assertEqual(self.checkout(self.line(cheap)).status_code, 201)

    def test_the_nightly_sweep_retires_what_an_earlier_void_left(self):
        order = self.sell(self.quoted())
        row = self.row(order)
        self.void(order)
        IntegrationFulfillment.objects.filter(pk=row.pk).update(
            status=IntegrationFulfillment.Status.PENDING,
            created_at=timezone.now() - timedelta(hours=7),
        )
        self.assertEqual(len(self.pending_alerts()), 1)
        reconcile_account(self.account)
        row.refresh_from_db()
        self.assertEqual(row.status, IntegrationFulfillment.Status.CANCELLED)
        self.assertEqual(self.pending_alerts(), [])


# --- the money call, and finding what it is for -------------------------------------------------------------------
class ServicesMoneyCallTests(ServicesSaleMixin, TransactionTestCase):
    reset_sequences = True

    def test_a_service_order_waits_longer_than_the_relay_and_less_than_a_settle(self):
        self.charge(self.sell(self.quoted()))
        waited = self.relay.order_timeouts[0]
        # The relay's own budget for one is 45 + 20 + 5 seconds; a settle may read
        # the attempt back after two minutes and must never meet a request still out.
        self.assertGreaterEqual(waited, 80)
        self.assertLess(waited, ATTEMPT_SETTLE_AFTER.total_seconds())

    def test_a_card_keeps_the_wait_it_always_had(self):
        card = self.voucher("itunes-us-10")
        response = self.checkout({"variant": card.variant_id, "quantity": "1"})
        order = Order.objects.get(pk=response.data["id"])
        self.relay.purchase = (
            201,
            {"purchase": purchase(unit_price=str(card.cost)), "balance": "200.00"},
        )
        self.charge(order)
        self.assertEqual(self.relay.purchases_sent[0]["timeout"], 60)

    def test_the_wait_stays_in_its_range_however_it_is_configured(self):
        for wanted, expected in ((10, 80), (95, 95), (500, 110)):
            with self.subTest(wanted=wanted):
                with override_settings(POINTY_RELAY_SERVICE_PURCHASE_TIMEOUT_SECONDS=wanted):
                    self.charge(self.sell(self.quoted()))
                self.assertEqual(self.relay.order_timeouts[-1], expected)
        self.assertLess(expected, ATTEMPT_SETTLE_AFTER.total_seconds())

    def test_an_order_is_looked_for_in_the_country_its_sale_named(self):
        order = self.sell(self.quoted())
        with mock.patch.object(
            services_mirror, "find_service", wraps=services_mirror.find_service
        ) as found:
            self.charge(order)
        self.assertTrue(found.call_args_list)
        self.assertEqual({call.kwargs.get("country") for call in found.call_args_list}, {"ML"})

    def test_an_operator_its_country_no_longer_lists_is_not_found_in_another(self):
        order = self.sell(self.quoted())
        moved, gone = niger(), mali()
        moved["airtime"]["operators"].append(operator(289))
        gone["airtime"]["operators"] = [
            row for row in gone["airtime"]["operators"] if row["id"] != 289
        ]
        self.relay.directory = services_directory(
            version="d2", countries=[moved, gone, nigeria(), senegal()]
        )
        self.sync_services()
        result = self.charge(order)["results"][0]
        self.assertEqual(
            (result["outcome"], result["error_code"]),
            (recharge.OUTCOME_REFUSED, "out_of_stock"),
        )
        self.assertEqual(self.relay.orders, [], "nothing was sent to a network elsewhere")

    def test_a_read_back_looks_in_that_country_too(self):
        order = self.sell(self.quoted())
        self.relay.order = RelayControlError("timed out", request_sent=True)
        self.charge(order)
        row = self.row(order)
        row.refresh_from_db()
        key = recharge.attempt_key(row)
        self.relay.outcomes[key] = {"purchase": service_purchase(key), "balance": "908.70"}
        with mock.patch.object(
            services_mirror, "find_service", wraps=services_mirror.find_service
        ) as found:
            settle_relay_attempts()
        self.assertTrue(found.call_args_list)
        self.assertEqual({call.kwargs.get("country") for call in found.call_args_list}, {"ML"})
        row.refresh_from_db()
        self.assertEqual(row.status, IntegrationFulfillment.Status.CONFIRMED)

    def test_one_row_that_cannot_be_settled_does_not_stop_the_others(self):
        orders = [self.sell(self.quoted(phone=phone)) for phone in ("70123456", "70123457")]
        self.relay.order = RelayControlError("timed out", request_sent=True)
        keys = []
        for order in orders:
            self.charge(order)
            row = self.row(order)
            row.refresh_from_db()
            keys.append(recharge.attempt_key(row))
            self.relay.outcomes[keys[-1]] = {
                "purchase": service_purchase(keys[-1]),
                "balance": "908.70",
            }
        real = PointyProvider.attempt_outcome

        def flaky(driver, key, **kwargs):
            if key == keys[0]:
                raise RuntimeError("a driver bug")
            return real(driver, key, **kwargs)

        with mock.patch.object(PointyProvider, "attempt_outcome", flaky):
            report = settle_relay_attempts()["accounts"][0]
        statuses = []
        for order in orders:
            row = self.row(order)
            row.refresh_from_db()
            statuses.append(row.status)
        self.assertEqual(
            statuses,
            [IntegrationFulfillment.Status.SUBMITTED, IntegrationFulfillment.Status.CONFIRMED],
        )
        self.assertEqual((report["confirmed"], len(report["unknown"])), (1, 1))


class CostCeilingTests(ServicesSaleMixin, TestCase):
    def test_a_service_is_held_to_its_price_and_a_card_to_its_cost(self):
        row = self.row(self.sell(self.quoted()))  # 91.30 to the relay, 96.50 from the customer
        self.assertEqual(recharge.cost_ceiling(row), Decimal("96.50"))
        card = self.voucher("itunes-us-10")
        response = self.checkout({"variant": card.variant_id, "quantity": "1"})
        card_row = Order.objects.get(pk=response.data["id"]).lines.get().integration_fulfillment
        self.assertEqual(recharge.cost_ceiling(card_row), card_row.cost)

    def test_the_ceiling_is_never_below_the_cost(self):
        order = self.sell(self.quoted())
        order.lines.update(unit_price=Decimal("50.00"))
        row = self.row(order)
        row.refresh_from_db()
        self.assertEqual(recharge.cost_ceiling(row), Decimal("91.30"))

    def test_a_line_that_cannot_be_read_leaves_the_stricter_ceiling(self):
        class Unreadable:
            pk = 7
            cost = Decimal("12.00")
            provider = "pointy"
            option_code = "air:289:5000:XOF"

            @property
            def order_line(self):
                raise RuntimeError("no such line")

        self.assertEqual(recharge.cost_ceiling(Unreadable()), Decimal("12.00"))


# --- the relay's price moves between the quote and the charge --------------------------------------------------
class ServicesPriceMovedTests(ServicesSaleMixin, TransactionTestCase):
    """The relay's price follows the exchange rate; a quote does not expire. A sale
    the customer paid for is performed whenever its price still covers what the
    relay now charges, and refused cleanly only when it does not."""

    reset_sequences = True

    def test_a_cost_that_rose_three_percent_is_still_performed_and_recorded(self):
        order = self.sell(self.quoted())  # 91.30 to the relay, 96.50 from the customer
        self.relay.live_cost = Decimal("94.04")
        result = self.charge(order)["results"][0]
        self.assertEqual(
            (result["outcome"], result["status"], result["error_code"]),
            (recharge.OUTCOME_CHARGED, "confirmed", ""),
        )
        self.assertEqual(self.relay.orders[0]["max_unit_price"], "96.50")
        row = self.row(order)
        row.refresh_from_db()
        self.assertEqual(row.cost, Decimal("94.04"), "what the relay really charged")
        self.assertEqual(row.order_line.unit_cost, Decimal("94.04"))
        self.assertEqual(row.order_line.unit_price, Decimal("96.50"), "the customer's price stands")

    def test_a_cost_above_what_the_customer_pays_is_refused_cleanly(self):
        order = self.sell(self.quoted())
        self.relay.live_cost = Decimal("97.00")
        result = self.charge(order)["results"][0]
        self.assertEqual(
            (result["outcome"], result["status"], result["error_code"]),
            (recharge.OUTCOME_REFUSED, "pending", ERROR_PRICE_CHANGED),
        )
        row = self.row(order)
        row.refresh_from_db()
        self.assertEqual(row.status, IntegrationFulfillment.Status.PENDING)
        self.assertEqual(row.cost, Decimal("91.30"), "nothing was spent, nothing is rewritten")
        # Prices move back: the same line is performed on its second go.
        self.relay.live_cost = Decimal("92.00")
        again = self.charge(order)["results"][0]
        self.assertEqual(again["outcome"], recharge.OUTCOME_CHARGED)

    def sell_with_discount(self, discount, *, cost="93.63", retail="97.00"):
        """A 5,000 francs top-up: 93.63 to the relay, 97.00 from the customer, less ``discount``."""
        self.relay.quote_answer = relay_quote(cost=cost, retail=retail)
        response = self.checkout(self.line(self.quoted()), extra_discount_amount=discount)
        self.assertEqual(response.status_code, 201, response.data)
        return Order.objects.get(pk=response.data["id"])

    def test_the_ceiling_is_what_the_customer_really_paid_after_every_discount(self):
        order = self.sell_with_discount("3.00")
        self.assertEqual(order.total, Decimal("94.00"))
        # The rate rises past what the customer paid: performing it would lose the
        # shop money on this line, so it is refused, whatever the list price was.
        self.relay.live_cost = Decimal("94.01")
        result = self.charge(order)["results"][0]
        self.assertEqual(
            (result["outcome"], result["error_code"]),
            (recharge.OUTCOME_REFUSED, ERROR_PRICE_CHANGED),
        )
        self.assertEqual(self.relay.orders[0]["max_unit_price"], "94.00")
        row = self.row(order)
        row.refresh_from_db()
        self.assertEqual(row.status, IntegrationFulfillment.Status.PENDING)

    def test_a_rise_the_discounted_price_still_covers_is_performed(self):
        for live in ("94.00", "93.99"):
            with self.subTest(live=live):
                order = self.sell_with_discount("3.00")
                self.relay.live_cost = Decimal(live)
                result = self.charge(order)["results"][0]
                self.assertEqual(result["outcome"], recharge.OUTCOME_CHARGED)
                row = self.row(order)
                row.refresh_from_db()
                self.assertEqual(row.cost, Decimal(live))
                self.assertEqual(row.order_line.unit_cost, Decimal(live))

    def test_a_rule_discount_counts_like_the_cashiers(self):
        DiscountRule.objects.create(
            name="ثلاثة بالمئة",
            channel=DiscountRule.Channel.SALES,
            application_type=DiscountRule.ApplicationType.COUPON_CODE,
            coupon_code="THREE",
            scope=DiscountRule.Scope.DOCUMENT,
            value_type=DiscountRule.ValueType.PERCENTAGE,
            value=Decimal("3"),
        )
        self.relay.quote_answer = relay_quote(cost="93.63", retail="97.00")
        response = self.checkout(self.line(self.quoted()), coupon_codes=["THREE"])
        self.assertEqual(response.status_code, 201, response.data)
        order = Order.objects.get(pk=response.data["id"])
        self.assertEqual(order.total, Decimal("94.09"))
        self.relay.live_cost = Decimal("94.10")
        self.assertEqual(self.charge(order)["results"][0]["outcome"], recharge.OUTCOME_REFUSED)
        self.assertEqual(self.relay.orders[0]["max_unit_price"], "94.09")

    def test_a_line_sold_under_its_cost_on_purpose_is_still_bought_at_its_cost(self):
        settings = ShopSettings.load()
        settings.prevent_selling_at_loss = False
        settings.save(update_fields=["prevent_selling_at_loss"])
        order = self.sell_with_discount("10.00")
        self.assertEqual(order.total, Decimal("87.00"))
        self.relay.live_cost = Decimal("93.64")
        result = self.charge(order)["results"][0]
        self.assertEqual(result["error_code"], ERROR_PRICE_CHANGED)
        self.assertEqual(self.relay.orders[0]["max_unit_price"], "93.63", "never below its cost")
        self.relay.live_cost = Decimal("93.63")
        self.assertEqual(self.charge(order)["results"][0]["outcome"], recharge.OUTCOME_CHARGED)

    def test_a_bill_is_held_to_its_price_the_same_way(self):
        order = self.sell(self.bill_quoted())  # 26.00 to the relay, 27.50 from the customer
        self.relay.order = (
            201,
            {"purchase": service_purchase(kind="bill", unit_price="26.00"), "balance": "974.00"},
        )
        self.relay.live_cost = Decimal("27.00")
        result = self.charge(order)["results"][0]
        self.assertEqual(result["outcome"], recharge.OUTCOME_CHARGED)
        self.assertEqual(self.relay.orders[0]["max_unit_price"], "27.50")

    def test_a_card_is_still_held_to_the_cost_it_was_sold_against(self):
        card = self.voucher("itunes-us-10")
        response = self.checkout({"variant": card.variant_id, "quantity": "1"})
        order = Order.objects.get(pk=response.data["id"])
        self.relay.purchase = (
            201,
            {"purchase": purchase(unit_price=str(card.cost)), "balance": "200.00"},
        )
        self.charge(order)
        self.assertEqual(self.relay.purchases_sent[0]["max_unit_price"], f"{card.cost:.2f}")


# --- the driver's reading of a read-back purchase -------------------------------------------------------------
class ServicesOutcomeTests(ServicesMixin, TestCase):
    def setUp(self):
        self.link_relay()
        self.relay = self.services_relay()
        self.account = self.pointy_account()
        self.sync_services()
        self.driver = PointyProvider(self.account)

    def outcome(self, answer, option_code="air:289:5000:XOF"):
        self.relay.outcomes["k"] = answer
        return self.driver.attempt_outcome("k", option_code=option_code)

    def test_a_service_purchase_read_back(self):
        from .providers.base import (
            ATTEMPT_ABSENT,
            ATTEMPT_CHARGED,
            ATTEMPT_REFUSED,
            ATTEMPT_UNKNOWN,
        )

        done = self.outcome({"purchase": service_purchase("k"), "balance": "200.00"})
        self.assertEqual(done.state, ATTEMPT_CHARGED)
        self.assertEqual(done.receipt["printed"], AIRTIME_SLIP)
        self.assertEqual(done.receipt["kind"], "airtime")
        self.assertEqual(done.actual_cost, Decimal("91.30"))
        self.assertEqual(done.balance_after, Decimal("200.00"))
        self.assertEqual(done.at.isoformat(), "2026-10-08T12:00:03+00:00")
        self.assertEqual(done.reference, "svc-1")

        failed = self.outcome(
            {
                "purchase": service_purchase(
                    "k", status="failed", error_code="supplier_credit", receipt=None
                )
            }
        )
        self.assertEqual((failed.state, failed.error_code), (ATTEMPT_REFUSED, ERROR_UNAVAILABLE))
        self.assertIn("supplier_credit", failed.error_detail)
        for status in ("pending", "something new"):
            waiting = self.outcome({"purchase": service_purchase("k", status=status, receipt=None)})
            self.assertEqual(waiting.state, ATTEMPT_UNKNOWN, status)
        not_yet = self.outcome({"purchase": service_purchase("k", receipt_pending=True)})
        self.assertEqual(
            (not_yet.state, not_yet.error_detail), (ATTEMPT_UNKNOWN, "receipt_pending")
        )
        self.assertEqual(self.outcome(refusal(404, "not_found")).state, ATTEMPT_ABSENT)

    def test_the_slip_is_in_the_relays_words_when_the_shop_cannot_say_more(self):
        # No option code to say which network: the relay's own name for it and the
        # number as it wrote it — but the currency is still read in Arabic, from
        # whichever country of the mirror carries it.
        slip = self.outcome({"purchase": service_purchase("k")}, option_code="").receipt["printed"]
        self.assertEqual(slip["rows"][0], ["الشبكة", "Orange Mali"])
        self.assertEqual(slip["rows"][1], ["الرقم", "+22370123456"])
        self.assertEqual(slip["rows"][2], ["المبلغ المرسل", "5,000 فرنك أفريقي"])
        # A mirror that no longer lists anything: no country names the currency, so
        # it keeps its code rather than a guess.
        IntegrationServiceCountry.objects.all().delete()
        slip = self.outcome({"purchase": service_purchase("k")}).receipt["printed"]
        self.assertEqual(slip["rows"][0], ["الشبكة", "Orange Mali"])
        self.assertEqual(slip["rows"][2], ["المبلغ المرسل", "5,000 XOF"])

    def test_a_bill_with_no_token_prints_none(self):
        receipt = {key: value for key, value in BILL_RECEIPT.items() if key != "token"}
        slip = self.outcome(
            {"purchase": service_purchase("k", kind="bill", receipt=receipt)},
            option_code="bill:5:5000:NGN",
        ).receipt["printed"]
        self.assertEqual((slip["pin"], slip["pin_label"]), ("", "رمز الشحن"))
        self.assertEqual(slip["notice"], "تم تسديد المبلغ للجهة المذكورة، ولا يمكن استرداده.")

    def test_a_token_on_a_bill_that_is_not_electricity_gets_its_own_notice(self):
        receipt = dict(BILL_RECEIPT, biller="Canal+ Mali", currency="XOF")
        slip = self.outcome(
            {"purchase": service_purchase("k", kind="bill", receipt=receipt)},
            option_code="bill:30:10000:XOF:2",
        ).receipt["printed"]
        self.assertEqual(slip["notice"], "استخدم رمز الشحن المذكور أعلاه.")
        self.assertEqual(slip["title"], "دفع اشتراك تلفزيون")

    def test_the_slip_names_a_bill_by_its_kind_even_for_a_mirror_without_it(self):
        slip = self.outcome(
            {"purchase": service_purchase("k", kind="bill")}, option_code=""
        ).receipt["printed"]
        self.assertEqual(slip["title"], "دفع فاتورة")
        labels = [label for label, _value in slip["rows"]]
        self.assertEqual(labels, ["الجهة", "رقم الحساب", "المبلغ", "الوحدات", "رقم العملية"])

    def test_nothing_unreadable_ever_reaches_the_slip(self):
        hostile = dict(
            AIRTIME_RECEIPT,
            operator="<script>" * 100,
            phone="+223" + "9" * 100,
            delivered_amount="1e999999999",
            delivered_currency="x" * 100,
            transaction_id=["not", "text"],
        )
        slip = self.outcome(
            {"purchase": service_purchase("k", receipt=hostile)}, option_code=""
        ).receipt["printed"]
        self.assertTrue(all(len(value) <= 200 for _label, value in slip["rows"]))
        self.assertNotIn("المبلغ المرسل", [label for label, _value in slip["rows"]])
        self.assertNotIn("رقم العملية", [label for label, _value in slip["rows"]])

    # --- the words on the slip: Arabic currencies, the number grouped, units as they came ---
    def airtime_slip(self, **changes):
        receipt = dict(AIRTIME_RECEIPT, **changes)
        return self.outcome({"purchase": service_purchase("k", receipt=receipt)}).receipt["printed"]

    def bill_slip(self, **changes):
        receipt = dict(BILL_RECEIPT, **changes)
        return self.outcome(
            {"purchase": service_purchase("k", kind="bill", receipt=receipt)},
            option_code="bill:5:5000:NGN",
        ).receipt["printed"]

    def test_every_amount_on_a_slip_carries_its_currency_in_arabic(self):
        # The currency delivered in need not be the operator's own country's: a Malian
        # network topped up in dollars, or in another country's naira.
        slip = self.airtime_slip(delivered_amount="10", delivered_currency="USD")
        self.assertEqual(slip["rows"][2], ["المبلغ المرسل", "10 دولار أمريكي"])
        slip = self.airtime_slip(delivered_amount="1500.50", delivered_currency="NGN")
        self.assertEqual(slip["rows"][2], ["المبلغ المرسل", "1,500.5 نيرة نيجيرية"])
        slip = self.bill_slip(amount="20", currency="USD")
        self.assertIn(["المبلغ", "20 دولار أمريكي"], slip["rows"])
        slip = self.bill_slip(amount="10000", currency="XOF")
        self.assertIn(["المبلغ", "10,000 فرنك أفريقي"], slip["rows"])
        # A currency nobody names keeps its code: better that than a wrong word.
        slip = self.airtime_slip(delivered_currency="GHS")
        self.assertEqual(slip["rows"][2], ["المبلغ المرسل", "5,000 GHS"])
        # And the usual slips have no code left in them at all.
        for slip in (self.airtime_slip(), self.bill_slip()):
            for _label, value in slip["rows"]:
                self.assertNotRegex(value, r"\b(XOF|NGN|USD)\b")

    def test_a_country_that_names_the_dollar_names_it_in_its_own_words(self):
        zimbabwe = country(
            "ZW", "زيمبابوي", ["263"], "USD", "دولار", operators=[operator(9, name_en="Econet")]
        )
        self.relay.directory = services_directory(
            version="d2", countries=[mali(), nigeria(), zimbabwe]
        )
        self.sync_services()
        slip = self.airtime_slip(delivered_amount="10", delivered_currency="USD")
        self.assertEqual(slip["rows"][2], ["المبلغ المرسل", "10 دولار"])

    def test_the_number_is_grouped_by_the_calling_code_of_its_operators_country_only(self):
        slip = self.airtime_slip(phone="+22370123456")
        self.assertEqual(slip["rows"][1], ["الرقم", "+223 70123456"])
        self.assertTrue(slip["rows"][1][1].isascii(), "nothing but ASCII: held left-to-right")
        # A number that is not of that country, or not a full number, is left as it came.
        self.assertEqual(
            self.airtime_slip(phone="+22570123456")["rows"][1], ["الرقم", "+22570123456"]
        )
        self.assertEqual(self.airtime_slip(phone="70123456")["rows"][1], ["الرقم", "70123456"])

    def test_a_delivered_amount_is_printed_to_its_currencys_minor_unit(self):
        slip = self.airtime_slip(delivered_amount="2010.002", delivered_currency="XOF")
        self.assertEqual(slip["rows"][2], ["المبلغ المرسل", "2,010 فرنك أفريقي"])
        slip = self.airtime_slip(delivered_amount="1500.505", delivered_currency="NGN")
        self.assertEqual(slip["rows"][2], ["المبلغ المرسل", "1,500.51 نيرة نيجيرية"])
        slip = self.bill_slip(amount="10000.4", currency="XOF")
        self.assertIn(["المبلغ", "10,000 فرنك أفريقي"], slip["rows"])
        # A pack of a few thousandths of a dollar is not rounded to nothing.
        slip = self.airtime_slip(delivered_amount="0.00123", delivered_currency="USD")
        self.assertEqual(slip["rows"][2], ["المبلغ المرسل", "0.00123 دولار أمريكي"])

    def test_a_fixed_plan_names_itself_on_the_slip(self):
        receipt = dict(BILL_RECEIPT, biller="Canal+ Mali", currency="XOF", amount="10000")
        slip = self.outcome(
            {"purchase": service_purchase("k", kind="bill", receipt=receipt)},
            option_code="bill:30:10000:XOF:2",
        ).receipt["printed"]
        labels = [label for label, _value in slip["rows"]]
        self.assertEqual(labels[:4], ["الجهة", "النوع", "الباقة", "رقم بطاقة الاشتراك"])
        self.assertIn(["الباقة", "كانال بلس أكسيس إنجليش بيسك – شهر"], slip["rows"])
        # A biller with no plans has no such row, and neither has a plan nobody knows.
        self.assertNotIn("الباقة", [label for label, _value in self.bill_slip()["rows"]])
        slip = self.outcome(
            {"purchase": service_purchase("k", kind="bill", receipt=receipt)},
            option_code="bill:30:10000:XOF:9",
        ).receipt["printed"]
        self.assertNotIn("الباقة", [label for label, _value in slip["rows"]])

    def test_a_unit_is_printed_as_the_relay_wrote_it(self):
        for units in ("10.7 kWh", "12 m3", "3 m³", "٥ وحدات"):
            self.assertIn(["الوحدات", units], self.bill_slip(units=units)["rows"], units)


class CardRefusalMappingTests(ServicesMixin, TestCase):
    """The relay's refusals of a CARD purchase: today only three were mapped and the
    rest ended as "indeterminate". Every code the relay states is definite now."""

    def setUp(self):
        self.link_relay()
        self.relay = self.services_relay()
        self.account = self.pointy_account()
        self.sync(self.account)
        self.driver = PointyProvider(self.account)

    def buy(self, answer):
        self.relay.purchase = answer
        return self.driver.recharge(
            "", "itunes-us-10", expected_cost=Decimal("50.00"), attempt_key="7-1"
        )

    def test_every_supplier_refusal_is_a_definite_refund(self):
        cases = {
            "supplier_out_of_stock": ERROR_OUT_OF_STOCK,
            "supplier_refused": ERROR_PROVIDER_ERROR,
            "supplier_unavailable": ERROR_PROVIDER_ERROR,
            "supplier_credit": ERROR_UNAVAILABLE,
            "supplier_unauthorized": ERROR_UNAVAILABLE,
            "supplier_unreachable": ERROR_UNREACHABLE,
        }
        for code, expected in cases.items():
            with self.subTest(code):
                failed = purchase(status="failed", error_code=code)
                result = self.buy(refusal(502, code, purchase=failed))
                self.assertTrue(result.is_definite_failure, code)
                self.assertEqual(result.error_code, expected)
                self.assertFalse(result.indeterminate)

    def test_a_refusal_the_relay_did_not_state_is_still_not_proof(self):
        for name, answer in {
            "a proxy's 502": refusal(502),
            "a code of a build we do not know": refusal(502, "supplier_something_new"),
            "a 503 that is not ours": refusal(503),
        }.items():
            with self.subTest(name):
                result = self.buy(answer)
                self.assertTrue(result.indeterminate, name)

    def test_a_refusal_whose_purchase_the_relay_holds_is_not_proof_either(self):
        for held in (
            purchase(status="failed", error_code="supplier_credit") | {"held": True},
            purchase(status="pending"),
            purchase(status="succeeded"),
        ):
            result = self.buy(refusal(502, "supplier_credit", purchase=held))
            self.assertTrue(result.indeterminate)

    def test_a_failed_purchase_read_back_or_replayed_says_why(self):
        from .providers.base import ATTEMPT_REFUSED

        for code, expected in {
            "supplier_credit": ERROR_UNAVAILABLE,
            "supplier_unauthorized": ERROR_UNAVAILABLE,
            "supplier_unreachable": ERROR_UNREACHABLE,
            "supplier_refused": ERROR_PROVIDER_ERROR,
            "supplier_out_of_stock": ERROR_OUT_OF_STOCK,
            "": ERROR_PROVIDER_ERROR,
        }.items():
            with self.subTest(code):
                failed = purchase("k", status="failed", error_code=code)
                self.relay.outcomes["k"] = {"purchase": failed, "balance": "250.00"}
                read = self.driver.attempt_outcome("k")
                self.assertEqual((read.state, read.error_code), (ATTEMPT_REFUSED, expected))
                replayed = self.buy(
                    (200, {"purchase": failed, "balance": "250.00", "replayed": True})
                )
                self.assertEqual(replayed.error_code, expected)
                self.assertTrue(replayed.is_definite_failure)

    def test_what_services_say_when_asked_about_a_card_changes_nothing(self):
        # The 404 of an unknown card, as ever, and the relay's other 404s.
        self.assertEqual(self.buy(refusal(404, "unknown_item")).error_code, ERROR_OUT_OF_STOCK)
        self.assertEqual(self.buy(refusal(404, "unknown_operator")).error_code, ERROR_OUT_OF_STOCK)
        self.assertEqual(self.buy(refusal(404, "something")).error_code, ERROR_UNAVAILABLE)
        self.assertEqual(self.buy(refusal(409, "item_unavailable")).error_code, ERROR_OUT_OF_STOCK)
