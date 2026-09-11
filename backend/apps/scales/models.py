"""The shop's weighing scales, and what was pushed to them.

A scale is the only device in the shop that holds its own copy of the prices.
That copy is what the customer sees on the sticker, so when it disagrees with
the till the shop has two prices and no way to know which one it sold at. The
point of this app is that the disagreement becomes visible and fixable: one
button, and a record of whether it worked.
"""

from __future__ import annotations

from django.conf import settings
from django.db import models

from apps.core.models import TimeStampedModel

from .drivers import DEFAULT_DRIVER_KEY, DRIVER_CHOICES


class ScaleQuerySet(models.QuerySet):
    def active(self):
        return self.filter(is_active=True)


class Scale(TimeStampedModel):
    """One label-printing scale on the shop's counter."""

    name = models.CharField(max_length=120)
    driver = models.CharField(
        max_length=32,
        choices=DRIVER_CHOICES,
        default=DEFAULT_DRIVER_KEY,
    )
    # Blank for file-export scales, which have no address to speak to.
    host = models.CharField(max_length=120, blank=True)
    port = models.PositiveIntegerField(default=0)
    # The scale's own department number. Most shops run one; the field exists
    # because the protocols insist on it and a wrong one writes the PLU into a
    # table the scale is not printing from.
    department = models.PositiveSmallIntegerField(default=1)
    # Per-driver settings: column order and encoding for a file, byte order for
    # a CAS, credentials for an FTP. Deliberately loose — every vendor's
    # quirks land here rather than in a column nobody else uses.
    options = models.JSONField(default=dict, blank=True)
    # Which rule the labels this scale prints follow, so the shop can see at a
    # glance that the scale it pushes PLUs to is the one whose stickers the till
    # knows how to read.
    barcode_rule = models.ForeignKey(
        "catalog.ScaleBarcodeRule",
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name="scales",
    )
    is_active = models.BooleanField(default=True)
    last_push_at = models.DateTimeField(null=True, blank=True)
    notes = models.TextField(blank=True)

    objects = ScaleQuerySet.as_manager()

    class Meta:
        ordering = ["name", "id"]
        permissions = [
            # Sending prices to a scale changes what the shop's stickers say,
            # so it is its own right rather than a side effect of being able to
            # edit the scale's address.
            ("push_scale", "Can send prices to a scale"),
        ]

    def __str__(self) -> str:
        return self.name


class ScalePushJob(TimeStampedModel):
    """One attempt to make a scale agree with the catalog.

    Kept even when it worked. "Did the new price reach the scale?" is a question
    a shop asks after an argument at the counter, which is exactly when nobody
    remembers whether they pressed the button.
    """

    class Status(models.TextChoices):
        PENDING = "pending", "Pending"
        SUCCEEDED = "succeeded", "Succeeded"
        PARTIAL = "partial", "Partially sent"
        FAILED = "failed", "Failed"
        #: The file was produced and is waiting for somebody to carry it to the
        #: scale. Not a success: the scale still holds the old prices.
        EXPORTED = "exported", "Exported to a file"

    scale = models.ForeignKey(Scale, on_delete=models.CASCADE, related_name="pushes")
    status = models.CharField(
        max_length=16,
        choices=Status.choices,
        default=Status.PENDING,
        db_index=True,
    )
    requested_by = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name="scale_pushes",
    )
    plu_count = models.PositiveIntegerField(default=0)
    sent_count = models.PositiveIntegerField(default=0)
    failed_count = models.PositiveIntegerField(default=0)
    # ``{plu_number: message}`` for whatever the scale refused, so a shop can be
    # told which three items did not land rather than "some errors".
    errors = models.JSONField(default=dict, blank=True)
    message = models.TextField(blank=True)
    filename = models.CharField(max_length=120, blank=True)
    finished_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        ordering = ["-created_at", "-id"]
        indexes = [models.Index(fields=["scale", "-created_at"])]

    def __str__(self) -> str:
        return f"{self.scale_id}: {self.status} ({self.sent_count}/{self.plu_count})"
