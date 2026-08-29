"""Query-count scaling for the asset registry.

The assets screen is a lookup tool a counter uses dozens of times a day, and
every row carries a current owner plus three annotated aggregates (total jobs,
open jobs, last visit). Aggregates are cheap only while they stay in the one
query that fetches the page; the moment one becomes a property that walks a
relation, the list pays a query per row. This keeps it flat.

Mirrors ``test_job_list_query_scaling`` — same warm-then-measure shape.
"""

from django.db import connection
from django.test import override_settings
from django.test.utils import CaptureQueriesContext
from django.urls import reverse

from apps.customers.models import Asset, Customer

from .tests import OperationsTestCase, authenticated_client


@override_settings(
    CACHES={"default": {"BACKEND": "django.core.cache.backends.locmem.LocMemCache"}}
)
class AssetListQueryScalingTests(OperationsTestCase):
    def _add_assets(self, count, *, offset=0):
        client = authenticated_client(self.technician)
        for index in range(offset, offset + count):
            owner = Customer.objects.create(
                full_name=f"مالك {index}",
                phone=f"09{index:08d}",
            )
            asset = Asset.objects.create(
                customer=owner,
                asset_type=Asset.AssetType.VEHICLE,
                brand="Toyota",
                model_name="Hilux",
                vin=f"VIN{index:014d}",
                plate_number=f"{index:02d}-0001",
            )
            self.create_repair_job(
                client=client,
                customer=owner.pk,
                asset_ids=[asset.pk],
            )

    def _list_query_count(self):
        url = reverse("asset-list")
        client = authenticated_client(self.manager)
        # Warm permissions / content types / settings singletons, or the first
        # request's fixed overhead lands in the measurement.
        client.get(url)
        with CaptureQueriesContext(connection) as ctx:
            response = client.get(url)
        self.assertEqual(response.status_code, 200)
        return len(ctx), response

    def test_list_query_count_is_flat_as_assets_grow(self):
        self._add_assets(5)
        five, response_five = self._list_query_count()

        self._add_assets(5, offset=5)
        ten, response_ten = self._list_query_count()

        self.assertGreater(len(response_ten.data["results"]), len(response_five.data["results"]))
        print(f"\n[scaling] 5 assets: {five} queries; 10 assets: {ten} queries")
        self.assertEqual(five, ten, "asset list scales with row count")

    def test_detail_query_count_is_flat_as_history_grows(self):
        client = authenticated_client(self.technician)
        url = reverse("asset-detail", args=[self.asset.pk])
        manager_client = authenticated_client(self.manager)
        self.create_repair_job(client=client)
        manager_client.get(url)

        with CaptureQueriesContext(connection) as ctx:
            manager_client.get(url)
        one_visit = len(ctx)

        for _ in range(4):
            self.create_repair_job(client=client)
        with CaptureQueriesContext(connection) as ctx:
            response = manager_client.get(url)
        five_visits = len(ctx)

        self.assertEqual(len(response.data["jobs"]), 5)
        print(
            f"\n[scaling] asset detail: 1 visit {one_visit} queries; "
            f"5 visits {five_visits} queries"
        )
        self.assertEqual(
            one_visit,
            five_visits,
            "asset history scales with visit count",
        )
