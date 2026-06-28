"""Tests for the reorder building blocks in ``purchasing.services``:
``supplier_candidates_for_variants`` (ranked supplier evidence per variant) and
``default_purchase_pack_for_product`` (whole-pack rounding unit)."""

from datetime import datetime, time, timedelta
from decimal import Decimal

from django.test import TestCase
from django.utils import timezone

from apps.catalog.models import Product, ProductVariant, ProductUnit, UnitOfMeasure
from apps.purchasing.models import PurchaseLine, PurchaseOrder, Supplier
from apps.purchasing.services import (
    default_purchase_pack_for_product,
    supplier_candidates_for_variants,
)


class SupplierCandidatesTests(TestCase):
    def setUp(self):
        self.product = Product.objects.create(name="ماء معدني")
        self.variant = ProductVariant.objects.create(
            product=self.product, sku="SC-WATER", unit_price=Decimal("1.00"), is_default=True
        )
        self.acme = Supplier.objects.create(name="آكمي")
        self.globex = Supplier.objects.create(name="غلوبكس")

    def _line(self, supplier, *, unit_cost, when, status=PurchaseOrder.Status.RECEIVED,
              unit="", unit_factor="1", variant=None):
        po = PurchaseOrder.objects.create(supplier=supplier, status=status)
        line = PurchaseLine.objects.create(
            purchase_order=po,
            variant=variant or self.variant,
            quantity=1,
            unit=unit,
            unit_factor=Decimal(unit_factor),
            unit_cost=Decimal(unit_cost),
        )
        dt = timezone.make_aware(datetime.combine(when, time(12, 0)))
        PurchaseOrder.objects.filter(pk=po.pk).update(created_at=dt, received_at=dt)
        PurchaseLine.objects.filter(pk=line.pk).update(created_at=dt)
        return line

    def _days_ago(self, n):
        return timezone.localdate() - timedelta(days=n)

    def test_returns_all_suppliers_ranked_most_recent_first(self):
        # Globex is the most recent; Acme older but bought more often.
        self._line(self.acme, unit_cost="2.00", when=self._days_ago(30))
        self._line(self.acme, unit_cost="2.20", when=self._days_ago(20))
        self._line(self.globex, unit_cost="2.50", when=self._days_ago(5))

        out = supplier_candidates_for_variants([self.variant.id])
        cands = out[self.variant.id]
        self.assertEqual([c["supplier_name"] for c in cands], ["غلوبكس", "آكمي"])
        acme = next(c for c in cands if c["supplier_name"] == "آكمي")
        self.assertEqual(acme["order_count"], 2)
        self.assertEqual(acme["last_base_unit_cost"], Decimal("2.20"))  # most recent line
        self.assertEqual(acme["min_base_unit_cost"], Decimal("2.00"))
        self.assertEqual(acme["avg_base_unit_cost"], Decimal("2.10"))

    def test_base_unit_cost_normalised_for_pack_purchases(self):
        # Bought a carton of 12 at 24.00 → base unit cost is 2.00.
        self._line(self.acme, unit_cost="24.00", when=self._days_ago(3), unit="carton", unit_factor="12")
        out = supplier_candidates_for_variants([self.variant.id])
        cand = out[self.variant.id][0]
        self.assertEqual(cand["last_base_unit_cost"], Decimal("2.00"))
        self.assertEqual(cand["last_unit"], "carton")
        self.assertEqual(cand["last_unit_factor"], Decimal("12"))

    def test_cancelled_pos_excluded(self):
        self._line(self.acme, unit_cost="2.00", when=self._days_ago(2),
                   status=PurchaseOrder.Status.CANCELLED)
        out = supplier_candidates_for_variants([self.variant.id])
        self.assertNotIn(self.variant.id, out)  # only purchase was cancelled → no history

    def test_no_history_variant_absent(self):
        out = supplier_candidates_for_variants([self.variant.id])
        self.assertEqual(out, {})


class DefaultPurchasePackTests(TestCase):
    def setUp(self):
        self.product = Product.objects.create(name="عصير")
        self.piece = UnitOfMeasure.objects.create(code="sc-piece", name="قطعة")
        self.box = UnitOfMeasure.objects.create(code="sc-box", name="علبة")
        self.carton = UnitOfMeasure.objects.create(code="sc-carton", name="كرتون")

    def test_prefers_largest_purchasable_pack(self):
        ProductUnit.objects.create(product=self.product, unit=self.box, factor_to_base=Decimal("6"))
        ProductUnit.objects.create(product=self.product, unit=self.carton, factor_to_base=Decimal("24"))
        code, factor = default_purchase_pack_for_product(self.product)
        self.assertEqual(code, "sc-carton")
        self.assertEqual(factor, Decimal("24"))

    def test_honours_preferred_unit_when_present(self):
        ProductUnit.objects.create(product=self.product, unit=self.box, factor_to_base=Decimal("6"))
        ProductUnit.objects.create(product=self.product, unit=self.carton, factor_to_base=Decimal("24"))
        code, factor = default_purchase_pack_for_product(self.product, preferred_unit_code="sc-box")
        self.assertEqual(code, "sc-box")
        self.assertEqual(factor, Decimal("6"))

    def test_falls_back_to_base_unit(self):
        code, factor = default_purchase_pack_for_product(self.product)
        self.assertEqual(code, "")
        self.assertEqual(factor, Decimal("1"))
