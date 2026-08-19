"""The category list must stay linear in the number of categories on the page.

``ProductCategoryViewSet`` reports ``children_count`` and ``product_count`` and
renders ``parent_name`` from ``parent.name``. Two independent regressions live
here, and they need different instruments:

* ``parent_name`` without ``select_related("parent")`` is one query per
  subcategory — a plain query-count scaling test catches it.
* Annotating the two counts as joined aggregates in one query makes the database
  materialise every (child x product) pair per category. The query *count* is
  identical either way, so only the plan can catch that one.
"""

import re
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.db import connection
from django.test import TestCase, override_settings
from django.test.utils import CaptureQueriesContext
from django.urls import reverse
from rest_framework.test import APIClient

from apps.core.roles import MANAGER_GROUP, ensure_role_groups

from .models import Product, ProductCategory
from .views import ProductCategoryViewSet

PARENTS = 6


def _seed(parents, children_per_parent, products_per_parent):
    """Categories whose children *and* products both hang off the same parent.

    The cross product only shows when one category has rows in both relations,
    which is also the real shape: a top-level category with subcategories and
    products of its own.
    """
    ProductCategory.objects.filter(parent__isnull=False).delete()
    ProductCategory.objects.all().delete()
    Product.objects.all().delete()
    for parent_index in range(parents):
        parent = ProductCategory.objects.create(name=f"top{parent_index}")
        ProductCategory.objects.bulk_create(
            [
                ProductCategory(name=f"sub{parent_index}-{i}", parent=parent)
                for i in range(children_per_parent)
            ]
        )
        products = Product.objects.bulk_create(
            [
                Product(name=f"p{parent_index}-{i}", is_active=True)
                for i in range(products_per_parent)
            ]
        )
        parent.products.add(*products)


def _list_queryset():
    view = ProductCategoryViewSet()
    view.request = None
    view.format_kwarg = None
    return view.get_queryset()


def _peak_rows_scanned(queryset):
    """Largest ``rows=`` any node in the plan actually produced."""
    sql, params = queryset.query.sql_with_params()
    with connection.cursor() as cursor:
        cursor.execute("EXPLAIN (ANALYZE) " + sql, params)
        plan = "\n".join(row[0] for row in cursor.fetchall())
    produced = [
        int(value)
        for value in re.findall(r"\(actual time=[\d.]+\.\.[\d.]+ rows=(\d+)", plan)
    ]
    assert produced, plan
    return max(produced)


@override_settings(
    CACHES={"default": {"BACKEND": "django.core.cache.backends.locmem.LocMemCache"}}
)
class ProductCategoryListValueTests(TestCase):
    def test_counts_and_parent_name_match_direct_lookups(self):
        _seed(parents=3, children_per_parent=2, products_per_parent=4)
        # A category with neither children nor products must still report 0 for
        # both: the old LEFT JOIN produced 0, and Coalesce keeps the subqueries
        # agreeing. Give it a parent too, so parent_name is exercised on a row
        # whose counts are empty.
        parent = ProductCategory.objects.filter(parent__isnull=True).first()
        ProductCategory.objects.create(name="empty leaf", parent=parent)
        # Uneven relations, so a swapped pair of annotations shows up.
        lonely = ProductCategory.objects.create(name="products only")
        lonely.products.add(*Product.objects.all()[:3])

        rows = list(_list_queryset())
        self.assertEqual(len(rows), ProductCategory.objects.count())
        for category in rows:
            self.assertEqual(
                category.children_count,
                ProductCategory.objects.filter(parent=category).count(),
                category.name,
            )
            self.assertEqual(
                category.product_count,
                Product.objects.filter(categories=category).count(),
                category.name,
            )
        by_name = {category.name: category for category in rows}
        self.assertEqual((by_name["empty leaf"].children_count, by_name["empty leaf"].product_count), (0, 0))
        self.assertEqual(by_name["empty leaf"].parent.name, parent.name)
        self.assertEqual((by_name["products only"].children_count, by_name["products only"].product_count), (0, 3))

    def test_archived_products_keep_counting_as_before(self):
        # product_count is now a count of the categories M2M through-table. The
        # joined aggregate never reached catalog_product either, so an archived
        # product stayed in the number — preserve that rather than quietly
        # changing what the screen reports.
        category = ProductCategory.objects.create(name="mixed")
        live = Product.objects.create(name="live", is_active=True)
        archived = Product.objects.create(
            name="archived", is_active=False, archived_at="2026-01-01T00:00:00Z"
        )
        category.products.add(live, archived)

        row = _list_queryset().get(pk=category.pk)
        self.assertEqual(row.product_count, 2)


@override_settings(
    CACHES={"default": {"BACKEND": "django.core.cache.backends.locmem.LocMemCache"}}
)
class ProductCategoryListQueryCountTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.client = APIClient()
        self.user = get_user_model().objects.create_user(username="u", password="p")
        self.user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client.force_authenticate(user=self.user)

    def _measure(self, expected_rows):
        url = reverse("productcategory-list")
        # Warm the per-request caches (catalog version stamp, permissions) so the
        # measured request reflects steady state, not first-request warmup.
        self.client.get(url)
        with CaptureQueriesContext(connection) as ctx:
            response = self.client.get(url)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data["count"], expected_rows)
        return len(ctx.captured_queries)

    def test_query_count_does_not_grow_with_subcategories(self):
        _seed(parents=2, children_per_parent=3, products_per_parent=2)
        small = self._measure(expected_rows=8)
        _seed(parents=4, children_per_parent=6, products_per_parent=2)
        large = self._measure(expected_rows=28)
        self.assertEqual(
            small,
            large,
            f"productcategory-list scaled with rows: {small} -> {large} queries "
            "(parent_name is an N+1 without select_related('parent'))",
        )


@override_settings(
    CACHES={"default": {"BACKEND": "django.core.cache.backends.locmem.LocMemCache"}}
)
class ProductCategoryListScalingTests(TestCase):
    def test_rows_scanned_stay_linear_in_products_per_category(self):
        if connection.vendor != "postgresql":
            self.skipTest("Plan row counts are measured on the real database.")

        _seed(parents=PARENTS, children_per_parent=4, products_per_parent=20)
        single = _peak_rows_scanned(_list_queryset())

        _seed(parents=PARENTS, children_per_parent=8, products_per_parent=40)
        double = _peak_rows_scanned(_list_queryset())

        # Doubling both relations doubles the page (children are rows) when the
        # counts are independent subqueries. Joining them in one query squares
        # the inner work instead: 6x4x20 = 480 rows -> 6x8x40 = 1920, a 4x jump
        # against a 2x growth in rows returned. Anything at or above 3x means
        # the cross product is back.
        self.assertLess(
            double,
            single * 3,
            f"category counts scale super-linearly: {single} -> {double} rows scanned",
        )
