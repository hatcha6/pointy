"""Documents that exist only so the lifecycle can be tested without one.

The primitive has to be provable on its own, before any real document adopts
it — otherwise the first adoption is both the feature and its own test harness,
and a bug in the lifecycle looks like a bug in purchasing. It also has routes
that no shipped document uses yet (``amend``, ``supersede``,
``edit_submitted``), and an untested transition is exactly the failure mode
this design exists to avoid.

This is a real app with real tables, installed only when ``settings.TESTING``.
Two earlier attempts are worth remembering:

* Creating the tables with the schema editor per test class and dropping them
  afterwards leaves the *models* registered for the rest of the run. Anything
  that sweeps every model then queries a table that is gone — the initial-setup
  check does, and so does Django's own delete collector whenever a user is
  deleted, because these models point at ``AUTH_USER_MODEL``.
* Creating them once and never dropping them fixes that and breaks
  ``TransactionTestCase``: its flush cannot ``TRUNCATE auth_user`` while an
  unmanaged table references it.

A managed app whose tables ``migrate`` creates and ``flush`` knows about has
neither problem, and ships nothing: production never installs it.
"""

from django.conf import settings
from django.db import models

from apps.core.models import TimeStampedModel
from apps.documents.guards import DocumentQuerySetMixin
from apps.documents.models import DocumentMixin


class FakeQuerySet(DocumentQuerySetMixin, models.QuerySet):
    pass


class FakeInvoice(DocumentMixin, TimeStampedModel):
    objects = FakeQuerySet.as_manager()

    number = models.CharField(max_length=32)
    customer_name = models.CharField(max_length=64, blank=True)
    amount = models.DecimalField(max_digits=10, decimal_places=2, default=0)
    notes = models.TextField(blank=True)
    settled_at = models.DateTimeField(blank=True, null=True)
    progress = models.CharField(max_length=16, default="pending")
    created_by = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.SET_NULL,
        related_name="fake_invoices",
        blank=True,
        null=True,
    )

    class Meta:
        constraints = [
            models.UniqueConstraint(
                fields=["number", "amendment_index"],
                name="fake_invoice_number_version_unique",
            )
        ]


class FakeDelivery(DocumentMixin, TimeStampedModel):
    """A child document, cancelled with its parent."""

    objects = FakeQuerySet.as_manager()

    invoice = models.ForeignKey(
        FakeInvoice, on_delete=models.CASCADE, related_name="deliveries"
    )
    quantity = models.PositiveIntegerField(default=1)


class FakeSettlement(models.Model):
    """Not a document — money that has landed against the invoice, and so the
    thing that blocks its cancellation."""

    invoice = models.ForeignKey(
        FakeInvoice, on_delete=models.CASCADE, related_name="settlements"
    )
    amount = models.DecimalField(max_digits=10, decimal_places=2, default=0)
