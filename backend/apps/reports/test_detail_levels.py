"""A summary is a summary, a detailed report is the detail — for every report.

``granularity`` used to be a row multiplier and nothing more. The summary built
every table the daily breakdown did, at the same caps — the newest orders,
every stock line, every expense, every movement — and the balance sheet read
the setting not at all, so an owner who asked for a summary got the long report
anyway. This pins, report by report, which tables each level prints, and that
the level changes what is shown and never what is stated.
"""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from apps.core.roles import MANAGER_GROUP, ensure_role_groups
from apps.customers.models import Customer
from apps.purchasing.models import Supplier

from .definitions import REPORT_DEFINITIONS
from .models import ReportRun
from .services import generate_report_payload

Type = ReportRun.ReportType

#: The tables each report prints in a summary.
SUMMARY = {
    Type.SALES_SUMMARY: {"summary", "top_products"},
    Type.PAYMENT_METHODS: {"summary", "payment_methods"},
    Type.REGISTER_CLOSURE: {"summary"},
    Type.INVENTORY_STATUS: {"summary"},
    Type.STOCK_MOVEMENTS: {"summary", "movement_mix"},
    Type.PURCHASING_SUMMARY: {"summary", "supplier_balances"},
    Type.REORDER_ITEMS: {"summary", "reorder_items"},
    Type.PAYROLL_SUMMARY: {"summary", "employee_totals"},
    Type.PROFIT_COSTS: {"summary", "profit_statement", "expense_categories"},
    Type.RECEIVABLES_AGING: {"summary", "receivables_aging"},
    Type.PAYABLES_AGING: {"summary", "payables_aging"},
    Type.CUSTOMER_STATEMENT: {"summary"},
    Type.SUPPLIER_STATEMENT: {"summary"},
    Type.CASH_POSITION: {"summary", "account_balances"},
    Type.EXPENSE_BREAKDOWN: {"summary", "expense_categories"},
    Type.PRODUCT_MARGIN: {"summary", "margin_losses", "category_margin"},
    Type.DISCOUNT_AUDIT: {"summary", "discount_rules", "giveaway_by_staff"},
    Type.SALES_BY_STAFF: {"summary", "sales_by_staff", "sales_by_hour"},
    Type.UNIT_AGING: {"summary", "aging_buckets"},
    Type.UNIT_MARGIN: {"summary"},
    Type.UNIT_LEDGER: {"summary"},
    Type.CONSIGNMENT_LEDGER: {"summary"},
    # الميزانية: the statement — what is ours and what we owe, at both ends.
    Type.BALANCE_SHEET: {"summary", "balance_assets", "balance_liabilities"},
    Type.MONTH_END_PACK: {
        "summary",
        "pack_profit_costs",
        "profit_statement",
        "expense_categories",
        "pack_cash_position",
        "account_balances",
        "pack_receivables_aging",
        "receivables_aging",
        "pack_payables_aging",
        "payables_aging",
        "pack_inventory_status",
        "pack_expense_breakdown",
        "pack_register_closure",
    },
}

#: What the day-by-day level adds, for the reports that have one.
DAILY = {
    Type.SALES_SUMMARY: {"daily_sales"},
    Type.PAYMENT_METHODS: {"daily_payments"},
    Type.SALES_BY_STAFF: {"daily_sales"},
}

#: What the detailed level adds beyond the daily one: the documents and lines
#: behind each total, and the reconciliations under each statement.
DETAIL = {
    Type.SALES_SUMMARY: {"recent_orders"},
    Type.REGISTER_CLOSURE: {"register_sessions"},
    Type.INVENTORY_STATUS: {"stock_reconciliation", "inventory_items"},
    Type.STOCK_MOVEMENTS: {"stock_movements"},
    Type.PURCHASING_SUMMARY: {"purchase_orders"},
    Type.PAYROLL_SUMMARY: {"payroll_runs", "employee_account_balances"},
    Type.PROFIT_COSTS: {"cash_bridge"},
    Type.CUSTOMER_STATEMENT: {"statement_entries"},
    Type.SUPPLIER_STATEMENT: {"statement_entries"},
    Type.CASH_POSITION: {"cash_movements"},
    Type.EXPENSE_BREAKDOWN: {"expenses"},
    Type.PRODUCT_MARGIN: {"product_margin"},
    Type.DISCOUNT_AUDIT: {"voids_and_refunds"},
    Type.UNIT_AGING: {"aging_units"},
    Type.UNIT_MARGIN: {"unit_margin"},
    Type.UNIT_LEDGER: {"unit_ledger"},
    Type.CONSIGNMENT_LEDGER: {"consignment_payables", "consignment_sales"},
    Type.BALANCE_SHEET: {"balance_net", "net_position_movement", "zakat"},
    Type.MONTH_END_PACK: {
        "cash_bridge",
        "cash_movements",
        "stock_reconciliation",
        "inventory_items",
        "expenses",
        "register_sessions",
    },
}


class DetailLevelTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.manager = get_user_model().objects.create_user(
            username="levels-manager", password="pass"
        )
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.customer = Customer.objects.create(full_name="زبون المستويات")
        self.supplier = Supplier.objects.create(name="مورد المستويات")

    def _payload(self, report_type, granularity, comparison="none"):
        params = {
            "preset": "month",
            "granularity": granularity,
            "comparison": comparison,
        }
        if report_type == Type.CUSTOMER_STATEMENT:
            params["customer_id"] = self.customer.pk
        if report_type == Type.SUPPLIER_STATEMENT:
            params["supplier_id"] = self.supplier.pk
        if report_type == Type.UNIT_LEDGER:
            params["code"] = "351234567890116"
        return generate_report_payload(
            report_type=report_type, params=params, user=self.manager
        )

    @staticmethod
    def _keys(payload):
        return {section["key"] for section in payload["sections"]}

    def test_every_report_is_covered(self):
        self.assertEqual(set(SUMMARY), set(REPORT_DEFINITIONS))

    def test_each_level_prints_its_own_tables(self):
        for report_type in REPORT_DEFINITIONS:
            summary = SUMMARY[report_type]
            daily = summary | DAILY.get(report_type, set())
            detailed = daily | DETAIL.get(report_type, set())
            for granularity, expected in (
                ("summary", summary),
                ("daily", daily),
                ("detailed", detailed),
            ):
                with self.subTest(report=report_type, granularity=granularity):
                    self.assertEqual(
                        self._keys(self._payload(report_type, granularity)),
                        expected,
                    )

    def test_the_level_changes_what_is_shown_never_what_is_stated(self):
        for report_type in REPORT_DEFINITIONS:
            with self.subTest(report=report_type):
                figures = {
                    granularity: self._payload(
                        report_type, granularity, comparison="previous_period"
                    )
                    for granularity in ("summary", "daily", "detailed")
                }
                self.assertEqual(
                    figures["summary"]["summary"], figures["detailed"]["summary"]
                )
                self.assertEqual(
                    figures["summary"]["summary"], figures["daily"]["summary"]
                )
                self.assertEqual(
                    figures["summary"].get("previous_summary"),
                    figures["detailed"].get("previous_summary"),
                )

    def test_the_balance_sheet_summary_is_the_statement(self):
        """The report an owner asks for by name: لنا, علينا, and الصافي above
        them. The bridge and the zakat working are the detail — the figures
        they explain are still in the headline."""
        payload = self._payload(Type.BALANCE_SHEET, "summary")
        self.assertEqual(
            [section["key"] for section in payload["sections"]],
            ["summary", "balance_assets", "balance_liabilities"],
        )
        for figure in ("net_position", "period_result", "zakat_due"):
            self.assertIn(figure, payload["summary"])

    def test_a_summary_does_not_query_for_what_it_leaves_out(self):
        """A summary of a busy year is the same page, and the same work, as a
        summary of a quiet one: the detail schedules are not built and thrown
        away."""
        from django.db import connection
        from django.test.utils import CaptureQueriesContext

        self._payload(Type.INVENTORY_STATUS, "summary")
        with CaptureQueriesContext(connection) as summary:
            self._payload(Type.INVENTORY_STATUS, "summary")
        with CaptureQueriesContext(connection) as detailed:
            self._payload(Type.INVENTORY_STATUS, "detailed")
        self.assertLess(len(summary), len(detailed))


class CatalogueLevelTests(TestCase):
    """The screen offers what a report can do, and nothing it cannot."""

    def setUp(self):
        ensure_role_groups()
        manager = get_user_model().objects.create_user(
            username="levels-catalogue", password="pass"
        )
        manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client = APIClient()
        self.client.force_authenticate(user=manager)

    def _entries(self):
        response = self.client.get(reverse("report-catalog"))
        return {entry["key"]: entry for entry in response.data["reports"]}

    def test_daily_is_offered_only_by_a_report_with_a_daily_table(self):
        entries = self._entries()
        for key, entry in entries.items():
            with self.subTest(report=key):
                expected = (
                    ["summary", "daily", "detailed"]
                    if key in DAILY
                    else ["summary", "detailed"]
                )
                self.assertEqual(list(entry["granularities"]), expected)

    def test_a_report_that_states_today_says_so(self):
        entries = self._entries()
        self.assertTrue(entries[Type.REORDER_ITEMS]["states_today"])
        self.assertTrue(entries[Type.UNIT_AGING]["states_today"])
        self.assertFalse(entries[Type.BALANCE_SHEET]["states_today"])

    def test_today_is_never_compared_with_today(self):
        manager = get_user_model().objects.get(username="levels-catalogue")
        payload = generate_report_payload(
            report_type=Type.REORDER_ITEMS,
            params={"preset": "last_month", "comparison": "previous_period"},
            user=manager,
        )
        self.assertNotIn("previous_summary", payload)
        self.assertNotIn("compared_to", payload["period"])
        self.assertNotIn("compared_with", {note["code"] for note in payload["notes"]})


class TextFiguresCompareTests(TestCase):
    """A figure that is not a number is compared by printing the earlier one,
    never by dividing — dividing it crashed every customer statement, because
    the screen asks for a comparison by default."""

    def setUp(self):
        ensure_role_groups()
        self.manager = get_user_model().objects.create_user(
            username="levels-text", password="pass"
        )
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))

    def test_a_statement_builds_with_the_default_comparison(self):
        customer = Customer.objects.create(full_name="زبون المقارنة")
        supplier = Supplier.objects.create(name="مورد المقارنة")
        for report_type, party in (
            (Type.CUSTOMER_STATEMENT, {"customer_id": customer.pk}),
            (Type.SUPPLIER_STATEMENT, {"supplier_id": supplier.pk}),
        ):
            with self.subTest(report=report_type):
                payload = generate_report_payload(
                    report_type=report_type,
                    params={
                        "preset": "last_month",
                        "comparison": "previous_period",
                        **party,
                    },
                    user=self.manager,
                )
                rows = {
                    row["metric"]: row
                    for row in payload["sections"][0]["rows"]
                }
                name = next(key for key in rows if key.endswith("_name"))
                self.assertIsNone(rows[name]["change_percent"])
                self.assertEqual(rows[name]["previous"], rows[name]["value"])

    def test_percent_change_leaves_text_alone(self):
        from .sections import percent_change

        self.assertIsNone(percent_change("زبون", "زبون"))
        self.assertIsNone(percent_change("14:00", "10:00"))
        self.assertIsNone(percent_change(True, False))
        self.assertEqual(percent_change("150.00", "100.00"), "50.00")
        self.assertEqual(percent_change(Decimal("50"), Decimal("100")), "-50.00")
