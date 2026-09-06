"""The freeze, at both places Django can write a row.

ERPNext's equivalent check lives in one method that ``db_set`` and raw SQL walk
straight past — and ERPNext's own code walks past it constantly. These tests
exist to make sure ours is not decorative: a submitted document must be
unwritable through ``save()`` *and* through ``QuerySet.update()``, and the one
escape hatch must be the only way past.
"""

from decimal import Decimal

from django.contrib.auth import get_user_model

from apps.documents import services
from apps.documents.errors import DocumentFrozen
from apps.documents.guards import system_write
from apps.documents.statuses import DocumentStatus
from apps.documents.test_support import DocumentPrimitiveTestCase, FakeInvoice


class FreezeTests(DocumentPrimitiveTestCase):
    def setUp(self):
        super().setUp()
        self.invoice = FakeInvoice.objects.create(
            number="INV-1", customer_name="سالم", amount=Decimal("100.00")
        )

    def _submit(self):
        return services.submit(self.invoice)

    def test_a_draft_is_a_draft_and_may_be_rewritten_freely(self):
        self.invoice.amount = Decimal("120.00")
        self.invoice.save()
        self.invoice.refresh_from_db()
        self.assertEqual(self.invoice.amount, Decimal("120.00"))

    def test_a_submitted_document_refuses_a_changed_amount(self):
        submitted = self._submit()
        submitted.amount = Decimal("120.00")
        with self.assertRaises(DocumentFrozen) as caught:
            submitted.save()
        self.assertIn("amount", caught.exception.fields)
        self.assertIn("INV-1", str(caught.exception.detail["detail"]))

    def test_a_submitted_document_still_accepts_its_declared_mutable_fields(self):
        submitted = self._submit()
        submitted.notes = "رقم فاتورة المورد ٤٤"
        submitted.save(update_fields=["notes"])
        submitted.refresh_from_db()
        self.assertEqual(submitted.notes, "رقم فاتورة المورد ٤٤")

    def test_a_cancelled_document_is_frozen_too(self):
        submitted = self._submit()
        cancelled = services.cancel(submitted, reason="خطأ")
        cancelled.amount = Decimal("1.00")
        with self.assertRaises(DocumentFrozen):
            cancelled.save()

    def test_a_queryset_update_cannot_walk_around_the_freeze(self):
        self._submit()
        with self.assertRaises(DocumentFrozen):
            FakeInvoice.objects.filter(number="INV-1").update(amount=Decimal("0.00"))
        self.assertEqual(
            FakeInvoice.objects.get(number="INV-1").amount, Decimal("100.00")
        )

    def test_a_queryset_update_over_drafts_only_is_untouched(self):
        FakeInvoice.objects.filter(number="INV-1").update(amount=Decimal("7.00"))
        self.assertEqual(
            FakeInvoice.objects.get(number="INV-1").amount, Decimal("7.00")
        )

    def test_a_queryset_update_of_a_derived_column_is_not_a_frozen_write(self):
        self._submit()
        FakeInvoice.objects.filter(number="INV-1").update(progress="anything")
        self.assertEqual(FakeInvoice.objects.get(number="INV-1").progress, "anything")

    def test_the_system_escape_lifts_the_freeze_for_a_machine_path(self):
        """``repost_valuation`` restamping a sold line's cost is not a person
        editing a document, and must not be blocked by a guard that exists to
        govern people."""
        submitted = self._submit()
        submitted.amount = Decimal("120.00")
        with system_write():
            submitted.save()
        submitted.refresh_from_db()
        self.assertEqual(submitted.amount, Decimal("120.00"))

        with system_write():
            FakeInvoice.objects.filter(pk=submitted.pk).update(amount=Decimal("5.00"))
        self.assertEqual(
            FakeInvoice.objects.get(pk=submitted.pk).amount, Decimal("5.00")
        )

    def test_a_save_that_names_no_frozen_field_never_reads_the_row_back(self):
        """The freeze must not put a SELECT on the checkout path's hot loop."""
        submitted = self._submit()
        submitted.progress = "posted"
        with self.assertNumQueries(1):
            submitted.save(update_fields=["progress"])

    def test_saving_an_unchanged_frozen_field_is_not_an_error(self):
        submitted = self._submit()
        submitted.save()
        submitted.refresh_from_db()
        self.assertEqual(submitted.doc_status, DocumentStatus.SUBMITTED)

    def test_the_freeze_understands_a_relation_named_either_way(self):
        """``update_fields`` accepts "created_by" and "created_by_id" alike, so
        a guard that only knew one of them would wave the other through."""
        user = get_user_model().objects.create_user("owner", password="x")
        self.invoice.created_by = user
        self.invoice.save(update_fields=["created_by"])
        submitted = self._submit()

        submitted.created_by = None
        with self.assertRaises(DocumentFrozen):
            submitted.save(update_fields=["created_by"])

        submitted.refresh_from_db()
        submitted.created_by_id = None
        with self.assertRaises(DocumentFrozen):
            submitted.save(update_fields=["created_by_id"])

        submitted.refresh_from_db()
        self.assertEqual(submitted.created_by_id, user.pk)
