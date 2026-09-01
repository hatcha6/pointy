"""Pricing a product from a foreign price sheet.

The invariant under test throughout: **the stored base price is always the
shop's own currency, and it only ever changes because somebody changed it.**
A rate moving is not a price change — it is a proposal.
"""

from datetime import timedelta
from decimal import Decimal

from django.db import connection
from django.test import TestCase
from django.test.utils import CaptureQueriesContext
from django.utils import timezone

from apps.catalog.models import Product, ProductUnit, ProductVariant, UnitOfMeasure
from apps.catalog.pricing import (
    apply_reprice,
    reprice_preview,
    set_base_price,
    set_foreign_price,
)
from apps.fx import currencies as ref
from apps.fx.models import ExchangeRate
from apps.fx.rates import invalidate_rate_cache
from apps.fx.services import ensure_builtin_currencies


class ForeignPricingTestCase(TestCase):
    def setUp(self):
        super().setUp()
        ensure_builtin_currencies()
        invalidate_rate_cache()
        self.now = timezone.now()

    def add_rate(self, rate, *, at=None, frm="USD", to="LYD"):
        return ExchangeRate.objects.create(
            from_currency_id=frm,
            to_currency_id=to,
            instrument=ref.INSTRUMENT_CASH,
            effective_at=at or self.now,
            rate=Decimal(rate),
            source=ref.SOURCE_RELAY,
        )

    def make_product(self, *, currency=None, price="10.00", name="Widget"):
        product = Product.objects.create(name=name, pricing_currency_id=currency)
        variant = ProductVariant.objects.create(
            product=product,
            sku=f"SKU-{product.pk}",
            unit_price=Decimal(price),
            is_default=True,
        )
        return product, variant


class SetForeignPriceTests(ForeignPricingTestCase):
    def test_base_priced_product_stores_the_amount_directly(self):
        product, variant = self.make_product()
        self.assertTrue(set_foreign_price(variant, "15.00"))
        variant.refresh_from_db()
        self.assertEqual(variant.unit_price, Decimal("15.00"))
        self.assertIsNone(variant.price_amount)
        self.assertIsNone(variant.price_rate)

    def test_foreign_priced_product_derives_its_base_price(self):
        self.add_rate("6.85")
        product, variant = self.make_product(currency="USD")
        self.assertTrue(set_foreign_price(variant, "12.00"))
        variant.refresh_from_db()
        self.assertEqual(variant.unit_price, Decimal("82.20"))
        self.assertEqual(variant.price_amount, Decimal("12.00"))
        self.assertEqual(variant.price_rate, Decimal("6.85000000"))
        self.assertIsNotNone(variant.price_rate_at)

    def test_the_rate_is_frozen_not_re_read(self):
        self.add_rate("6.85")
        product, variant = self.make_product(currency="USD")
        set_foreign_price(variant, "12.00")
        # The dollar moves. The shelf price does not.
        self.add_rate("7.11", at=self.now - timedelta(hours=1))
        invalidate_rate_cache()
        variant.refresh_from_db()
        self.assertEqual(variant.unit_price, Decimal("82.20"))
        self.assertEqual(variant.price_rate, Decimal("6.85000000"))

    def test_no_rate_keeps_the_existing_base_price_rather_than_zeroing_it(self):
        product, variant = self.make_product(currency="USD", price="99.00")
        self.assertFalse(set_foreign_price(variant, "12.00"))
        variant.refresh_from_db()
        self.assertEqual(variant.unit_price, Decimal("99.00"))
        # The foreign number is still recorded, so the row reprices itself the
        # moment a rate arrives.
        self.assertEqual(variant.price_amount, Decimal("12.00"))
        self.assertIsNone(variant.price_rate)

    def test_switching_a_product_back_to_base_clears_the_foreign_trio(self):
        self.add_rate("6.85")
        product, variant = self.make_product(currency="USD")
        set_foreign_price(variant, "12.00")
        product.pricing_currency_id = None
        product.save(update_fields=["pricing_currency"])
        variant.product = product
        set_foreign_price(variant, "50.00")
        variant.refresh_from_db()
        self.assertEqual(variant.unit_price, Decimal("50.00"))
        self.assertIsNone(variant.price_amount)
        self.assertIsNone(variant.price_rate)

    def test_pricing_currency_equal_to_base_is_treated_as_base(self):
        product, variant = self.make_product(currency="LYD")
        self.assertTrue(set_foreign_price(variant, "20.00"))
        variant.refresh_from_db()
        self.assertEqual(variant.unit_price, Decimal("20.00"))
        self.assertIsNone(variant.price_rate)

    def test_a_product_unit_carries_its_own_foreign_price(self):
        self.add_rate("6.85")
        product, variant = self.make_product(currency="USD")
        box, _ = UnitOfMeasure.objects.get_or_create(
            code="box", defaults={"name": "Box"}
        )
        unit = ProductUnit.objects.create(
            product=product, unit=box, factor_to_base=Decimal("12")
        )
        self.assertTrue(set_foreign_price(unit, "130.00"))
        unit.refresh_from_db()
        self.assertEqual(unit.price, Decimal("890.50"))
        self.assertEqual(unit.price_amount, Decimal("130.00"))


class SetBasePriceTests(ForeignPricingTestCase):
    """Typing a price by hand — the purchase draft's pricing sheet, the
    product-details Change-prices dialog — writes the shop's own currency.

    The trap this class exists to keep shut: writing that number straight onto
    ``unit_price`` leaves a foreign-priced product's frozen price sheet pointing
    at the OLD price, so the next repricing quietly reverts the number the owner
    just set. It has to be restated, not left behind.
    """

    def test_base_priced_product_just_stores_the_number(self):
        product, variant = self.make_product()
        self.assertTrue(set_base_price(variant, Decimal("15.00")))
        variant.refresh_from_db()
        self.assertEqual(variant.unit_price, Decimal("15.00"))
        self.assertIsNone(variant.price_amount)
        self.assertIsNone(variant.price_rate)

    def test_a_foreign_priced_row_restates_its_price_sheet_at_the_frozen_rate(self):
        self.add_rate("6.85")
        product, variant = self.make_product(currency="USD")
        set_foreign_price(variant, "12.00")
        variant.refresh_from_db()
        self.assertEqual(variant.unit_price, Decimal("82.20"))

        # The owner reprices to 90 dinars by hand.
        self.assertTrue(set_base_price(variant, Decimal("90.00")))
        variant.refresh_from_db()
        self.assertEqual(variant.unit_price, Decimal("90.00"))
        # 90 / 6.85 -> 13.14 dollars, at the same frozen rate.
        self.assertEqual(variant.price_amount, Decimal("13.14"))
        self.assertEqual(variant.price_rate, Decimal("6.85"))

    def test_a_price_the_rate_can_express_leaves_nothing_to_reprice(self):
        """The whole point: after a manual reprice, nothing has drifted."""
        self.add_rate("6.85")
        product, variant = self.make_product(currency="USD")
        set_foreign_price(variant, "12.00")

        # 68.50 dinars is exactly $10.00 at this rate, so the restated price
        # sheet round-trips and the reprice screen has nothing to say.
        set_base_price(variant, Decimal("68.50"))

        proposals = [
            p for p in reprice_preview() if p.target_id == variant.pk and p.changed
        ]
        self.assertEqual(proposals, [])

    def test_a_price_the_rate_cannot_express_drifts_a_cent_never_a_revert(self):
        """90.00 dinars sits between $13.13 and $13.14 at 6.85 — no dollar
        amount lands on it. The residue must stay a rounding cent; the failure
        this guards against is the screen proposing the OLD price back."""
        self.add_rate("6.85")
        product, variant = self.make_product(currency="USD")
        set_foreign_price(variant, "12.00")
        self.assertEqual(ProductVariant.objects.get(pk=variant.pk).unit_price,
                         Decimal("82.20"))

        set_base_price(variant, Decimal("90.00"))

        proposals = [
            p for p in reprice_preview() if p.target_id == variant.pk and p.changed
        ]
        for proposal in proposals:
            self.assertLessEqual(abs(proposal.delta), Decimal("0.01"))

    def test_a_never_foreign_priced_row_picks_up_todays_rate(self):
        self.add_rate("7.00")
        product, variant = self.make_product(currency="USD", price="0.00")

        self.assertTrue(set_base_price(variant, Decimal("70.00")))
        variant.refresh_from_db()
        self.assertEqual(variant.unit_price, Decimal("70.00"))
        self.assertEqual(variant.price_amount, Decimal("10.00"))
        self.assertEqual(variant.price_rate, Decimal("7.00"))

    def test_no_rate_still_writes_the_price_it_just_cannot_restate_the_sheet(self):
        product, variant = self.make_product(currency="USD")

        self.assertFalse(set_base_price(variant, Decimal("50.00")))
        variant.refresh_from_db()
        self.assertEqual(variant.unit_price, Decimal("50.00"))
        self.assertIsNone(variant.price_amount)

    def test_a_product_unit_is_repriced_the_same_way(self):
        self.add_rate("6.85")
        product, variant = self.make_product(currency="USD")
        unit = UnitOfMeasure.objects.create(code="sbp-carton", name="كرتونة")
        product_unit = ProductUnit.objects.create(
            product=product,
            unit=unit,
            factor_to_base=Decimal("12"),
        )
        set_foreign_price(product_unit, "100.00")

        self.assertTrue(set_base_price(product_unit, Decimal("700.00")))
        product_unit.refresh_from_db()
        self.assertEqual(product_unit.price, Decimal("700.00"))
        self.assertEqual(product_unit.price_amount, Decimal("102.19"))


class RepricePreviewTests(ForeignPricingTestCase):
    def setUp(self):
        super().setUp()
        self.add_rate("6.85", at=self.now - timedelta(hours=2))
        self.product, self.variant = self.make_product(currency="USD")
        set_foreign_price(self.variant, "12.00")

    def test_no_rate_movement_means_nothing_to_reprice(self):
        self.assertEqual(reprice_preview(), [])

    def test_a_rate_move_produces_a_proposal_with_both_rates(self):
        self.add_rate("7.11", at=self.now - timedelta(hours=1))
        invalidate_rate_cache()
        proposals = reprice_preview()
        self.assertEqual(len(proposals), 1)
        proposal = proposals[0]
        self.assertEqual(proposal.current_base_price, Decimal("82.20"))
        self.assertEqual(proposal.proposed_base_price, Decimal("85.32"))
        self.assertEqual(proposal.old_rate, Decimal("6.85000000"))
        self.assertEqual(proposal.new_rate, Decimal("7.11000000"))
        self.assertEqual(proposal.currency_code, "USD")

    def test_the_delta_explains_the_move(self):
        self.add_rate("7.11", at=self.now - timedelta(hours=1))
        invalidate_rate_cache()
        proposal = reprice_preview()[0]
        self.assertEqual(proposal.delta, Decimal("3.12"))
        self.assertEqual(proposal.delta_percent, Decimal("3.80"))

    def test_base_priced_products_are_never_proposed(self):
        self.make_product(name="Local", price="5.00")
        self.add_rate("7.11", at=self.now - timedelta(hours=1))
        invalidate_rate_cache()
        self.assertEqual({p.product_id for p in reprice_preview()}, {self.product.pk})

    def test_archived_products_are_never_proposed(self):
        self.product.archive()
        self.add_rate("7.11", at=self.now - timedelta(hours=1))
        invalidate_rate_cache()
        self.assertEqual(reprice_preview(), [])

    def test_a_product_with_no_resolvable_rate_is_reported_not_hidden(self):
        other = Product.objects.create(name="Turkish", pricing_currency_id="TRY")
        variant = ProductVariant.objects.create(
            product=other, sku="TRY-1", unit_price=Decimal("10.00"), is_default=True
        )
        set_foreign_price(variant, "300.00")
        proposals = [p for p in reprice_preview() if p.product_id == other.pk]
        self.assertEqual(len(proposals), 1)
        self.assertTrue(proposals[0].unpriceable)
        self.assertIsNone(proposals[0].proposed_base_price)

    def test_include_unchanged_returns_the_whole_foreign_catalogue(self):
        self.assertEqual(len(reprice_preview(include_unchanged=True)), 1)

    def test_query_count_does_not_grow_with_the_catalogue(self):
        """The guard that matters when a real importer's catalogue is 4,000 rows.

        Pinned as a comparison rather than a magic number: what must hold is
        that adding rows adds no queries, whatever the fixed cost happens to be.
        """
        self.add_rate("7.11", at=self.now - timedelta(hours=1))

        def count_for(extra_rows):
            for index in range(extra_rows):
                _product, variant = self.make_product(
                    currency="USD", name=f"Bulk {index}"
                )
                # Priced at the OLD rate, so they genuinely have drift to
                # report — pricing them after the new rate landed would leave
                # nothing to propose and the guard would prove nothing.
                set_foreign_price(
                    variant, "5.00", at=self.now - timedelta(hours=2)
                )
            invalidate_rate_cache()
            with CaptureQueriesContext(connection) as captured:
                proposals = reprice_preview()
            return len(captured), len(proposals)

        small_queries, small_rows = count_for(0)
        large_queries, large_rows = count_for(12)
        self.assertEqual(small_rows, 1)
        self.assertEqual(large_rows, 13)
        self.assertEqual(
            small_queries,
            large_queries,
            "reprice_preview issues a query per row; it must resolve one rate "
            "per currency and read the catalogue in fixed queries.",
        )


class ApplyRepriceTests(ForeignPricingTestCase):
    def setUp(self):
        super().setUp()
        self.add_rate("6.85", at=self.now - timedelta(hours=2))
        self.product, self.variant = self.make_product(currency="USD")
        set_foreign_price(self.variant, "12.00")
        self.add_rate("7.11", at=self.now - timedelta(hours=1))
        invalidate_rate_cache()

    def test_applying_writes_the_new_base_price_and_rate(self):
        self.assertEqual(apply_reprice(reprice_preview()), 1)
        self.variant.refresh_from_db()
        self.assertEqual(self.variant.unit_price, Decimal("85.32"))
        self.assertEqual(self.variant.price_rate, Decimal("7.11000000"))

    def test_the_foreign_price_itself_is_untouched(self):
        apply_reprice(reprice_preview())
        self.variant.refresh_from_db()
        self.assertEqual(self.variant.price_amount, Decimal("12.00"))

    def test_it_applies_the_rate_that_was_previewed_not_a_newer_one(self):
        proposals = reprice_preview()
        # A newer rate lands between the preview and the confirmation.
        self.add_rate("9.99", at=self.now - timedelta(minutes=1))
        invalidate_rate_cache()
        apply_reprice(proposals)
        self.variant.refresh_from_db()
        # What was on screen is what was written.
        self.assertEqual(self.variant.unit_price, Decimal("85.32"))

    def test_applying_twice_is_a_no_op(self):
        proposals = reprice_preview()
        self.assertEqual(apply_reprice(proposals), 1)
        self.assertEqual(apply_reprice(reprice_preview()), 0)

    def test_unpriceable_rows_are_skipped(self):
        other = Product.objects.create(name="Turkish", pricing_currency_id="TRY")
        variant = ProductVariant.objects.create(
            product=other, sku="TRY-1", unit_price=Decimal("10.00"), is_default=True
        )
        set_foreign_price(variant, "300.00")
        apply_reprice(reprice_preview())
        variant.refresh_from_db()
        self.assertEqual(variant.unit_price, Decimal("10.00"))
