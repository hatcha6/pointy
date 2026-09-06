"""The closed month, stored without anyone remembering to store it.

A report that exists only when somebody presses a button is a report nobody has
for the month they most need it — and the verification endpoint has nothing to
compare against, because the baseline it wants is a run taken while the month
was fresh. These tests pin the three properties that make the snapshot
trustworthy: it fires on the shop's own day, it happens exactly once per month
however many times the task runs, and it sees the whole shop rather than the
scheduler's (non-existent) till.
"""

from datetime import date, timedelta
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.utils import timezone

from apps.catalog.testing import create_product_with_default_variant
from apps.core.models import ShopSettings
from apps.core.roles import CASHIER_GROUP, ensure_role_groups
from apps.payments.models import Payment
from apps.sales.models import Order, OrderLine, RegisterSession

from .models import ReportRun
from .tasks import snapshot_month_end


class MonthEndSnapshotTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        User = get_user_model()
        self.cashier = User.objects.create_user(username="snap-cashier", password="p")
        self.cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))

        self.today = date(2026, 9, 1)
        self.last_month_day = date(2026, 8, 15)

        product = create_product_with_default_variant(
            sku="SNAP-1", name="سلعة", unit_price=Decimal("10.00")
        )
        # The sale belongs to the cashier's till. The scheduler owns no till, so
        # a snapshot that scoped itself the way a user is scoped would record a
        # month in which the shop sold nothing.
        session = RegisterSession.objects.create(
            owner=self.cashier,
            owner_key=f"user:{self.cashier.pk}",
            opening_cash=Decimal("0.00"),
        )
        order = Order.objects.create(
            register_session=session,
            status=Order.Status.PAID,
            subtotal=Decimal("20.00"),
            total=Decimal("20.00"),
        )
        OrderLine.objects.create(
            order=order,
            variant=product.default_variant,
            quantity=2,
            unit_price=Decimal("10.00"),
            unit_cost=Decimal("4.00"),
        )
        when = timezone.make_aware(
            timezone.datetime.combine(self.last_month_day, timezone.datetime.min.time())
        )
        # Dated at creation: when the money moved is part of what a payment
        # says, and it says it from the moment it exists.
        Payment.objects.create(
            order=order,
            method=Payment.Method.CASH,
            amount=Decimal("20.00"),
            paid_at=when,
        )
        Order.objects.filter(pk=order.pk).update(created_at=when)

    def _settings(self, **fields):
        settings = ShopSettings.load()
        for name, value in fields.items():
            setattr(settings, name, value)
        settings.save()
        return settings

    def test_it_stores_the_whole_previous_month(self):
        result = snapshot_month_end(today=self.today)
        run = ReportRun.objects.get(pk=result["run_id"])

        self.assertEqual(run.report_type, ReportRun.ReportType.MONTH_END_PACK)
        self.assertEqual(run.status, ReportRun.Status.SUCCESS)
        self.assertEqual(run.params["start_date"], "2026-08-01")
        self.assertEqual(run.params["end_date"], "2026-08-31")

    def test_the_scheduler_sees_the_shop_not_its_own_till(self):
        """Non-vacuity, and the defect this would otherwise repeat."""
        result = snapshot_month_end(today=self.today)
        run = ReportRun.objects.get(pk=result["run_id"])
        self.assertEqual(run.payload["summary"]["profit_costs__net_sales"], "20.00")

    def test_it_only_fires_on_the_configured_day(self):
        self._settings(month_end_snapshot_day=5)
        self.assertEqual(
            snapshot_month_end(today=self.today)["skipped"], "not_snapshot_day"
        )
        self.assertEqual(ReportRun.objects.count(), 0)

        result = snapshot_month_end(today=date(2026, 9, 5))
        self.assertIn("run_id", result)

    def test_zero_turns_it_off(self):
        self._settings(month_end_snapshot_day=0)
        self.assertEqual(
            snapshot_month_end(today=self.today)["skipped"], "not_snapshot_day"
        )

    def test_running_twice_stores_one_snapshot(self):
        """A retry, a second worker and a double-fired beat all produce one."""
        first = snapshot_month_end(today=self.today)
        second = snapshot_month_end(today=self.today)

        self.assertEqual(second["skipped"], "already_taken")
        self.assertEqual(second["run_id"], first["run_id"])
        self.assertEqual(
            ReportRun.objects.filter(
                report_type=ReportRun.ReportType.MONTH_END_PACK
            ).count(),
            1,
        )

    def test_the_snapshot_is_its_own_baseline(self):
        """What the whole thing is for.

        The stored figures checksum is what a later verification compares
        against, so the snapshot has to carry one.
        """
        run = ReportRun.objects.get(pk=snapshot_month_end(today=self.today)["run_id"])
        self.assertTrue(run.figures_checksum)

    def test_it_stores_even_when_nothing_can_be_messaged(self):
        """The snapshot is the deliverable; the message is the notification."""
        self._settings(month_end_report_phone="")
        result = snapshot_month_end(today=self.today)
        self.assertIn("run_id", result)
        self.assertFalse(result["notified"])

    def test_a_configured_number_is_messaged_with_the_headline(self):
        from apps.messaging.models import MessagingGateway, OutboundMessage

        MessagingGateway.objects.create(
            name="بوابة",
            channel=MessagingGateway.Channel.SMS,
            provider=MessagingGateway.Provider.SMS_GATE,
            is_active=True,
        )
        self._settings(month_end_report_phone="0912345678")

        result = snapshot_month_end(today=self.today)
        self.assertTrue(result["notified"])

        message = OutboundMessage.objects.get()
        self.assertIn("20.00", message.body)
        self.assertEqual(message.dedup_key, "month-end:2026-08-01")

    def test_a_month_with_no_trade_still_gets_a_snapshot(self):
        """An empty month is a fact about the month, not a reason to skip it."""
        Payment.objects.all().delete()
        OrderLine.objects.all().delete()
        Order.objects.all().delete()
        result = snapshot_month_end(today=self.today)
        run = ReportRun.objects.get(pk=result["run_id"])
        self.assertEqual(run.payload["summary"]["profit_costs__net_sales"], "0.00")

    def test_the_window_is_always_the_whole_previous_month(self):
        for today, expected in [
            (date(2026, 1, 1), ("2025-12-01", "2025-12-31")),
            (date(2026, 3, 1), ("2026-02-01", "2026-02-28")),
            (date(2024, 3, 1), ("2024-02-01", "2024-02-29")),
        ]:
            with self.subTest(today=today):
                ReportRun.objects.all().delete()
                result = snapshot_month_end(today=today, force=True)
                run = ReportRun.objects.get(pk=result["run_id"])
                self.assertEqual(
                    (run.params["start_date"], run.params["end_date"]), expected
                )

    def test_a_snapshot_of_a_closed_period_says_so(self):
        self._settings(books_locked_through=date(2026, 8, 31))
        run = ReportRun.objects.get(pk=snapshot_month_end(today=self.today)["run_id"])
        codes = {note["code"] for note in run.payload["notes"]}
        self.assertIn("period_closed", codes)

    def test_the_snapshot_compares_against_the_month_before(self):
        run = ReportRun.objects.get(pk=snapshot_month_end(today=self.today)["run_id"])
        self.assertEqual(
            run.payload["period"]["compared_to"]["start_date"], "2026-07-01"
        )


class SnapshotBoundaryTests(TestCase):
    """The snapshot must not reach into the month it runs in."""

    def setUp(self):
        ensure_role_groups()
        User = get_user_model()
        cashier = User.objects.create_user(username="edge-cashier", password="p")
        cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.session = RegisterSession.objects.create(
            owner=cashier,
            owner_key=f"user:{cashier.pk}",
            opening_cash=Decimal("0.00"),
        )

    def _sale(self, when, total):
        order = Order.objects.create(
            register_session=self.session,
            status=Order.Status.PAID,
            subtotal=Decimal(total),
            total=Decimal(total),
        )
        Order.objects.filter(pk=order.pk).update(
            created_at=timezone.make_aware(
                timezone.datetime.combine(when, timezone.datetime.min.time())
            )
            + timedelta(hours=12)
        )

    def test_the_last_day_is_in_and_the_first_of_this_month_is_out(self):
        self._sale(date(2026, 8, 31), "5.00")
        self._sale(date(2026, 9, 1), "99.00")

        run = ReportRun.objects.get(
            pk=snapshot_month_end(today=date(2026, 9, 1))["run_id"]
        )
        self.assertEqual(run.payload["summary"]["profit_costs__net_sales"], "5.00")
