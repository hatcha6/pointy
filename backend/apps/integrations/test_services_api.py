"""«الشحن المباشر» and «دفع الفواتير»: what the till reads and asks.

The directory, the country screens, the flags and the menu are read from the
shop's mirror and never call the relay; detection and the quote are the two live
questions, and their refusals are answers (``200``), not errors.
"""

from __future__ import annotations

import base64
import io
import json
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.utils import timezone
from PIL import Image
from rest_framework.test import APIClient

from apps.catalog.models import ProductVariant
from apps.core.models import RelayInstallation
from apps.core.relay import RelayControlError
from apps.core.roles import CASHIER_GROUP, MANAGER_GROUP, ensure_role_groups

from . import quotes, vouchers
from .models import IntegrationAccount
from .providers.base import ERROR_UNAVAILABLE
from .test_pointy import png, refusal
from .test_services import (
    UNSUPPORTED,
    ServicesMixin,
    logo_ref,
    amount,
    biller,
    country,
    mali,
    niger,
    nigeria,
    operator,
    relay_quote,
    senegal,
    services_directory,
)

BASE = "/api/integrations/services"


class ServicesApiMixin(ServicesMixin):
    """Two readers (a manager sees the shop's cost, a cashier does not), a linked
    shop with 100 dinars in its voucher balance, and the directory mirrored."""

    def setUp(self):
        ensure_role_groups()
        User = get_user_model()
        self.manager = User.objects.create_user(username="mgr", password="x")
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.cashier = User.objects.create_user(username="csh", password="x")
        self.cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.client = APIClient()
        self.link_relay()
        self.relay = self.services_relay()
        self.relay.images[logo_ref(289)[7:]] = png()
        self.account = self.pointy_account(balance=Decimal("100.00"), balance_at=timezone.now())
        self.sync_services()

    def get(self, path, user=None):
        self.client.force_authenticate(user or self.cashier)
        response = self.client.get(path)
        self.assertEqual(response.status_code, 200, getattr(response, "data", None))
        return json.loads(response.content)

    def post(self, path, body, user=None):
        self.client.force_authenticate(user or self.cashier)
        response = self.client.post(path, body, format="json")
        self.assertEqual(response.status_code, 200, getattr(response, "data", None))
        return json.loads(response.content)

    def quote(self, user=None, **body):
        """A quote for a top-up of 5,000 francs to a Malian number — or, when the
        ``kind`` is a bill, for 5,000 naira on a Nigerian electricity meter —
        with whatever is said instead."""
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
        return self.post(f"{BASE}/quote/", request, user)

    def republish(self, directory, **kwargs):
        self.relay.directory = directory
        self.sync_services(**kwargs)


# --- the directory ---------------------------------------------------------------------------------
class ServicesDirectoryApiTests(ServicesApiMixin, TestCase):
    def test_the_directory_lists_countries_without_operators_or_flags(self):
        data = self.get(f"{BASE}/directory/")
        self.assertEqual(data.pop("balance_at"), self.account.balance_at.isoformat())
        self.assertEqual(
            data,
            {
                "available": True,
                "error_code": "",
                "version": "d1",
                "test_mode": False,
                "balance": "100.00",
                "popular": ["NE", "ML", "NG"],
                "countries": [
                    {
                        "code": "NE",
                        "name": "النيجر",
                        "name_en": "",
                        "dial": ["227"],
                        "currency": "XOF",
                        "currency_name": "فرنك أفريقي",
                        "popular": 1,
                        "airtime": 1,
                        "bills": 0,
                    },
                    {
                        "code": "ML",
                        "name": "مالي",
                        "name_en": "",
                        "dial": ["223"],
                        "currency": "XOF",
                        "currency_name": "فرنك أفريقي",
                        "popular": 2,
                        "airtime": 2,
                        "bills": 1,
                    },
                    {
                        "code": "NG",
                        "name": "نيجيريا",
                        "name_en": "",
                        "dial": ["234"],
                        "currency": "NGN",
                        "currency_name": "نيرة نيجيرية",
                        "popular": 3,
                        "airtime": 1,
                        "bills": 1,
                    },
                    {
                        "code": "SN",
                        "name": "السنغال",
                        "name_en": "",
                        "dial": ["221"],
                        "currency": "XOF",
                        "currency_name": "فرنك أفريقي",
                        "popular": 0,
                        "airtime": 0,
                        "bills": 2,
                    },
                ],
                "bill_types": [
                    {
                        "type": "electricity",
                        "countries": ["NG", "SN"],
                        "counts": {"NG": 1, "SN": 1},
                        "billers": 2,
                    },
                    {"type": "water", "countries": ["SN"], "counts": {"SN": 1}, "billers": 1},
                    {"type": "tv", "countries": ["ML"], "counts": {"ML": 1}, "billers": 1},
                ],
                "unsupported": UNSUPPORTED,
            },
        )

    def test_each_kind_of_bill_says_how_many_billers_each_country_has(self):
        more = nigeria()
        more["bills"]["billers"].append(biller(6, name="كهرباء أبوجا", name_en="Abuja Electricity"))
        more["bills"]["billers"].append(
            biller(7, name="مياه لاغوس", name_en="Lagos Water", kind="water")
        )
        self.republish(
            services_directory(version="d2", countries=[mali(), more, niger(), senegal()])
        )
        kinds = {row["type"]: row for row in self.get(f"{BASE}/directory/")["bill_types"]}
        self.assertEqual(
            kinds["electricity"],
            {
                "type": "electricity",
                "countries": ["NG", "SN"],
                "counts": {"NG": 2, "SN": 1},
                "billers": 3,
            },
        )
        self.assertEqual(kinds["water"]["counts"], {"NG": 1, "SN": 1})
        self.assertEqual(kinds["water"]["billers"], 2)
        # The counts say what the countries add up to, so the till reads no country.
        for row in kinds.values():
            self.assertEqual(sum(row["counts"].values()), row["billers"])
            self.assertEqual(list(row["counts"]), row["countries"])

    def test_tolls_and_the_catch_all_are_in_no_count(self):
        # Nigeria has three billers in the mirror and one on the till.
        nigeria_row = next(
            row for row in self.get(f"{BASE}/directory/")["countries"] if row["code"] == "NG"
        )
        self.assertEqual(nigeria_row["bills"], 1)
        payload = self.get(f"{BASE}/countries/NG/")
        self.assertEqual([b["id"] for b in payload["bills"]["billers"]], [5])

    def test_the_search_finds_a_country_by_its_latin_name_too(self):
        named = mali()
        named["name_en"] = "Mali"
        self.republish(services_directory(version="d2", countries=[named, niger()]))
        by_code = {row["code"]: row for row in self.get(f"{BASE}/directory/")["countries"]}
        self.assertEqual((by_code["ML"]["name"], by_code["ML"]["name_en"]), ("مالي", "Mali"))

    def test_the_directory_says_why_when_nothing_can_be_sold(self):
        def reason():
            return self.get(f"{BASE}/directory/")

        # The relay has no rate to price by.
        self.republish(services_directory(version="d2", priced=False))
        answer = reason()
        self.assertEqual((answer["available"], answer["error_code"]), (False, "rate_unset"))
        self.assertEqual((answer["countries"], answer["balance"]), ([], "100.00"))
        # The relay is not set up at all.
        self.republish(services_directory(version="d3", configured=False, countries=[]))
        self.assertEqual(reason()["error_code"], ERROR_UNAVAILABLE)
        # Back.
        self.republish(services_directory(version="d4"))
        self.assertTrue(reason()["available"])
        # An older relay.
        self.relay.directory_error = RelayControlError(
            "404", status_code=404, body='{"error": "not found"}', request_sent=True
        )
        self.sync_services()
        self.assertEqual(reason()["error_code"], ERROR_UNAVAILABLE)
        self.relay.directory_error = None
        self.sync_services()
        self.assertTrue(reason()["available"])
        # The operator's off switch.
        RelayInstallation.objects.update(integrations_disabled=["pointy"])
        answer = reason()
        self.assertEqual(
            (answer["available"], answer["error_code"], answer["countries"]),
            (False, "switched_off", []),
        )
        RelayInstallation.objects.update(integrations_disabled=[])
        # Not switched on, or not linked.
        IntegrationAccount.objects.filter(pk=self.account.pk).update(is_active=False)
        self.assertEqual(reason()["error_code"], "not_configured")
        IntegrationAccount.objects.filter(pk=self.account.pk).update(is_active=True)
        RelayInstallation.objects.all().delete()
        self.assertEqual(reason()["error_code"], "not_configured")

    def test_a_shop_that_never_synced_has_nothing_to_sell(self):
        IntegrationAccount.objects.filter(pk=self.account.pk).update(config={})
        answer = self.get(f"{BASE}/directory/")
        self.assertEqual((answer["available"], answer["error_code"]), (False, ERROR_UNAVAILABLE))

    def test_reading_never_calls_the_relay(self):
        calls = len(self.relay.directory_etags)
        self.get(f"{BASE}/directory/")
        self.get(f"{BASE}/countries/ML/")
        self.get(f"{BASE}/countries/SN/", self.manager)
        self.get(f"{BASE}/flags/?codes=ML,NE")
        self.get(f"{BASE}/recent/?kind=airtime")
        self.get("/api/integrations/vouchers/menu/")
        self.assertEqual(len(self.relay.directory_etags), calls)
        self.assertEqual((self.relay.detects, self.relay.quotes, self.relay.orders), ([], [], []))

    def test_the_directory_and_a_country_cost_the_same_queries_with_more_countries(self):
        from django.db import connection
        from django.test.utils import CaptureQueriesContext

        def measure():
            self.get(f"{BASE}/directory/")
            self.get(f"{BASE}/countries/ML/")
            with CaptureQueriesContext(connection) as queries:
                self.get(f"{BASE}/directory/")
                self.get(f"{BASE}/countries/ML/")
            return len(queries.captured_queries)

        small = measure()
        many = [
            country(
                f"C{index:02d}",
                f"بلد {index}",
                [str(300 + index)],
                "XOF",
                "فرنك أفريقي",
                operators=[operator(2000 + index)],
            )
            for index in range(40)
        ]
        self.republish(services_directory(version="d2", countries=[niger(), mali(), *many]))
        self.assertEqual(measure(), small)

    def test_nobody_without_the_till_permission_reads_any_of_it(self):
        stranger = get_user_model().objects.create_user(username="nobody", password="x")
        self.client.force_authenticate(stranger)
        for path in (
            f"{BASE}/directory/",
            f"{BASE}/countries/ML/",
            f"{BASE}/flags/?codes=ML",
            f"{BASE}/recent/",
        ):
            with self.subTest(path=path):
                self.assertEqual(self.client.get(path).status_code, 403)
        for path in (f"{BASE}/quote/", f"{BASE}/detect/"):
            with self.subTest(path=path):
                self.assertEqual(
                    self.client.post(path, {"kind": "airtime"}, format="json").status_code, 403
                )
        self.client.force_authenticate(None)
        self.assertIn(self.client.get(f"{BASE}/directory/").status_code, (401, 403))


# --- one country --------------------------------------------------------------------------------------
class ServicesCountryApiTests(ServicesApiMixin, TestCase):
    def test_a_country_carries_its_networks_priced_for_the_customer(self):
        data = self.get(f"{BASE}/countries/ML/")
        self.assertEqual(
            data["country"],
            {
                "code": "ML",
                "name": "مالي",
                "name_en": "",
                "dial": ["223"],
                "currency": "XOF",
                "currency_name": "فرنك أفريقي",
                "popular": 2,
            },
        )
        self.assertTrue(data["available"])
        orange, malitel = data["airtime"]["operators"]
        # The relay's rows, names in both spellings, with the customer's price in
        # the place of the relay's suggestion and the shop's cost nowhere.
        self.assertEqual(
            orange,
            {
                "id": 289,
                "name": "أورنج مالي",
                "name_en": "Orange Mali",
                "logo": f"http://testserver/api/integrations/services/logos/{logo_ref(289)[7:]}/",
                "mode": "range",
                "amount_currency": "XOF",
                "receive_currency": "XOF",
                "approximate": False,
                "min": "1967",
                "max": "32800",
                "amounts": [
                    {
                        "amount": "2500",
                        "receive": "2500",
                        "receive_currency": "XOF",
                        "price": "48.50",
                        "exceeds_float": False,
                    },
                    {
                        "amount": "5000",
                        "receive": "5000",
                        "receive_currency": "XOF",
                        "price": "96.50",
                        "exceeds_float": False,
                    },
                ],
                "popular_amount": "5000",
            },
        )
        self.assertEqual(malitel["mode"], "fixed")
        self.assertEqual([a["amount"] for a in malitel["amounts"]], ["1000", "2000"])
        self.assertNotIn("unit_price", json.dumps(data))
        self.assertNotIn("retail_price", json.dumps(data))
        self.assertNotIn("cost", json.dumps(data))
        tv = data["bills"]["billers"][0]
        self.assertEqual(
            (tv["id"], tv["type"], tv["service"], tv["mode"], tv["requires_invoice"]),
            (30, "tv", "prepaid", "fixed", False),
        )
        self.assertEqual(
            tv["plans"],
            [
                {
                    "id": 2,
                    "amount": "10000",
                    "description": "كانال بلس أكسيس إنجليش بيسك – شهر",
                    "description_en": "Canalplus Acces English Basic (10000/1MOIS)",
                    "price": "195.00",
                    "exceeds_float": True,
                }
            ],
        )

    def test_an_operators_logo_is_the_shops_own_copy_never_a_supplier_address(self):
        data = self.get(f"{BASE}/countries/ML/")
        orange, malitel = data["airtime"]["operators"]
        digest = logo_ref(289)[7:]
        self.assertEqual(
            orange["logo"], f"http://testserver/api/integrations/services/logos/{digest}/"
        )
        # Malitel's picture never came from the relay: no logo, not a link elsewhere.
        self.assertEqual(malitel["logo"], "")
        self.assertNotIn("amazonaws", json.dumps(data))
        # A till's image cache fetches it with no login; the bytes are the PNG we kept.
        anonymous = APIClient().get(f"/api/integrations/services/logos/{digest}/")
        self.assertEqual(anonymous.status_code, 200)
        self.assertEqual(anonymous["Content-Type"], "image/png")
        self.assertEqual(Image.open(io.BytesIO(anonymous.content)).format, "PNG")
        self.assertEqual(APIClient().get("/api/integrations/services/logos/zz/").status_code, 404)
        self.assertEqual(
            APIClient().get(f"/api/integrations/services/logos/{'0' * 64}/").status_code, 404
        )

    def test_the_shops_cost_is_the_reporting_roles_figure(self):
        cashier = self.get(f"{BASE}/countries/ML/")
        manager = self.get(f"{BASE}/countries/ML/", self.manager)
        self.assertNotIn('"cost"', json.dumps(cashier))
        amounts = manager["airtime"]["operators"][0]["amounts"]
        self.assertEqual([a["cost"] for a in amounts], ["46.00", "91.30"])
        self.assertEqual(manager["bills"]["billers"][0]["plans"][0]["cost"], "184.00")
        # What a cashier is told is whether the float covers it, which both are.
        self.assertTrue(all("exceeds_float" in a for a in amounts))

    def test_the_customer_never_pays_less_than_it_costs_the_shop(self):
        loss = mali()
        loss["airtime"]["operators"][0]["amounts"] = [amount("5000", "91.30", "80.00")]
        self.republish(services_directory(version="d2", countries=[loss]))
        amounts = self.get(f"{BASE}/countries/ML/")["airtime"]["operators"][0]["amounts"]
        self.assertEqual(amounts[0]["price"], "91.30")

    def test_a_float_that_cannot_pay_is_flagged(self):
        IntegrationAccount.objects.filter(pk=self.account.pk).update(balance=Decimal("47.00"))
        amounts = self.get(f"{BASE}/countries/ML/")["airtime"]["operators"][0]["amounts"]
        self.assertEqual([a["exceeds_float"] for a in amounts], [False, True])
        IntegrationAccount.objects.filter(pk=self.account.pk).update(balance=None)
        amounts = self.get(f"{BASE}/countries/ML/")["airtime"]["operators"][0]["amounts"]
        self.assertEqual(
            [a["exceeds_float"] for a in amounts], [False, False], "no figure, no warning"
        )

    def test_a_directory_that_was_not_priced_has_no_prices_to_show(self):
        unpriced = mali()
        for row in unpriced["airtime"]["operators"]:
            for entry in row["amounts"]:
                del entry["unit_price"], entry["retail_price"]
        self.republish(services_directory(version="d2", countries=[unpriced], priced=False))
        data = self.get(f"{BASE}/countries/ML/")
        self.assertEqual(
            (data["available"], data["error_code"], data["country"]), (False, "rate_unset", None)
        )

    def test_the_billers_that_need_an_invoice_say_so(self):
        billers = self.get(f"{BASE}/countries/SN/")["bills"]["billers"]
        self.assertEqual(
            {b["id"]: (b["type"], b["service"], b["requires_invoice"]) for b in billers},
            {24: ("water", "postpaid", True), 25: ("electricity", "postpaid", True)},
        )
        self.assertNotIn("airtime", self.get(f"{BASE}/countries/SN/"))
        self.assertNotIn("bills", self.get(f"{BASE}/countries/NE/"))

    def test_an_unknown_country_is_not_found_and_a_lowercase_code_is_fine(self):
        self.client.force_authenticate(self.cashier)
        self.assertEqual(self.client.get(f"{BASE}/countries/ZZ/").status_code, 404)
        self.assertEqual(self.get(f"{BASE}/countries/ml/")["country"]["code"], "ML")

    def test_a_country_the_shop_cannot_sell_to_says_why(self):
        RelayInstallation.objects.update(integrations_disabled=["pointy"])
        data = self.get(f"{BASE}/countries/ML/")
        self.assertEqual(
            data,
            {"available": False, "error_code": "switched_off", "test_mode": False, "country": None},
        )


# --- the flags ----------------------------------------------------------------------------------------------
class ServicesFlagsApiTests(ServicesApiMixin, TestCase):
    def test_flags_come_inline_for_the_codes_asked_unknown_ones_omitted(self):
        data = self.get(f"{BASE}/flags/?codes=ml,NE,ZZ,SN,ml")
        self.assertEqual(sorted(data["flags"]), ["ML", "NE"], "SN has none, ZZ is no country")
        picture = Image.open(io.BytesIO(base64.b64decode(data["flags"]["ML"])))
        self.assertEqual(picture.format, "PNG")
        self.assertLessEqual(max(picture.size), 96)

    def test_at_most_forty_codes_at_a_time(self):
        forty = ",".join(f"C{index:02d}" for index in range(40))
        self.assertEqual(self.get(f"{BASE}/flags/?codes={forty}"), {"flags": {}})
        self.client.force_authenticate(self.cashier)
        response = self.client.get(f"{BASE}/flags/?codes={forty},ML")
        self.assertEqual(response.status_code, 400)

    def test_no_codes_no_flags(self):
        self.assertEqual(self.get(f"{BASE}/flags/"), {"flags": {}})
        self.assertEqual(self.get(f"{BASE}/flags/?codes=,,"), {"flags": {}})

    def test_a_switched_off_shop_serves_none(self):
        RelayInstallation.objects.update(integrations_disabled=["pointy"])
        self.assertEqual(self.get(f"{BASE}/flags/?codes=ML"), {"flags": {}})


# --- the menu's service cards --------------------------------------------------------------------------------
class ServicesMenuTests(ServicesApiMixin, TestCase):
    def menu(self, user=None):
        return self.get("/api/integrations/vouchers/menu/", user)

    def variant(self, kind):
        return ProductVariant.objects.get(sku=f"INTEG-POINTY-{kind.upper()}").pk

    def test_one_card_per_service_the_shop_can_sell(self):
        services = self.menu()["services"]
        airtime, bill = self.variant("airtime"), self.variant("bill")
        self.assertEqual(
            services,
            [
                {
                    "key": "airtime",
                    "kind": "airtime",
                    "available": True,
                    "variant_id": airtime,
                    "countries": 3,
                    "providers": 4,
                    "test_mode": False,
                },
                {
                    "key": "bill:electricity",
                    "kind": "bill",
                    "bill_type": "electricity",
                    "available": True,
                    "variant_id": bill,
                    "countries": 2,
                    "providers": 2,
                    "test_mode": False,
                },
                {
                    "key": "bill:water",
                    "kind": "bill",
                    "bill_type": "water",
                    "available": True,
                    "variant_id": bill,
                    "countries": 1,
                    "providers": 1,
                    "test_mode": False,
                },
                {
                    "key": "bill:tv",
                    "kind": "bill",
                    "bill_type": "tv",
                    "available": True,
                    "variant_id": bill,
                    "countries": 1,
                    "providers": 1,
                    "test_mode": False,
                },
            ],
        )
        self.assertNotEqual(
            airtime, bill, "two service products, whatever the country or the biller"
        )

    def test_a_sandbox_relay_says_so_on_every_screen_that_sells(self):
        for typed in (self.cashier, self.manager):
            menu = self.menu(typed)
            self.assertFalse(menu["test_mode"])
            self.assertFalse(any(card["test_mode"] for card in menu["services"]))
        self.republish(services_directory(version="d2", test_mode=True))
        for typed in (self.cashier, self.manager):
            menu = self.menu(typed)
            self.assertTrue(menu["test_mode"], "the menu's top level")
            self.assertTrue(menu["services"])
            self.assertTrue(all(card["test_mode"] is True for card in menu["services"]))
        self.assertTrue(self.get(f"{BASE}/directory/")["test_mode"])
        self.assertTrue(self.get(f"{BASE}/countries/ML/")["test_mode"])
        # And back, the day the relay buys for real.
        self.republish(services_directory(version="d3", test_mode=False))
        self.assertFalse(self.menu()["test_mode"])
        self.assertFalse(self.get(f"{BASE}/directory/")["test_mode"])
        self.assertFalse(self.get(f"{BASE}/countries/ML/")["test_mode"])
        self.assertFalse(any(card["test_mode"] for card in self.menu()["services"]))

    def test_a_sandbox_is_said_even_when_the_rate_is_missing(self):
        self.republish(services_directory(version="d2", test_mode=True, priced=False))
        self.assertTrue(self.get(f"{BASE}/directory/")["test_mode"])
        self.assertTrue(self.get(f"{BASE}/countries/ML/")["test_mode"])
        self.assertTrue(self.menu()["test_mode"])

    def test_the_cards_have_keys_only_never_names(self):
        for card in self.menu()["services"]:
            self.assertEqual(
                set(card) - {"bill_type"},
                {"key", "kind", "available", "variant_id", "countries", "providers", "test_mode"},
            )

    def test_a_card_with_nothing_behind_it_is_not_listed(self):
        # Mali alone: its airtime and a TV biller, no electricity, no water.
        self.republish(services_directory(version="d2", countries=[mali()]))
        keys = [card["key"] for card in self.menu()["services"]]
        self.assertEqual(keys, ["airtime", "bill:tv"])
        # No networks anywhere: no airtime card.
        bills_only = [senegal()]
        self.republish(services_directory(version="d3", countries=bills_only))
        self.assertEqual(
            [card["key"] for card in self.menu()["services"]], ["bill:electricity", "bill:water"]
        )

    def test_only_the_offered_kinds_of_bill_make_a_card(self):
        tolls = country(
            "KE",
            "كينيا",
            ["254"],
            "KES",
            "شلن كيني",
            billers=[
                {
                    **nigeria()["bills"]["billers"][1],
                    "id": 700,
                    "amount_currency": "KES",
                }
            ],
        )
        self.republish(services_directory(version="d2", countries=[tolls, mali()]))
        keys = [card["key"] for card in self.menu()["services"]]
        self.assertEqual(keys, ["airtime", "bill:tv"], "a toll biller makes no card")

    def test_nothing_is_listed_when_the_services_cannot_be_sold(self):
        self.republish(services_directory(version="d2", priced=False))
        self.assertEqual(self.menu()["services"], [])
        self.republish(services_directory(version="d3"))
        self.assertTrue(self.menu()["services"])
        RelayInstallation.objects.update(integrations_disabled=["pointy"])
        data = self.menu()
        self.assertEqual((data["available"], data["services"]), (False, []))
        RelayInstallation.objects.update(integrations_disabled=[])
        RelayInstallation.objects.all().delete()
        self.assertEqual(self.menu()["services"], [])

    def test_the_services_do_not_depend_on_the_cards(self):
        # A relay with no card wholesaler set up still sells top-ups and bills.
        self.account.refresh_from_db()
        IntegrationAccount.objects.filter(pk=self.account.pk).update(
            config={**self.account.config, vouchers.CONFIG_LISTING_ERROR: ERROR_UNAVAILABLE}
        )
        data = self.menu()
        # A menu with no brands, not an unavailable one.
        self.assertEqual((data["available"], data["error_code"], data["brands"]), (True, "", []))
        self.assertEqual(len(data["services"]), 4)
        # With nothing to sell at all it is unavailable, as ever.
        self.republish(services_directory(version="d2", priced=False))
        data = self.menu()
        self.assertEqual((data["available"], data["error_code"]), (False, ERROR_UNAVAILABLE))
        self.assertEqual(data["services"], [])

    def test_the_menu_costs_the_same_queries_with_more_countries(self):
        from django.db import connection
        from django.test.utils import CaptureQueriesContext

        self.menu()  # warm whatever is cached per process
        with CaptureQueriesContext(connection) as small:
            self.menu()
        many = [
            country(
                f"C{index:02d}",
                f"بلد {index}",
                [str(300 + index)],
                "XOF",
                "فرنك أفريقي",
                operators=[operator(2000 + index)],
            )
            for index in range(30)
        ]
        self.republish(services_directory(version="d2", countries=[niger(), mali(), *many]))
        with CaptureQueriesContext(connection) as large:
            data = self.menu()
        self.assertEqual(data["services"][0]["countries"], 32)
        self.assertEqual(len(large.captured_queries), len(small.captured_queries))


# --- which network is this number ----------------------------------------------------------------------------------
class ServicesDetectApiTests(ServicesApiMixin, TestCase):
    def detect(self, phone="70123456", country="ML", user=None):
        """Asked the way the till asks: the number in the body, never in the address."""
        return self.post(f"{BASE}/detect/", {"country": country, "phone": phone}, user)

    def test_a_number_is_placed_on_its_network_with_prices_like_the_country_screen(self):
        data = self.detect()
        self.assertEqual((data["detected"], data["reason"]), (True, ""))
        self.assertEqual(
            data["phone"], {"e164": "+22370123456", "national": "70123456", "country": "ML"}
        )
        operator_row = data["operator"]
        self.assertEqual((operator_row["id"], operator_row["name"]), (289, "أورنج مالي"))
        self.assertEqual(operator_row["name_en"], "Orange Mali")
        self.assertEqual(operator_row["amounts"][1]["price"], "96.50")
        self.assertNotIn("cost", json.dumps(data))
        self.assertEqual(self.relay.detects, [("ML", "70123456")])
        manager = self.detect(user=self.manager)
        self.assertEqual(manager["operator"]["amounts"][1]["cost"], "91.30")

    def test_the_relays_none_found_and_not_a_number_are_answers(self):
        self.relay.detect_answer = refusal(404, "operator_not_detected")
        self.assertEqual(
            self.detect(),
            {"detected": False, "reason": "not_detected", "operator": None, "phone": None},
        )
        self.relay.detect_answer = refusal(422, "invalid_phone")
        self.assertEqual(self.detect()["reason"], "invalid_phone")

    def test_a_number_that_cannot_be_one_is_not_even_asked_about(self):
        for phone in ("abc", "7", "70123456789012345678901234567890123", "7012;3456"):
            with self.subTest(phone=phone):
                self.assertEqual(self.detect(phone)["reason"], "invalid_phone")
        self.assertEqual(self.detect("70123456", country="x")["reason"], "not_detected")
        self.assertEqual(self.relay.detects, [])

    def test_arabic_digits_and_decoration_reach_the_relay_as_digits(self):
        self.detect("٧٠ ١٢ ٣٤ ٥٦")
        self.detect("+223 70 12 34 56")
        self.assertEqual(self.relay.detects, [("ML", "70 12 34 56"), ("ML", "+223 70 12 34 56")])

    def test_a_number_is_a_string_or_a_number_in_the_body(self):
        self.detect(70123456)
        self.assertEqual(self.relay.detects, [("ML", "70123456")])

    def test_a_relay_that_cannot_be_asked_is_unavailable_not_an_error(self):
        faults = {
            "unreachable": RelayControlError("down", request_sent=False),
            "reloadly down": refusal(503, "reloadly_unreachable"),
            "no route": RelayControlError("404", status_code=404, body='{"error": "not found"}'),
            "unreadable": {"nothing": "useful"},
        }
        for name, answer in faults.items():
            with self.subTest(name):
                self.relay.detect_answer = answer
                data = self.detect()
                self.assertEqual((data["detected"], data["reason"]), (False, "unavailable"))
        self.relay.detect_answer = refusal(401, "unauthorized")
        self.assertEqual(self.detect()["reason"], "not_configured")

    def test_a_shop_that_cannot_sell_is_told_why(self):
        RelayInstallation.objects.update(integrations_disabled=["pointy"])
        self.assertEqual(self.detect()["reason"], "switched_off")
        RelayInstallation.objects.update(integrations_disabled=[])
        self.republish(services_directory(version="d2", priced=False))
        self.assertEqual(self.detect()["reason"], "unavailable")
        RelayInstallation.objects.all().delete()
        self.assertEqual(self.detect()["reason"], "not_configured")
        self.assertEqual(self.relay.detects, [])

    def test_the_request_must_name_a_country_and_a_number(self):
        self.client.force_authenticate(self.cashier)
        for body in ({}, {"country": "ML"}, {"phone": "70123456"}, {"country": "", "phone": "7"}):
            with self.subTest(body=body):
                self.assertEqual(
                    self.client.post(f"{BASE}/detect/", body, format="json").status_code, 400
                )
        self.assertEqual(self.relay.detects, [])

    def test_a_number_in_the_address_is_not_a_request(self):
        # The number belongs in the body: the address would reach every access log.
        self.client.force_authenticate(self.cashier)
        self.assertIn(
            self.client.get(f"{BASE}/detect/?country=ML&phone=70123456").status_code,
            (403, 405),
            "there is no GET any more",
        )
        self.assertEqual(
            self.client.post(
                f"{BASE}/detect/?country=ML&phone=70123456", {}, format="json"
            ).status_code,
            400,
            "the query string is not read",
        )
        self.assertEqual(self.relay.detects, [])

    def test_only_a_till_may_ask(self):
        stranger = get_user_model().objects.create_user(username="nobody", password="x")
        self.client.force_authenticate(stranger)
        body = {"country": "ML", "phone": "70123456"}
        self.assertEqual(self.client.post(f"{BASE}/detect/", body, format="json").status_code, 403)
        self.assertEqual(self.relay.detects, [])


# --- what exactly does it cost -----------------------------------------------------------------------------------------
class ServicesQuoteApiTests(ServicesApiMixin, TestCase):
    def service_variant(self, kind):
        return ProductVariant.objects.get(sku=f"INTEG-POINTY-{kind.upper()}").pk

    def test_an_airtime_quote_is_priced_labelled_in_arabic_and_sealed(self):
        data = self.quote()
        token = data.pop("quote")
        self.assertEqual(
            data,
            {
                "ok": True,
                "kind": "airtime",
                "option_code": "air:289:5000:XOF",
                "option_label": "أورنج مالي · 5,000 فرنك أفريقي",
                "subscriber_ref": "+22370123456",
                "price": "96.50",
                "receive": {"amount": "5000", "currency": "XOF"},
                "approximate": False,
                "service_variant_id": self.service_variant("airtime"),
                "exceeds_float": False,
            },
        )
        # The relay was asked exactly this: the network, the amount and the number
        # as it was typed, with its country, for the relay to read.
        self.assertEqual(
            self.relay.quotes,
            [
                {
                    "kind": "airtime",
                    "operator_id": 289,
                    "amount": "5000",
                    "amount_currency": "XOF",
                    "country": "ML",
                    "phone": "70123456",
                }
            ],
        )
        # What the token holds, only the server can read.
        self.assertEqual(
            quotes.open_priced_quote(
                token,
                account=self.account,
                subscriber_ref="+22370123456",
                option_code="air:289:5000:XOF",
            ),
            (Decimal("91.30"), Decimal("96.50")),
        )
        self.assertNotIn("91.30", token)

    def test_the_shops_cost_goes_to_the_reporting_roles_only(self):
        cashier = self.quote()
        manager = self.quote(user=self.manager)
        self.assertNotIn("cost", cashier)
        self.assertEqual(manager["cost"], "91.30")
        self.assertEqual({key for key in manager} - {key for key in cashier}, {"cost"})
        self.assertIn("exceeds_float", cashier)

    def test_the_float_that_cannot_pay_is_flagged_but_the_quote_stands(self):
        IntegrationAccount.objects.filter(pk=self.account.pk).update(balance=Decimal("50.00"))
        data = self.quote()
        self.assertTrue(data["ok"])
        self.assertTrue(data["exceeds_float"])

    def test_the_customer_is_never_asked_for_less_than_it_costs(self):
        self.relay.quote_answer = relay_quote(cost="91.30", retail="80.00")
        data = self.quote()
        self.assertEqual(data["price"], "91.30")
        self.relay.quote_answer = relay_quote(cost="91.30", retail=None)
        data = self.quote()
        self.assertEqual(data["price"], "91.30", "a relay that priced only the cost")
        self.assertEqual(
            quotes.open_priced_quote(
                data["quote"],
                account=self.account,
                subscriber_ref="+22370123456",
                option_code="air:289:5000:XOF",
            ),
            (Decimal("91.30"), Decimal("91.30")),
        )

    def test_the_shops_markup_applies_when_the_relay_gives_no_price_of_its_own(self):
        IntegrationAccount.objects.filter(pk=self.account.pk).update(
            markup_kind=IntegrationAccount.Markup.PERCENT, markup_value=Decimal("10")
        )
        self.relay.quote_answer = relay_quote(cost="91.30", retail=None)
        self.assertEqual(self.quote()["price"], "100.43")

    def test_an_approximate_conversion_is_marked(self):
        self.relay.quote_answer = {
            "quote": {
                **relay_quote()["quote"],
                "approximate": True,
                "receive": {"amount": "8.2", "currency": "USD"},
            }
        }
        data = self.quote()
        self.assertTrue(data["approximate"])
        self.assertEqual(data["receive"], {"amount": "8.2", "currency": "USD"})

    def test_the_number_may_be_typed_any_way_a_cashier_would(self):
        for typed, sent in (
            ("70123456", "70123456"),
            ("070123456", "070123456"),
            ("70 12 34 56", "70 12 34 56"),
            ("+223 70 12 34 56", "+223 70 12 34 56"),
            ("00223 70123456", "00223 70123456"),
            ("٧٠١٢٣٤٥٦", "70123456"),
        ):
            with self.subTest(typed=typed):
                self.assertEqual(self.quote(phone=typed)["subscriber_ref"], "+22370123456")
                self.assertEqual(self.relay.quotes[-1]["phone"], sent, "sent as it was typed")

    def test_the_number_sold_is_the_one_the_relay_read_never_the_shops_own_reading(self):
        # The numbers whose trunk zero stays (Côte d'Ivoire, Benin) or goes
        # (Nigeria, Egypt, Mali) — the relay's ParsePhone knows which; the shop,
        # which once dropped one zero from every number, does not pretend to.
        countries = [
            country(
                code,
                name,
                [dial],
                currency,
                currency_name,
                operators=[
                    operator(oid, name_en=en, amount_currency=currency, receive_currency=currency)
                ],
            )
            for code, name, dial, currency, currency_name, oid, en in (
                ("CI", "ساحل العاج", "225", "XOF", "فرنك أفريقي", 701, "Orange CI"),
                ("BJ", "بنين", "229", "XOF", "فرنك أفريقي", 702, "MTN Benin"),
                ("EG", "مصر", "20", "EGP", "جنيه مصري", 703, "Vodafone Egypt"),
            )
        ]
        self.republish(
            services_directory(version="d2", countries=[mali(), nigeria(), senegal(), *countries])
        )
        cases = (
            # country, operator, typed, what the relay reads it as
            ("CI", 701, "XOF", "0707123456", "+2250707123456"),
            ("CI", 701, "XOF", "+225 07 07 12 34 56", "+2250707123456"),
            ("BJ", 702, "XOF", "0197123456", "+2290197123456"),
            ("NG", 5, "NGN", "08031234567", "+2348031234567"),
            ("ML", 289, "XOF", "22370123456", "+22370123456"),
            ("EG", 703, "EGP", "01012345678", "+201012345678"),
        )
        for code, operator_id, currency, typed, e164 in cases:
            with self.subTest(code=code, typed=typed):
                self.relay.quote_answer = lambda payload, e164=e164, code=code: {
                    **relay_quote(currency=payload["amount_currency"]),
                    "phone": {"e164": e164, "national": e164[4:], "country": code},
                }
                data = self.quote(
                    country=code,
                    operator_id=operator_id,
                    phone=typed,
                    amount_currency=currency,
                    amount="2000" if code == "ML" else "1000",
                )
                self.assertEqual(data["subscriber_ref"], e164)
                self.assertEqual(
                    quotes.open_priced_quote(
                        data["quote"],
                        account=self.account,
                        subscriber_ref=e164,
                        option_code=data["option_code"],
                    )[0],
                    Decimal("91.30"),
                )
                self.assertEqual(
                    (self.relay.quotes[-1]["country"], self.relay.quotes[-1]["phone"]),
                    (code, typed),
                )

    def test_a_number_the_relay_refuses_is_refused_with_the_same_word(self):
        self.relay.quote_answer = refusal(422, "invalid_phone")
        self.assertEqual(self.quote(), {"ok": False, "error_code": "invalid_phone"})
        self.relay.quote_answer = relay_quote()
        # A relay that does not say which number it read has not read it: nothing is
        # sealed, sold or guessed at.
        self.relay.reads_numbers = False
        data = self.quote()
        self.assertEqual(
            (data["ok"], data["error_code"], data["reason"]),
            (False, "service_unavailable", "unreadable_answer"),
        )
        self.assertNotIn("quote", data)

    def test_an_amount_may_be_typed_any_way_too(self):
        for typed in ("5000", "5000.00", " 5000 ", 5000, "5e3"):
            with self.subTest(typed=typed):
                self.assertEqual(self.quote(amount=typed)["option_code"], "air:289:5000:XOF")
        self.assertEqual(self.relay.quotes[-1]["amount"], "5000")

    def test_a_bill_is_quoted_by_its_biller_and_its_account(self):
        self.relay.quote_answer = relay_quote(
            kind="bill", cost="26.00", retail="27.50", amount="5000", currency="NGN"
        )
        data = self.quote(kind="bill", account="0422 3568 280")
        token = data.pop("quote")
        self.assertEqual(
            data,
            {
                "ok": True,
                "kind": "bill",
                "option_code": "bill:5:5000:NGN",
                "option_label": "كهرباء إيكيجا (مسبقة الدفع) · 5,000 نيرة نيجيرية",
                "subscriber_ref": "04223568280",
                "price": "27.50",
                "receive": {"amount": "5000", "currency": "NGN"},
                "approximate": False,
                "service_variant_id": self.service_variant("bill"),
                "exceeds_float": False,
            },
        )
        self.assertEqual(
            self.relay.quotes[-1],
            {
                "kind": "bill",
                "biller_id": 5,
                "amount": "5000",
                "amount_currency": "NGN",
                "amount_id": None,
            },
        )
        self.assertEqual(
            quotes.open_priced_quote(
                token,
                account=self.account,
                subscriber_ref="04223568280",
                option_code="bill:5:5000:NGN",
            ),
            (Decimal("26.00"), Decimal("27.50")),
        )

    def test_a_fixed_plan_is_named_by_its_own_description(self):
        self.relay.quote_answer = relay_quote(
            kind="bill", cost="184.00", retail="195.00", amount="10000", currency="XOF"
        )
        data = self.quote(
            kind="bill",
            country="ML",
            biller_id=30,
            account="5550011",
            amount="10000",
            amount_currency="XOF",
            amount_id=2,
        )
        self.assertEqual(data["option_code"], "bill:30:10000:XOF:2")
        self.assertEqual(
            data["option_label"],
            "تلفزيون · كانال بلس أكسيس إنجليش بيسك – شهر · 10,000 فرنك أفريقي",
        )
        self.assertEqual(self.relay.quotes[-1]["amount_id"], 2)
        self.assertTrue(data["exceeds_float"], "184 is more than the 100 in the float")

    def test_a_fixed_biller_sells_its_plans_and_only_their_amounts(self):
        body = dict(
            kind="bill", country="ML", biller_id=30, account="5550011", amount_currency="XOF"
        )
        for extra in (
            dict(amount="10000"),  # no plan named
            dict(amount="10000", amount_id=9),  # no such plan
            dict(amount="9000", amount_id=2),  # not that plan's amount
        ):
            with self.subTest(extra=extra):
                self.assertEqual(
                    self.quote(**body, **extra), {"ok": False, "error_code": "amount_not_offered"}
                )
        self.assertEqual(self.relay.quotes, [], "the relay was not asked")

    def test_a_plan_is_for_billers_that_have_them(self):
        refused = self.quote(kind="bill", amount_id=2)
        self.assertEqual(refused, {"ok": False, "error_code": "amount_not_offered"})
        refused = self.quote(amount_id=2)
        self.assertEqual(refused, {"ok": False, "error_code": "amount_not_offered"})

    def test_a_biller_that_needs_an_invoice_asks_for_it_and_carries_it(self):
        body = dict(
            kind="bill",
            country="SN",
            biller_id=24,
            account="77123456",
            amount="15000",
            amount_currency="XOF",
        )
        self.relay.quote_answer = relay_quote(
            kind="bill", cost="270.00", retail="285.00", amount="15000", currency="XOF"
        )
        for invoice in (None, "", "  "):
            with self.subTest(invoice=invoice):
                self.assertEqual(
                    self.quote(**body, invoice_id=invoice),
                    {"ok": False, "error_code": "invoice_required"},
                )
        # Given, but not an invoice number: a refusal of its own.
        for invoice in ("a:b", "x" * 25, "ف١٢", "a b", "a/b?", "x" * 40):
            with self.subTest(invoice=invoice):
                self.assertEqual(
                    self.quote(**body, invoice_id=invoice),
                    {"ok": False, "error_code": "invalid_invoice"},
                )
        self.assertEqual(self.relay.quotes, [], "nothing is asked of the relay without it")
        data = self.quote(**body, invoice_id="2024-118833")
        self.assertTrue(data["ok"], data)
        self.assertEqual(data["option_code"], "bill:24:15000:XOF::2024-118833")
        self.assertEqual(data["subscriber_ref"], "77123456")
        # The name already says it is water.
        self.assertEqual(data["option_label"], "سن إيو (مياه) · 15,000 فرنك أفريقي")
        # The invoice is the option's, not the relay's quote's.
        self.assertNotIn("invoice_id", self.relay.quotes[-1])
        self.assertEqual(
            quotes.open_priced_quote(
                data["quote"],
                account=self.account,
                subscriber_ref="77123456",
                option_code="bill:24:15000:XOF::2024-118833",
            )[1],
            Decimal("285.00"),
        )

    def test_an_invoice_number_typed_on_an_arabic_keyboard_is_the_number_it_looks_like(self):
        self.relay.quote_answer = relay_quote(
            kind="bill", cost="270.00", retail="285.00", amount="15000", currency="XOF"
        )
        data = self.quote(
            kind="bill",
            country="SN",
            biller_id=24,
            account="77123456",
            amount="15000",
            amount_currency="XOF",
            invoice_id="٢٠٢٤-١١٨٨٣٣",
        )
        self.assertEqual(data["option_code"], "bill:24:15000:XOF::2024-118833")

    def test_a_biller_that_needs_none_ignores_one(self):
        self.relay.quote_answer = relay_quote(
            kind="bill", cost="26.00", retail="27.50", amount="5000", currency="NGN"
        )
        data = self.quote(kind="bill", invoice_id="2024-1")
        self.assertEqual(data["option_code"], "bill:5:5000:NGN")

    def test_what_the_shop_does_not_list_is_not_asked_about(self):
        cases = {
            "an operator that does not exist": (dict(operator_id=999999), "unknown_operator"),
            "another country's operator": (dict(country="NE", operator_id=289), "unknown_operator"),
            "an unknown country": (dict(country="ZZ"), "unknown_operator"),
            "a biller that does not exist": (dict(kind="bill", biller_id=424242), "unknown_biller"),
            "a toll": (dict(kind="bill", biller_id=98), "unknown_biller"),
            "the catch-all": (dict(kind="bill", biller_id=99), "unknown_biller"),
            "another country's biller": (dict(kind="bill", country="ML"), "unknown_biller"),
        }
        for name, (body, code) in cases.items():
            with self.subTest(name):
                self.assertEqual(self.quote(**body), {"ok": False, "error_code": code})
        self.assertEqual(self.relay.quotes, [])

    def test_what_is_plainly_no_number_is_refused_before_the_relay(self):
        for phone in ("", "abc", "12", "7012x456", None, "1" * 16):
            with self.subTest(phone=phone):
                self.assertEqual(
                    self.quote(phone=phone), {"ok": False, "error_code": "invalid_phone"}
                )
        self.assertEqual(self.relay.quotes, [])

    def test_a_number_of_another_country_is_the_relays_to_refuse(self):
        self.relay.quote_answer = lambda payload: refusal(422, "invalid_phone")
        self.assertEqual(
            self.quote(phone="+33 6 12 34 56 78"), {"ok": False, "error_code": "invalid_phone"}
        )
        self.assertEqual(self.relay.quotes[-1]["phone"], "+33 6 12 34 56 78")

    def test_an_amount_has_no_more_decimals_than_its_currency_has(self):
        # The CFA franc has no minor unit: whole numbers only, as the relay insists.
        for typed in ("5000.5", "2010.002", "1999.99", "0.5"):
            with self.subTest(typed=typed):
                self.assertEqual(
                    self.quote(amount=typed), {"ok": False, "error_code": "invalid_amount"}
                )
        self.assertEqual(self.quote(amount="5000.00")["option_code"], "air:289:5000:XOF")
        self.assertEqual(self.relay.quotes[-1]["amount"], "5000")
        # A bill in francs the same.
        self.relay.quote_answer = relay_quote(
            kind="bill", cost="270.00", retail="285.00", amount="15000", currency="XOF"
        )
        sn = dict(
            kind="bill", country="SN", biller_id=24, account="77123456", amount_currency="XOF"
        )
        self.assertEqual(
            self.quote(**sn, invoice_id="A1", amount="15000.5"),
            {"ok": False, "error_code": "invalid_amount"},
        )
        # Naira have kobo: two decimals, not three.
        self.relay.quote_answer = relay_quote(
            kind="bill", cost="26.00", retail="27.50", amount="5000", currency="NGN"
        )
        self.assertTrue(self.quote(kind="bill", amount="5000.55")["ok"])
        self.assertEqual(
            self.quote(kind="bill", amount="5000.555"),
            {"ok": False, "error_code": "invalid_amount"},
        )

    def test_an_amount_the_network_lists_itself_may_have_the_decimals_it_lists(self):
        pack = operator(
            801,
            name_en="Lonestar",
            mode="fixed",
            min=None,
            max=None,
            amount_currency="USD",
            receive_currency="USD",
            amounts=[amount("0.00123", "1.00", "1.10", currency="USD")],
        )
        self.republish(
            services_directory(
                version="d2",
                countries=[
                    mali(),
                    country("LR", "ليبيريا", ["231"], "LRD", "دولار ليبيري", operators=[pack]),
                ],
            )
        )
        body = dict(country="LR", operator_id=801, phone="770123456", amount_currency="USD")
        data = self.quote(**body, amount="0.00123")
        self.assertEqual(data["option_code"], "air:801:0.00123:USD")
        for typed in ("0.0012", "0.00124", "0.000001"):
            with self.subTest(typed=typed):
                self.assertEqual(
                    self.quote(**body, amount=typed), {"ok": False, "error_code": "invalid_amount"}
                )

    def test_an_account_that_cannot_be_one_is_refused_before_the_relay(self):
        for account in ("", "ab", "04:22", "x" * 41, "٠٤ ٢٢:٣", None, "---", "..", "-_-/", "a-b"):
            with self.subTest(account=account):
                self.assertEqual(
                    self.quote(kind="bill", account=account),
                    {"ok": False, "error_code": "invalid_account"},
                )
        self.assertEqual(self.relay.quotes, [])

    def test_a_meter_number_typed_on_an_arabic_keyboard_is_the_number_it_looks_like(self):
        self.relay.quote_answer = relay_quote(
            kind="bill", cost="26.00", retail="27.50", amount="5000", currency="NGN"
        )
        data = self.quote(kind="bill", account="٠٤٢٢ ٣٥٦٨ ٢٨٠")
        self.assertEqual(data["subscriber_ref"], "04223568280")

    def test_an_amount_that_cannot_be_one_is_refused_before_the_relay(self):
        for typed, currency in (("0", "XOF"), ("-5", "XOF"), ("abc", "XOF"), ("5000", "USD")):
            with self.subTest(amount=typed, currency=currency):
                self.assertEqual(
                    self.quote(amount=typed, amount_currency=currency),
                    {"ok": False, "error_code": "invalid_amount"},
                )
        self.assertEqual(self.relay.quotes, [])

    def test_the_relays_own_refusals_come_through_in_its_words(self):
        cases = [
            (
                refusal(422, "amount_out_of_range", min="1967", max="32800"),
                {"ok": False, "error_code": "amount_out_of_range", "min": "1967", "max": "32800"},
            ),
            (refusal(422, "amount_not_offered"), {"ok": False, "error_code": "amount_not_offered"}),
            (refusal(422, "invalid_amount"), {"ok": False, "error_code": "invalid_amount"}),
            (refusal(404, "unknown_operator"), {"ok": False, "error_code": "unknown_operator"}),
            (
                refusal(409, "service_unavailable", reason="supplier_down"),
                {"ok": False, "error_code": "service_unavailable", "reason": "supplier_down"},
            ),
            (
                refusal(409, "service_unavailable", reason="rate_unset"),
                {"ok": False, "error_code": "rate_unset"},
            ),
            (refusal(503, "services_unpriced"), {"ok": False, "error_code": "rate_unset"}),
        ]
        for answer, expected in cases:
            with self.subTest(expected=expected):
                self.relay.quote_answer = answer
                self.assertEqual(self.quote(), expected)

    def test_a_relay_that_cannot_be_asked_is_a_refusal_not_an_error(self):
        faults = {
            "unreachable": (
                RelayControlError("down", request_sent=False),
                {"error_code": "unreachable"},
            ),
            "a proxy's 502": (refusal(502), {"error_code": "unreachable"}),
            "refused token": (refusal(401, "unauthorized"), {"error_code": "not_configured"}),
            "no route": (
                RelayControlError("404", status_code=404, body='{"error": "not found"}'),
                {"error_code": "service_unavailable", "reason": "unsupported_relay"},
            ),
            "unreadable": (
                {"nothing": "useful"},
                {"error_code": "service_unavailable", "reason": "unreadable_answer"},
            ),
        }
        for name, (answer, expected) in faults.items():
            with self.subTest(name):
                self.relay.quote_answer = answer
                self.assertEqual(self.quote(), {"ok": False, **expected})

    def test_a_shop_that_cannot_sell_is_told_why(self):
        RelayInstallation.objects.update(integrations_disabled=["pointy"])
        self.assertEqual(self.quote(), {"ok": False, "error_code": "switched_off"})
        RelayInstallation.objects.update(integrations_disabled=[])
        self.republish(services_directory(version="d2", priced=False))
        self.assertEqual(self.quote(), {"ok": False, "error_code": "rate_unset"})
        self.republish(services_directory(version="d3", configured=False, countries=[]))
        self.assertEqual(
            self.quote(),
            {"ok": False, "error_code": "service_unavailable", "reason": "unavailable"},
        )
        RelayInstallation.objects.all().delete()
        self.assertEqual(self.quote(), {"ok": False, "error_code": "not_configured"})
        self.assertEqual(self.relay.quotes, [])

    def test_a_request_that_is_not_shaped_like_one_is_a_plain_400(self):
        self.client.force_authenticate(self.cashier)
        bad = [
            {},
            {"kind": "toll", "country": "ML", "amount": "5", "amount_currency": "XOF"},
            {"kind": "airtime", "country": "ML", "amount": "5", "amount_currency": "XOF"},
            {
                "kind": "bill",
                "country": "NG",
                "operator_id": 5,
                "amount": "5",
                "amount_currency": "NGN",
            },
            {
                "kind": "airtime",
                "country": "ML",
                "operator_id": "x",
                "amount": "5",
                "amount_currency": "XOF",
            },
            {"kind": "airtime", "country": "ML", "operator_id": 289, "amount_currency": "XOF"},
            {
                "kind": "airtime",
                "country": "ML",
                "operator_id": 289,
                "amount": "5",
                "amount_currency": "",
            },
        ]
        for body in bad:
            with self.subTest(body=body):
                response = self.client.post(f"{BASE}/quote/", body, format="json")
                self.assertEqual(response.status_code, 400)
        self.assertEqual(self.relay.quotes, [])

    def test_a_quote_charges_nothing_and_writes_no_sale(self):
        from .models import IntegrationFulfillment, IntegrationSubscriber

        self.quote()
        self.assertEqual(self.relay.orders, [])
        self.assertFalse(IntegrationFulfillment.objects.exists())
        self.assertFalse(IntegrationSubscriber.objects.exists())

    def test_the_quote_token_binds_what_it_was_quoted_for(self):
        data = self.quote()
        token, ref, code = data["quote"], data["subscriber_ref"], data["option_code"]
        other = IntegrationAccount.objects.create(provider="hdbox")
        opens = lambda **changes: quotes.open_priced_quote(  # noqa: E731
            changes.get("token", token),
            account=changes.get("account", self.account),
            subscriber_ref=changes.get("ref", ref),
            option_code=changes.get("code", code),
        )
        self.assertEqual(opens(), (Decimal("91.30"), Decimal("96.50")))
        self.assertIsNone(opens(ref="+22370123457"), "another number")
        self.assertIsNone(opens(code="air:289:2500:XOF"), "another amount")
        self.assertIsNone(opens(code="air:290:5000:XOF"), "another network")
        self.assertIsNone(opens(account=other), "another account")
        self.assertIsNone(opens(token=token[:-4] + "AAAA"), "a token someone edited")
        self.assertIsNone(opens(token=""))
        self.assertIsNone(opens(token="not a token"))
        # The cost of a token is readable whatever is sealed beside it; one
        # without a price is no quote for a service.
        self.assertEqual(
            quotes.open_quote(token, account=self.account, subscriber_ref=ref, option_code=code),
            Decimal("91.30"),
        )
        old = quotes.seal_quote(self.account, ref, code, Decimal("91.30"))
        self.assertIsNone(
            quotes.open_priced_quote(
                old, account=self.account, subscriber_ref=ref, option_code=code
            )
        )
        self.assertEqual(
            quotes.open_quote(old, account=self.account, subscriber_ref=ref, option_code=code),
            Decimal("91.30"),
        )

    def test_the_variants_are_made_once_and_are_system_service_products(self):
        first = self.quote()["service_variant_id"]
        again = self.quote()["service_variant_id"]
        self.assertEqual(first, again)
        variant = ProductVariant.objects.select_related("product").get(pk=first)
        self.assertEqual(variant.sku, "INTEG-POINTY-AIRTIME")
        self.assertEqual(variant.product.name, "شحن مباشر")
        self.assertTrue(variant.product.is_system and variant.product.is_service)
        self.relay.quote_answer = relay_quote(kind="bill", amount="5000", currency="NGN")
        bill = self.quote(kind="bill")["service_variant_id"]
        bill_variant = ProductVariant.objects.select_related("product").get(pk=bill)
        self.assertEqual(
            (bill_variant.sku, bill_variant.product.name), ("INTEG-POINTY-BILL", "دفع فاتورة")
        )
