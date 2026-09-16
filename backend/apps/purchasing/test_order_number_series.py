"""The purchase-order series must not skip.

The same defect the receipt series had, and for the same reason: the number was
the row's own primary key in a costume, ``P{date}{order.id}``. A primary key is
allowed to have gaps — a rolled-back insert keeps the value it took, and
PostgreSQL crash recovery resumes a sequence from the 32 values it had reserved
in WAL rather than the ones it handed out. That skipped 155 receipt numbers in
one field week.

These numbers go to suppliers, who reconcile deliveries and invoices against
them. A supplier looking at a jump from P…000418 to P…000450 has the same
question the shop had about its own invoices, and nobody could answer it.
"""

import unittest
from importlib import import_module

from django.db import connection, transaction
from django.test import TestCase

from apps.documents.numbering import PURCHASE_ORDER_SERIES
from apps.purchasing.models import PurchaseOrder, Supplier


def _tail(order_number: str) -> int:
    """The counter part of ``P20260916000123``."""
    return int(order_number[9:])


class PurchaseOrderNumberSeriesTests(TestCase):
    @classmethod
    def setUpTestData(cls):
        cls.supplier = Supplier.objects.create(name="مورد")

    def _order(self, **kwargs):
        return PurchaseOrder.objects.create(supplier=self.supplier, **kwargs)

    def test_consecutive_orders_are_numbered_consecutively(self):
        first = self._order()
        second = self._order()

        self.assertEqual(_tail(second.order_number), _tail(first.order_number) + 1)

    def test_the_number_is_stamped_on_the_insert_itself(self):
        """One write per order, not two.

        The number used to be read off the saved row, so every order cost an
        INSERT and then an UPDATE — and the UPDATE had to be smuggled past the
        document freeze, because an order created already submitted (the POS
        cash purchase, the importer) looked like an edit to a submitted
        document.
        """
        order = self._order()

        self.assertTrue(order.order_number)
        self.assertEqual(
            PurchaseOrder.objects.get(pk=order.pk).order_number, order.order_number
        )

    def test_an_order_that_fails_does_not_consume_a_number(self):
        first = self._order()

        with self.assertRaises(RuntimeError):
            with transaction.atomic():
                self._order()
                raise RuntimeError("the supplier withdrew the quote")

        second = self._order()
        self.assertEqual(_tail(second.order_number), _tail(first.order_number) + 1)

    def test_a_caller_that_brings_its_own_number_keeps_it(self):
        """Imports replay historical documents under their own numbers."""
        order = self._order(order_number="P20200101000042")

        self.assertEqual(order.order_number, "P20200101000042")

    def test_the_series_survives_a_hole_in_the_primary_key(self):
        first = self._order()
        second = self._order(id=first.id + 500)
        third = self._order()

        self.assertEqual(_tail(second.order_number), _tail(first.order_number) + 1)
        self.assertEqual(_tail(third.order_number), _tail(second.order_number) + 1)
        self.assertNotIn(str(second.id), second.order_number)


@unittest.skipUnless(
    connection.vendor == "postgresql",
    "The sequence reservation this reproduces is a PostgreSQL mechanism.",
)
class PurchaseOrderNumberSurvivesSequenceBurnTests(TestCase):
    def test_a_burned_id_sequence_does_not_move_the_order_series(self):
        """What a power cut does, minus the power cut.

        Crash recovery leaves the id sequence at the reservation's high-water
        mark, so the next order's id is up to 32 higher than the last one's.
        Before this change the order number went with it.
        """
        supplier = Supplier.objects.create(name="مورد")
        first = PurchaseOrder.objects.create(supplier=supplier)

        sequence = connection.ops.quote_name("purchasing_purchaseorder_id_seq")
        with connection.cursor() as cursor:
            cursor.execute(
                f"SELECT setval('{sequence}', nextval('{sequence}') + 32, true)"
            )

        second = PurchaseOrder.objects.create(supplier=supplier)

        self.assertGreater(
            second.id - first.id, 32, "the id sequence really did skip a batch"
        )
        self.assertEqual(
            _tail(second.order_number),
            _tail(first.order_number) + 1,
            "the order series must not follow the primary key into the hole",
        )


class PurchaseOrderNumberSeedTests(TestCase):
    """An upgrade must not restart the shop's numbering.

    The migration seeds the counter from the highest number the series has
    already reached, so the first order raised afterwards is the next one.
    Colliding with a number a supplier already holds would refuse a purchase —
    `order_number` is unique.
    """

    seed = import_module("apps.purchasing.migrations.0034_seed_order_number_series")

    def test_an_order_number_yields_its_counter(self):
        self.assertEqual(self.seed._trailing_number("P20260916000123"), 123)

    def test_a_number_from_somewhere_else_counts_for_nothing(self):
        for odd in ("", "PO-7", "P2026091", "P20260916ABC", "R20260916000123"):
            with self.subTest(odd):
                self.assertEqual(self.seed._trailing_number(odd), 0)

    def test_the_upgrade_continues_the_shop_s_existing_series(self):
        from django.apps import apps as registry

        from apps.documents.numbering import DocumentNumberSeries

        supplier = Supplier.objects.create(name="مورد")
        PurchaseOrder.objects.create(supplier=supplier, order_number="P20260916000418")
        PurchaseOrder.objects.create(supplier=supplier, order_number="P20260916000419")
        DocumentNumberSeries.objects.filter(pk=PURCHASE_ORDER_SERIES).delete()

        self.seed.seed(registry, None)

        self.assertEqual(
            DocumentNumberSeries.objects.get(pk=PURCHASE_ORDER_SERIES).last_value,
            419,
        )
        self.assertEqual(
            _tail(PurchaseOrder.objects.create(supplier=supplier).order_number),
            420,
            "the next order is the next one, not P...000001",
        )

    def test_the_upgrade_never_lowers_a_counter_it_finds(self):
        from django.apps import apps as registry

        from apps.documents.numbering import DocumentNumberSeries

        DocumentNumberSeries.objects.update_or_create(
            pk=PURCHASE_ORDER_SERIES, defaults={"last_value": 900000}
        )
        PurchaseOrder.objects.create(
            supplier=Supplier.objects.create(name="مورد"),
            order_number="P20260916000418",
        )

        self.seed.seed(registry, None)

        self.assertEqual(
            DocumentNumberSeries.objects.get(pk=PURCHASE_ORDER_SERIES).last_value,
            900000,
        )
