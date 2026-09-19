"""§18.4: one flag, not two — and what a pharmacy notices on upgrade day.

The fold is a behaviour change for shops that already tick ``tracks_expiry``,
so the things that must *not* change are asserted here alongside the one thing
that does.
"""

from datetime import timedelta
from decimal import Decimal

from django.test import TestCase
from django.utils import timezone
from rest_framework import serializers as drf

from apps.catalog.models import Product, ProductVariant
from apps.inventory.integrity import tracking_invariant_violations
from apps.inventory.models import StockBatch, StockItem
from apps.inventory.tracked_testing import receive, tracked_product
from apps.sales.models import RegisterSession
from apps.sales.services import checkout_order


class TheFlagIsDerived(TestCase):
    def test_a_lot_tracked_product_tracks_expiry_by_definition(self):
        product = tracked_product(
            name="بنادول", sku="F1", mode=Product.TrackingMode.BATCH
        )
        self.assertTrue(product.tracks_expiry)

    def test_the_flag_cannot_be_set_against_the_mode(self):
        """The four-combination state §18.4 says must not exist."""
        product = tracked_product(
            name="كولا", sku="F2", mode=Product.TrackingMode.QUANTITY
        )
        product.tracks_expiry = True
        product.save()
        product.refresh_from_db()
        self.assertFalse(product.tracks_expiry)

    def test_turning_it_on_through_the_api_sets_the_mode(self):
        """An old client still sends the flag; it means what it always meant."""
        from apps.catalog.serializers import ProductCatalogSerializer

        product = tracked_product(
            name="حليب", sku="F3", mode=Product.TrackingMode.QUANTITY
        )
        serializer = ProductCatalogSerializer(
            product, data={"tracks_expiry": True}, partial=True
        )
        serializer.is_valid(raise_exception=True)
        serializer.save()
        product.refresh_from_db()
        self.assertEqual(product.tracking_mode, Product.TrackingMode.BATCH)
        self.assertTrue(product.tracks_expiry)


class WhatAPharmacyKeeps(TestCase):
    """The shop that only ever wanted "this milk goes off on the 12th"."""

    def setUp(self):
        self.product = tracked_product(
            name="حليب", sku="MILKF", mode=Product.TrackingMode.BATCH,
            unit_price="3.00",
        )
        self.product.expiry_required = True
        self.product.save(update_fields=["expiry_required", "updated_at"])
        self.variant = self.product.default_variant
        self.expiry = timezone.localdate() + timedelta(days=10)

    def test_it_never_has_to_type_a_lot_code(self):
        receive(
            variant=self.variant, quantity=6, unit_cost="2.00",
            expiry_date=self.expiry,
        )
        lot = StockBatch.objects.get()
        self.assertTrue(lot.code_is_generated)
        self.assertEqual(lot.display_code, "")

    def test_the_expiry_date_survives_onto_the_generated_lot(self):
        """The alerts are the whole reason the box was ticked."""
        receive(
            variant=self.variant, quantity=6, unit_cost="2.00",
            expiry_date=self.expiry,
        )
        self.assertEqual(StockBatch.objects.get().expiry_date, self.expiry)

    def test_selling_draws_the_earliest_expiring_cohort_first(self):
        receive(
            variant=self.variant, quantity=3, unit_cost="2.00",
            expiry_date=self.expiry + timedelta(days=30),
        )
        receive(
            variant=self.variant, quantity=3, unit_cost="2.00",
            expiry_date=self.expiry,
        )
        checkout_order(
            register_session=RegisterSession.objects.create(
                owner_key="fold", status=RegisterSession.Status.OPEN,
                opening_cash=Decimal("0.00"),
            ),
            lines_data=[{"variant": self.variant, "quantity": Decimal("2")}],
            payments_data=[{"method": "cash", "amount": Decimal("6.00")}],
        )
        earliest = StockBatch.objects.get(expiry_date=self.expiry)
        self.assertEqual(
            earliest.balances.get().remaining_quantity, Decimal("1.000")
        )
        self.assertEqual(tracking_invariant_violations(), [])

    def test_a_stock_count_still_works(self):
        """The tripwire refuses tracked movements that name nothing, so the
        drawdown has to allocate — otherwise the fold would take stock counts
        away from every shop it touched."""
        from apps.inventory.services import consume_expiring_stock_batches
        from apps.inventory.models import Warehouse

        receive(
            variant=self.variant, quantity=6, unit_cost="2.00",
            expiry_date=self.expiry,
        )
        plan = consume_expiring_stock_batches(
            variant=self.variant,
            quantity=Decimal("2"),
            warehouse=Warehouse.default_id(),
        )
        self.assertEqual(plan.quantity, Decimal("2.000"))
        self.assertEqual(
            StockBatch.objects.get().balances.get().remaining_quantity,
            Decimal("4.000"),
        )


class WhatDoesNotBecomeMandatory(TestCase):
    def test_a_lot_tracked_product_need_not_carry_an_expiry_date(self):
        """A paint batch is lot-tracked for provenance and never goes off.

        Before ``expiry_required`` was split out, folding the flag would have
        made every lot-tracked delivery demand a date.
        """
        product = tracked_product(
            name="دهان", sku="PAINT", mode=Product.TrackingMode.BATCH
        )
        self.assertTrue(product.tracks_expiry)
        self.assertFalse(product.expiry_required)
        receive(variant=product.default_variant, quantity=5, unit_cost="10.00")
        self.assertIsNone(StockBatch.objects.get().expiry_date)
