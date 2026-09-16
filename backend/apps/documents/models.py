"""The lifecycle fields every document carries, and the trail they leave.

The fields live on the domain row rather than in a central registry table. The
checkout path cannot afford a join to learn whether an order is a draft, the
stock ledger already addresses documents as ``(voucher_type, voucher_id)`` with
no registry table and that works, and a second copy of the lifecycle is a second
thing that can drift out of step with the first.

What genuinely needs its own table is the trail — and nothing else. (And, since
a customer-facing number must not inherit a primary key's licence to skip, the
counter in ``numbering`` — re-exported here so Django finds the model.)
"""

from django.conf import settings
from django.db import models

from apps.core.models import TimeStampedModel
from apps.documents import guards
from apps.documents.numbering import DocumentNumberSeries
from apps.documents.statuses import DocumentStatus

__all__ = ["DocumentMixin", "DocumentEvent", "DocumentNumberSeries"]


class DocumentMixin(models.Model):
    """Lifecycle for one document. Abstract; see ``DOCUMENT_LIFECYCLE_PLAN.md``.

    ``amended_from`` and ``superseded_by`` are deliberately both stored.
    ERPNext keeps only the backward pointer, so finding the live version of a
    document costs a walk forward, and naive reports show a cancelled invoice
    beside the amendment that replaced it. With the forward pointer indexed,
    "current version only" is ``superseded_by__isnull=True`` — an index scan —
    and "where did this go?" is one read. The redundancy is written in exactly
    one place, by the amend transition.
    """

    # ``db_default`` as well as ``default``, on every non-nullable column this
    # mixin adds. Django backfills existing rows with the Python default and
    # then drops the database default, so a column added this way is NOT NULL
    # with nothing to fall back on — and during the minute of a live update the
    # *old* backend is still writing, with an INSERT that names no such column.
    # Without this the till stops taking sales mid-upgrade, which is the one
    # thing the zero-downtime design exists to prevent
    # (deploy/onprem/README.md: migrations must be backward compatible across
    # one version).
    doc_status = models.CharField(
        max_length=16,
        choices=DocumentStatus.choices,
        default=DocumentStatus.DRAFT,
        db_default=DocumentStatus.DRAFT,
        db_index=True,
    )
    submitted_at = models.DateTimeField(blank=True, null=True)
    submitted_by = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.SET_NULL,
        related_name="%(app_label)s_%(class)s_submitted",
        blank=True,
        null=True,
    )
    cancelled_at = models.DateTimeField(blank=True, null=True)
    cancelled_by = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.SET_NULL,
        related_name="%(app_label)s_%(class)s_cancelled",
        blank=True,
        null=True,
    )
    cancel_reason = models.TextField(blank=True, db_default="")
    amended_from = models.ForeignKey(
        "self",
        on_delete=models.SET_NULL,
        related_name="%(app_label)s_%(class)s_amendments",
        blank=True,
        null=True,
    )
    # The successor, indexed: reports filter "current version only" on it.
    superseded_by = models.ForeignKey(
        "self",
        on_delete=models.SET_NULL,
        related_name="%(app_label)s_%(class)s_supersedes",
        blank=True,
        null=True,
        db_index=True,
    )
    # 0 for an original. The document *number* never changes across an
    # amendment (a customer holds a receipt with it printed on); this is what
    # distinguishes the versions, and what uniqueness is composed with.
    amendment_index = models.PositiveSmallIntegerField(default=0, db_default=0)

    class Meta:
        abstract = True

    @property
    def is_draft(self) -> bool:
        return self.doc_status == DocumentStatus.DRAFT

    @property
    def is_submitted(self) -> bool:
        return self.doc_status == DocumentStatus.SUBMITTED

    @property
    def is_cancelled(self) -> bool:
        return self.doc_status == DocumentStatus.CANCELLED

    @property
    def is_current(self) -> bool:
        """Whether this is the live version of its document identity."""
        return self.superseded_by_id is None

    def _stamp_born_submitted(self):
        """A document with no draft state is issued the moment it exists.

        Money either moved or it did not; a payment half-written is not a
        thing. Rather than have every caller remember to say so — and one of
        them eventually forget — the type declares ``has_draft_state=False``
        and the row is stamped here, on insert only.
        """
        from apps.documents import registry

        if not self._state.adding or self.doc_status != DocumentStatus.DRAFT:
            return
        doc_type = registry.for_instance(self)
        if doc_type is not None and not doc_type.has_draft_state:
            self.doc_status = DocumentStatus.SUBMITTED

    def save(self, *args, **kwargs):
        self._stamp_born_submitted()
        guards.assert_not_frozen(self, kwargs.get("update_fields"))
        return super().save(*args, **kwargs)


class DocumentEvent(TimeStampedModel):
    """Append-only record of everything that happened to a document.

    Separate from the analytics domain events that ``record_domain_event``
    writes: those are the fleet's telemetry, sampled and aggregated; this is the
    shop's own record, shown in the app and never dropped. It outlives its
    document — ``document_number`` is denormalised — because an audit trail that
    disappears with the row it audits is not one.
    """

    class Action(models.TextChoices):
        CREATED = "created", "Created"
        SUBMITTED = "submitted", "Submitted"
        EDITED = "edited", "Edited after submit"
        CORRECTED = "corrected", "Corrected in place"
        CANCELLED = "cancelled", "Cancelled"
        AMENDED = "amended", "Amended"
        SUPERSEDED = "superseded", "Superseded"

    document_type = models.CharField(max_length=32, db_index=True)
    object_id = models.PositiveBigIntegerField(db_index=True)
    document_number = models.CharField(max_length=64, blank=True)
    action = models.CharField(max_length=16, choices=Action.choices)
    reason = models.TextField(blank=True)
    details = models.JSONField(default=dict, blank=True)
    actor = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.SET_NULL,
        related_name="document_events",
        blank=True,
        null=True,
    )

    class Meta:
        ordering = ["-created_at", "-id"]
        indexes = [
            models.Index(
                fields=["document_type", "object_id", "-created_at"],
                name="document_event_doc_idx",
            ),
        ]

    def __str__(self) -> str:
        return f"{self.action} {self.document_type} {self.document_number}".strip()
