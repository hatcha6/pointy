"""The receipt series must not skip.

A field week produced five jumps in the shop's receipt numbers — 30, 31, 31, 31
and 32 — totalling 155 invoice numbers that were never issued to anybody. Every
one of them landed on an unclean restart of the database.

The cause was that the receipt number was the row's own primary key in a
costume: ``R{date}{order.id}``. PostgreSQL reserves 32 sequence values in WAL at
a time so `nextval` need not write a WAL record per call, and crash recovery
resumes from that reservation rather than from the last value actually handed
out. The reservation is refreshed after every checkpoint, so at a sale every
hundred seconds and a checkpoint every five minutes, a crash always discarded
almost the whole batch of 32. None of that is a PostgreSQL bug — a primary key
is allowed to have gaps. A number the shop writes in its paper ledger is not.
"""

import unittest
from importlib import import_module

from django.db import connection, transaction
from django.test import TestCase

from apps.documents.numbering import SALE_ORDER_SERIES
from apps.sales.models import Order


def _tail(receipt_number: str) -> int:
    """The counter part of ``R20260916798785``."""
    return int(receipt_number[9:])


class ReceiptSeriesTests(TestCase):
    def test_consecutive_sales_are_numbered_consecutively(self):
        first = Order.objects.create()
        second = Order.objects.create()

        self.assertEqual(_tail(second.receipt_number), _tail(first.receipt_number) + 1)

    def test_the_number_is_stamped_on_the_insert_itself(self):
        """One write per sale, not two.

        The number used to be read off the saved row, so every sale cost an
        INSERT and then an UPDATE — and the UPDATE had to be smuggled past the
        document guard, because an order created already paid looked like an
        edit to a submitted document.
        """
        order = Order.objects.create()

        self.assertTrue(order.receipt_number)
        self.assertEqual(
            Order.objects.get(pk=order.pk).receipt_number, order.receipt_number
        )

    def test_a_sale_that_fails_does_not_consume_a_number(self):
        first = Order.objects.create()

        with self.assertRaises(RuntimeError):
            with transaction.atomic():
                Order.objects.create()
                raise RuntimeError("payment declined after the order was written")

        second = Order.objects.create()
        self.assertEqual(_tail(second.receipt_number), _tail(first.receipt_number) + 1)

    def test_a_caller_that_brings_its_own_number_keeps_it(self):
        """Imports and corrections name their own receipts."""
        order = Order.objects.create(receipt_number="R20200101000042")

        self.assertEqual(order.receipt_number, "R20200101000042")

    def test_the_series_survives_a_hole_in_the_primary_key(self):
        """The regression itself, without needing a crash.

        Burning primary keys is exactly what crash recovery does to the id
        sequence. What must not happen any more is the receipt series following
        it.
        """
        first = Order.objects.create()
        # A hole in the ids, whatever burned them.
        second = Order.objects.create(id=first.id + 500)
        third = Order.objects.create()

        self.assertEqual(_tail(second.receipt_number), _tail(first.receipt_number) + 1)
        self.assertEqual(_tail(third.receipt_number), _tail(second.receipt_number) + 1)
        self.assertNotIn(str(second.id), second.receipt_number)


@unittest.skipUnless(
    connection.vendor == "postgresql",
    "The sequence reservation this reproduces is a PostgreSQL mechanism.",
)
class ReceiptSeriesSurvivesSequenceBurnTests(TestCase):
    def test_a_burned_id_sequence_does_not_move_the_receipt_series(self):
        """Exactly what the field saw, minus the power cut.

        Crash recovery leaves the id sequence at the reservation's high-water
        mark, so the next sale's id is up to 32 higher than the last one's.
        Before this change the receipt number went with it.
        """
        first = Order.objects.create()

        sequence = connection.ops.quote_name("sales_order_id_seq")
        with connection.cursor() as cursor:
            cursor.execute(
                f"SELECT setval('{sequence}', nextval('{sequence}') + 32, true)"
            )

        second = Order.objects.create()

        self.assertGreater(
            second.id - first.id, 32, "the id sequence really did skip a batch"
        )
        self.assertEqual(
            _tail(second.receipt_number),
            _tail(first.receipt_number) + 1,
            "the receipt series must not follow the primary key into the hole",
        )


class ReceiptSeriesSeedTests(TestCase):
    """An upgrade must not restart the shop's numbering.

    The migration seeds the counter from the highest number the series has
    already reached, so the first receipt issued after the upgrade is the next
    one. Starting again from ``R…000001`` would be a far worse surprise than a
    gap, and colliding with a number already in the ledger would refuse a sale.
    """

    seed = import_module("apps.sales.migrations.0033_seed_receipt_number_series")

    def test_a_receipt_number_yields_its_counter(self):
        self.assertEqual(self.seed._trailing_number("R20260916798785"), 798785)

    def test_the_upgrade_continues_the_shop_s_existing_series(self):
        """What actually runs on a real database, on the real models."""
        from django.apps import apps as registry

        from apps.documents.numbering import DocumentNumberSeries

        Order.objects.create(receipt_number="R20260916798785")
        Order.objects.create(receipt_number="R20260916798786")
        DocumentNumberSeries.objects.filter(pk=SALE_ORDER_SERIES).delete()

        self.seed.seed(registry, None)

        self.assertEqual(
            DocumentNumberSeries.objects.get(pk=SALE_ORDER_SERIES).last_value,
            798786,
        )
        self.assertEqual(
            _tail(Order.objects.create().receipt_number),
            798787,
            "the next receipt is the next one, not R...000001",
        )

    def test_the_upgrade_never_lowers_a_counter_it_finds(self):
        # Re-running a migration, or running it after the series has already
        # moved on, must not hand out a number twice — `receipt_number` is
        # unique, so a collision refuses a sale.
        from django.apps import apps as registry

        from apps.documents.numbering import DocumentNumberSeries

        DocumentNumberSeries.objects.update_or_create(
            pk=SALE_ORDER_SERIES, defaults={"last_value": 900000}
        )
        Order.objects.create(receipt_number="R20260916798785")

        self.seed.seed(registry, None)

        self.assertEqual(
            DocumentNumberSeries.objects.get(pk=SALE_ORDER_SERIES).last_value,
            900000,
        )

    def test_a_number_from_somewhere_else_counts_for_nothing(self):
        # An import or a hand correction can carry anything at all; it must not
        # crash the upgrade, and it must not pretend to be a counter.
        for odd in ("", "INV-7", "R2026091", "R20260916ABC", "798785"):
            with self.subTest(odd):
                self.assertEqual(self.seed._trailing_number(odd), 0)
