"""The durable record of one photographed supplier invoice on its way to a
purchase order.

The pipeline that fills it lives beside this module: ``schemas`` normalises what
the vision model returned, ``checks`` proves the arithmetic on the paper adds
up, ``reconcile`` resolves each printed line to a product this shop already
sells, ``plan`` turns that into an editable creation plan, and ``services``
applies the plan in one transaction.

Everything the pipeline produces is stored as JSON on the intake rather than in
side tables: it is a *proposal* until the user applies it, the shape is still
moving, and nothing else in the system reads it. What is relational is what
outlives the proposal — the pages (so the photographed invoice travels with the
purchase order, which matters where the paper document is the authoritative
record), the supplier, and the purchase order that was finally created.
"""

from django.conf import settings
from django.db import models

from apps.core.models import TimeStampedModel

# Line statuses the reconciler assigns; also the vocabulary the review card
# groups by. Kept here (not in reconcile.py) because both the plan JSON and the
# counting properties below speak it.
LINE_MATCHED = "matched"
LINE_AUTO = "auto"
LINE_NEW = "new"
LINE_REVIEW = "review"
LINE_STATUSES = (LINE_MATCHED, LINE_AUTO, LINE_NEW, LINE_REVIEW)


class InvoiceIntake(TimeStampedModel):
    """One invoice being read, reconciled and turned into a purchase order."""

    class Source(models.TextChoices):
        CHAT = "chat", "Chat"
        PURCHASING = "purchasing", "Purchasing screen"

    class Status(models.TextChoices):
        CAPTURING = "capturing", "Capturing"
        EXTRACTING = "extracting", "Extracting"
        RECONCILING = "reconciling", "Reconciling"
        PLANNED = "planned", "Planned"
        APPLIED = "applied", "Applied"
        FAILED = "failed", "Failed"
        CANCELLED = "cancelled", "Cancelled"

    created_by = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.SET_NULL,
        related_name="invoice_intakes",
        blank=True,
        null=True,
    )
    source = models.CharField(
        max_length=16,
        choices=Source.choices,
        default=Source.CHAT,
    )
    status = models.CharField(
        max_length=16,
        choices=Status.choices,
        default=Status.CAPTURING,
        db_index=True,
    )
    # The photographed pages, stored through apps.attachments. On apply they are
    # re-pointed at the created purchase order (see services.apply_intake), so
    # the image outlives the intake even after the intake is purged.
    pages = models.ManyToManyField(
        "attachments.Attachment",
        blank=True,
        related_name="invoice_intakes",
    )
    # What the vision model read, normalised by schemas.normalise_extraction.
    extraction = models.JSONField(default=dict, blank=True)
    # The IntakePlan built by plan.build_plan — what would be created.
    plan = models.JSONField(default=dict, blank=True)
    # What the user changed on the review card before applying.
    review_edits = models.JSONField(default=dict, blank=True)
    # Per-status line counts + the arithmetic verdict, so a list row can be
    # rendered without re-reading the (large) plan.
    confidence_summary = models.JSONField(default=dict, blank=True)
    supplier = models.ForeignKey(
        "purchasing.Supplier",
        on_delete=models.SET_NULL,
        related_name="invoice_intakes",
        blank=True,
        null=True,
    )
    purchase_order = models.ForeignKey(
        "purchasing.PurchaseOrder",
        on_delete=models.SET_NULL,
        related_name="invoice_intakes",
        blank=True,
        null=True,
    )
    error = models.TextField(blank=True)

    class Meta:
        ordering = ["-created_at", "-id"]

    def __str__(self) -> str:
        return f"Invoice intake {self.pk} ({self.status})"

    # ── Counts ───────────────────────────────────────────────────────────────
    #
    # Read off the stored plan (falling back to the reconciliation carried in
    # the plan), so a caller never has to know the JSON's shape.

    @property
    def plan_lines(self):
        plan = self.plan if isinstance(self.plan, dict) else {}
        lines = plan.get("lines")
        return lines if isinstance(lines, list) else []

    def _count(self, status):
        return sum(1 for line in self.plan_lines if line.get("status") == status)

    @property
    def line_count(self):
        return len(self.plan_lines)

    @property
    def matched_line_count(self):
        """Lines resolved deterministically (barcode, alias, exact name)."""
        return self._count(LINE_MATCHED)

    @property
    def auto_line_count(self):
        """Lines resolved by a weaker-but-accepted prior (supplier history)."""
        return self._count(LINE_AUTO)

    @property
    def new_line_count(self):
        return self._count(LINE_NEW)

    @property
    def review_line_count(self):
        return self._count(LINE_REVIEW)

    @property
    def needs_review(self):
        """True while a line still needs a human decision. The review card's
        footer disables ``Create`` on exactly this."""
        return self.review_line_count > 0

    @property
    def is_applied(self):
        return self.status == self.Status.APPLIED and self.purchase_order_id is not None

    def counts(self):
        return {
            "total": self.line_count,
            "matched": self.matched_line_count,
            "auto": self.auto_line_count,
            "new": self.new_line_count,
            "review": self.review_line_count,
        }
