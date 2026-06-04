from django.conf import settings
from django.db import models
from django.utils import timezone

from apps.core.models import TimeStampedModel


class BusinessNotification(TimeStampedModel):
    class Category(models.TextChoices):
        INVENTORY = "inventory", "Inventory"
        PURCHASING = "purchasing", "Purchasing"
        PRINTING = "printing", "Printing"
        SALES = "sales", "Sales"
        FRAUD = "fraud", "Fraud"
        DISCOUNTS = "discounts", "Discounts"
        OPERATIONS = "operations", "Operations"

    class Severity(models.TextChoices):
        INFO = "info", "Info"
        WARNING = "warning", "Warning"
        CRITICAL = "critical", "Critical"

    class Status(models.TextChoices):
        ACTIVE = "active", "Active"
        RESOLVED = "resolved", "Resolved"

    code = models.CharField(max_length=80, db_index=True)
    category = models.CharField(max_length=32, choices=Category.choices, db_index=True)
    severity = models.CharField(max_length=16, choices=Severity.choices, db_index=True)
    status = models.CharField(
        max_length=16,
        choices=Status.choices,
        default=Status.ACTIVE,
        db_index=True,
    )
    fingerprint = models.CharField(max_length=180, unique=True)
    entity_type = models.CharField(max_length=80, blank=True, db_index=True)
    entity_id = models.CharField(max_length=96, blank=True, db_index=True)
    payload = models.JSONField(default=dict, blank=True)
    first_seen_at = models.DateTimeField(default=timezone.now)
    last_seen_at = models.DateTimeField(default=timezone.now, db_index=True)
    occurrence_count = models.PositiveIntegerField(default=1)
    resolved_at = models.DateTimeField(blank=True, null=True)

    class Meta:
        ordering = ["status", "-last_seen_at", "-id"]
        indexes = [
            models.Index(fields=["status", "severity", "last_seen_at"]),
            models.Index(fields=["category", "status"]),
            models.Index(fields=["code", "status"]),
        ]

    def __str__(self) -> str:
        return f"{self.code} ({self.status})"


class BusinessNotificationUserState(TimeStampedModel):
    notification = models.ForeignKey(
        BusinessNotification,
        on_delete=models.CASCADE,
        related_name="user_states",
    )
    user = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name="business_notification_states",
    )
    acknowledged_at = models.DateTimeField(blank=True, null=True)
    snoozed_until = models.DateTimeField(blank=True, null=True)

    class Meta:
        constraints = [
            models.UniqueConstraint(
                fields=["notification", "user"],
                name="unique_business_notification_user_state",
            )
        ]
        indexes = [
            models.Index(fields=["user", "acknowledged_at"]),
            models.Index(fields=["user", "snoozed_until"]),
        ]

    def __str__(self) -> str:
        return f"{self.user_id} state for {self.notification_id}"
