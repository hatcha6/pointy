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
        RECEIVABLES_AGING = "receivables_aging", "Receivables aging"
        PAYABLES_AGING = "payables_aging", "Payables aging"
        CUSTOMER_STATEMENT = "customer_statement", "Customer statement"
        SUPPLIER_STATEMENT = "supplier_statement", "Supplier statement"
        CASH_POSITION = "cash_position", "Cash and bank position"
        EXPENSE_BREAKDOWN = "expense_breakdown", "Expenses by category"
        PRODUCT_MARGIN = "product_margin", "Gross margin by product"
        DISCOUNT_AUDIT = "discount_audit", "Discounts, voids and returns"
        SALES_BY_STAFF = "sales_by_staff", "Sales by staff and hour"
        MONTH_END_PACK = "month_end_pack", "Month-end pack"
        # Identified stock: the four questions a quantity-only ledger cannot be
        # made to answer at all.
        UNIT_AGING = "unit_aging", "Identified stock aging"
        UNIT_MARGIN = "unit_margin", "Margin per identified article"
        UNIT_LEDGER = "unit_ledger", "One article's life"
        CONSIGNMENT_LEDGER = "consignment_ledger", "Consignment ledger and payables"

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
    #: Hash of the whole payload, timestamp included — identifies this run.
    checksum = models.CharField(max_length=64, blank=True)
    #: Hash of the figures alone, with the generation timestamp excluded. This
    #: is the one that answers the question a checksum is for: "are September's
    #: numbers still what I reported?" ``checksum`` never could, because
    #: ``generated_at`` was inside the bytes it hashed, so two runs of the same
    #: closed period were guaranteed to differ.
    figures_checksum = models.CharField(max_length=64, blank=True, db_index=True)
    completed_at = models.DateTimeField(blank=True, null=True)
    error_message = models.TextField(blank=True)

    class Meta:
        ordering = ["-created_at", "-id"]
        indexes = [
            models.Index(fields=["report_type", "created_at"]),
            models.Index(fields=["requested_by", "created_at"]),
            models.Index(fields=["status", "created_at"]),
            # The run history lists one report type's runs newest-first and
            # compares them by the figures they carry; this is that query.
            models.Index(
                fields=["report_type", "figures_checksum"],
                name="reports_type_figures_idx",
            ),
        ]
        permissions = [
            (
                "manage_period_lock",
                "Can close and re-open an accounting period",
            ),
            (
                "override_period_lock",
                "Can post into a closed accounting period",
            ),
        ]

    def mark_success(self, *, payload, row_count, checksum, figures_checksum=""):
        self.status = self.Status.SUCCESS
        # Stock quantities are Decimals since weighted-product support; the
        # payload column is JSON, so coerce them at the boundary.
        self.payload = _json_safe_payload(payload)
        self.row_count = row_count
        self.checksum = checksum
        self.figures_checksum = figures_checksum
        self.completed_at = timezone.now()
        self.error_message = ""
        self.save(
            update_fields=[
                "status",
                "payload",
                "row_count",
                "checksum",
                "figures_checksum",
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

def _json_safe_payload(value):
    from decimal import Decimal

    if isinstance(value, Decimal):
        return float(value)
    if isinstance(value, dict):
        return {key: _json_safe_payload(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [_json_safe_payload(item) for item in value]
    return value
