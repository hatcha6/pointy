from django.conf import settings
from django.core.validators import MaxValueValidator, MinValueValidator
from django.db import models
from django.utils import timezone

from apps.core.models import TimeStampedModel


class FraudFinding(TimeStampedModel):
    class Status(models.TextChoices):
        ACTIVE = "active", "Active"
        RESOLVED = "resolved", "Resolved"
        REVIEWED = "reviewed", "Reviewed"
        DISMISSED = "dismissed", "Dismissed"

    class Severity(models.TextChoices):
        INFO = "info", "Info"
        WARNING = "warning", "Warning"
        CRITICAL = "critical", "Critical"

    fingerprint = models.CharField(max_length=180, unique=True)
    rule_code = models.CharField(max_length=96, db_index=True)
    status = models.CharField(
        max_length=16,
        choices=Status.choices,
        default=Status.ACTIVE,
        db_index=True,
    )
    severity = models.CharField(
        max_length=16,
        choices=Severity.choices,
        default=Severity.WARNING,
        db_index=True,
    )
    target_user = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.SET_NULL,
        related_name="fraud_findings",
        blank=True,
        null=True,
    )
    target_user_label = models.CharField(max_length=160, blank=True)
    entity_type = models.CharField(max_length=80, blank=True, db_index=True)
    entity_id = models.CharField(max_length=96, blank=True, db_index=True)
    risk_score = models.PositiveSmallIntegerField(
        validators=[MinValueValidator(0), MaxValueValidator(100)],
        db_index=True,
    )
    window_start = models.DateTimeField(db_index=True)
    window_end = models.DateTimeField(db_index=True)
    summary = models.JSONField(default=dict, blank=True)
    evidence = models.JSONField(default=dict, blank=True)
    metrics = models.JSONField(default=dict, blank=True)
    peer_metrics = models.JSONField(default=dict, blank=True)
    pattern_count = models.PositiveSmallIntegerField(default=1)
    first_detected_at = models.DateTimeField(default=timezone.now)
    last_detected_at = models.DateTimeField(default=timezone.now, db_index=True)
    occurrence_count = models.PositiveIntegerField(default=1)
    resolved_at = models.DateTimeField(blank=True, null=True)

    class Meta:
        ordering = ["status", "-risk_score", "-last_detected_at", "-id"]
        indexes = [
            models.Index(fields=["status", "severity", "last_detected_at"]),
            models.Index(fields=["target_user", "status", "risk_score"]),
            models.Index(fields=["rule_code", "status"]),
            models.Index(fields=["window_start", "window_end"]),
        ]

    def __str__(self) -> str:
        return f"{self.rule_code} for {self.target_user_label or self.target_user_id}"
