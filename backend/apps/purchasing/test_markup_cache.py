"""The shop's typical markup is computed once per catalog version.

``pricing-suggestion`` resolves a markup every time a buyer prices a purchase
line: the product's category first and, when that category is too thin to
trust, the shop-wide figure as well. Each is a scan of every priced variant
carrying a correlated "latest purchase cost" subquery, so the field export
measured the endpoint at 348ms with 247ms of database time for two or three
queries.

It is a statistic about the whole catalogue, and the catalog version already
moves on every product, price and stock write — so it is cached against that
version. These tests hold the three things that can go wrong: the repeat must
not touch the database, a catalogue change must not be served a stale figure,
and "too little data to trust" must cache as itself rather than as a miss that
recomputes forever.
"""

from decimal import Decimal

from django.test import TestCase, override_settings
from django.test.utils import CaptureQueriesContext
from django.db import connection

from apps.catalog.cache import bump_catalog_version
from apps.catalog.models import Product, ProductCategory, ProductVariant
from apps.inventory.models import Warehouse

from .models import PurchaseLine, PurchaseOrder, Supplier
from .pricing import (
    DEFAULT_MARKUP_PERCENT,
    category_markup_percent,
    shop_typical_markup_percent,
)

CACHED = {
    "POINTY_MARKUP_CACHE_TTL": 900,
    "POINTY_CATALOG_CACHE_ENABLED": True,
    "CACHES": {
        "default": {"BACKEND": "django.core.cache.backends.locmem.LocMemCache"}
    },
}


@override_settings(**CACHED)
class MarkupCacheTests(TestCase):
    def setUp(self):
        from django.core.cache import cache

        cache.clear()
        self.warehouse = Warehouse.objects.first() or Warehouse.objects.create(
            name="main"
        )
        self.supplier = Supplier.objects.create(name="مورد", phone="0910000000")
        self.category = ProductCategory.objects.create(name="بقالة")
        self._seq = 0

    def _priced_product(self, *, cost, price, category=None):
        self._seq += 1
        product = Product.objects.create(name=f"p{self._seq}", is_active=True)
        product.categories.add(category or self.category)
        variant = ProductVariant.objects.create(
            product=product,
            name="",
            sku=f"MK-{self._seq}",
            unit_price=Decimal(price),
            is_active=True,
            is_default=True,
        )
        order = PurchaseOrder.objects.create(
            warehouse=self.warehouse,
            supplier=self.supplier,
            order_number=f"MK-PO-{self._seq:04d}",
            status=PurchaseOrder.Status.RECEIVED,
        )
        PurchaseLine.objects.create(
            purchase_order=order,
            variant=variant,
            quantity=Decimal("1"),
            unit_cost=Decimal(cost),
            unit_factor=Decimal("1"),
        )
        return product

    def _seed(self, count):
        for _ in range(count):
            self._priced_product(cost="10.00", price="13.00")

    def test_the_repeat_does_not_touch_the_database(self):
        self._seed(6)
        first = shop_typical_markup_percent()
        self.assertIsNotNone(first)
        with CaptureQueriesContext(connection) as ctx:
            again = shop_typical_markup_percent()
        self.assertEqual(again, first)
        self.assertEqual(
            len(ctx.captured_queries),
            0,
            "the cached markup still queried: "
            f"{[q['sql'][:80] for q in ctx.captured_queries]}",
        )

    def test_a_catalogue_change_is_not_served_the_old_figure(self):
        self._seed(6)
        before = shop_typical_markup_percent()
        # Six products at 30% markup, then six at 150%: the median must move.
        for _ in range(6):
            self._priced_product(cost="10.00", price="25.00")
        bump_catalog_version()
        after = shop_typical_markup_percent()
        self.assertNotEqual(before, after)

    def test_too_little_data_caches_as_itself(self):
        """The sentinel: ``None`` means "don't trust a markup", not "cache miss"."""
        self._seed(2)  # below the five-point floor
        self.assertIsNone(shop_typical_markup_percent())
        with CaptureQueriesContext(connection) as ctx:
            self.assertIsNone(shop_typical_markup_percent())
        self.assertEqual(
            len(ctx.captured_queries),
            0,
            "a 'too little data' answer was recomputed instead of cached",
        )

    def test_a_category_and_the_shop_are_cached_apart(self):
        other = ProductCategory.objects.create(name="مشروبات")
        for _ in range(4):
            self._priced_product(cost="10.00", price="13.00")
        for _ in range(4):
            self._priced_product(cost="10.00", price="20.00", category=other)
        grocery = category_markup_percent([self.category.pk])
        drinks = category_markup_percent([other.pk])
        self.assertEqual(grocery, Decimal("30"))
        self.assertEqual(drinks, Decimal("100"))
        # And the cached values stay apart on the repeat.
        self.assertEqual(category_markup_percent([self.category.pk]), grocery)
        self.assertEqual(category_markup_percent([other.pk]), drinks)


@override_settings(
    POINTY_MARKUP_CACHE_TTL=900,
    POINTY_CATALOG_CACHE_ENABLED=False,
    CACHES={
        "default": {"BACKEND": "django.core.cache.backends.locmem.LocMemCache"}
    },
)
class MarkupCacheDisabledTests(TestCase):
    """With no catalog version there is no safe key, so the cache steps aside."""

    def test_the_answer_is_unchanged_without_a_version(self):
        warehouse = Warehouse.objects.first() or Warehouse.objects.create(name="main")
        supplier = Supplier.objects.create(name="مورد", phone="0910000001")
        category = ProductCategory.objects.create(name="بقالة")
        for n in range(6):
            product = Product.objects.create(name=f"q{n}", is_active=True)
            product.categories.add(category)
            variant = ProductVariant.objects.create(
                product=product,
                name="",
                sku=f"NC-{n}",
                unit_price=Decimal("13.00"),
                is_active=True,
                is_default=True,
            )
            order = PurchaseOrder.objects.create(
                warehouse=warehouse,
                supplier=supplier,
                order_number=f"NC-PO-{n:04d}",
                status=PurchaseOrder.Status.RECEIVED,
            )
            PurchaseLine.objects.create(
                purchase_order=order,
                variant=variant,
                quantity=Decimal("1"),
                unit_cost=Decimal("10.00"),
                unit_factor=Decimal("1"),
            )
        self.assertEqual(shop_typical_markup_percent(), Decimal("30"))
        self.assertNotEqual(shop_typical_markup_percent(), DEFAULT_MARKUP_PERCENT + 1)
