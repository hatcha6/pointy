"""Once a period has been reported, it stops moving.

An owner could hand September's profit to a partner on 3 October and somebody
could book a backdated expense into September on the 4th — silently rewriting
the figure that had already been quoted, with no record that it had been
rewritten. These tests pin the three properties that make the lock worth having:
it guards the *money date* rather than the row's age, it can be overridden but
never bypassed, and every override and every re-opening leaves a trail.
"""

from datetime import timedelta
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.urls import reverse
from django.utils import timezone
from rest_framework import status
from rest_framework.test import APIClient

from apps.analytics.models import AnalyticsEvent
from apps.core.models import ShopSettings
from apps.core.period_lock import PeriodLocked, assert_period_open, period_is_locked
from apps.core.roles import (
    ACCOUNTANT_GROUP,
    CASHIER_GROUP,
    MANAGER_GROUP,
    ensure_role_groups,
)
from apps.expenses.models import Expense, ExpenseCategory


class PeriodLockCoreTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        User = get_user_model()
        self.plain = User.objects.create_user(username="lock-plain", password="p")
        self.plain.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.manager = User.objects.create_user(username="lock-mgr", password="p")
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.today = timezone.localdate()
        self._lock(self.today - timedelta(days=10))

    def _lock(self, when):
        settings = ShopSettings.load()
        settings.books_locked_through = when
        settings.save(update_fields=["books_locked_through", "updated_at"])

    def test_a_date_inside_the_closed_period_is_refused(self):
        with self.assertRaises(PeriodLocked):
            assert_period_open(self.today - timedelta(days=20), user=self.plain)

    def test_the_lock_day_itself_is_closed(self):
        """"Closed through the 31st" includes the 31st."""
        with self.assertRaises(PeriodLocked):
            assert_period_open(self.today - timedelta(days=10), user=self.plain)

    def test_the_day_after_the_lock_is_open(self):
        self.assertFalse(
            assert_period_open(self.today - timedelta(days=9), user=self.plain)
        )

    def test_a_holder_of_the_override_may_post_and_it_is_recorded(self):
        # Audit events are written on commit, so the callback has to be run for
        # the record to exist inside a test's transaction.
        with self.captureOnCommitCallbacks(execute=True):
            overridden = assert_period_open(
                self.today - timedelta(days=20),
                user=self.manager,
                entity_type="expense",
                entity_id=7,
                action="expense.save",
            )
        self.assertTrue(overridden)
        event = AnalyticsEvent.objects.filter(name="period_lock.override").first()
        self.assertIsNotNone(event)
        self.assertEqual(event.severity, AnalyticsEvent.Severity.WARNING)
        self.assertEqual(event.attributes["action"], "expense.save")

    def test_no_lock_means_nothing_is_closed(self):
        self._lock(None)
        self.assertFalse(period_is_locked(self.today - timedelta(days=400)))

    def test_the_refusal_names_the_date_and_the_lock(self):
        with self.assertRaises(PeriodLocked) as caught:
            assert_period_open(self.today - timedelta(days=20), user=self.plain)
        message = str(caught.exception)
        self.assertIn((self.today - timedelta(days=10)).isoformat(), message)
        self.assertIn((self.today - timedelta(days=20)).isoformat(), message)


class BackdatedWriteTests(TestCase):
    """The paths a closed month can actually be changed through."""

    def setUp(self):
        ensure_role_groups()
        User = get_user_model()
        self.accountant = User.objects.create_user(username="lock-acc", password="p")
        self.accountant.groups.add(Group.objects.get(name=ACCOUNTANT_GROUP))
        self.today = timezone.localdate()
        self.closed_day = self.today - timedelta(days=20)

        settings = ShopSettings.load()
        settings.books_locked_through = self.today - timedelta(days=10)
        settings.save(update_fields=["books_locked_through", "updated_at"])

        self.category, _ = ExpenseCategory.objects.get_or_create(name="مصروف الاختبار")
        self.client = APIClient()
        self.client.force_authenticate(user=self.accountant)

    def _post_expense(self, spent_at):
        return self.client.post(
            reverse("expense-list"),
            {
                "category": self.category.pk,
                "description": "إيجار الشهر",
                "amount": "100.00",
                "payment_method": Expense.PaymentMethod.CASH,
                "spent_at": spent_at.isoformat(),
            },
            format="json",
        )

    def test_a_backdated_expense_into_a_closed_month_is_refused(self):
        response = self._post_expense(self.closed_day)
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)
        self.assertEqual(Expense.objects.count(), 0)

    def test_an_expense_in_the_open_period_is_accepted(self):
        response = self._post_expense(self.today)
        self.assertEqual(response.status_code, status.HTTP_201_CREATED)

    def test_moving_an_expense_out_of_a_closed_month_is_refused_too(self):
        """Both dates are checked on an edit.

        Moving an expense *out of* a closed period changes that period's total
        just as surely as moving one in.
        """
        settings = ShopSettings.load()
        settings.books_locked_through = None
        settings.save(update_fields=["books_locked_through", "updated_at"])
        expense = Expense.objects.create(
            category=self.category,
            description="قديم",
            amount=Decimal("50.00"),
            payment_method=Expense.PaymentMethod.CASH,
            spent_at=self.closed_day,
        )
        settings.books_locked_through = self.today - timedelta(days=10)
        settings.save(update_fields=["books_locked_through", "updated_at"])

        response = self.client.patch(
            reverse("expense-detail", args=[expense.pk]),
            {"spent_at": self.today.isoformat()},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)

    def test_retracting_out_of_a_closed_month_is_refused(self):
        settings = ShopSettings.load()
        settings.books_locked_through = None
        settings.save(update_fields=["books_locked_through", "updated_at"])
        expense = Expense.objects.create(
            category=self.category,
            description="قديم",
            amount=Decimal("50.00"),
            payment_method=Expense.PaymentMethod.CASH,
            spent_at=self.closed_day,
        )
        settings.books_locked_through = self.today - timedelta(days=10)
        settings.save(update_fields=["books_locked_through", "updated_at"])

        # Deleting used to be the way to make an expense stop counting, and it
        # was refused here. Cancelling is that way now, and it is refused for
        # the same reason: the month it belongs to has been reported.
        response = self.client.post(
            reverse("expense-cancel", args=[expense.pk]),
            {"reason": "متأخر"},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)
        expense.refresh_from_db()
        self.assertEqual(expense.doc_status, "submitted")


class PeriodLockApiTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        User = get_user_model()
        self.accountant = User.objects.create_user(username="api-acc", password="p")
        self.accountant.groups.add(Group.objects.get(name=ACCOUNTANT_GROUP))
        self.cashier = User.objects.create_user(username="api-cashier", password="p")
        self.cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.today = timezone.localdate()
        self.url = reverse("report-period-lock")

    def _client(self, user):
        client = APIClient()
        client.force_authenticate(user=user)
        return client

    def test_an_accountant_can_close_a_period(self):
        response = self._client(self.accountant).post(
            self.url, {"locked_through": self.today.isoformat()}, format="json"
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(ShopSettings.load().books_locked_through, self.today)

    def test_a_cashier_cannot(self):
        response = self._client(self.cashier).post(
            self.url, {"locked_through": self.today.isoformat()}, format="json"
        )
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)

    def test_re_opening_needs_an_explicit_acknowledgement(self):
        client = self._client(self.accountant)
        client.post(self.url, {"locked_through": self.today.isoformat()}, format="json")

        response = client.post(
            self.url,
            {"locked_through": (self.today - timedelta(days=30)).isoformat()},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(
            str(response.data["code"]), "period_reopen_requires_acknowledgement"
        )
        self.assertEqual(ShopSettings.load().books_locked_through, self.today)

    def test_an_acknowledged_re_opening_is_allowed_and_recorded_as_a_warning(self):
        client = self._client(self.accountant)
        client.post(self.url, {"locked_through": self.today.isoformat()}, format="json")
        with self.captureOnCommitCallbacks(execute=True):
            response = client.post(
                self.url,
                {
                    "locked_through": (self.today - timedelta(days=30)).isoformat(),
                    "acknowledged": True,
                    "note": "correcting a supplier invoice",
                },
                format="json",
            )
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        event = AnalyticsEvent.objects.filter(
            name="period_lock.changed", severity=AnalyticsEvent.Severity.WARNING
        ).first()
        self.assertIsNotNone(event)
        self.assertTrue(event.attributes["reopened"])
        self.assertEqual(event.attributes["note"], "correcting a supplier invoice")

    def test_the_fiscal_year_is_set_through_the_same_endpoint(self):
        """The accounting calendar is one control, not two screens.

        The fiscal year decides what "this year" means in every report, and the
        role that owns it — the accountant — deliberately does not hold
        permission to edit shop settings.
        """
        response = self._client(self.accountant).post(
            self.url, {"fiscal_year_start_month": 7}, format="json"
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["fiscal_year_start_month"], 7)
        self.assertEqual(ShopSettings.load().fiscal_year_start_month, 7)

    def test_setting_only_the_fiscal_year_leaves_the_lock_alone(self):
        client = self._client(self.accountant)
        client.post(self.url, {"locked_through": self.today.isoformat()}, format="json")

        client.post(self.url, {"fiscal_year_start_month": 4}, format="json")
        self.assertEqual(ShopSettings.load().books_locked_through, self.today)

    def test_an_empty_body_is_refused(self):
        response = self._client(self.accountant).post(self.url, {}, format="json")
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_a_month_outside_the_year_is_refused(self):
        response = self._client(self.accountant).post(
            self.url, {"fiscal_year_start_month": 13}, format="json"
        )
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_the_fiscal_year_anchors_the_year_preset(self):
        """Non-vacuity: the setting has to actually move the window."""
        from .periods import Preset, resolve_period

        self._client(self.accountant).post(
            self.url, {"fiscal_year_start_month": 7}, format="json"
        )
        window = resolve_period({"preset": Preset.YEAR})
        self.assertEqual(window.start_date.month, 7)

    def test_the_lock_state_is_readable_by_any_reporting_role(self):
        response = self._client(self.accountant).get(self.url)
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertIn("can_manage", response.data)
        self.assertTrue(response.data["can_manage"])


class LockedPeriodReportNoteTests(TestCase):
    """A report says whether the period it covers can still change."""

    def setUp(self):
        ensure_role_groups()
        User = get_user_model()
        self.manager = User.objects.create_user(username="note-mgr", password="p")
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.today = timezone.localdate()

    def _notes(self, **params):
        from .models import ReportRun
        from .services import generate_report_payload

        payload = generate_report_payload(
            report_type=ReportRun.ReportType.SALES_SUMMARY,
            params=params,
            user=self.manager,
        )
        return {note["code"] for note in payload["notes"]}

    def test_an_open_period_is_marked_open(self):
        self.assertIn("period_open", self._notes(preset="month"))

    def test_a_closed_period_is_marked_closed(self):
        settings = ShopSettings.load()
        settings.books_locked_through = self.today
        settings.save(update_fields=["books_locked_through", "updated_at"])
        self.assertIn("period_closed", self._notes(preset="last_month"))
