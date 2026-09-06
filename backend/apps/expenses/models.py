from decimal import Decimal

from django.conf import settings
from django.core.validators import MinValueValidator
from django.db import models
from django.utils import timezone

from apps.core.models import TimeStampedModel
from apps.documents.guards import DocumentQuerySetMixin
from apps.documents.models import DocumentMixin


class ExpenseCategory(TimeStampedModel):
    """A bucket for shop expenses (rent, utilities, ...). Managed by the shop,
    seeded with sensible defaults. Categories are kept (not deleted) once an
    expense references them — the FK from ``Expense`` is ``PROTECT``.
    """

    name = models.CharField(max_length=120, unique=True)
    is_active = models.BooleanField(default=True)
    display_order = models.PositiveIntegerField(default=0)

    class Meta:
        ordering = ["display_order", "name"]
        verbose_name = "expense category"
        verbose_name_plural = "expense categories"

    def __str__(self) -> str:
        return self.name


class ExpenseQuerySet(DocumentQuerySetMixin, models.QuerySet):
    pass


class Expense(DocumentMixin, TimeStampedModel):
    """A single shop expense that is not tied to an employee or a product —
    rent, utilities, maintenance, supplies, and the like.

    When paid in cash from an open register, the expense also records a linked
    ``RegisterCashMovement`` pay-out (``cash_movement``) so the drawer
    reconciles. The unified expense ledger excludes such pay-outs from the
    register-pay-out source so a drawer-paid expense is never counted twice.
    """

    objects = ExpenseQuerySet.as_manager()

    class PaymentMethod(models.TextChoices):
        CASH = "cash", "Cash"
        CARD = "card", "Card"
        TRANSFER = "transfer", "Transfer"

    category = models.ForeignKey(
        ExpenseCategory,
        on_delete=models.PROTECT,
        related_name="expenses",
    )
    description = models.CharField(max_length=255)
    amount = models.DecimalField(
        max_digits=10,
        decimal_places=2,
        validators=[MinValueValidator(Decimal("0.01"))],
    )
    payment_method = models.CharField(
        max_length=16,
        choices=PaymentMethod.choices,
        default=PaymentMethod.CASH,
    )
    # Backdatable day the money was spent; reports/dashboard filter on this,
    # mirroring how payroll filters on payment_date.
    spent_at = models.DateField(default=timezone.localdate, db_index=True)
    reference = models.CharField(max_length=128, blank=True)
    notes = models.TextField(blank=True)
    register_session = models.ForeignKey(
        "sales.RegisterSession",
        on_delete=models.PROTECT,
        related_name="expenses",
        blank=True,
        null=True,
    )
    cash_movement = models.OneToOneField(
        "sales.RegisterCashMovement",
        on_delete=models.PROTECT,
        related_name="expense",
        blank=True,
        null=True,
    )
    created_by = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.SET_NULL,
        related_name="expenses",
        blank=True,
        null=True,
    )

    class Meta:
        ordering = ["-spent_at", "-created_at"]

    def __str__(self) -> str:
        return f"{self.description} {self.amount}"
