"""Deterministic boundaries of the cashier fraud metrics.

``apps.fraud`` decides whether a named employee is presented to the owner as a
theft suspect, so a wrong denominator or a mis-attributed refund is not a
cosmetic defect — it accuses an honest cashier, or hides a real one. The
existing suite (``apps/fraud/tests.py``) covers the end-to-end sync, triage API
and one peer-outlier pattern; these pin the arithmetic boundaries underneath it:

* a refund that never touched the drawer must not read as a cash refund,
* a register that came up *over* must never read as a shortage,
* the "late adjustment" deadline is exclusive at exactly the window,
* cashiers who behave identically are never outliers of each other.
"""

from datetime import timedelta
from decimal import Decimal
from types import SimpleNamespace

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.utils import timezone

from apps.catalog.testing import create_product_with_default_variant
from apps.core.models import ShopSettings
from apps.core.roles import CASHIER_GROUP, MANAGER_GROUP, ensure_role_groups
from apps.inventory.models import StockItem
from apps.payments.models import Payment
from apps.sales.models import (
    Order,
    OrderAdjustment,
    OrderLine,
    RegisterSession,
)
from apps.sales.services import checkout_order, return_order_items

from .engine import detect_suspected_fraud
from .metrics import build_cashier_metrics


class RefundAttributionMetricTests(TestCase):
    """``cash_refund_*`` must follow the money out of the drawer.

    ``OrderAdjustment.cash_amount`` — not ``amount`` and not ``refund_method``
    — is the cash share of a refund. Reading either of the others turns a card
    refund, or the card half of a split refund, into evidence of cash-refund
    concentration against the cashier who processed it.
    """

    def setUp(self):
        ensure_role_groups()
        ShopSettings.load()
        User = get_user_model()
        self.user = User.objects.create_user(username="refund-cashier", password="pw")
        # Manager so the cashier adjustment window never blocks the return; this
        # suite is about the metric, not about who may press the button.
        self.user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.product = create_product_with_default_variant(
            name="Coffee", sku="FRD-BND-COF", unit_price="10.00", barcode=""
        )
        self.variant = self.product.default_variant
        StockItem.objects.create(variant=self.variant, quantity_on_hand=Decimal("50"))
        self.session = RegisterSession.objects.create(
            owner=self.user, owner_key=f"user:{self.user.pk}"
        )
        # Adjustments are attributed to the user on the request; the service
        # only reads ``request.user``.
        self.request = SimpleNamespace(user=self.user)

    def _window(self):
        now = timezone.now()
        return now - timedelta(days=30), now + timedelta(seconds=1)

    def _metrics(self):
        start, end = self._window()
        return build_cashier_metrics(start, end)[self.user.pk]

    def _checkout(self, payments):
        return checkout_order(
            register_session=self.session,
            lines_data=[{"variant": self.variant, "quantity": Decimal("2")}],
            payments_data=payments,
        )

    def test_card_only_refund_is_not_counted_as_a_cash_refund(self):
        # 20.00 paid entirely by card, then fully returned. Nothing left the
        # drawer, so the cashier's cash-refund exposure must stay at zero even
        # though a 20.00 return happened.
        order = self._checkout(
            [{"method": Payment.Method.CARD, "amount": Decimal("20.00")}]
        )
        return_order_items(
            order=order,
            lines=[(order.lines.get(), 2)],
            reason="card refund",
            request=self.request,
            register_session=self.session,
        )

        metrics = self._metrics()

        self.assertEqual(metrics.return_count, 1)
        self.assertEqual(metrics.return_amount, Decimal("20.00"))
        self.assertEqual(metrics.cash_refund_count, 0)
        self.assertEqual(metrics.cash_refund_amount, Decimal("0.00"))
        self.assertEqual(metrics.rate("cash_refund_rate"), 0.0)
        self.assertEqual(metrics.evidence["cash_refund_concentration"], [])

    def test_split_tender_refund_counts_only_the_cash_share(self):
        # 12.00 cash + 8.00 card on a 20.00 sale, fully returned: exactly the
        # 12.00 cash share leaves the drawer, so that — not the 20.00 refund —
        # is the cashier's cash-refund exposure.
        order = self._checkout(
            [
                {"method": Payment.Method.CASH, "amount": Decimal("12.00")},
                {"method": Payment.Method.CARD, "amount": Decimal("8.00")},
            ]
        )
        return_order_items(
            order=order,
            lines=[(order.lines.get(), 2)],
            reason="split refund",
            request=self.request,
            register_session=self.session,
        )

        metrics = self._metrics()

        self.assertEqual(metrics.return_amount, Decimal("20.00"))
        self.assertEqual(metrics.cash_refund_count, 1)
        self.assertEqual(metrics.cash_refund_amount, Decimal("12.00"))


class RegisterVarianceMetricTests(TestCase):
    """A drawer that came up *over* is not a shortage.

    ``cash_shortage_*`` drives both the absolute ``cash_shortage`` rule and the
    ``shortage_with_adjustments`` composite (the highest-scoring finding the
    engine emits). Counting an overage, or a dead-even drawer, as a shortage
    manufactures a critical theft finding out of a cashier who is exactly right
    or handed in too much.
    """

    def setUp(self):
        ensure_role_groups()
        User = get_user_model()
        self.user = User.objects.create_user(username="drawer-cashier", password="pw")
        self.user.groups.add(Group.objects.get(name=CASHIER_GROUP))

    def _closed_session(self, *, opening, closing):
        closed_at = timezone.now() - timedelta(hours=1)
        return RegisterSession.objects.create(
            owner=self.user,
            owner_key=f"user:{self.user.pk}:{closing}",
            status=RegisterSession.Status.CLOSED,
            opening_cash=opening,
            closing_cash=closing,
            opened_at=closed_at - timedelta(hours=8),
            closed_at=closed_at,
        )

    def _metrics(self):
        now = timezone.now()
        return build_cashier_metrics(now - timedelta(days=30), now)[self.user.pk]

    def test_cash_overage_is_never_recorded_as_a_shortage(self):
        # No sales, no movements: expected cash is the 100.00 float. Handing in
        # 115.00 is a 15.00 overage.
        self._closed_session(opening=Decimal("100.00"), closing=Decimal("115.00"))

        metrics = self._metrics()

        self.assertEqual(metrics.closed_session_count, 1)
        self.assertEqual(metrics.cash_shortage_count, 0)
        self.assertEqual(metrics.cash_shortage_amount, Decimal("0.00"))
        self.assertEqual(metrics.cash_overage_amount, Decimal("15.00"))
        self.assertEqual(metrics.evidence["cash_shortage"], [])

    def test_exactly_balanced_drawer_is_neither_shortage_nor_overage(self):
        self._closed_session(opening=Decimal("100.00"), closing=Decimal("100.00"))

        metrics = self._metrics()

        self.assertEqual(metrics.closed_session_count, 1)
        self.assertEqual(metrics.cash_shortage_count, 0)
        self.assertEqual(metrics.cash_shortage_amount, Decimal("0.00"))
        self.assertEqual(metrics.cash_overage_amount, Decimal("0.00"))

    def test_shortage_is_recorded_with_its_absolute_value(self):
        # Handing in 40.00 against a 100.00 float is a 60.00 shortage — a
        # positive magnitude, not the negative variance.
        self._closed_session(opening=Decimal("100.00"), closing=Decimal("40.00"))

        metrics = self._metrics()

        self.assertEqual(metrics.cash_shortage_count, 1)
        self.assertEqual(metrics.cash_shortage_amount, Decimal("60.00"))
        self.assertEqual(metrics.cash_overage_amount, Decimal("0.00"))


class LateAdjustmentBoundaryTests(TestCase):
    """The cashier adjustment window is a deadline, not a range.

    ``late_void_or_return`` fires on the very first late adjustment with a risk
    score of 75+, so the boundary decides between "routine same-shift void" and
    "named suspect". An adjustment landing exactly on the deadline is inside
    the window the shop granted, and must not be late.
    """

    def setUp(self):
        ensure_role_groups()
        self.window_hours = ShopSettings.load().cashier_return_window_hours
        User = get_user_model()
        self.user = User.objects.create_user(username="window-cashier", password="pw")
        self.user.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.product = create_product_with_default_variant(
            name="Tea", sku="FRD-BND-TEA", unit_price="10.00", barcode=""
        )
        self.variant = self.product.default_variant

    def _void_at(self, *, offset_from_deadline):
        """A 10.00 sale voided exactly ``window_hours`` after it, shifted by
        ``offset_from_deadline``."""
        sold_at = timezone.now() - timedelta(hours=self.window_hours + 2)
        adjusted_at = sold_at + timedelta(hours=self.window_hours) + offset_from_deadline
        session = RegisterSession.objects.create(
            owner=self.user,
            owner_key=f"user:{self.user.pk}",
            opened_at=sold_at - timedelta(hours=1),
        )
        order = Order.objects.create(
            register_session=session,
            status=Order.Status.PAID,
            subtotal=Decimal("10.00"),
            total=Decimal("10.00"),
        )
        Order.objects.filter(pk=order.pk).update(created_at=sold_at)
        OrderLine.objects.create(
            order=order, variant=self.variant, quantity=1, unit_price=Decimal("10.00")
        )
        adjustment = OrderAdjustment.objects.create(
            order=order,
            register_session=session,
            adjustment_type=OrderAdjustment.AdjustmentType.VOID,
            amount=Decimal("10.00"),
            cash_amount=Decimal("10.00"),
            created_by=self.user,
        )
        OrderAdjustment.objects.filter(pk=adjustment.pk).update(created_at=adjusted_at)
        now = timezone.now()
        return build_cashier_metrics(now - timedelta(days=30), now)[self.user.pk]

    def test_adjustment_exactly_on_the_deadline_is_not_late(self):
        metrics = self._void_at(offset_from_deadline=timedelta(0))

        self.assertEqual(metrics.void_count, 1)
        self.assertEqual(metrics.late_adjustment_count, 0)
        self.assertEqual(metrics.late_adjustment_amount, Decimal("0.00"))

    def test_adjustment_one_second_past_the_deadline_is_late(self):
        metrics = self._void_at(offset_from_deadline=timedelta(seconds=1))

        self.assertEqual(metrics.late_adjustment_count, 1)
        self.assertEqual(metrics.late_adjustment_amount, Decimal("10.00"))

    def test_adjustment_one_second_inside_the_deadline_is_not_late(self):
        metrics = self._void_at(offset_from_deadline=timedelta(seconds=-1))

        self.assertEqual(metrics.late_adjustment_count, 0)


class PeerOutlierFairnessTests(TestCase):
    """An outlier detector must not accuse a whole shift at once.

    ``void_peer_outlier`` compares each cashier against the *other* cashiers.
    If every cashier voids at the same rate that rate is the shop's normal, no
    matter how high it is, and nobody is an outlier. A regression here (a
    self-inclusive peer set, or a lost minimum spread) would flag every cashier
    in the shop on the same sweep.
    """

    def setUp(self):
        ensure_role_groups()
        ShopSettings.load()
        self.product = create_product_with_default_variant(
            name="Juice", sku="FRD-BND-JCE", unit_price="10.00", barcode=""
        )
        self.variant = self.product.default_variant

    def _cashier(self, name):
        User = get_user_model()
        user = User.objects.create_user(username=name, password="pw")
        user.groups.add(Group.objects.get(name=CASHIER_GROUP))
        return user

    def _activity(self, user, *, sales, voids):
        """``sales`` paid orders in the window, ``voids`` of them voided well
        inside the adjustment window (so no ``late_void_or_return`` noise)."""
        sold_at = timezone.now() - timedelta(hours=1)
        session = RegisterSession.objects.create(
            owner=user,
            owner_key=f"user:{user.pk}",
            opened_at=sold_at - timedelta(hours=2),
        )
        for index in range(sales):
            order = Order.objects.create(
                register_session=session,
                status=Order.Status.PAID,
                subtotal=Decimal("10.00"),
                total=Decimal("10.00"),
            )
            Order.objects.filter(pk=order.pk).update(created_at=sold_at)
            OrderLine.objects.create(
                order=order,
                variant=self.variant,
                quantity=1,
                unit_price=Decimal("10.00"),
            )
            Payment.objects.create(
                order=order, method=Payment.Method.CASH, amount=Decimal("10.00")
            )
            if index < voids:
                OrderAdjustment.objects.create(
                    order=order,
                    register_session=session,
                    adjustment_type=OrderAdjustment.AdjustmentType.VOID,
                    amount=Decimal("10.00"),
                    cash_amount=Decimal("10.00"),
                    created_by=user,
                )

    def _void_outlier_user_ids(self):
        now = timezone.now()
        specs = detect_suspected_fraud(
            window_start=now - timedelta(days=30), window_end=now
        )
        return {
            spec.user_id for spec in specs if spec.rule_code == "void_peer_outlier"
        }

    def test_cashiers_with_identical_void_patterns_are_never_outliers(self):
        # Four cashiers, same shift, same behaviour: 6 sales and 3 voids each —
        # past the >=3 volume gate, so only the peer comparison can spare them.
        for index in range(4):
            self._activity(self._cashier(f"same-{index}"), sales=6, voids=3)

        self.assertEqual(self._void_outlier_user_ids(), set())

    def test_one_cashier_voiding_far_above_identical_peers_is_flagged(self):
        # The same fixture with one cashier swapped for a heavy voider — proves
        # the test above is spared by the comparison, not by the volume gate.
        peers = [self._cashier(f"clean-{index}") for index in range(3)]
        for peer in peers:
            self._activity(peer, sales=6, voids=0)
        suspect = self._cashier("heavy-voider")
        self._activity(suspect, sales=6, voids=5)

        self.assertEqual(self._void_outlier_user_ids(), {suspect.pk})
