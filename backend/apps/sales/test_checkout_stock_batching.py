"""Regression tests: a cart's stock writes must not scale with its line count.

Deducting stock at checkout used to cost three statements per line — a
``SELECT ... FOR UPDATE`` on the stock row, an ``UPDATE`` of its quantities and
an ``INSERT`` of the ledger movement. Checkout is the one request a cashier
stands and waits for, so the three are batched (``lock_stock_items``,
``save_stock_item_quantities_bulk``, ``create_stock_movements``).

The scaling test bounds the marginal cost; the ledger test proves the batched
write records exactly what the per-line write did, because the stock ledger is
what every cost and profit report is derived from.
"""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.db import connection
from django.test import TestCase, override_settings
from django.test.utils import CaptureQueriesContext
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient

from apps.catalog.testing import create_product_with_default_variant
from apps.core.models import ShopSettings
from apps.core.roles import CASHIER_GROUP, ensure_role_groups
from apps.inventory.models import StockItem, StockMovement

CACHE_SETTINGS = {
    "default": {"BACKEND": "django.core.cache.backends.locmem.LocMemCache"}
}

# One lock, one quantity update, one ledger insert — for the whole cart.
EXPECTED_STOCK_STATEMENTS = 3
STOCK_TABLES = ("inventory_stockitem", "inventory_stockmovement")


@override_settings(CACHES=CACHE_SETTINGS)
class CheckoutStockBatchingTests(TestCase):
    _seq = 0

    def setUp(self):
        ensure_role_groups()
        self.client = APIClient()
        self.user = get_user_model().objects.create_user(username="till", password="p")
        self.user.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.client.force_authenticate(user=self.user)
        self.client.post(
            reverse("register-session-start"), {"opening_cash": "0.00"}, format="json"
        )

    def _variants(self, count, *, on_hand="100"):
        variants = []
        for _ in range(count):
            CheckoutStockBatchingTests._seq += 1
            i = CheckoutStockBatchingTests._seq
            product = create_product_with_default_variant(
                name=f"sb{i}", sku=f"SB{i}", unit_price="3.00", barcode=""
            )
            StockItem.objects.create(
                variant=product.default_variant,
                quantity_on_hand=Decimal(on_hand),
            )
            variants.append(product.default_variant)
        return variants

    def _checkout(self, variants, *, quantity=1):
        payload = {
            "lines": [
                {"variant": variant.pk, "quantity": quantity} for variant in variants
            ],
            "payment_method": "cash",
            "amount_received": f"{3 * quantity * len(variants)}.00",
        }
        return self.client.post(reverse("order-checkout"), payload, format="json")

    def _stock_statement_count(self, line_count):
        variants = self._variants(line_count)
        # Warm the per-request caches so the measured request is steady-state.
        self.client.get(reverse("order-list"))
        with CaptureQueriesContext(connection) as ctx:
            response = self._checkout(variants)
        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        return sum(
            1
            for query in ctx.captured_queries
            if any(table in query["sql"] for table in STOCK_TABLES)
        )

    def test_stock_writes_do_not_scale_with_the_cart(self):
        small = self._stock_statement_count(2)
        large = self._stock_statement_count(8)
        self.assertEqual(
            (small, large),
            (EXPECTED_STOCK_STATEMENTS, EXPECTED_STOCK_STATEMENTS),
            f"checkout ran {small} stock statements on a 2-line cart and {large} "
            f"on an 8-line one; a per-line lock, quantity save or movement "
            "insert was likely reintroduced.",
        )

    def test_batched_ledger_matches_the_single_line_write(self):
        """Every movement still carries its own line's before/after snapshot."""
        single = self._variants(1, on_hand="40")[0]
        response = self._checkout([single], quantity=3)
        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        reference = StockMovement.objects.get(variant=single)

        batched_variants = self._variants(3, on_hand="40")
        response = self._checkout(batched_variants, quantity=3)
        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        receipt_number = response.data["receipt_number"]

        movements = {
            movement.variant_id: movement
            for movement in StockMovement.objects.filter(
                variant__in=batched_variants,
            )
        }
        self.assertEqual(len(movements), 3)
        for variant in batched_variants:
            movement = movements[variant.pk]
            with self.subTest(variant=variant.pk):
                self.assertEqual(movement.movement_type, reference.movement_type)
                self.assertEqual(movement.quantity, reference.quantity)
                self.assertEqual(movement.on_hand_before, reference.on_hand_before)
                self.assertEqual(movement.on_hand_after, reference.on_hand_after)
                self.assertEqual(movement.committed_before, reference.committed_before)
                self.assertEqual(movement.committed_after, reference.committed_after)
                self.assertEqual(movement.expected_before, reference.expected_before)
                self.assertEqual(movement.expected_after, reference.expected_after)
                self.assertEqual(movement.created_by, self.user)
                self.assertEqual(movement.note, f"بيع {receipt_number}")
                self.assertEqual(movement.stock_item.variant_id, variant.pk)
                self.assertIsNotNone(movement.created_at)

                stock_item = StockItem.objects.get(variant=variant)
                self.assertEqual(stock_item.quantity_on_hand, Decimal("37.000"))
                # bulk_update skips auto_now, so the batched path stamps it by
                # hand; a stale updated_at here means that stamp was dropped.
                self.assertGreater(stock_item.updated_at, stock_item.created_at)

    def test_a_variant_without_a_stock_row_is_still_locked_and_deducted(self):
        """The bulk lock finds no row for a never-stocked variant, so that one
        falls through to create-and-lock. Overselling is on so the sale lands
        and the created row can be inspected."""
        ShopSettings.objects.filter(pk=1).update(allow_overselling=True)
        stocked = self._variants(1)[0]
        CheckoutStockBatchingTests._seq += 1
        i = CheckoutStockBatchingTests._seq
        unstocked = create_product_with_default_variant(
            name=f"sb{i}", sku=f"SB{i}", unit_price="3.00", barcode=""
        ).default_variant
        self.assertFalse(StockItem.objects.filter(variant=unstocked).exists())

        response = self._checkout([stocked, unstocked], quantity=2)
        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)

        created = StockItem.objects.get(variant=unstocked)
        self.assertEqual(created.quantity_on_hand, Decimal("-2.000"))
        movement = StockMovement.objects.get(variant=unstocked)
        self.assertEqual(movement.on_hand_before, Decimal("0.000"))
        self.assertEqual(movement.on_hand_after, Decimal("-2.000"))
