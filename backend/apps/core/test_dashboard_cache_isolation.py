"""Dashboard figures must never leak from one test into the next.

Each dashboard section is cached under a FIXED key —
``dashboard:v1:purchasing:global:days:30`` is the same string in every test —
and no write invalidates it. Redis outlives a test's rolled-back rows, so of two
dashboard tests run within 30s of each other, the second was served the first
one's figures: ``DashboardDueTotalTests`` read the supplier balance
``ExpenseReportingTests`` had cached (0.00, not 500.00), and in CI's
alphabetical order the same pair failed the other way round.

So the cache is off under the test runner (``POINTY_DASHBOARD_CACHE_ENABLED``),
and these tests hold that line against the suite's real cache — Redis whenever
it is up, as it is in CI. ``DashboardApiTests`` opts back in, in a private
LocMem, to test the cache itself.
"""

from decimal import Decimal
from unittest import mock

from django.conf import settings
from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from apps.core import caching
from apps.core.dashboard.view import warm_dashboard_cache
from apps.core.roles import MANAGER_GROUP, ensure_role_groups
from apps.purchasing.models import PurchaseOrder, Supplier


class DashboardCacheIsolationTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        manager = get_user_model().objects.create_user(
            username="isolation-manager", password="p"
        )
        manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client = APIClient()
        self.client.force_authenticate(manager)

    def _due_total(self):
        response = self.client.get(reverse("dashboard"))
        return response.data["sections"]["purchasing"]["summary"]["due_total"]

    def test_the_section_cache_is_off_under_the_test_runner(self):
        self.assertFalse(settings.POINTY_DASHBOARD_CACHE_ENABLED)

    def test_a_later_load_sees_rows_written_after_an_earlier_one(self):
        # The leak in miniature: the same key read twice well inside 30s. With
        # the cache on, the second load is served the first load's figures.
        self.assertEqual(self._due_total(), "0.00")
        PurchaseOrder.objects.create(
            supplier=Supplier.objects.create(name="مورد"),
            status=PurchaseOrder.Status.SUBMITTED,
            subtotal=Decimal("120.00"),
            total=Decimal("120.00"),
        )
        self.assertEqual(self._due_total(), "120.00")

    def test_the_warmer_writes_nothing(self):
        # A warmed entry lives 20 minutes: long enough to reach every later
        # test in the run, and the start of the next run.
        with mock.patch.object(caching, "_safe_set") as safe_set:
            result = warm_dashboard_cache()

        self.assertEqual(result["warmed"], 0)
        safe_set.assert_not_called()
