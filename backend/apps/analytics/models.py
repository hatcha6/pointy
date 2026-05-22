import uuid

from django.conf import settings
from django.core.validators import MaxValueValidator, MinValueValidator
from django.db import models

from apps.core.models import TimeStampedModel


class AnalyticsEvent(TimeStampedModel):
    class EventType(models.TextChoices):
        USAGE = "usage", "Usage"
        ERROR = "error", "Error"
        PERFORMANCE = "performance", "Performance"
        SECURITY = "security", "Security"
        FRAUD_SIGNAL = "fraud_signal", "Fraud signal"
        AUDIT = "audit", "Audit"

    class Severity(models.TextChoices):
        DEBUG = "debug", "Debug"
        INFO = "info", "Info"
        WARNING = "warning", "Warning"
        ERROR = "error", "Error"
        CRITICAL = "critical", "Critical"

    class Source(models.TextChoices):
        FRONTEND = "frontend", "Frontend"
        BACKEND = "backend", "Backend"
        PRINT_AGENT = "print_agent", "Print agent"
        INTEGRATION = "integration", "Integration"

    client_event_id = models.UUIDField(default=uuid.uuid4, unique=True, editable=False)
    event_type = models.CharField(
        max_length=32,
        choices=EventType.choices,
        db_index=True,
    )
    name = models.CharField(max_length=120, db_index=True)
    severity = models.CharField(
        max_length=16,
        choices=Severity.choices,
        default=Severity.INFO,
        db_index=True,
    )
    source = models.CharField(
        max_length=32,
        choices=Source.choices,
        default=Source.FRONTEND,
        db_index=True,
    )
    occurred_at = models.DateTimeField(db_index=True)
    received_by = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.SET_NULL,
        related_name="analytics_events",
        blank=True,
        null=True,
    )
    session_id = models.CharField(max_length=96, blank=True, db_index=True)
    device_id = models.CharField(max_length=96, blank=True, db_index=True)
    installation_id = models.CharField(max_length=96, blank=True, db_index=True)
    app_version = models.CharField(max_length=40, blank=True)
    platform = models.CharField(max_length=48, blank=True)
    request_path = models.CharField(max_length=256, blank=True)
    ip_address = models.GenericIPAddressField(blank=True, null=True)
    user_agent = models.TextField(blank=True)
    trace_id = models.CharField(max_length=96, blank=True, db_index=True)
    entity_type = models.CharField(max_length=64, blank=True, db_index=True)
    entity_id = models.CharField(max_length=96, blank=True, db_index=True)
    risk_score = models.PositiveSmallIntegerField(
        blank=True,
        null=True,
        validators=[MinValueValidator(0), MaxValueValidator(100)],
    )
    attributes = models.JSONField(default=dict, blank=True)
    metrics = models.JSONField(default=dict, blank=True)

    class Meta:
        ordering = ["-occurred_at", "-id"]
        indexes = [
            models.Index(fields=["event_type", "occurred_at"]),
            models.Index(fields=["name", "occurred_at"]),
            models.Index(fields=["source", "occurred_at"]),
            models.Index(fields=["received_by", "occurred_at"]),
            models.Index(fields=["entity_type", "entity_id"]),
            models.Index(fields=["risk_score", "occurred_at"]),
        ]

    def __str__(self):
        return f"{self.name} ({self.event_type})"
