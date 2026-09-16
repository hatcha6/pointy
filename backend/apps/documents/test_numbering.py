"""A document number that does not skip.

The property under test is the one a database sequence deliberately does not
have: a number handed out by a transaction that does not commit must come back.
"""

from django.db import transaction
from django.test import TestCase

from apps.documents.numbering import DocumentNumberSeries, next_document_number


class DocumentNumberingTests(TestCase):
    def test_numbers_are_consecutive(self):
        self.assertEqual(
            [next_document_number("test") for _ in range(4)], [1, 2, 3, 4]
        )

    def test_a_series_nobody_declared_starts_at_one(self):
        self.assertEqual(next_document_number("brand-new"), 1)
        self.assertTrue(
            DocumentNumberSeries.objects.filter(pk="brand-new").exists()
        )

    def test_a_number_taken_by_a_failed_document_comes_back(self):
        """The whole reason this is a row and not a sequence.

        A sequence is non-transactional on purpose: a value it hands out is
        gone whether or not the insert that asked for it survives. A counter
        row rolls back with its transaction, so a checkout that fails half way
        leaves no hole in the shop's ledger.
        """
        next_document_number("till")  # 1, committed

        with self.assertRaises(RuntimeError):
            with transaction.atomic():
                self.assertEqual(next_document_number("till"), 2)
                raise RuntimeError("the sale fell over")

        self.assertEqual(next_document_number("till"), 2)

    def test_series_do_not_share_a_counter(self):
        self.assertEqual(next_document_number("a"), 1)
        self.assertEqual(next_document_number("b"), 1)
        self.assertEqual(next_document_number("a"), 2)
