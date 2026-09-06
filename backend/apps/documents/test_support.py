"""The fixture the primitive's own tests share.

The documents themselves live in ``apps.documents.testkit`` — a real, test-only
app, for the reasons its module docstring gives. What is here is the wiring: a
recorder that captures what the primitive asked the domain to do, and a test
case that registers the fake types and takes them out of the registry again.
"""

from django.test import TestCase

from apps.documents import registry
from apps.documents.statuses import Correction, Transition
from apps.documents.testkit.models import (  # noqa: F401  (re-exported for tests)
    FakeDelivery,
    FakeInvoice,
    FakeSettlement,
)


class Recorder:
    """Captures what the primitive asked the domain to do."""

    def __init__(self):
        self.reversals = []
        self.releases = []
        self.progress_calls = []

    def reverse(self, document, *, at, actor, reason, context=None):
        self.reversals.append(
            {
                "id": document.pk,
                "at": at,
                "actor": actor,
                "reason": reason,
                "context": context or {},
            }
        )

    def release_draft(self, document, *, actor, reason):
        self.releases.append({"id": document.pk, "actor": actor, "reason": reason})

    def progress(self, document):
        self.progress_calls.append(document.pk)
        document.progress = "cancelled" if document.is_cancelled else "posted"
        document.save(update_fields=["progress"])

    def in_place_allowed(self, document):
        return not document.settlements.exists()

    def amend_copy(self, document, *, actor):
        return FakeInvoice(
            number=document.number,
            customer_name=document.customer_name,
            amount=document.amount,
            notes=document.notes,
            created_by=actor,
        )


class DocumentPrimitiveTestCase(TestCase):
    """Registers the fake types for one test class and unregisters them after.

    The registry is deliberately closed and global, so a test that registers
    into it has to put it back exactly as it found it.
    """

    correction_window = None
    corrections = (Correction.ALLOW_AFTER_SUBMIT, Correction.AMEND)

    def setUp(self):
        super().setUp()
        self.recorder = Recorder()
        self.invoice_type = registry.register(
            key="fake_invoice",
            label="فاتورة تجريبية",
            model=FakeInvoice,
            number_field="number",
            money_date_field="settled_at",
            has_draft_state=True,
            draft_effects=("reservation",),
            submit_effects=("receivable",),
            corrections=self.corrections,
            mutable_after_submit=("notes",),
            derived_fields=("progress",),
            blocks_cancel=(("settlements", "دفعات"),),
            cascades=("deliveries",),
            progress=self.recorder.progress,
            permissions={
                Transition.SUBMIT: "documents.add_documentevent",
                Transition.CANCEL: "documents.delete_documentevent",
                Transition.AMEND: "documents.change_documentevent",
                Transition.EDIT: "documents.change_documentevent",
                Transition.CORRECT: "documents.change_documentevent",
            },
            correction_window=self.correction_window,
            reverse=self.recorder.reverse,
            amend_copy=self.recorder.amend_copy,
            in_place_allowed=self.recorder.in_place_allowed,
            release_draft=self.recorder.release_draft,
        )
        self.delivery_type = registry.register(
            key="fake_delivery",
            label="تسليم تجريبي",
            model=FakeDelivery,
            number_field=None,
            money_date_field=None,
            has_draft_state=True,
            draft_effects=(),
            submit_effects=("stock",),
            corrections=(Correction.COUNTER,),
            mutable_after_submit=(),
            derived_fields=(),
            blocks_cancel=(),
            cascades=(),
            progress=None,
            permissions={
                Transition.SUBMIT: "documents.add_documentevent",
                Transition.CANCEL: "documents.delete_documentevent",
            },
            correction_window=None,
            reverse=self.recorder.reverse,
            amend_copy=None,
            in_place_allowed=None,
            release_draft=None,
        )
        self.addCleanup(registry._unregister, "fake_invoice")
        self.addCleanup(registry._unregister, "fake_delivery")


__all__ = [
    "DocumentPrimitiveTestCase",
    "FakeDelivery",
    "FakeInvoice",
    "FakeSettlement",
    "Recorder",
]
