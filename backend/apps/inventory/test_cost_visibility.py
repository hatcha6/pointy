"""What stock cost reaches whom, on the surfaces that went around the masks.

Two audiences, both the owner's call (2026-09-26):

* **A unit's cost** — what one identified article cost — stays behind
  ``inventory.view_stockunit_cost``, the mask ``StockUnitSerializer`` already
  applies. Its history, its timeline and a count's list of missing units carry
  the same figure, and used to hand it back to anyone who could read them.
* **A lot's cost** goes to whoever reads purchase orders (the reporting roles,
  the stock clerk and the buyer all see it on the order that bought the lot)
  or holds the unit-cost permission. The cashier and the technician do not:
  the cashier's role opens lots for the till's picker, never for what they
  cost.

And one figure that must *not* hide behind the unit's cost: what a sold
consignment's owner is still owed. The counter pays consignors out, so it goes
to whoever may see consignment liabilities, as figures of its own.

Masked keys are removed, not blanked.
"""

from datetime import timedelta
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group, Permission
from django.test import TestCase
from django.urls import reverse
from django.utils import timezone
from rest_framework import status
from rest_framework.test import APIClient

from apps.ai.tools import get_resource, query_resource
from apps.catalog.models import Product
from apps.core.roles import (
    CASHIER_GROUP,
    INVENTORY_CLERK_GROUP,
    MANAGER_GROUP,
    PURCHASING_AGENT_GROUP,
    ensure_role_groups,
)

from .models import StockBatch, StockUnit
from .test_consignment_api import ConsignmentApiTestCase
from .tracked_testing import receive, tracked_product


def _user(username, group, *extra_permissions):
    user = get_user_model().objects.create_user(username=username, password="pw")
    user.groups.add(Group.objects.get(name=group))
    for code in extra_permissions:
        app_label, codename = code.split(".")
        user.user_permissions.add(
            Permission.objects.get(
                content_type__app_label=app_label, codename=codename
            )
        )
    return user


def _client(user):
    client = APIClient()
    client.force_authenticate(user=user)
    return client


def _rows(response):
    payload = response.data
    return payload["results"] if isinstance(payload, dict) else payload


class LotCostVisibilityTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.cashier = _user("lot-cashier", CASHIER_GROUP)
        self.clerk = _user("lot-clerk", INVENTORY_CLERK_GROUP)
        self.buyer = _user("lot-buyer", PURCHASING_AGENT_GROUP)
        self.manager = _user("lot-manager", MANAGER_GROUP)
        product = tracked_product(
            name="أموكسيسيلين",
            sku="COST-AMOX",
            mode=Product.TrackingMode.BATCH,
            unit_price="20.00",
        )
        receive(
            variant=product.default_variant,
            quantity=10,
            unit_cost="14.00",
            batches=[
                {
                    "code": "A-2026-01",
                    "quantity": Decimal("10"),
                    # Inside the markdown ladder, so a suggestion is made.
                    "expiry_date": timezone.localdate() + timedelta(days=5),
                }
            ],
        )
        self.batch = StockBatch.objects.get()

    def _lot(self, user):
        response = _client(user).get(
            reverse("stock-batch-detail", args=[self.batch.pk])
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        return response.data

    def _watchlist_row(self, user):
        response = _client(user).get(
            reverse("stock-batch-expiry-watchlist"), {"days": 30}
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        return _rows(response)[0]

    def _history(self, user):
        response = _client(user).get(
            reverse("stock-batch-history", args=[self.batch.pk])
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        return response.data

    def _recall(self, user):
        response = _client(user).get(
            reverse("stock-batch-recall-report", args=[self.batch.pk])
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        return response.data

    def test_a_cashier_reads_the_lot_but_not_what_it_cost(self):
        lot = self._lot(self.cashier)
        self.assertEqual(lot["code"], "A-2026-01")
        self.assertNotIn("incoming_rate", lot["balances"][0])

        listed = _rows(_client(self.cashier).get(reverse("stock-batch-list")))
        self.assertNotIn("incoming_rate", listed[0]["balances"][0])

        balances = _client(self.cashier).get(
            reverse("stock-batch-balances", args=[self.batch.pk])
        ).data
        self.assertNotIn("incoming_rate", balances[0])

    def test_purchase_readers_keep_the_lots_cost(self):
        for user in (self.clerk, self.buyer, self.manager):
            with self.subTest(user=user.username):
                balance = self._lot(user)["balances"][0]
                self.assertEqual(Decimal(str(balance["incoming_rate"])), Decimal("14"))

    def test_the_lots_history_follows_the_lots_audience(self):
        row = self._history(self.cashier)[0]
        self.assertEqual(row["direction"], "in")
        self.assertNotIn("rate", row)
        self.assertNotIn("value_change", row)

        row = self._history(self.clerk)[0]
        self.assertEqual(Decimal(str(row["rate"])), Decimal("14"))
        self.assertEqual(Decimal(str(row["value_change"])), Decimal("140"))

    def test_the_expiry_advice_goes_only_to_those_who_may_see_its_cost_floor(self):
        row = self._watchlist_row(self.cashier)
        # The lot is listed — it is expiring — but the advice priced off its
        # cost is not given at all.
        self.assertEqual(row["id"], self.batch.pk)
        self.assertNotIn("markdown", row)
        self.assertNotIn("incoming_rate", row["balances"][0])

        advice = self._watchlist_row(self.clerk)["markdown"]
        self.assertEqual(advice["write_off_avoided"], Decimal("140.00"))
        self.assertIn("at_cost_floor", advice)

    def test_the_recall_report_names_the_delivery_not_its_price(self):
        inward = self._recall(self.cashier)["inward"][0]
        self.assertEqual(inward["quantity"], Decimal("10"))
        self.assertNotIn("rate", inward)

        inward = self._recall(self.buyer)["inward"][0]
        self.assertEqual(Decimal(str(inward["rate"])), Decimal("14"))

    def test_the_assistant_reads_the_same_masked_lot(self):
        listed = query_resource(user=self.cashier, resource="stock-batches")
        fetched = get_resource(
            user=self.cashier, resource="stock-batches", id=self.batch.pk
        )

        self.assertTrue(listed["ok"], listed)
        self.assertTrue(fetched["ok"], fetched)
        self.assertNotIn("incoming_rate", listed["data"]["results"][0]["balances"][0])
        self.assertNotIn("incoming_rate", fetched["data"]["balances"][0])

        clerk = get_resource(user=self.clerk, resource="stock-batches", id=self.batch.pk)
        self.assertIn("incoming_rate", clerk["data"]["balances"][0])


class UnitCostVisibilityTests(TestCase):
    """A unit's rate is its cost, so its history follows the unit's own mask
    — which a stock clerk does not hold by role, reading purchase orders or
    not."""

    def setUp(self):
        ensure_role_groups()
        self.cashier = _user("unit-cashier", CASHIER_GROUP)
        self.clerk = _user("unit-clerk", INVENTORY_CLERK_GROUP)
        self.manager = _user("unit-manager", MANAGER_GROUP)
        self.granted = _user(
            "unit-granted", CASHIER_GROUP, "inventory.view_stockunit_cost"
        )
        product = tracked_product(
            name="آيفون",
            sku="COST-IP",
            mode=Product.TrackingMode.SERIAL,
            unit_price="1500.00",
        )
        self.variant = product.default_variant
        receive(
            variant=self.variant,
            quantity=2,
            unit_cost="1200.00",
            units=[{"code": "IMEI-1"}, {"code": "IMEI-2"}],
        )
        self.unit = StockUnit.objects.get(code="IMEI-1")

    def _history(self, user):
        response = _client(user).get(
            reverse("stock-unit-history", args=[self.unit.pk])
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        return response.data

    def _timeline(self, user):
        response = _client(user).get(
            reverse("stock-unit-timeline", args=[self.unit.pk])
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        return [row for row in response.data if row["source"] == "allocation"]

    def test_the_history_and_timeline_withhold_what_the_unit_payload_withholds(self):
        for user in (self.cashier, self.clerk):
            with self.subTest(user=user.username):
                row = self._history(user)[0]
                self.assertEqual(row["unit_code"], "IMEI-1")
                self.assertNotIn("rate", row)
                self.assertNotIn("value_change", row)
                timeline = self._timeline(user)[0]
                self.assertEqual(timeline["kind"], "in")
                self.assertNotIn("rate", timeline)

    def test_whoever_may_see_the_units_cost_sees_it_in_its_history_too(self):
        for user in (self.manager, self.granted):
            with self.subTest(user=user.username):
                self.assertEqual(
                    Decimal(str(self._history(user)[0]["rate"])), Decimal("1200")
                )
                self.assertEqual(
                    Decimal(self._timeline(user)[0]["rate"]), Decimal("1200")
                )

    def test_a_count_names_the_missing_unit_but_not_its_value(self):
        counter = _client(self.cashier)
        count = counter.post(
            "/api/stock-counts/start/", {"scope": "full"}, format="json"
        ).data
        scanned = counter.post(
            f"/api/stock-counts/{count['id']}/scan/", {"code": "IMEI-2"}, format="json"
        )
        self.assertEqual(scanned.status_code, status.HTTP_201_CREATED, scanned.data)
        url = f"/api/stock-counts/{count['id']}/scan-reconciliation/"

        missing = counter.get(url).data["missing"]
        self.assertEqual([row["code"] for row in missing], ["IMEI-1"])
        self.assertNotIn("value", missing[0])

        missing = _client(self.manager).get(url).data["missing"]
        self.assertEqual(Decimal(missing[0]["value"]), Decimal("1200"))


class ConsignmentPayoutVisibilityTests(ConsignmentApiTestCase):
    """The counter pays consignors out, so it must see what it owes them.

    A sold consignment's payout is stamped on the unit as ``incoming_rate`` —
    its cost — and the unit screen used to read the payout from there. The cost
    mask hides that from the cashier, who holds the right to see and settle
    consignment liabilities, so the screen told the person handing the money
    over that the owner was owed 0.00. The unit now carries the payout as its
    own figures, to whoever may see consignment liabilities, while its cost
    stays masked.
    """

    def setUp(self):
        super().setUp()
        self.cashier = _user("payout-cashier", CASHIER_GROUP)
        # May look at stock, may not see what the shop owes consignors.
        self.looker = get_user_model().objects.create_user(
            username="payout-looker", password="pw"
        )
        self.looker.user_permissions.add(
            Permission.objects.get(
                content_type__app_label="inventory", codename="view_stockunit"
            )
        )
        agreement = self._agreement()  # a fixed payout of 10,000
        self._submit(agreement["id"])
        self.unit = StockUnit.objects.get()

    def _unit(self, user):
        response = _client(user).get(
            reverse("stock-unit-detail", args=[self.unit.pk])
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        return response.data

    def test_the_cashier_sees_what_to_hand_over_but_not_the_cost(self):
        self._sell(self.unit)

        unit = self._unit(self.cashier)

        self.assertEqual(unit["net_due"], "10000.00")
        self.assertEqual(unit["payout_due"], "10000.00")
        self.assertEqual(unit["consignor_advance"], "0.00")
        self.assertNotIn("incoming_rate", unit)
        self.assertNotIn("total_cost", unit)

    def test_an_advance_is_taken_off_what_is_still_owed(self):
        self._sell(self.unit)
        StockUnit.objects.filter(pk=self.unit.pk).update(
            consignor_advance=Decimal("1600.00")
        )

        unit = self._unit(self.cashier)

        self.assertEqual(unit["payout_due"], "10000.00")
        self.assertEqual(unit["consignor_advance"], "1600.00")
        self.assertEqual(unit["net_due"], "8400.00")

    def test_an_owner_who_took_more_is_owed_nothing_not_a_negative(self):
        self._sell(self.unit)
        StockUnit.objects.filter(pk=self.unit.pk).update(
            consignor_advance=Decimal("12000.00")
        )

        self.assertEqual(self._unit(self.cashier)["net_due"], "0.00")

    def test_without_the_liability_right_nothing_is_said_about_the_payout(self):
        self._sell(self.unit)

        unit = self._unit(self.looker)

        for field in ("net_due", "payout_due", "consignor_advance", "incoming_rate"):
            self.assertNotIn(field, unit)

    def test_only_a_sold_and_unpaid_article_carries_a_payout(self):
        # On the shelf: nothing is owed yet.
        self.assertNotIn("net_due", self._unit(self.cashier))

        self._sell(self.unit)
        StockUnit.objects.filter(pk=self.unit.pk).update(
            consignor_paid_at=timezone.now()
        )
        # Collected: nothing is owed any more.
        self.assertNotIn("net_due", self._unit(self.cashier))

    def test_the_owner_sees_both_the_payout_and_the_cost(self):
        self._sell(self.unit)

        unit = self._unit(self.manager)

        self.assertEqual(unit["net_due"], "10000.00")
        self.assertEqual(Decimal(str(unit["incoming_rate"])), Decimal("10000"))
