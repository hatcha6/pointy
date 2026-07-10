"""Tests for the Redis-backed price-lookup cache (cache.py).

The catalog-version machinery is globally disabled under the test runner (see
``TESTING`` in settings), so these tests opt back in explicitly with an
isolated LocMem cache.
"""

from decimal import Decimal
from unittest import mock

from django.core.cache import cache
from django.test import TestCase, override_settings

from apps.price_checker import cache as lookup_cache
from apps.price_checker.cache import lookup_price_cached

from .tests import BARCODE, add_percentage_discount, make_product

CACHED = override_settings(
    CACHES={
        "default": {
            "BACKEND": "django.core.cache.backends.locmem.LocMemCache",
            "LOCATION": "price-lookup-cache-tests",
        },
    },
    POINTY_CATALOG_CACHE_ENABLED=True,
    POINTY_PRICE_LOOKUP_CACHE_TTL=30,
)


@CACHED
class PriceLookupCacheTests(TestCase):
    def setUp(self):
        cache.clear()

    def test_repeat_scan_is_served_with_zero_queries(self):
        make_product(price="20.00")
        first = lookup_price_cached(BARCODE)
        with self.assertNumQueries(0):
            second = lookup_price_cached(BARCODE)
        self.assertEqual(second, first)
        self.assertTrue(second.found)
        self.assertEqual(second.final_price, Decimal("20.00"))

    def test_not_found_is_cached_too(self):
        self.assertFalse(lookup_price_cached("no-such-code").found)
        with self.assertNumQueries(0):
            self.assertFalse(lookup_price_cached("no-such-code").found)

    def test_price_change_invalidates(self):
        product = make_product(price="20.00")
        self.assertEqual(lookup_price_cached(BARCODE).final_price, Decimal("20.00"))
        variant = product.variants.get()
        variant.unit_price = Decimal("25.00")
        variant.save()  # post_save bumps the catalog version
        self.assertEqual(lookup_price_cached(BARCODE).final_price, Decimal("25.00"))

    def test_new_discount_invalidates(self):
        product = make_product(price="20.00")
        self.assertEqual(lookup_price_cached(BARCODE).final_price, Decimal("20.00"))
        add_percentage_discount(product, "10")  # bumps the discount rules version
        result = lookup_price_cached(BARCODE)
        self.assertEqual(result.final_price, Decimal("18.00"))
        self.assertTrue(result.has_discount)

    def test_stock_change_refreshes_in_stock_flag(self):
        from apps.inventory.models import StockItem

        product = make_product(price="20.00")
        variant = product.variants.get()
        StockItem.objects.create(variant=variant, quantity_on_hand=Decimal("5"))
        self.assertTrue(lookup_price_cached(BARCODE).in_stock)
        stock = StockItem.objects.get(variant=variant)
        stock.quantity_on_hand = Decimal("0")
        stock.save()  # post_save bumps the catalog version
        self.assertFalse(lookup_price_cached(BARCODE).in_stock)

    def test_fails_open_when_redis_is_down(self):
        make_product(price="20.00")
        boom = mock.Mock(side_effect=ConnectionError("redis down"))
        with mock.patch.object(lookup_cache.cache, "get", boom), mock.patch.object(
            lookup_cache.cache, "set", boom
        ):
            result = lookup_price_cached(BARCODE)
        self.assertTrue(result.found)
        self.assertEqual(result.final_price, Decimal("20.00"))
