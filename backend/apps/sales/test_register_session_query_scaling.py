"""Query-count scaling for the register-sessions list.

``RegisterSessionSerializer`` exposes eight reconciliation fields that are all
Python ``@property`` aggregates on the model, and the composite ones
(``expected_cash`` -> its four parts, ``cash_variance`` -> ``expected_cash``,
``has_cash_variance`` -> ``cash_variance``) silently re-run their parts. These
tests keep the per-row cost flat as the page grows.
"""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.db import connection
from django.test import TestCase, override_settings
from django.test.utils import CaptureQueriesContext
from django.urls import reverse
from rest_framework.test import APIClient

from apps.catalog.testing import create_product_with_default_variant
from apps.core.roles import MANAGER_GROUP, ensure_role_groups
from apps.inventory.models import StockItem

from .models import RegisterCashMovement, RegisterSession
from .services import checkout_order


@override_settings(
    CACHES={"default": {"BACKEND": "django.core.cache.backends.locmem.LocMemCache"}}
)
class RegisterSessionListQueryScalingTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.client = APIClient()
        self.user = get_user_model().objects.create_user(username="m", password="p")
        self.user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client.force_authenticate(user=self.user)
        product = create_product_with_default_variant(
            name="Widget",
            sku="W1",
            barcode="",
            unit_price=Decimal("5.00"),
        )
        self.variant = product.default_variant
        StockItem.objects.create(
            variant=self.variant, quantity_on_hand=Decimal("100000")
        )
        self._seq = 0

    def _add_sessions(self, count):
        """Each session: a cash sale, a pay-in, a pay-out and a close (so the
        closed-session branch of cash_variance/has_cash_variance is exercised)."""
        for _ in range(count):
            self._seq += 1
            session = RegisterSession.objects.create(
                owner=self.user,
                owner_key=f"user:{self.user.pk}:{self._seq}",
                opening_cash=Decimal("10.00"),
            )
            checkout_order(
                register_session=session,
                lines_data=[{"variant": self.variant, "quantity": Decimal("1")}],
                payments_data=[{"method": "cash", "amount": Decimal("5.00")}],
            )
            RegisterCashMovement.objects.create(
                register_session=session,
                movement_type=RegisterCashMovement.MovementType.PAY_IN,
                amount=Decimal("3.00"),
            )
            RegisterCashMovement.objects.create(
                register_session=session,
                movement_type=RegisterCashMovement.MovementType.PAY_OUT,
                amount=Decimal("2.00"),
            )
            session.status = RegisterSession.Status.CLOSED
            session.closing_cash = Decimal("15.00")
            session.save(update_fields=["status", "closing_cash"])

    def _list_query_count(self):
        url = reverse("register-session-list")
        # Warm permissions / content types / settings singletons first, or the
        # first request's fixed overhead pollutes the count.
        self.client.get(url)
        with CaptureQueriesContext(connection) as ctx:
            response = self.client.get(url)
        self.assertEqual(response.status_code, 200)
        return len(ctx), response

    def test_list_query_count_is_flat_as_sessions_grow(self):
        self._add_sessions(5)
        five, response_five = self._list_query_count()
        self.assertEqual(len(response_five.data["results"]), 5)

        self._add_sessions(5)
        ten, response_ten = self._list_query_count()
        self.assertEqual(len(response_ten.data["results"]), 10)

        print(f"\n[scaling] 5 sessions: {five} queries; 10 sessions: {ten} queries")
        self.assertEqual(five, ten, "register-session list scales with row count")

    def test_primed_rows_match_cold_values(self):
        """The primer batches only the *fetching*; every reconciliation number
        must equal what the un-primed properties compute."""
        self._add_sessions(3)
        _count, response = self._list_query_count()
        by_id = {row["id"]: row for row in response.data["results"]}
        self.assertEqual(len(by_id), 3)
        for session in RegisterSession.objects.filter(pk__in=by_id):
            # A fresh instance with no primed cache — the cold path.
            cold = RegisterSession.objects.get(pk=session.pk)
            row = by_id[cold.pk]
            self.assertEqual(row["cash_sales_total"], str(cold.cash_sales_total))
            self.assertEqual(row["pay_in_total"], str(cold.pay_in_total))
            self.assertEqual(row["pay_out_total"], str(cold.pay_out_total))
            self.assertEqual(row["cash_refund_total"], str(cold.cash_refund_total))
            self.assertEqual(row["expected_cash"], str(cold.expected_cash))
            self.assertEqual(row["cash_variance"], str(cold.cash_variance))
            self.assertEqual(row["has_cash_variance"], cold.has_cash_variance)

    def test_single_session_detail_batches_its_drawer_totals(self):
        self._add_sessions(1)
        session = RegisterSession.objects.get()
        url = reverse("register-session-detail", args=[session.pk])
        self.client.get(url)  # warm permissions / settings singletons
        with CaptureQueriesContext(connection) as ctx:
            response = self.client.get(url)
        self.assertEqual(response.status_code, 200)
        print(f"[detail] 1 session: {len(ctx)} queries")
        # Was 16 aggregates + fixed overhead; the primer makes it 3.
        self.assertLessEqual(len(ctx), 8)

    def test_session_summary_batches_its_drawer_totals(self):
        self._add_sessions(1)
        session = RegisterSession.objects.get()
        url = reverse("register-session-summary", args=[session.pk])
        self.client.get(url)  # warm permissions / settings singletons
        with CaptureQueriesContext(connection) as ctx:
            response = self.client.get(url)
        self.assertEqual(response.status_code, 200)
        print(f"[summary] 1 session: {len(ctx)} queries")
        self.assertLessEqual(len(ctx), 22)
