"""Query-count scaling for the operations job board.

``JobMaterialSerializer.variant_name`` and ``JobSerializer.output_variant_name``
read ``ProductVariant.display_name``, which falls back to
``option_values_label`` -> a ``VariantOptionValue`` query whenever the variant
carries no explicit name. That is the common case for default variants, so the
board paid one query per *material line*. These tests keep it flat.
"""

from decimal import Decimal

from django.db import connection
from django.test import override_settings
from django.test.utils import CaptureQueriesContext
from django.urls import reverse

from apps.catalog.testing import create_product_with_default_variant
from apps.inventory.models import StockItem

from .models import Job
from .services import add_job_material
from .tests import OperationsTestCase, authenticated_client

MATERIALS_PER_JOB = 3


@override_settings(
    CACHES={"default": {"BACKEND": "django.core.cache.backends.locmem.LocMemCache"}}
)
class JobListQueryScalingTests(OperationsTestCase):
    def setUp(self):
        super().setUp()
        self.material_variants = []
        for index in range(MATERIALS_PER_JOB):
            product = create_product_with_default_variant(
                sku=f"PART-{index}",
                name=f"قطعة {index}",
                unit_price=Decimal("10.00"),
            )
            StockItem.objects.create(
                variant=product.default_variant,
                quantity_on_hand=Decimal("10000"),
            )
            self.material_variants.append(product.default_variant)

    def _add_jobs(self, count):
        client = authenticated_client(self.technician)
        for _ in range(count):
            data = self.create_repair_job(client=client)
            job = Job.objects.get(pk=data["id"])
            for variant in self.material_variants:
                add_job_material(job=job, variant=variant, quantity=Decimal("1"))

    def _list_query_count(self):
        url = reverse("job-list")
        client = authenticated_client(self.manager)
        # Warm permissions / content types / settings singletons first, or the
        # first request's fixed overhead pollutes the count.
        client.get(url)
        with CaptureQueriesContext(connection) as ctx:
            response = client.get(url)
        self.assertEqual(response.status_code, 200)
        return len(ctx), response

    def test_list_query_count_is_flat_as_jobs_grow(self):
        self._add_jobs(5)
        five, response_five = self._list_query_count()
        self.assertEqual(len(response_five.data["results"]), 5)

        self._add_jobs(5)
        ten, response_ten = self._list_query_count()
        self.assertEqual(len(response_ten.data["results"]), 10)

        print(f"\n[scaling] 5 jobs: {five} queries; 10 jobs: {ten} queries")
        self.assertEqual(five, ten, "job list scales with row count")

    def test_material_names_still_resolve(self):
        """The prefetch only changes where the label is *fetched* from — every
        rendered name must equal what a cold variant computes."""
        self._add_jobs(1)
        _count, response = self._list_query_count()
        row = response.data["results"][0]
        expected = {
            variant.pk: variant.display_name for variant in self.material_variants
        }
        self.assertEqual(len(row["materials"]), MATERIALS_PER_JOB)
        for material in row["materials"]:
            self.assertEqual(material["variant_name"], expected[material["variant"]])
