"""The vocabulary. Three lifecycle states and nothing else.

Deliberately not four. "Amended" is not a state a document is in — it is
``CANCELLED`` plus a successor, so it stays derivable and no report, filter or
serializer has to learn a fourth value. The same reasoning keeps *paid*,
*received* and *approved* out: those are progress and approval, which are
separate axes with separate fields (see ``DOCUMENT_LIFECYCLE_PLAN.md`` §4.1).
"""

from django.db import models


class DocumentStatus(models.TextChoices):
    DRAFT = "draft", "Draft"
    SUBMITTED = "submitted", "Submitted"
    CANCELLED = "cancelled", "Cancelled"


class Correction(models.TextChoices):
    """How a submitted document of this type may be put right.

    ERPNext offers only ``AMEND`` as a named route, so its users reach for
    cancel-and-amend even when the change carries no financial consequence and
    even when the honest answer is a counter-document. Naming all three, and
    making every document type declare which of them apply, is most of the fix.
    """

    #: Edit a named allow-list of fields in place. No reversal, no successor.
    ALLOW_AFTER_SUBMIT = "allow_after_submit", "Editable fields after submit"
    #: Retract and replace: the document is cancelled and a successor carries
    #: the corrections, keeping the same number.
    AMEND = "amend", "Cancel and amend"
    #: A separate, opposing document (return, refund, credit note). The original
    #: stays submitted because it did happen.
    COUNTER = "counter", "Reversed by a counter-document"
    #: Rewrite the submitted document itself, while a type-declared condition
    #: still holds — for a purchase order, until money has settled against it.
    #: ERPNext has no such route and its users cancel whole invoices to fix a
    #: cost; we keep the affordance and make it audited rather than silent.
    #: The cost is real and stated in DOCUMENT_LIFECYCLE_PLAN.md §3 T1: the
    #: original figures are not preserved as their own version. Converting this
    #: route to a true amendment is a later step, and is one clause away.
    IN_PLACE = "in_place", "Corrected in place while unsettled"


class Transition(models.TextChoices):
    SUBMIT = "submit", "Submit"
    CANCEL = "cancel", "Cancel"
    #: Retracting a *draft*. A different act from cancelling a submitted
    #: document — nothing has been posted, so nothing is being reversed — and
    #: often a different person's job: the member of staff who abandons their
    #: half-finished stock count is not the manager who un-applies one. Types
    #: that do not declare it fall back to ``CANCEL``.
    DISCARD = "discard", "Discard a draft"
    AMEND = "amend", "Amend"
    EDIT = "edit", "Edit after submit"
    CORRECT = "correct", "Correct in place"


#: Fields the primitive owns on every document. Never frozen (the lifecycle has
#: to be able to move) and never part of a frozen-field diff.
LIFECYCLE_FIELDS = frozenset(
    {
        "doc_status",
        "submitted_at",
        "submitted_by",
        "submitted_by_id",
        "cancelled_at",
        "cancelled_by",
        "cancelled_by_id",
        "cancel_reason",
        "amended_from",
        "amended_from_id",
        "superseded_by",
        "superseded_by_id",
        "amendment_index",
    }
)

#: Bookkeeping columns that are not part of what a document *says*.
#:
#: ``created_at`` is here after being tried the other way. It *is* the money
#: date of most documents (``apps.core.money_dates``), so moving it moves which
#: month a sale belongs to — but ``auto_now_add`` means no ordinary save can
#: touch it, and the only writers are deliberate ``.update(created_at=...)``
#: calls building history: the importer, the demo seeder, and the fixtures of
#: perhaps forty tests. Freezing it bought protection against a door nobody
#: walks through, at the price of making "give this shop a past" a guarded act.
HOUSEKEEPING_FIELDS = frozenset({"id", "created_at", "updated_at"})
