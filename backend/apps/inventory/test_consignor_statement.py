"""كشف حساب صاحب الأمانة over the wire.

One consignor, every agreement they signed, every article in every state — and
three properties that are easy to lose: the period narrows the history and
never hides a debt, the shop's margin stays with the reporting roles, and a
page of fifty articles costs what a page of three does.
"""

from datetime import timedelta
from decimal import Decimal

from django.db import connection
from django.test.utils import CaptureQueriesContext
from django.urls import reverse
from django.utils import timezone
from rest_framework import status
from rest_framework.test import APIClient

from apps.customers.models import Customer

from .consignment_reminders import send_unclaimed_payout_reminders
from .consignment_service import return_to_consignor
from .models import StockUnit
from .test_consignment_api import _user
from .test_consignment_reminders import ReminderTestCase


class StatementTestCase(ReminderTestCase):
    def _statement(self, client=None, **params):
        return (client or self.client).get(
            reverse("consignor-statement", args=[self.consignor.pk]), params
        )

    def _shelf(self, count, prefix):
        """``count`` articles on one agreement: sold-and-waiting, sold-and-paid,
        held and returned, in rotation."""
        from .consignment_service import disburse_payout
        from .test_consignment import _request_with, _session

        units = self._take_in(*[f"{prefix}-{index:02d}" for index in range(count)])
        for index, unit in enumerate(units):
            kind = index % 4
            if kind == 0:
                self._sold_days_ago(unit, 40)
            elif kind == 1:
                self._sold_days_ago(unit, 10)
                disburse_payout(units=[unit], request=_request_with(_session()))
            elif kind == 3:
                return_to_consignor(unit)
        return units


class ConsignorStatementTests(StatementTestCase):
    def test_one_page_across_every_agreement(self):
        first = self._take_in("W-1")[0]
        second = self._take_in("W-2", "W-3")
        self._sold_days_ago(first, 5)

        response = self._statement()

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        figures = response.data["figures"]
        self.assertEqual(figures["agreement_count"], 2)
        self.assertEqual(figures["payable"], Decimal("10000.00"))
        self.assertEqual(figures["held_count"], 2)
        self.assertEqual(figures["held_declared_value"], Decimal("24000.00"))
        self.assertEqual(figures["awaiting_count"], 1)
        self.assertEqual(response.data["consignor"]["full_name"], "سالم")
        # What is owed comes first: it is why the consignor is at the counter.
        states = [line["state"] for line in response.data["results"]]
        self.assertEqual(states, ["awaiting", "held", "held"])
        line = response.data["results"][0]
        self.assertEqual(line["code"], "W-1")
        self.assertEqual(line["net_due"], Decimal("10000.00"))
        self.assertEqual(line["days_waiting"], 5)
        self.assertTrue(line["invoice_number"])
        self.assertFalse(line["payout_is_estimate"])
        self.assertTrue(response.data["results"][1]["payout_is_estimate"])
        self.assertTrue(second)

    def test_another_consignor_s_goods_are_not_on_the_page(self):
        self._take_in("W-1")
        other = Customer.objects.create(full_name="خالد", phone="0920000000")
        mine = self._statement()

        theirs = self.client.get(reverse("consignor-statement", args=[other.pk]))

        self.assertEqual(mine.data["count"], 1)
        self.assertEqual(theirs.data["count"], 0)
        self.assertEqual(theirs.data["figures"]["total_count"], 0)

    def test_the_period_narrows_the_history_and_never_hides_a_debt(self):
        self._shelf(4, "P")
        future = (timezone.localdate() + timedelta(days=30)).isoformat()

        response = self._statement(start=future, end=future)

        # Paid and returned fall outside a window in the future; the article
        # waiting for its money and the one on the shelf do not care.
        self.assertEqual(
            sorted(line["state"] for line in response.data["results"]),
            ["awaiting", "held"],
        )
        figures = response.data["figures"]
        self.assertEqual(figures["period_sold_count"], 0)
        self.assertEqual(figures["period_paid_total"], Decimal("0.00"))
        self.assertEqual(figures["payable"], Decimal("10000.00"))

        everything = self._statement()
        self.assertEqual(
            sorted(line["state"] for line in everything.data["results"]),
            ["awaiting", "held", "paid", "returned"],
        )
        self.assertEqual(everything.data["figures"]["period_paid_total"], Decimal("10000.00"))
        self.assertEqual(everything.data["figures"]["returned_count"], 1)

    def test_the_lines_can_be_narrowed_to_a_state(self):
        self._shelf(4, "S")

        response = self._statement(state="paid,returned")

        self.assertEqual(
            sorted(line["state"] for line in response.data["results"]),
            ["paid", "returned"],
        )
        paid = next(
            line for line in response.data["results"] if line["state"] == "paid"
        )
        self.assertTrue(paid["payout_number"])
        self.assertIsNotNone(paid["paid_at"])
        self.assertIsNone(paid["days_waiting"])

    def test_a_summary_carries_no_lines(self):
        self._take_in("W-1")

        response = self._statement(summary="1")

        self.assertNotIn("results", response.data)
        self.assertEqual(response.data["figures"]["held_count"], 1)

    def test_a_bad_date_is_refused_in_arabic(self):
        response = self._statement(start="yesterday")

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("start", response.data)

    def test_the_last_reminder_is_on_the_line_and_the_page(self):
        unit = self._take_in("W-1")[0]
        self._sold_days_ago(unit, 31)
        send_unclaimed_payout_reminders()

        response = self._statement()

        line = response.data["results"][0]
        self.assertEqual(line["last_reminder"]["round"], 1)
        self.assertEqual(line["last_reminder"]["status"], "queued")
        reminders = response.data["reminders"]
        self.assertTrue(reminders["enabled"])
        self.assertEqual(reminders["every_days"], 30)
        self.assertEqual(reminders["max_rounds"], 3)
        self.assertIsNotNone(reminders["last_at"])

    def test_a_resold_article_does_not_wear_the_last_sale_s_reminder(self):
        unit = self._take_in("W-1")[0]
        self._sold_days_ago(unit, 31)
        send_unclaimed_payout_reminders()
        StockUnit.objects.filter(pk=unit.pk).update(sold_at=timezone.now())

        line = self._statement().data["results"][0]

        self.assertIsNone(line["last_reminder"])


class StatementVisibilityTests(StatementTestCase):
    def test_the_shop_s_commission_is_for_the_reporting_roles(self):
        unit = self._take_in("W-1")[0]
        self._sold_days_ago(unit, 3)
        counter = _user(
            "counter", permissions=("inventory.view_consignment_liability",)
        )
        client = APIClient()
        client.force_authenticate(user=counter)

        owner_view = self._statement()
        counter_view = self._statement(client)

        self.assertEqual(owner_view.data["figures"]["shop_commission"], Decimal("2000.00"))
        self.assertEqual(counter_view.status_code, status.HTTP_200_OK)
        self.assertNotIn("shop_commission", counter_view.data["figures"])
        self.assertEqual(counter_view.data["figures"]["payable"], Decimal("10000.00"))

    def test_seeing_it_needs_the_liability_permission(self):
        stranger = _user("stranger", permissions=("inventory.view_stockunit",))
        client = APIClient()
        client.force_authenticate(user=stranger)

        self.assertEqual(
            self._statement(client).status_code, status.HTTP_403_FORBIDDEN
        )


class StatementQueryScalingTests(StatementTestCase):
    def _queries(self):
        with CaptureQueriesContext(connection) as captured:
            response = self._statement()
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        return len(captured), response.data["count"]

    def test_a_long_statement_costs_what_a_short_one_does(self):
        self._shelf(4, "A")
        send_unclaimed_payout_reminders()
        small, small_count = self._queries()

        self._shelf(12, "B")
        send_unclaimed_payout_reminders()
        large, large_count = self._queries()

        self.assertEqual((small_count, large_count), (4, 16))
        self.assertLessEqual(large, 20, "the statement is a fixed handful of reads")
        self.assertEqual(small, large, "the statement grew a per-article query")
