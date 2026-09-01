"""Closing stock at a past date, and a schedule that foots to it.

Year end has one non-negotiable number: what the goods on hand cost at the close
of the last day. The stock report took a period and ignored it — it valued the
shelf at the moment the button was pressed — so on 15 January, 31 December's
stock was already unrecoverable. And the supporting table listed *retail* value
per line under a *cost* total, so the schedule could not be added up to the
figure it supported.

The data was never missing. Every ledger entry carries the running balance for
its variant, so the position on any past day is the last entry at or before it.
"""

from datetime import timedelta
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.utils import timezone

from apps.catalog.testing import create_product_with_default_variant
from apps.core.roles import MANAGER_GROUP, ensure_role_groups
from apps.inventory.models import StockItem, StockLedgerEntry, Warehouse
from apps.inventory.reporting import stock_cost_value, stock_position_by_variant

from .models import ReportRun
from .sections import decimal_from
from .services import generate_report_payload


class ClosingStockTests(TestCase):
    """Three receipts and an issue, spread across three weeks."""

    def setUp(self):
        ensure_role_groups()
        User = get_user_model()
        self.manager = User.objects.create_user(username="stock-mgr", password="p")
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))

        self.today = timezone.localdate()
        self.warehouse = Warehouse.objects.first() or Warehouse.objects.create(
            name="Main"
        )
        product = create_product_with_default_variant(
            sku="CLOSE-1", name="بضاعة", unit_price=Decimal("10.00")
        )
        self.variant = product.default_variant
        StockItem.objects.create(
            variant=self.variant, quantity_on_hand=Decimal("11.000")
        )
        self._entry(days_ago=21, quantity=10, value="20.00", balance=(10, "20.00"))
        self._entry(days_ago=14, quantity=5, value="15.00", balance=(15, "35.00"))
        self._entry(days_ago=7, quantity=-4, value="-8.00", balance=(11, "27.00"))

    def _entry(self, *, days_ago, quantity, value, balance):
        quantity_balance, value_balance = balance
        StockLedgerEntry.objects.create(
            variant=self.variant,
            warehouse=self.warehouse,
            posting_at=timezone.now() - timedelta(days=days_ago),
            quantity_change=Decimal(quantity),
            valuation_rate=Decimal("2.00"),
            value_change=Decimal(value),
            balance_quantity=Decimal(quantity_balance),
            balance_value=Decimal(value_balance),
        )

    def _as_of(self, days_ago):
        return self.today - timedelta(days=days_ago)

    # -- the ledger helpers -------------------------------------------------

    def test_the_value_walks_back_through_the_ledger(self):
        self.assertEqual(stock_cost_value(as_of=self._as_of(0)), Decimal("27.00"))
        self.assertEqual(stock_cost_value(as_of=self._as_of(8)), Decimal("35.00"))
        self.assertEqual(stock_cost_value(as_of=self._as_of(15)), Decimal("20.00"))

    def test_before_the_first_movement_the_shop_held_nothing(self):
        self.assertEqual(stock_cost_value(as_of=self._as_of(30)), Decimal("0.00"))

    def test_a_backdated_correction_does_not_become_the_latest_position(self):
        """Ranked by id, a late-arriving correction would win.

        A backdated entry is appended with a higher primary key and an earlier
        posting date. The position must still be read in posting order, or a
        correction to last month silently becomes this month's balance.
        """
        self._entry(days_ago=10, quantity=1, value="2.00", balance=(16, "37.00"))
        self.assertEqual(stock_cost_value(as_of=self._as_of(0)), Decimal("27.00"))
        self.assertEqual(stock_cost_value(as_of=self._as_of(9)), Decimal("37.00"))

    def test_the_per_variant_position_agrees_with_the_total(self):
        position = stock_position_by_variant(as_of=self._as_of(0))
        quantity, value = position[self.variant.pk]
        self.assertEqual(quantity, Decimal("11.000"))
        self.assertEqual(value, stock_cost_value(as_of=self._as_of(0)))

    # -- the report ---------------------------------------------------------

    def _report(self, start, end):
        return generate_report_payload(
            report_type=ReportRun.ReportType.INVENTORY_STATUS,
            params={"start_date": start.isoformat(), "end_date": end.isoformat()},
            user=self.manager,
        )

    def _section(self, payload, key):
        return next(s for s in payload["sections"] if s["key"] == key)

    def test_a_past_period_values_stock_at_the_close_of_that_period(self):
        payload = self._report(self._as_of(20), self._as_of(8))
        self.assertEqual(payload["summary"]["cost_stock_value"], "35.00")

    def test_a_period_ending_today_values_stock_live(self):
        payload = self._report(self._as_of(30), self.today)
        self.assertEqual(payload["summary"]["cost_stock_value"], "0.00")

    def test_the_report_says_which_of_the_two_it_is(self):
        historical = {n["code"] for n in self._report(self._as_of(20), self._as_of(8))["notes"]}
        live = {n["code"] for n in self._report(self._as_of(30), self.today)["notes"]}
        self.assertIn("stock_historical", historical)
        self.assertIn("stock_live", live)

    def test_the_as_of_date_is_stated(self):
        payload = self._report(self._as_of(20), self._as_of(8))
        stated = next(n for n in payload["notes"] if n["code"] == "stock_as_of")
        self.assertEqual(stated["args"]["date"], self._as_of(8).isoformat())

    def test_the_schedule_foots_to_the_stated_cost_value(self):
        """The defect: a cost total with no supporting schedule.

        Every line stated retail value only, so the one figure an auditor tests
        — the money tied up in stock — could not be added up from the rows
        beneath it.
        """
        payload = self._report(self._as_of(20), self._as_of(8))
        section = self._section(payload, "inventory_items")
        self.assertIn("cost_value", section["columns"])

        rows_total = sum(
            (decimal_from(row["cost_value"]) for row in section["rows"]),
            Decimal("0.00"),
        )
        self.assertEqual(rows_total, Decimal(payload["summary"]["cost_stock_value"]))
        self.assertEqual(
            section["totals"]["shown"]["cost_value"],
            payload["summary"]["cost_stock_value"],
        )

    def test_retail_is_stated_only_for_a_live_run(self):
        """Retail is quantity times *today's* price.

        Applied to a past quantity it is a number that was never true on any
        day, so a historical run states cost and stays quiet about retail.
        """
        historical = self._report(self._as_of(20), self._as_of(8))
        live = self._report(self._as_of(30), self.today)
        self.assertNotIn("retail_stock_value", historical["summary"])
        self.assertIn("retail_stock_value", live["summary"])
        self.assertNotIn("retail_value", self._section(historical, "inventory_items")["columns"])

    def test_the_reconciliation_explains_the_movement(self):
        """Opening + received − issued = closing, with the residual shown."""
        payload = self._report(self._as_of(20), self._as_of(8))
        rows = {row["line"]: decimal_from(row["value"]) for row in
                self._section(payload, "stock_reconciliation")["rows"]}
        # The window opens the day after the first receipt, so 20.00 is
        # brought forward and only the second receipt lands inside it.
        self.assertEqual(rows["opening_value"], Decimal("20.00"))
        self.assertEqual(rows["received_value"], Decimal("15.00"))
        self.assertEqual(rows["issued_value"], Decimal("0.00"))
        self.assertEqual(rows["closing_value"], Decimal("35.00"))
        self.assertEqual(rows["unexplained_difference"], Decimal("0.00"))
