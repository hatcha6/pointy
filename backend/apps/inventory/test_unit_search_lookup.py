"""The identifier lookup as the catalog's search box asks it.

Somebody types an IMEI, a VIN or a serial into the products search to answer
*«هل بعنا هذا الجهاز، ولمن؟»*. So the answer has to carry the sale — the invoice
and the buyer — to whoever may read those, nothing to whoever may not, and no
cost beyond the unit's own mask. And because it fires on every identifier typed,
it must cost the same few queries however long the article's history is.
"""

from __future__ import annotations

from decimal import Decimal

from django.db import connection
from django.test import TestCase
from django.test.utils import CaptureQueriesContext
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient

from apps.catalog.models import Product
from apps.core.roles import ensure_role_groups
from apps.customers.models import Customer
from apps.sales.services import checkout_order

from .models import StockUnit
from .test_tracked_api import _user
from .test_used_goods import _session
from .tracked_testing import receive, tracked_product

IMEI = "351234567890116"
IMEI_2 = "356938035643809"
VIEW = "inventory.view_stockunit"


class UnitSearchLookupTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.product = tracked_product(
            name="iPhone 14",
            sku="US-IP14",
            mode=Product.TrackingMode.SERIAL,
            unit_price="2000.00",
        )
        self.product.warranty_days = 365
        self.product.save(update_fields=["warranty_days"])
        self.variant = self.product.default_variant
        self.customer = Customer.objects.create(
            full_name="أحمد علي", phone="0912345678"
        )

    # -- helpers ------------------------------------------------------------

    def arrive(self, code=IMEI, secondary=""):
        row = {"code": code, "identifier_kind": "imei"}
        if secondary:
            row["secondary_code"] = secondary
        receive(variant=self.variant, quantity=1, unit_cost="1500.00", units=[row])
        return StockUnit.objects.get(
            code_normalized=code, status=StockUnit.Status.IN_STOCK
        )

    def sell(self, unit, customer=None):
        return checkout_order(
            register_session=_session(),
            lines_data=[
                {
                    "variant": self.variant,
                    "quantity": Decimal("1"),
                    "effective_unit_price": Decimal("1900.00"),
                    "stock_units": [unit.pk],
                }
            ],
            payments_data=[{"method": "cash", "amount": Decimal("1900.00")}],
            customer=customer,
        )

    def client_for(self, *permissions):
        client = APIClient()
        client.force_authenticate(user=_user("searcher", permissions=permissions))
        return client

    def lookup(self, client, code=IMEI):
        response = client.post(reverse("stock-unit-lookup"), {"code": code}, format="json")
        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        return response.data

    # -- what the card is drawn from ----------------------------------------

    def test_a_live_unit_carries_the_price_the_counter_would_charge(self):
        self.arrive()
        data = self.lookup(self.client_for(VIEW))

        self.assertEqual(data["unit"]["code"], IMEI)
        self.assertEqual(Decimal(data["unit"]["asking_price"]), Decimal("2000.00"))
        self.assertEqual(data["history"], [])
        self.assertIsNone(data["warranty"])

    def test_its_own_price_wins_over_the_variants(self):
        unit = self.arrive()
        unit.list_price = Decimal("1750.00")
        unit.save(update_fields=["list_price"])

        data = self.lookup(self.client_for(VIEW))
        self.assertEqual(Decimal(data["unit"]["asking_price"]), Decimal("1750.00"))

    def test_a_sold_unit_names_its_invoice_and_its_buyer(self):
        order = self.sell(self.arrive(), customer=self.customer)
        order.refresh_from_db()

        data = self.lookup(self.client_for(VIEW, "sales.view_order"))

        self.assertIsNone(data["unit"])
        [row] = data["history"]
        self.assertEqual(row["status"], StockUnit.Status.SOLD)
        self.assertEqual(row["sold_order"], order.pk)
        self.assertEqual(row["sold_receipt_number"], order.receipt_number)
        self.assertTrue(order.receipt_number)
        self.assertEqual(row["customer_name"], "أحمد علي")
        self.assertEqual(data["warranty"]["customer"], self.customer.pk)
        self.assertTrue(data["warranty"]["is_covered"])
        self.assertEqual(data["warranty"]["repair_count"], 0)

    def test_a_walk_in_sale_says_so_with_an_empty_name(self):
        self.sell(self.arrive())
        [row] = self.lookup(self.client_for(VIEW, "sales.view_order"))["history"]
        self.assertEqual(row["customer_name"], "")
        self.assertIsNotNone(row["sold_order"])

    def test_the_second_imei_finds_the_sold_handset_too(self):
        self.sell(self.arrive(secondary=IMEI_2), customer=self.customer)

        data = self.lookup(self.client_for(VIEW, "sales.view_order"), code=IMEI_2)
        [row] = data["history"]
        self.assertEqual(row["code"], IMEI)
        self.assertEqual(row["secondary_code"], IMEI_2)

    def test_a_trade_in_sold_twice_comes_back_latest_first(self):
        first = self.sell(self.arrive(), customer=self.customer)
        second_buyer = Customer.objects.create(full_name="سالم", phone="0923456789")
        second = self.sell(self.arrive(), customer=second_buyer)
        live = self.arrive()

        data = self.lookup(self.client_for(VIEW, "sales.view_order"))

        self.assertEqual(data["unit"]["id"], live.pk)
        self.assertEqual(
            [row["sold_order"] for row in data["history"]], [second.pk, first.pk]
        )
        self.assertEqual(data["history"][0]["customer_name"], "سالم")

    # -- who may read what ----------------------------------------------------

    def test_without_invoices_or_contacts_the_sale_is_absent_not_blank(self):
        self.sell(self.arrive(), customer=self.customer)
        [row] = self.lookup(self.client_for(VIEW))["history"]
        for field in ("sold_order", "sold_receipt_number", "customer_name"):
            self.assertNotIn(field, row)
        # The date it went out on is the unit's own fact, and stays.
        self.assertIsNotNone(row["sold_at"])

    def test_the_contact_book_names_the_buyer_but_not_the_invoice(self):
        self.sell(self.arrive(), customer=self.customer)
        [row] = self.lookup(self.client_for(VIEW, "customers.view_customer"))[
            "history"
        ]
        self.assertEqual(row["customer_name"], "أحمد علي")
        self.assertNotIn("sold_order", row)
        self.assertNotIn("sold_receipt_number", row)

    def test_no_cost_rides_along_for_a_reader_without_the_cost_permission(self):
        self.arrive()
        self.sell(self.arrive(code=IMEI_2), customer=self.customer)
        clerk = self.client_for(VIEW, "sales.view_order", "customers.view_customer")
        for code in (IMEI, IMEI_2):
            data = self.lookup(clerk, code=code)
            rows = [data["unit"]] if data["unit"] else data["history"]
            for row in rows:
                for field in ("incoming_rate", "refurb_cost", "total_cost"):
                    self.assertNotIn(field, row)

    def test_the_lookup_needs_the_unit_permission(self):
        response = self.client_for("sales.view_order").post(
            reverse("stock-unit-lookup"), {"code": IMEI}, format="json"
        )
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)

    def test_a_code_nobody_ever_held_answers_empty(self):
        data = self.lookup(self.client_for(VIEW), code="NOPE-0000-1234")
        self.assertIsNone(data["unit"])
        self.assertEqual(data["history"], [])
        self.assertIsNone(data["warranty"])

    # -- the page the card opens ------------------------------------------------

    def test_the_unit_page_of_a_sold_unit_names_the_sale_too(self):
        unit = self.arrive()
        order = self.sell(unit, customer=self.customer)
        order.refresh_from_db()

        response = self.client_for(VIEW, "sales.view_order").get(
            reverse("stock-unit-detail", args=[unit.pk])
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["sold_receipt_number"], order.receipt_number)
        self.assertEqual(response.data["customer_name"], "أحمد علي")

    def test_the_units_list_stays_on_the_lean_row(self):
        self.sell(self.arrive(), customer=self.customer)
        response = self.client_for(VIEW, "sales.view_order").get(
            reverse("stock-unit-list")
        )
        payload = response.data
        rows = payload["results"] if isinstance(payload, dict) else payload
        self.assertNotIn("sold_receipt_number", rows[0])

    # -- speed --------------------------------------------------------------

    def _queries_for_lookup(self, client):
        with CaptureQueriesContext(connection) as captured:
            data = self.lookup(client)
        return len(captured.captured_queries), data

    def test_a_long_history_costs_no_query_per_row(self):
        client = self.client_for(VIEW, "sales.view_order", "customers.view_customer")
        self.sell(self.arrive(), customer=self.customer)
        self.lookup(client)  # the user's permissions, cached on first use

        short, data = self._queries_for_lookup(client)
        self.assertEqual(len(data["history"]), 1)

        for _ in range(3):
            self.sell(self.arrive(), customer=self.customer)
        long, data = self._queries_for_lookup(client)
        self.assertEqual(len(data["history"]), 4)

        self.assertEqual(short, long)
        # Two probes (primary, then secondary), the history with its two
        # prefetches, the warranty's repair count: a handful, never a page.
        self.assertLessEqual(long, 8)

    def test_a_live_hit_is_a_handful_of_queries(self):
        client = self.client_for(VIEW, "sales.view_order")
        self.arrive()
        self.lookup(client)
        count, data = self._queries_for_lookup(client)
        self.assertIsNotNone(data["unit"])
        self.assertLessEqual(count, 7)
