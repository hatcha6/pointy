"""Nightly "most bought" popularity recompute (apps.catalog.popularity)."""

from datetime import timedelta
from decimal import Decimal

from django.test import TestCase
from django.utils import timezone

from apps.inventory.models import StockItem

from .models import Product
from .popularity import recompute_product_popularity
from .testing import create_product_with_default_variant


class RecomputeProductPopularityTests(TestCase):
    def setUp(self):
        from apps.sales.models import RegisterSession

        self.session = RegisterSession.objects.create(
            owner_key="seed:popularity",
            status=RegisterSession.Status.OPEN,
        )

    def _sellable(self, name, sku):
        product = create_product_with_default_variant(
            name=name, sku=sku, unit_price=Decimal("5.00")
        )
        variant = product.default_variant
        StockItem.objects.create(variant=variant, quantity_on_hand=Decimal("1000"))
        return product, variant

    def _paid_order(self, *variants):
        from apps.payments.models import Payment
        from apps.sales.services import checkout_order

        return checkout_order(
            register_session=self.session,
            lines_data=[
                {"variant": variant, "quantity": Decimal("1")} for variant in variants
            ],
            payments_data=[
                {"method": Payment.Method.CASH, "amount": Decimal(5 * len(variants))}
            ],
        )

    def test_counts_paid_lines_per_product(self):
        product_a, a = self._sellable("Alpha", "A")
        product_b, b = self._sellable("Beta", "B")
        product_c, _ = self._sellable("Gamma", "C")

        # A appears on 3 paid lines, B on 1, C on none.
        self._paid_order(a, b)
        self._paid_order(a)
        self._paid_order(a)

        summary = recompute_product_popularity()

        product_a.refresh_from_db()
        product_b.refresh_from_db()
        product_c.refresh_from_db()
        self.assertEqual(product_a.popularity, 3)
        self.assertEqual(product_b.popularity, 1)
        self.assertEqual(product_c.popularity, 0)
        self.assertEqual(summary["products_with_sales"], 2)

    def test_excludes_orders_outside_the_window(self):
        product_a, a = self._sellable("Alpha", "A")

        old = self._paid_order(a)
        self._paid_order(a)  # recent
        from apps.sales.models import Order

        Order.objects.filter(pk=old.pk).update(
            created_at=timezone.now() - timedelta(days=100)
        )

        recompute_product_popularity()

        product_a.refresh_from_db()
        # Only the in-window (recent) line is counted.
        self.assertEqual(product_a.popularity, 1)

    def test_resets_products_with_no_recent_sales(self):
        product_a, a = self._sellable("Alpha", "A")
        product_a.popularity = 42  # stale value from a previous window
        product_a.save(update_fields=["popularity"])

        old = self._paid_order(a)
        from apps.sales.models import Order

        Order.objects.filter(pk=old.pk).update(
            created_at=timezone.now() - timedelta(days=200)
        )

        recompute_product_popularity()

        product_a.refresh_from_db()
        self.assertEqual(product_a.popularity, 0)

    def test_idempotent(self):
        _product_a, a = self._sellable("Alpha", "A")
        self._paid_order(a)
        self._paid_order(a)

        recompute_product_popularity()
        first = list(Product.objects.order_by("id").values_list("id", "popularity"))
        recompute_product_popularity()
        second = list(Product.objects.order_by("id").values_list("id", "popularity"))

        self.assertEqual(first, second)
