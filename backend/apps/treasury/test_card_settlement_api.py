"""Held card takings over the API, in the alerts, and in the reports.

The money rules are pinned in ``test_card_settlement``; these check that every
surface states them the same way — the screen, the settlement endpoints, the
overdue alert, the balance sheet and the profit statement — and that only the
people who keep the books can record or undo a settlement.
"""

from datetime import timedelta
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.db import connection
from django.test.utils import CaptureQueriesContext
from django.urls import reverse
from rest_framework.test import APIClient

from apps.core.roles import (
    ACCOUNTANT_GROUP,
    AUDITOR_GROUP,
    CASHIER_GROUP,
    ensure_role_groups,
)
from apps.notifications.models import BusinessNotification
from apps.notifications.services import (
    MANAGED_CODES,
    NOTIFICATION_AUDIENCE_RULES,
    _codes_for_user,
    sync_business_notifications,
)
from apps.reports.models import ReportRun
from apps.reports.services import generate_report_payload

from .held_days import pending_days
from .models import CardSettlement, MoneyAccount
from .position import treasury_position
from .test_card_settlement import HeldCardTestCase, money

User = get_user_model()
OVERDUE_CODE = "treasury.card_settlement_overdue"


class SettlementApiTestCase(HeldCardTestCase):
    def setUp(self):
        super().setUp()
        ensure_role_groups()
        self.accountant = self.member("acc", ACCOUNTANT_GROUP)
        self.cashier = self.member("till", CASHIER_GROUP)
        self.auditor = self.member("aud", AUDITOR_GROUP)
        self.client = APIClient()
        self.client.force_authenticate(self.accountant)

    def member(self, username, group):
        user = User.objects.create_user(username=username, password="pw")
        user.groups.add(Group.objects.get(name=group))
        return User.objects.get(pk=user.pk)

    def held_url(self, clearing, **params):
        url = reverse("treasury-clearing-held", args=[clearing.pk])
        if params:
            url += "?" + "&".join(f"{key}={value}" for key, value in params.items())
        return url


class ClearingAccountApiTests(SettlementApiTestCase):
    def test_an_accountant_opens_one_for_the_shops_bank(self):
        response = self.client.post(
            reverse("money-account-list"),
            {
                "name": "معاملات — قيد التسوية",
                "kind": "clearing",
                "settles_into": self.bank.pk,
                "opening_at": (self.today - timedelta(days=3)).isoformat(),
                "settlement_weekdays": "6,0,1,2,3",
            },
            format="json",
        )
        self.assertEqual(response.status_code, 201, response.data)
        self.assertEqual(response.data["kind"], "clearing")
        self.assertTrue(response.data["holds_untagged_card"])
        self.assertEqual(response.data["settles_into_name"], self.bank.name)
        self.assertEqual(response.data["opening_balance"], "0.00")
        self.assertFalse(response.data["is_routed"])

    def test_a_schedule_with_no_paying_day_is_refused(self):
        response = self.client.post(
            reverse("money-account-list"),
            {
                "name": "معاملات",
                "kind": "clearing",
                "settles_into": self.bank.pk,
                "settlement_weekdays": "",
            },
            format="json",
        )
        self.assertEqual(response.status_code, 400)
        self.assertIn("settlement_weekdays", response.data)

    def test_the_position_states_the_held_money_and_its_days(self):
        clearing = self.open_clearing()
        self.pay("100.00", days_ago=9)
        self.pay("50.00", days_ago=1)

        response = self.client.get(reverse("treasury-position"))

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data["totals"]["in_transit"], "148.50")
        # Proved by settlements, not counts: never "waiting to be counted".
        self.assertEqual(
            response.data["totals"]["accounts_total"],
            MoneyAccount.objects.exclude(kind="clearing").filter(is_active=True).count(),
        )
        entry = next(
            item
            for item in response.data["accounts"]
            if item["account"]["id"] == clearing.pk
        )
        self.assertEqual(entry["expected_balance"], "148.50")
        self.assertEqual(entry["held"]["days"], 2)
        self.assertEqual(entry["held"]["payments"], 2)
        self.assertEqual(entry["held"]["overdue_days"], 1)
        self.assertEqual(entry["held"]["overdue_amount"], "99.00")
        bank_entry = next(
            item
            for item in response.data["accounts"]
            if item["account"]["id"] == self.bank.pk
        )
        self.assertIsNone(bank_entry["held"])

    def test_a_deleted_account_with_history_is_refused_in_words(self):
        clearing = self.open_clearing()
        self.pay("100.00", days_ago=2)
        self.settle(clearing, "99.00")
        response = self.client.delete(
            reverse("money-account-detail", args=[clearing.pk])
        )
        # The accountant cannot delete accounts at all; the owner gets a reason.
        self.assertEqual(response.status_code, 403)
        owner = APIClient()
        owner.force_authenticate(self.owner)
        response = owner.delete(reverse("money-account-detail", args=[clearing.pk]))
        self.assertEqual(response.status_code, 400)


class HeldDaysApiTests(SettlementApiTestCase):
    def test_the_days_their_expected_dates_and_a_proposed_match(self):
        clearing = self.open_clearing()
        self.pay("100.00", days_ago=9)
        self.pay("100.00", days_ago=8)
        self.pay("40.00", days_ago=1)

        response = self.client.get(self.held_url(clearing, amount="198.00"))

        self.assertEqual(response.status_code, 200)
        days = response.data["days"]
        self.assertEqual(len(days), 3)
        self.assertEqual(days[0]["day"], (self.today - timedelta(days=9)).isoformat())
        self.assertTrue(days[0]["overdue"])
        self.assertEqual(days[0]["net"], "99.00")
        self.assertEqual(response.data["totals"]["net"], "237.60")
        self.assertEqual(response.data["suggestion"]["match"], "exact")
        self.assertEqual(
            response.data["suggestion"]["days"], [days[0]["day"], days[1]["day"]]
        )

    def test_one_days_sales_are_listed_for_the_owner_to_check(self):
        clearing = self.open_clearing()
        sale = self.pay("100.00", days_ago=2)
        day = pending_days(clearing)[0].day.isoformat()

        response = self.client.get(
            reverse("treasury-clearing-held-day", args=[clearing.pk, day])
        )

        self.assertEqual(response.status_code, 200)
        self.assertEqual([row["id"] for row in response.data["payments"]], [sale.pk])
        self.assertEqual(response.data["payments"][0]["net"], "99.00")

    def test_a_cashier_sees_none_of_it(self):
        clearing = self.open_clearing()
        self.client.force_authenticate(self.cashier)
        self.assertEqual(self.client.get(self.held_url(clearing)).status_code, 403)
        self.assertEqual(
            self.client.get(reverse("card-settlement-list")).status_code, 403
        )


class SettlementApiTests(SettlementApiTestCase):
    def record(self, clearing, amount, **extra):
        payload = {
            "clearing_account": clearing.pk,
            "settled_on": self.today.isoformat(),
            "amount_received": amount,
            "days": [day.day.isoformat() for day in pending_days(clearing)],
        }
        payload.update(extra)
        return self.client.post(reverse("card-settlement-list"), payload, format="json")

    def test_recording_and_cancelling_a_deposit(self):
        clearing = self.open_clearing()
        self.pay("1000.00", days_ago=2)

        response = self.record(clearing, "985.00", expected_amount="990.00")
        self.assertEqual(response.status_code, 201, response.data)
        self.assertEqual(response.data["difference"], "-5.00")
        self.assertEqual(response.data["doc_status"], "submitted")
        settlement_id = response.data["id"]

        covered = self.client.get(
            reverse("card-settlement-payments", args=[settlement_id])
        )
        self.assertEqual(len(covered.data["payments"]), 1)

        response = self.client.post(
            reverse("card-settlement-cancel", args=[settlement_id]),
            {"reason": "سجّلت المبلغ خطأ"},
            format="json",
        )
        self.assertEqual(response.status_code, 200, response.data)
        self.assertEqual(response.data["doc_status"], "cancelled")
        self.assertEqual(self.balance(clearing), money("990.00"))

    def test_a_stale_figure_is_refused_with_a_reason_and_a_code(self):
        clearing = self.open_clearing()
        self.pay("100.00", days_ago=2)
        response = self.record(clearing, "99.00", expected_amount="50.00")
        self.assertEqual(response.status_code, 400)
        self.assertEqual(response.data["code"], "held_amount_changed")
        self.assertFalse(CardSettlement.objects.exists())

    def test_nothing_chosen_is_refused(self):
        clearing = self.open_clearing()
        response = self.record(clearing, "99.00", days=[])
        self.assertEqual(response.status_code, 400)

    def test_only_the_bookkeepers_record_or_undo_one(self):
        clearing = self.open_clearing()
        self.pay("100.00", days_ago=2)
        for user in (self.cashier, self.auditor):
            self.client.force_authenticate(user)
            with self.subTest(user=user.username):
                self.assertEqual(self.record(clearing, "99.00").status_code, 403)

        self.client.force_authenticate(self.auditor)
        self.assertEqual(self.client.get(reverse("card-settlement-list")).status_code, 200)

        self.client.force_authenticate(self.accountant)
        settlement_id = self.record(clearing, "99.00").data["id"]
        self.client.force_authenticate(self.auditor)
        response = self.client.post(
            reverse("card-settlement-cancel", args=[settlement_id]),
            {"reason": "x"},
            format="json",
        )
        self.assertEqual(response.status_code, 403)


class OverdueAlertTests(SettlementApiTestCase):
    def test_the_alert_reaches_whoever_records_settlements(self):
        self.assertIn(OVERDUE_CODE, MANAGED_CODES)
        self.assertIn(OVERDUE_CODE, NOTIFICATION_AUDIENCE_RULES)
        self.assertIn(OVERDUE_CODE, set(_codes_for_user(self.accountant)))
        self.assertIn(OVERDUE_CODE, set(_codes_for_user(self.owner)))
        self.assertNotIn(OVERDUE_CODE, set(_codes_for_user(self.cashier)))

    def test_a_late_day_raises_it_and_recording_the_deposit_resolves_it(self):
        clearing = self.open_clearing()
        self.pay("100.00", days_ago=9)
        self.pay("50.00", days_ago=1)

        sync_business_notifications()
        alert = BusinessNotification.objects.get(code=OVERDUE_CODE)
        self.assertEqual(alert.status, BusinessNotification.Status.ACTIVE)
        self.assertEqual(alert.payload["amount"], "99.00")
        self.assertEqual(alert.payload["count"], 1)
        self.assertEqual(alert.payload["account"], clearing.name)

        oldest = pending_days(clearing)[0].day
        self.settle(clearing, "99.00", days=[oldest])
        sync_business_notifications()
        alert.refresh_from_db()
        self.assertEqual(alert.status, BusinessNotification.Status.RESOLVED)

    def test_nothing_is_raised_while_the_money_is_still_on_its_way(self):
        self.open_clearing()
        self.pay("50.00", days_ago=0)
        sync_business_notifications()
        self.assertFalse(BusinessNotification.objects.filter(code=OVERDUE_CODE).exists())


class ReportsTests(SettlementApiTestCase):
    def report(self, report_type, *, start_days_ago=20):
        return generate_report_payload(
            report_type=report_type,
            params={
                "start_date": (self.today - timedelta(days=start_days_ago)).isoformat(),
                "end_date": self.today.isoformat(),
                "granularity": "detailed",
            },
            user=self.owner,
        )

    def section(self, payload, key):
        return next(section for section in payload["sections"] if section["key"] == key)

    def test_the_balance_sheet_states_held_money_beside_the_bank(self):
        self.open_clearing()
        self.pay("100.00", days_ago=2)

        sheet = self.report(ReportRun.ReportType.BALANCE_SHEET)
        lines = {
            row["line"]: row for row in self.section(sheet, "balance_assets")["rows"]
        }
        cash_report = self.report(ReportRun.ReportType.CASH_POSITION)
        position = treasury_position(as_of=self.today)["totals"]

        self.assertEqual(
            Decimal(lines["cards_in_transit"]["closing_balance"]), money("99.00")
        )
        self.assertEqual(
            Decimal(lines["cash_and_bank"]["closing_balance"])
            + Decimal(lines["cards_in_transit"]["closing_balance"]),
            Decimal(cash_report["summary"]["closing_total"]),
        )
        self.assertEqual(
            Decimal(cash_report["summary"]["cards_in_transit"]), money("99.00")
        )
        self.assertEqual(
            Decimal(cash_report["summary"]["closing_total"]), position["total"]
        )
        self.assertIn(
            "cards_held_until_settled", {note["code"] for note in cash_report["notes"]}
        )

    def test_a_fee_the_processor_kept_beyond_the_estimate_is_a_cost(self):
        clearing = self.open_clearing()
        self.pay("1000.00", days_ago=2)
        plain = self.report(ReportRun.ReportType.PROFIT_COSTS)["summary"]
        self.assertNotIn("card_settlement_fee_total", plain)

        self.settle(clearing, "985.00")
        summary = self.report(ReportRun.ReportType.PROFIT_COSTS)["summary"]

        self.assertEqual(summary["card_settlement_fee_total"], "5.00")
        self.assertEqual(
            Decimal(summary["operating_expense_total"])
            - Decimal(plain["operating_expense_total"]),
            money("5.00"),
        )
        self.assertEqual(
            Decimal(plain["net_operating_profit"])
            - Decimal(summary["net_operating_profit"]),
            money("5.00"),
        )


class ClearingQueryScalingTests(SettlementApiTestCase):
    def queries(self):
        with CaptureQueriesContext(connection) as captured:
            treasury_position(as_of=self.today)
        return len(captured)

    def test_held_money_costs_a_fixed_number_of_queries(self):
        clearing = self.open_clearing()
        self.pay("10.00", days_ago=2)
        self.settle(clearing, "9.90")
        baseline = self.queries()

        for _ in range(5):
            self.pay("10.00", days_ago=1)
        self.settle(clearing, "49.50")
        self.assertEqual(self.queries(), baseline)

    def test_a_shop_without_one_runs_the_queries_it_always_ran(self):
        baseline = self.queries()
        self.pay("10.00", days_ago=1)
        self.assertEqual(self.queries(), baseline)
        self.assertFalse(MoneyAccount.objects.filter(kind="clearing").exists())
