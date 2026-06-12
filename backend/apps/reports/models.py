from django.conf import settings
from django.db import models
from django.utils import timezone

from apps.core.models import TimeStampedModel


class ReportRun(TimeStampedModel):
    class ReportType(models.TextChoices):
        SALES_SUMMARY = "sales_summary", "Sales summary"
        PAYMENT_METHODS = "payment_methods", "Payment methods"
        REGISTER_CLOSURE = "register_closure", "Register closure"
        INVENTORY_STATUS = "inventory_status", "Inventory status"
        STOCK_MOVEMENTS = "stock_movements", "Stock movements"
        PURCHASING_SUMMARY = "purchasing_summary", "Purchasing summary"
        REORDER_ITEMS = "reorder_items", "Reorder items"
        PAYROLL_SUMMARY = "payroll_summary", "Payroll summary"
        PROFIT_COSTS = "profit_costs", "Profit and costs"

    class OutputFormat(models.TextChoices):
        JSON = "json", "JSON"
        PDF = "pdf", "PDF"
        CSV = "csv", "CSV"

    class Status(models.TextChoices):
        PENDING = "pending", "Pending"
        SUCCESS = "success", "Success"
        FAILED = "failed", "Failed"

    requested_by = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.SET_NULL,
        related_name="report_runs",
        blank=True,
        null=True,
    )
    report_type = models.CharField(max_length=48, choices=ReportType.choices)
    params = models.JSONField(default=dict, blank=True)
    output_format = models.CharField(
        max_length=16,
        choices=OutputFormat.choices,
        default=OutputFormat.PDF,
    )
    status = models.CharField(
        max_length=16,
        choices=Status.choices,
        default=Status.PENDING,
    )
    payload = models.JSONField(default=dict, blank=True)
    row_count = models.PositiveIntegerField(default=0)
    checksum = models.CharField(max_length=64, blank=True)
    completed_at = models.DateTimeField(blank=True, null=True)
    error_message = models.TextField(blank=True)

    class Meta:
        ordering = ["-created_at", "-id"]
        indexes = [
            models.Index(fields=["report_type", "created_at"]),
            models.Index(fields=["requested_by", "created_at"]),
            models.Index(fields=["status", "created_at"]),
        ]

    def mark_success(self, *, payload, row_count, checksum):
        self.status = self.Status.SUCCESS
        self.payload = payload
        self.row_count = row_count
        self.checksum = checksum
        self.completed_at = timezone.now()
        self.error_message = ""
        self.save(
            update_fields=[
                "status",
                "payload",
                "row_count",
                "checksum",
                "completed_at",
                "error_message",
                "updated_at",
            ],
        )

    def mark_failed(self, message):
        self.status = self.Status.FAILED
        self.error_message = str(message)
        self.completed_at = timezone.now()
        self.save(
            update_fields=[
                "status",
                "error_message",
                "completed_at",
                "updated_at",
            ],
        )

    def __str__(self):
        return f"{self.report_type} by {self.requested_by_id or 'system'}"
