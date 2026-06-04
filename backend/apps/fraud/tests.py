from datetime import timedelta
from decimal import Decimal

from django.conf import settings
from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.utils import timezone

from apps.analytics.models import AnalyticsEvent
from apps.catalog.testing import create_product_with_default_variant
from apps.core.roles import CASHIER_GROUP, MANAGER_GROUP, ensure_role_groups
from apps.notifications.models import BusinessNotification
from apps.notifications.services import sync_business_notifications
from apps.payments.models import Payment
from apps.sales.models import Order, OrderAdjustment, OrderLine, RegisterSession

from .models import FraudFinding
from .services import sync_suspected_fraud_findings


class FraudDetectionTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        User = get_user_model()
        self.manager = User.objects.create_user(
            username="fraud-manager",
            password="pass",
        )
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.cashier = User.objects.create_user(
            username="fraud-cashier",
            password="pass",
        )
        self.cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.peer = User.objects.create_user(username="fraud-peer", password="pass")
        self.peer.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.product = create_product_with_default_variant(
            name="قهوة اختبار الاشتباه",
            sku="FRD-COF",
            unit_price=Decimal("10.00"),
        )
        self.variant = self.product.default_variant

    def test_late_void_creates_finding_and_manager_notification(self):
        order = self._paid_order(
            user=self.cashier,
            total=Decimal("90.00"),
            created_at=timezone.now() - timedelta(days=3),
        )
        OrderAdjustment.objects.create(
            order=order,
            register_session=order.register_session,
            adjustment_type=OrderAdjustment.AdjustmentType.VOID,
            amount=Decimal("90.00"),
            refund_method=Payment.Method.CASH,
            reason="Manager review",
            created_by=self.cashier,
            created_at=timezone.now(),
        )

        result = sync_suspected_fraud_findings()

        self.assertGreaterEqual(result.generated, 1)
        late_finding = FraudFinding.objects.get(rule_code="late_void_or_return")
        self.assertEqual(late_finding.status, FraudFinding.Status.ACTIVE)
        self.assertEqual(late_finding.target_user, self.cashier)
        self.assertGreaterEqual(late_finding.risk_score, 75)
        self.assertEqual(
            late_finding.summary["review_wording"],
            "suspected_activity",
        )
        self.assertIn("late_void_or_return", late_finding.evidence)

        sync_business_notifications()
        notification = BusinessNotification.objects.get(
            code="fraud.suspected_cashier_activity",
            entity_type="fraud.fraudfinding",
            entity_id=str(late_finding.pk),
        )
        self.assertEqual(notification.category, "fraud")
        self.assertEqual(notification.payload["user_id"], self.cashier.pk)
        self.assertEqual(
            notification.payload["investigation_query"]["received_by"],
            str(self.cashier.pk),
        )

    def test_peer_outlier_discount_pattern_is_detected(self):
        for index in range(4):
            self._paid_order(
                user=self.peer,
                total=Decimal("40.00"),
                subtotal=Decimal("40.00"),
                discount_total=Decimal("0.00"),
                receipt=f"PEER-{index}",
            )
        for index in range(4):
            self._paid_order(
                user=self.cashier,
                total=Decimal("20.00"),
                subtotal=Decimal("40.00"),
                discount_total=Decimal("20.00"),
                receipt=f"DISC-{index}",
            )

        result = sync_suspected_fraud_findings()

        self.assertGreaterEqual(result.generated, 1)
        finding = FraudFinding.objects.get(rule_code="discount_peer_outlier")
        self.assertEqual(finding.target_user, self.cashier)
        self.assertEqual(finding.metrics["discount_total"], "80.00")
        self.assertTrue(finding.peer_metrics["peer_outlier"])
        self.assertIn("discount_peer_outlier", finding.evidence)

    def test_repeated_sync_does_not_duplicate_detection_audit_events(self):
        order = self._paid_order(
            user=self.cashier,
            total=Decimal("90.00"),
            created_at=timezone.now() - timedelta(days=3),
        )
        OrderAdjustment.objects.create(
            order=order,
            register_session=order.register_session,
            adjustment_type=OrderAdjustment.AdjustmentType.VOID,
            amount=Decimal("90.00"),
            refund_method=Payment.Method.CASH,
            reason="Manager review",
            created_by=self.cashier,
            created_at=timezone.now(),
        )

        with self.captureOnCommitCallbacks(execute=True):
            first_result = sync_suspected_fraud_findings()
        event_count_after_first_sync = AnalyticsEvent.objects.filter(
            name="fraud.suspected_activity.detected",
        ).count()
        with self.captureOnCommitCallbacks(execute=True):
            second_result = sync_suspected_fraud_findings()

        self.assertGreaterEqual(first_result.generated, 1)
        self.assertGreaterEqual(event_count_after_first_sync, 1)
        self.assertEqual(second_result.generated, 0)
        self.assertEqual(
            AnalyticsEvent.objects.filter(
                name="fraud.suspected_activity.detected",
            ).count(),
            event_count_after_first_sync,
        )

    def test_notification_sync_does_not_trigger_detection(self):
        order = self._paid_order(
            user=self.cashier,
            total=Decimal("90.00"),
            created_at=timezone.now() - timedelta(days=3),
        )
        OrderAdjustment.objects.create(
            order=order,
            register_session=order.register_session,
            adjustment_type=OrderAdjustment.AdjustmentType.VOID,
            amount=Decimal("90.00"),
            refund_method=Payment.Method.CASH,
            reason="Manager review",
            created_by=self.cashier,
            created_at=timezone.now(),
        )

        sync_business_notifications()

        self.assertFalse(FraudFinding.objects.exists())
        self.assertFalse(
            BusinessNotification.objects.filter(
                code="fraud.suspected_cashier_activity",
            ).exists()
        )

    def test_fraud_detection_is_scheduled_in_celery_beat(self):
        schedule = settings.CELERY_BEAT_SCHEDULE[
            "fraud.sync-suspected-fraud-findings"
        ]

        self.assertEqual(schedule["task"], "fraud.sync_suspected_fraud_findings")
        self.assertEqual(
            schedule["schedule"].total_seconds(),
            settings.POINTY_FRAUD_DETECTION_INTERVAL_MINUTES * 60,
        )

    def _paid_order(
        self,
        *,
        user,
        total,
        subtotal=None,
        discount_total=Decimal("0.00"),
        created_at=None,
        receipt="",
    ):
        created_at = created_at or timezone.now()
        session = RegisterSession.objects.create(
            owner=user,
            owner_key=f"user:{user.pk}:{receipt or total}",
            status=RegisterSession.Status.CLOSED,
            opening_cash=Decimal("0.00"),
            closing_cash=Decimal("0.00"),
            opened_at=created_at - timedelta(hours=1),
            closed_at=created_at + timedelta(hours=1),
        )
        order = Order.objects.create(
            register_session=session,
            status=Order.Status.PAID,
            subtotal=subtotal or total,
            discount_total=discount_total,
            total=total,
        )
        Order.objects.filter(pk=order.pk).update(
            created_at=created_at,
            updated_at=created_at,
        )
        order.refresh_from_db()
        if receipt:
            order.receipt_number = receipt
            order.save(update_fields=["receipt_number"])
        OrderLine.objects.create(
            order=order,
            variant=self.variant,
            quantity=1,
            unit_price=subtotal or total,
            discount_total=discount_total,
        )
        Payment.objects.create(order=order, method=Payment.Method.CASH, amount=total)
        return order
