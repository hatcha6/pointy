from datetime import timedelta
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.urls import reverse
from django.utils import timezone
from rest_framework import status
from rest_framework.test import APITestCase

from apps.core.roles import ensure_role_groups
from apps.customers.models import Customer
from apps.customers.segmentation import recompute_customer_segments
from apps.sales.models import Order, OrderAdjustment, RegisterSession

NOW = timezone.now()


def _committed_sale(customer, *, total, days_ago, sale_type=Order.SaleType.STANDARD):
    """Create one recognized sale for ``customer`` dated ``days_ago`` days back."""
    status_value = (
        Order.Status.OPEN
        if sale_type == Order.SaleType.CREDIT
        else Order.Status.PAID
    )
    order = Order.objects.create(
        customer=customer,
        sale_type=sale_type,
        status=status_value,
        subtotal=Decimal(total),
        total=Decimal(total),
    )
    # created_at is auto_now_add, so backdate it through the ORM after creation.
    Order.objects.filter(pk=order.pk).update(
        created_at=NOW - timedelta(days=days_ago)
    )
    return order


class SegmentationServiceTests(APITestCase):
    def test_customer_without_committed_sales_is_inactive(self):
        customer = Customer.objects.create(full_name="No purchases yet")

        summary = recompute_customer_segments(reference_time=NOW)

        customer.refresh_from_db()
        self.assertEqual(customer.rfm_segment, Customer.Rank.INACTIVE)
        self.assertEqual(customer.rfm_score, 0)
        self.assertEqual(customer.rfm_frequency, 0)
        self.assertEqual(customer.rfm_monetary, Decimal("0.00"))
        self.assertIsNone(customer.rfm_recency_days)
        self.assertIsNotNone(customer.rfm_calculated_at)
        self.assertEqual(summary["purchasers"], 0)

    def test_recent_frequent_big_spender_outranks_an_old_one_off_buyer(self):
        champion = Customer.objects.create(full_name="Champion")
        for days_ago in (1, 4, 9, 15, 22):
            _committed_sale(champion, total="120.00", days_ago=days_ago)

        # A spread of middling customers so the quintiles have something to bite on.
        for index in range(2, 7):
            middle = Customer.objects.create(full_name=f"Middle {index}")
            for offset in range(index):
                _committed_sale(middle, total="30.00", days_ago=30 + offset * 5)

        lost = Customer.objects.create(full_name="Lost")
        _committed_sale(lost, total="8.00", days_ago=400)

        recompute_customer_segments(reference_time=NOW)

        champion.refresh_from_db()
        lost.refresh_from_db()
        self.assertEqual(champion.rfm_segment, Customer.Rank.CHAMPION)
        self.assertEqual(champion.rfm_recency_score, 5)
        self.assertEqual(champion.rfm_frequency_score, 5)
        self.assertEqual(champion.rfm_monetary_score, 5)
        self.assertEqual(champion.rfm_frequency, 5)
        self.assertEqual(champion.rfm_monetary, Decimal("600.00"))
        # The old single-purchase, tiny-spend customer should rank well below.
        self.assertEqual(lost.rfm_segment, Customer.Rank.LOST)
        self.assertGreater(champion.rfm_score, lost.rfm_score)

    def test_returns_reduce_monetary_value(self):
        customer = Customer.objects.create(full_name="Returner")
        order = _committed_sale(customer, total="200.00", days_ago=3)
        session = RegisterSession.objects.create(owner_key="user:returns")
        OrderAdjustment.objects.create(
            order=order,
            register_session=session,
            adjustment_type=OrderAdjustment.AdjustmentType.RETURN,
            amount=Decimal("50.00"),
            cash_amount=Decimal("50.00"),
        )

        recompute_customer_segments(reference_time=NOW)

        customer.refresh_from_db()
        self.assertEqual(customer.rfm_monetary, Decimal("150.00"))

    def test_credit_invoices_count_as_recognized_sales(self):
        customer = Customer.objects.create(full_name="On credit")
        _committed_sale(
            customer,
            total="75.00",
            days_ago=2,
            sale_type=Order.SaleType.CREDIT,
        )

        recompute_customer_segments(reference_time=NOW)

        customer.refresh_from_db()
        self.assertEqual(customer.rfm_frequency, 1)
        self.assertEqual(customer.rfm_monetary, Decimal("75.00"))
        self.assertNotEqual(customer.rfm_segment, Customer.Rank.INACTIVE)

    def test_quotations_and_voids_are_ignored(self):
        customer = Customer.objects.create(full_name="Just quotes")
        Order.objects.create(
            customer=customer,
            sale_type=Order.SaleType.QUOTATION,
            status=Order.Status.OPEN,
            subtotal=Decimal("500.00"),
            total=Decimal("500.00"),
        )
        Order.objects.create(
            customer=customer,
            sale_type=Order.SaleType.STANDARD,
            status=Order.Status.VOID,
            subtotal=Decimal("500.00"),
            total=Decimal("500.00"),
        )

        recompute_customer_segments(reference_time=NOW)

        customer.refresh_from_db()
        self.assertEqual(customer.rfm_segment, Customer.Rank.INACTIVE)
        self.assertEqual(customer.rfm_frequency, 0)

    def test_recompute_is_idempotent(self):
        customer = Customer.objects.create(full_name="Stable")
        _committed_sale(customer, total="40.00", days_ago=5)

        first = recompute_customer_segments(reference_time=NOW)
        customer.refresh_from_db()
        segment_after_first = customer.rfm_segment
        score_after_first = customer.rfm_score

        second = recompute_customer_segments(reference_time=NOW)
        customer.refresh_from_db()

        self.assertEqual(customer.rfm_segment, segment_after_first)
        self.assertEqual(customer.rfm_score, score_after_first)
        self.assertEqual(first["segments"], second["segments"])


class SegmentationApiTests(APITestCase):
    def setUp(self):
        groups = ensure_role_groups()
        self.user = get_user_model().objects.create_user(
            username="manager",
            password="password",
        )
        self.user.groups.add(groups["manager"])
        self.client.force_authenticate(self.user)

    def test_list_exposes_and_filters_by_rank(self):
        champion = Customer.objects.create(full_name="VIP")
        for days_ago in (1, 3, 6, 10, 14):
            _committed_sale(champion, total="100.00", days_ago=days_ago)
        for index in range(5):
            other = Customer.objects.create(full_name=f"Casual {index}")
            _committed_sale(other, total="10.00", days_ago=120 + index)
        recompute_customer_segments(reference_time=NOW)

        # The rank is serialized.
        detail = self.client.get(reverse("customer-detail", args=[champion.pk]))
        self.assertEqual(detail.data["rfm_segment"], Customer.Rank.CHAMPION)
        self.assertEqual(detail.data["rfm_segment_display"], "Champion")
        self.assertEqual(detail.data["rfm_frequency"], 5)

        # And it filters the list.
        listing = self.client.get(
            reverse("customer-list"),
            {"rfm_segment": Customer.Rank.CHAMPION},
        )
        ids = [row["id"] for row in listing.data["results"]]
        self.assertIn(champion.pk, ids)
        self.assertTrue(
            all(row["rfm_segment"] == Customer.Rank.CHAMPION for row in listing.data["results"])
        )

    def test_recompute_segments_endpoint_schedules_task(self):
        with self.settings(
            CELERY_TASK_ALWAYS_EAGER=True,
            CELERY_TASK_EAGER_PROPAGATES=True,
        ):
            customer = Customer.objects.create(full_name="Fresh")
            _committed_sale(customer, total="60.00", days_ago=1)

            response = self.client.post(reverse("customer-recompute-segments"))

        self.assertEqual(response.status_code, status.HTTP_202_ACCEPTED)
        self.assertEqual(response.data["status"], "scheduled")
        customer.refresh_from_db()
        self.assertNotEqual(customer.rfm_segment, Customer.Rank.INACTIVE)
