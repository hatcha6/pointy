"""A known lot is the same lot whatever form its date arrives in.

Receiving validates its lot rows through a serializer and hands dates over as
dates. Opening identification and a manual stock movement pass their lot rows
on as the JSON they arrived in, so there the expiry is a string — and a string
never equals the date a lot already stores, so every delivery of a known lot
through those two doors used to read as an expiry conflict.
"""

from datetime import date

from django.test import TestCase
from rest_framework import serializers

from apps.catalog.models import Product

from . import tracking
from .tracked_testing import tracked_product


class LotDateStringTests(TestCase):
    def setUp(self):
        product = tracked_product(
            name="شراب", sku="SYR-1", mode=Product.TrackingMode.BATCH
        )
        self.variant = product.default_variant

    def test_a_known_lot_named_with_a_string_date_is_the_same_lot(self):
        first, created = tracking.resolve_batch(
            variant=self.variant, code="L-77", expiry_date=date(2027, 3, 31)
        )
        again, created_again = tracking.resolve_batch(
            variant=self.variant, code="L-77", expiry_date="2027-03-31"
        )

        self.assertTrue(created)
        self.assertFalse(created_again)
        self.assertEqual(again.pk, first.pk)

    def test_a_new_lot_named_with_a_string_date_stores_a_date(self):
        batch, _ = tracking.resolve_batch(
            variant=self.variant,
            code="L-78",
            expiry_date="2027-05-31",
            manufactured_on="2025-05-01",
        )

        batch.refresh_from_db()
        self.assertEqual(batch.expiry_date, date(2027, 5, 31))
        self.assertEqual(batch.manufactured_on, date(2025, 5, 1))

    def test_a_different_date_on_a_known_lot_is_still_the_conflict(self):
        tracking.resolve_batch(
            variant=self.variant, code="L-79", expiry_date=date(2027, 3, 31)
        )

        with self.assertRaises(serializers.ValidationError):
            tracking.resolve_batch(
                variant=self.variant, code="L-79", expiry_date="2027-04-30"
            )

    def test_an_unreadable_date_is_refused_by_name(self):
        with self.assertRaises(serializers.ValidationError) as raised:
            tracking.resolve_batch(
                variant=self.variant, code="L-80", expiry_date="soon"
            )

        self.assertIn("expiry_date", raised.exception.detail)
