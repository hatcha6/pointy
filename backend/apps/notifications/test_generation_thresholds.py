"""Tests for business-notification generation thresholds, idempotency and
crash-safety.

These tests drive ``apps.notifications.services.sync_business_notifications``
directly and inspect the persisted ``BusinessNotification`` rows, complementing
``apps.notifications.tests`` (which exercises the API list endpoint and the
per-user visibility/dismiss flow). The focus here is on the numeric thresholds
and severity bands that decide *whether* (and at what severity) a notification is
generated, plus the get_or_create idempotency contract of ``_upsert_notification``.
"""

from datetime import timedelta
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.utils import timezone

from apps.catalog.testing import create_product_with_default_variant
from apps.core.roles import MANAGER_GROUP, ensure_role_groups
from apps.discounts.models import DiscountRule
from apps.inventory.models import StockBatch, StockItem
from apps.notifications.models import (
    BusinessNotification,
    BusinessNotificationUserState,
)
from apps.notifications.services import (
    acknowledge_notification,
    sync_business_notifications,
    visible_notifications_for_user,
)
from apps.purchasing.models import PurchaseOrder, PurchaseReceipt, Supplier
from apps.sales.models import Order, OrderLine, RegisterSession


def _make_stock(name, sku, qty, reorder_level=5, unit_price="3.00"):
    product = create_product_with_default_variant(
        name=name,
        sku=sku,
        unit_price=Decimal(unit_price),
    )
    StockItem.objects.create(
        variant=product.default_variant,
        quantity_on_hand=Decimal(str(qty)),
        reorder_level=reorder_level,
    )
    return product


def _make_expiring_batch(name, sku, *, expiry_date, tracks_expiry=True, remaining="5"):
    """Build the full PO -> receipt -> receipt line -> batch chain the expiry
    generator walks (StockBatch.source_receipt_line is a non-null OneToOne)."""
    product = create_product_with_default_variant(
        name=name,
        sku=sku,
        unit_price=Decimal("6.00"),
    )
    if tracks_expiry != product.tracks_expiry:
        product.tracks_expiry = tracks_expiry
        product.save(update_fields=["tracks_expiry", "updated_at"])
    supplier = Supplier.objects.create(name=f"supplier-{sku}")
    order = PurchaseOrder.objects.create(supplier=supplier)
    purchase_line = order.lines.create(
        variant=product.default_variant,
        quantity=5,
        unit_cost=Decimal("4.00"),
        expiry_date=expiry_date,
    )
    receipt = PurchaseReceipt.objects.create(purchase_order=order)
    receipt_line = receipt.lines.create(
        purchase_line=purchase_line,
        variant=product.default_variant,
        ordered_quantity=5,
        outstanding_before=5,
        accepted_quantity=5,
        outstanding_after=0,
        expiry_date=expiry_date,
    )
    batch = StockBatch.objects.create(
        variant=product.default_variant,
        source_receipt_line=receipt_line,
        expiry_date=expiry_date,
        received_quantity=5,
        remaining_quantity=Decimal(remaining),
    )
    return product, batch


def _closed_session(owner, *, opening, closing, suffix=""):
    """A CLOSED session with a controllable cash variance: with no orders or
    cash movements, expected_cash == opening_cash, so variance == closing - opening."""
    return RegisterSession.objects.create(
        owner=owner,
        owner_key=f"user:{owner.pk}:closed:{suffix}",
        status=RegisterSession.Status.CLOSED,
        opening_cash=Decimal(opening),
        closing_cash=Decimal(closing),
        closed_at=timezone.now(),
    )


def _negative_margin_order(*, unit_price, unit_cost, quantity="1", discount_total="0"):
    """Create a PAID order with a single line sold below cost (revenue > 0,
    cost > revenue). created_at is auto_now_add (== now)."""
    product = create_product_with_default_variant(
        name="loss-leader",
        sku="LOSS-1",
        unit_price=Decimal(unit_price),
    )
    order = Order.objects.create(status=Order.Status.PAID)
    OrderLine.objects.create(
        order=order,
        variant=product.default_variant,
        quantity=Decimal(quantity),
        unit_price=Decimal(unit_price),
        unit_cost=Decimal(unit_cost),
        discount_total=Decimal(discount_total),
    )
    return order


def _active(code):
    return BusinessNotification.objects.filter(
        code=code,
        status=BusinessNotification.Status.ACTIVE,
    )


class NotificationGenerationThresholdTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        User = get_user_model()
        self.manager = User.objects.create_user(username="thresh-mgr", password="pass")
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))

    # ------------------------------------------------------------------ #
    # 1. Idempotency (get_or_create) regression
    # ------------------------------------------------------------------ #
    def test_sync_is_idempotent_no_duplicate_rows(self):
        _make_stock("Coffee", "IDEM-COF", qty=0, reorder_level=5)

        now1 = timezone.now()
        sync_business_notifications(now=now1)
        count_after_first = BusinessNotification.objects.count()
        self.assertEqual(count_after_first, 1)

        notification = BusinessNotification.objects.get(code="inventory.out_of_stock")
        first_seen = notification.first_seen_at
        last_seen_1 = notification.last_seen_at

        now2 = now1 + timedelta(minutes=20)
        sync_business_notifications(now=now2)

        # Same number of rows, no duplicate fingerprint, advances last_seen_at.
        self.assertEqual(BusinessNotification.objects.count(), count_after_first)
        notification.refresh_from_db()
        self.assertEqual(notification.first_seen_at, first_seen)
        self.assertEqual(notification.last_seen_at, now2)
        self.assertGreater(notification.last_seen_at, last_seen_1)
        # Re-running an already-active alert must NOT bump occurrence_count.
        self.assertEqual(notification.occurrence_count, 1)
        self.assertEqual(
            BusinessNotification.objects.filter(
                fingerprint=notification.fingerprint
            ).count(),
            1,
        )

    def test_resolved_then_reappearing_alert_reactivates_and_counts_occurrence(self):
        product = _make_stock("Sugar", "IDEM-SUG", qty=0, reorder_level=5)
        stock = StockItem.objects.get(variant=product.default_variant)

        sync_business_notifications()
        notification = _active("inventory.out_of_stock").get()
        self.assertEqual(notification.occurrence_count, 1)

        # Condition clears -> resolved.
        stock.quantity_on_hand = Decimal("10")
        stock.save(update_fields=["quantity_on_hand", "updated_at"])
        sync_business_notifications()
        notification.refresh_from_db()
        self.assertEqual(notification.status, BusinessNotification.Status.RESOLVED)

        # Condition returns -> reactivated, occurrence_count incremented, same row.
        stock.quantity_on_hand = Decimal("0")
        stock.save(update_fields=["quantity_on_hand", "updated_at"])
        sync_business_notifications()
        reborn = _active("inventory.out_of_stock").get()
        self.assertEqual(reborn.pk, notification.pk)
        self.assertEqual(reborn.occurrence_count, 2)

    # ------------------------------------------------------------------ #
    # 2. Low-stock / out-of-stock thresholds
    # ------------------------------------------------------------------ #
    def test_qty_equal_to_reorder_level_is_low_stock_warning(self):
        _make_stock("AtThreshold", "LS-EQ", qty=5, reorder_level=5)
        sync_business_notifications()

        self.assertFalse(_active("inventory.out_of_stock").exists())
        warning = _active("inventory.low_stock").get()
        self.assertEqual(warning.severity, BusinessNotification.Severity.WARNING)
        self.assertEqual(warning.payload["quantity"], 5)
        self.assertEqual(warning.payload["threshold"], 5)

    def test_qty_one_above_reorder_level_produces_nothing(self):
        _make_stock("AboveThreshold", "LS-AB", qty=6, reorder_level=5)
        sync_business_notifications()

        self.assertFalse(_active("inventory.low_stock").exists())
        self.assertFalse(_active("inventory.out_of_stock").exists())

    def test_qty_zero_or_below_is_out_of_stock_critical(self):
        _make_stock("Empty", "LS-ZERO", qty=0, reorder_level=5)
        _make_stock("Negative", "LS-NEG", qty=-2, reorder_level=5)
        sync_business_notifications()

        self.assertFalse(_active("inventory.low_stock").exists())
        critical = _active("inventory.out_of_stock")
        self.assertEqual(critical.count(), 2)
        for notification in critical:
            self.assertEqual(
                notification.severity, BusinessNotification.Severity.CRITICAL
            )

    # ------------------------------------------------------------------ #
    # 3. Expiry severity bands
    # ------------------------------------------------------------------ #
    def test_expiry_within_one_day_is_critical(self):
        today = timezone.localdate()
        _make_expiring_batch("MilkTomorrow", "EXP-1D", expiry_date=today + timedelta(days=1))
        sync_business_notifications()

        notification = _active("inventory.expiring_batch").get()
        self.assertEqual(notification.severity, BusinessNotification.Severity.CRITICAL)
        self.assertEqual(notification.payload["days"], 1)

    def test_expiry_within_week_is_warning(self):
        today = timezone.localdate()
        _make_expiring_batch("MilkInFive", "EXP-5D", expiry_date=today + timedelta(days=5))
        sync_business_notifications()

        notification = _active("inventory.expiring_batch").get()
        self.assertEqual(notification.severity, BusinessNotification.Severity.WARNING)
        self.assertEqual(notification.payload["days"], 5)

    def test_expiry_beyond_window_produces_nothing(self):
        # Window default is 30 days; 40 days out is outside it.
        today = timezone.localdate()
        _make_expiring_batch("MilkFarOut", "EXP-FAR", expiry_date=today + timedelta(days=40))
        sync_business_notifications()

        self.assertFalse(_active("inventory.expiring_batch").exists())

    def test_expiry_ignored_when_product_does_not_track_expiry(self):
        today = timezone.localdate()
        _make_expiring_batch(
            "NoTrack",
            "EXP-NOTRACK",
            expiry_date=today + timedelta(days=2),
            tracks_expiry=False,
        )
        sync_business_notifications()

        self.assertFalse(_active("inventory.expiring_batch").exists())

    # ------------------------------------------------------------------ #
    # 4. Register variance bands
    # ------------------------------------------------------------------ #
    def test_register_variance_small_is_warning(self):
        _closed_session(self.manager, opening="100.00", closing="80.00", suffix="warn")
        sync_business_notifications()

        notification = _active("sales.register_variance").get()
        self.assertEqual(notification.severity, BusinessNotification.Severity.WARNING)
        # variance is reported as an absolute amount string.
        self.assertEqual(notification.payload["amount"], "20.00")

    def test_register_variance_large_is_critical(self):
        # abs(variance) >= 100 -> critical. closing - opening = -150.
        _closed_session(self.manager, opening="200.00", closing="50.00", suffix="crit")
        sync_business_notifications()

        notification = _active("sales.register_variance").get()
        self.assertEqual(notification.severity, BusinessNotification.Severity.CRITICAL)
        self.assertEqual(notification.payload["amount"], "150.00")

    def test_register_variance_boundary_exactly_100_is_critical(self):
        _closed_session(self.manager, opening="100.00", closing="200.00", suffix="bound")
        sync_business_notifications()

        notification = _active("sales.register_variance").get()
        self.assertEqual(notification.severity, BusinessNotification.Severity.CRITICAL)
        self.assertEqual(notification.payload["amount"], "100.00")

    def test_zero_variance_produces_no_notification(self):
        _closed_session(self.manager, opening="100.00", closing="100.00", suffix="zero")
        sync_business_notifications()

        self.assertFalse(_active("sales.register_variance").exists())

    # ------------------------------------------------------------------ #
    # 5. Discount expiry day rounding regression
    # ------------------------------------------------------------------ #
    def _discount_rule(self, name, *, ends_at):
        return DiscountRule.objects.create(
            name=name,
            channel=DiscountRule.Channel.SALES,
            value_type=DiscountRule.ValueType.PERCENTAGE,
            value=Decimal("10.0000"),
            is_active=True,
            ends_at=ends_at,
        )

    def test_discount_ending_in_36_hours_rounds_up_to_two_days_warning(self):
        now = timezone.now()
        self._discount_rule("Flash36h", ends_at=now + timedelta(hours=36))
        sync_business_notifications(now=now)

        notification = _active("discounts.expiring_rule").get()
        # 36h truncates to 1 with timedelta.days; the fix ceilings it to 2.
        self.assertGreaterEqual(notification.payload["days"], 2)
        self.assertEqual(notification.payload["days"], 2)
        self.assertEqual(notification.severity, BusinessNotification.Severity.WARNING)

    def test_discount_ending_in_six_days_is_info(self):
        now = timezone.now()
        self._discount_rule("SixDays", ends_at=now + timedelta(days=6))
        sync_business_notifications(now=now)

        notification = _active("discounts.expiring_rule").get()
        self.assertEqual(notification.payload["days"], 6)
        self.assertEqual(notification.severity, BusinessNotification.Severity.INFO)

    def test_discount_ending_in_few_hours_is_at_least_one_day_warning(self):
        now = timezone.now()
        # ~6 hours left: ceiling of 0.25 days is 1, never 0 for an active rule.
        self._discount_rule("Almost", ends_at=now + timedelta(hours=6))
        sync_business_notifications(now=now)

        notification = _active("discounts.expiring_rule").get()
        self.assertGreaterEqual(notification.payload["days"], 1)
        self.assertEqual(notification.payload["days"], 1)
        self.assertEqual(notification.severity, BusinessNotification.Severity.WARNING)

    def test_discount_already_ended_or_far_future_produces_nothing(self):
        now = timezone.now()
        self._discount_rule("Expired", ends_at=now - timedelta(hours=1))
        self._discount_rule("FarFuture", ends_at=now + timedelta(days=30))
        sync_business_notifications(now=now)

        self.assertFalse(_active("discounts.expiring_rule").exists())

    # ------------------------------------------------------------------ #
    # 6. Negative margin generator
    # ------------------------------------------------------------------ #
    def test_negative_margin_order_produces_critical(self):
        _negative_margin_order(unit_price="5.00", unit_cost="8.00")
        # auto_now_add stamps created_at == real now; sync with a slightly later
        # `now` so the order falls inside [now-30d, now).
        sync_business_notifications(now=timezone.now() + timedelta(seconds=1))

        notification = _active("sales.negative_margin").get()
        self.assertEqual(notification.severity, BusinessNotification.Severity.CRITICAL)
        # revenue 5, cost 8 -> loss 3.00.
        self.assertEqual(notification.payload["amount"], "3.00")
        self.assertEqual(notification.payload["days"], 30)
        self.assertEqual(notification.payload["count"], 1)

    def test_profitable_sales_produce_no_negative_margin(self):
        product = create_product_with_default_variant(
            name="winner", sku="WIN-1", unit_price=Decimal("10.00")
        )
        order = Order.objects.create(status=Order.Status.PAID)
        OrderLine.objects.create(
            order=order,
            variant=product.default_variant,
            quantity=Decimal("1"),
            unit_price=Decimal("10.00"),
            unit_cost=Decimal("4.00"),
        )
        sync_business_notifications(now=timezone.now() + timedelta(seconds=1))

        self.assertFalse(_active("sales.negative_margin").exists())

    # ------------------------------------------------------------------ #
    # 7. Empty-DB crash safety
    # ------------------------------------------------------------------ #
    def test_sync_on_empty_db_does_not_raise(self):
        # Nothing seeded beyond the migration fixtures; sync must run cleanly
        # and produce zero managed notifications.
        result = sync_business_notifications()

        self.assertIsInstance(result, dict)
        self.assertEqual(result["generated"], 0)
        self.assertEqual(
            BusinessNotification.objects.filter(
                status=BusinessNotification.Status.ACTIVE
            ).count(),
            0,
        )

    # ------------------------------------------------------------------ #
    # 8. Per-user read state
    # ------------------------------------------------------------------ #
    def test_dismiss_hides_for_one_manager_but_not_another(self):
        User = get_user_model()
        other_manager = User.objects.create_user(
            username="thresh-mgr-2", password="pass"
        )
        other_manager.groups.add(Group.objects.get(name=MANAGER_GROUP))

        _make_stock("Shared", "STATE-1", qty=0, reorder_level=5)
        sync_business_notifications()
        notification = _active("inventory.out_of_stock").get()

        # Manager A dismisses (acknowledges) the notification.
        acknowledge_notification(notification, self.manager)

        visible_a = visible_notifications_for_user(self.manager)
        from apps.notifications.services import notification_is_hidden_for_user

        hidden_a, reason = notification_is_hidden_for_user(
            visible_a.get(pk=notification.pk), self.manager
        )
        self.assertTrue(hidden_a)
        self.assertEqual(reason, "acknowledged")

        # Manager B still sees it as not hidden.
        visible_b = visible_notifications_for_user(other_manager)
        hidden_b, _ = notification_is_hidden_for_user(
            visible_b.get(pk=notification.pk), other_manager
        )
        self.assertFalse(hidden_b)

        # Only one user-state row exists (Manager A's).
        self.assertEqual(
            BusinessNotificationUserState.objects.filter(
                notification=notification
            ).count(),
            1,
        )
        self.assertEqual(
            BusinessNotificationUserState.objects.get(
                notification=notification
            ).user_id,
            self.manager.pk,
        )
