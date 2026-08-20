"""Query-count scaling for the recipes (bill of materials) list.

``BomLineSerializer.component_name`` and ``BillOfMaterialsSerializer.variant_name``
read ``ProductVariant.display_name``, which falls back to ``option_values_label``
-> a ``VariantOptionValue`` query whenever the variant carries no explicit name.
That is the common case for default variants, so the list paid one query per
recipe *and* one per component line. These tests keep it flat.
"""

from decimal import Decimal

from django.db import connection
from django.test import override_settings
from django.test.utils import CaptureQueriesContext
from django.urls import reverse

from apps.catalog.models import BillOfMaterials, BomLine
from apps.catalog.testing import create_product_with_default_variant

from .tests import OperationsTestCase, authenticated_client

LINES_PER_RECIPE = 4


@override_settings(
    CACHES={"default": {"BACKEND": "django.core.cache.backends.locmem.LocMemCache"}}
)
class BomListQueryScalingTests(OperationsTestCase):
    def setUp(self):
        super().setUp()
        self.components = []
        for index in range(LINES_PER_RECIPE):
            product = create_product_with_default_variant(
                sku=f"BOM-ING-{index}",
                name=f"مكوّن {index}",
                unit_price=Decimal("3.00"),
            )
            self.components.append(product.default_variant)
        self._recipe_index = 0

    def _add_recipes(self, count):
        for _ in range(count):
            product = create_product_with_default_variant(
                sku=f"BOM-DISH-{self._recipe_index}",
                name=f"طبق {self._recipe_index}",
                unit_price=Decimal("20.00"),
            )
            self._recipe_index += 1
            bom = BillOfMaterials.objects.create(
                variant=product.default_variant,
                name=f"وصفة {product.name}",
                output_quantity=Decimal("1"),
            )
            for component in self.components:
                BomLine.objects.create(
                    bom=bom,
                    component_variant=component,
                    quantity=Decimal("1.000"),
                )

    def _list_query_count(self):
        url = reverse("bom-list")
        client = authenticated_client(self.manager)
        client.get(url)
        with CaptureQueriesContext(connection) as ctx:
            response = client.get(url)
        self.assertEqual(response.status_code, 200)
        return len(ctx), response

    def test_list_query_count_is_flat_as_recipes_grow(self):
        self._add_recipes(5)
        five, response_five = self._list_query_count()

        self._add_recipes(5)
        ten, response_ten = self._list_query_count()

        print(
            f"\n[scaling] 5 recipes x {LINES_PER_RECIPE} lines: {five} queries; "
            f"10 recipes: {ten} queries"
        )
        self.assertEqual(five, ten, "recipe list scales with row count")

    def test_component_names_still_resolve(self):
        self._add_recipes(1)
        _count, response = self._list_query_count()
        row = response.data["results"][0]
        expected = {variant.pk: variant.display_name for variant in self.components}
        self.assertEqual(len(row["lines"]), LINES_PER_RECIPE)
        for line in row["lines"]:
            self.assertEqual(
                line["component_name"], expected[line["component_variant"]]
            )
