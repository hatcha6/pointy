"""The stock-transfer series must not skip.

The same defect the receipt series had, and for the same reason: the number was
the row's own primary key in a costume, ``T{date}{transfer.id}``. A primary key
is allowed to have gaps — a rolled-back insert keeps the value it took, and
PostgreSQL crash recovery resumes a sequence from the 32 values it had reserved
in WAL rather than the ones it handed out.

Internal, but an audit document all the same. A transfer number is how a count
discrepancy is traced back to the movement that caused it, and a series with
holes in it makes "no transfer was recorded" and "that number was never issued"
the same observation.
"""

import unittest
from importlib import import_module

from django.db import connection, transaction
from django.test import TestCase

from apps.documents.numbering import STOCK_TRANSFER_SERIES
from apps.inventory.models import StockTransfer, Warehouse


def _tail(transfer_number: str) -> int:
    """The counter part of ``T20260916000123``."""
    return int(transfer_number[9:])


class StockTransferNumberSeriesTests(TestCase):
    def setUp(self):
        self.source = Warehouse.objects.get(pk=Warehouse.default_id())
        self.destination = Warehouse.objects.create(
            name="المخزن", code="store", kind=Warehouse.Kind.STORE_ROOM
        )

    def _transfer(self, **kwargs):
        return StockTransfer.objects.create(
            source=self.source, destination=self.destination, **kwargs
        )

    def test_consecutive_transfers_are_numbered_consecutively(self):
        first = self._transfer()
        second = self._transfer()

        self.assertEqual(
            _tail(second.transfer_number), _tail(first.transfer_number) + 1
        )

    def test_the_number_is_stamped_on_the_insert_itself(self):
        """One write per transfer, not two — and no lifting of the freeze."""
        transfer = self._transfer()

        self.assertTrue(transfer.transfer_number)
        self.assertEqual(
            StockTransfer.objects.get(pk=transfer.pk).transfer_number,
            transfer.transfer_number,
        )

    def test_a_transfer_that_fails_does_not_consume_a_number(self):
        first = self._transfer()

        with self.assertRaises(RuntimeError):
            with transaction.atomic():
                self._transfer()
                raise RuntimeError("the stock was not there to move")

        second = self._transfer()
        self.assertEqual(
            _tail(second.transfer_number), _tail(first.transfer_number) + 1
        )

    def test_a_caller_that_brings_its_own_number_keeps_it(self):
        transfer = self._transfer(transfer_number="T20200101000042")

        self.assertEqual(transfer.transfer_number, "T20200101000042")

    def test_the_series_survives_a_hole_in_the_primary_key(self):
        first = self._transfer()
        second = self._transfer(id=first.id + 500)
        third = self._transfer()

        self.assertEqual(
            _tail(second.transfer_number), _tail(first.transfer_number) + 1
        )
        self.assertEqual(
            _tail(third.transfer_number), _tail(second.transfer_number) + 1
        )
        self.assertNotIn(str(second.id), second.transfer_number)


@unittest.skipUnless(
    connection.vendor == "postgresql",
    "The sequence reservation this reproduces is a PostgreSQL mechanism.",
)
class StockTransferNumberSurvivesSequenceBurnTests(TestCase):
    def test_a_burned_id_sequence_does_not_move_the_transfer_series(self):
        source = Warehouse.objects.get(pk=Warehouse.default_id())
        destination = Warehouse.objects.create(
            name="المخزن", code="store", kind=Warehouse.Kind.STORE_ROOM
        )
        first = StockTransfer.objects.create(
            source=source, destination=destination
        )

        sequence = connection.ops.quote_name("inventory_stocktransfer_id_seq")
        with connection.cursor() as cursor:
            cursor.execute(
                f"SELECT setval('{sequence}', nextval('{sequence}') + 32, true)"
            )

        second = StockTransfer.objects.create(
            source=source, destination=destination
        )

        self.assertGreater(
            second.id - first.id, 32, "the id sequence really did skip a batch"
        )
        self.assertEqual(
            _tail(second.transfer_number),
            _tail(first.transfer_number) + 1,
            "the transfer series must not follow the primary key into the hole",
        )


class StockTransferNumberSeedTests(TestCase):
    """An upgrade must not restart the numbering a stock count is traced with."""

    seed = import_module(
        "apps.inventory.migrations.0024_seed_transfer_number_series"
    )

    def test_a_transfer_number_yields_its_counter(self):
        self.assertEqual(self.seed._trailing_number("T20260916000123"), 123)

    def test_a_number_from_somewhere_else_counts_for_nothing(self):
        for odd in ("", "TR-7", "T2026091", "T20260916ABC", "P20260916000123"):
            with self.subTest(odd):
                self.assertEqual(self.seed._trailing_number(odd), 0)

    def test_the_upgrade_continues_the_existing_series(self):
        from django.apps import apps as registry

        from apps.documents.numbering import DocumentNumberSeries

        source = Warehouse.objects.get(pk=Warehouse.default_id())
        destination = Warehouse.objects.create(
            name="المخزن", code="store", kind=Warehouse.Kind.STORE_ROOM
        )
        StockTransfer.objects.create(
            source=source, destination=destination, transfer_number="T20260916000418"
        )
        DocumentNumberSeries.objects.filter(pk=STOCK_TRANSFER_SERIES).delete()

        self.seed.seed(registry, None)

        self.assertEqual(
            DocumentNumberSeries.objects.get(pk=STOCK_TRANSFER_SERIES).last_value,
            418,
        )
        self.assertEqual(
            _tail(
                StockTransfer.objects.create(
                    source=source, destination=destination
                ).transfer_number
            ),
            419,
        )

    def test_the_upgrade_never_lowers_a_counter_it_finds(self):
        from django.apps import apps as registry

        from apps.documents.numbering import DocumentNumberSeries

        DocumentNumberSeries.objects.update_or_create(
            pk=STOCK_TRANSFER_SERIES, defaults={"last_value": 900000}
        )
        source = Warehouse.objects.get(pk=Warehouse.default_id())
        StockTransfer.objects.create(
            source=source,
            destination=Warehouse.objects.create(
                name="المخزن", code="store", kind=Warehouse.Kind.STORE_ROOM
            ),
            transfer_number="T20260916000418",
        )

        self.seed.seed(registry, None)

        self.assertEqual(
            DocumentNumberSeries.objects.get(pk=STOCK_TRANSFER_SERIES).last_value,
            900000,
        )
