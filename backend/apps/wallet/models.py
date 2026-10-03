"""The shop's side of its Daftar wallet.

The wallet itself — the balance and its ledger — lives on the relay, because
it is the shop's prepaid money with the company and the company's services
draw on it. What lives here is what only the shop knows: who started each
top-up, whether the shop wants top-ups in its own books, and which expense a
paid top-up became. That link is what makes booking the expense happen once,
however many times the top-up is read back.
"""

from django.conf import settings
from django.db import models

from apps.core.models import TimeStampedModel


class WalletSettings(TimeStampedModel):
    """The shop's wallet preferences. One row."""

    # On by default: the owner asked for the bookkeeping to be automatic, and a
    # card payment to the company that is not in the books is money the shop's
    # figures cannot explain.
    record_topups_as_expenses = models.BooleanField(default=True)
    # Where a top-up's expense is filed. Empty until the first booking, which
    # files it under «خدمات دفتر» (created then) and remembers that category,
    # so renaming it later does not start a second one.
    expense_category = models.ForeignKey(
        "expenses.ExpenseCategory",
        on_delete=models.SET_NULL,
        related_name="+",
        blank=True,
        null=True,
    )

    class Meta:
        verbose_name = "wallet settings"
        verbose_name_plural = "wallet settings"

    @classmethod
    def load(cls):
        return cls.objects.get_or_create(pk=1)[0]


class WalletTopUp(TimeStampedModel):
    """The shop's copy of one relay top-up."""

    class Status(models.TextChoices):
        PENDING = "pending", "Pending"
        PAID = "paid", "Paid"
        CANCELED = "canceled", "Canceled"
        FAILED = "failed", "Failed"
        EXPIRED = "expired", "Expired"

    #: Statuses the relay can still move: a checkout nobody came back from can
    #: be paid late, or reconciled by the company.
    OPEN_STATUSES = (Status.PENDING, Status.EXPIRED)

    relay_id = models.CharField(max_length=64, unique=True)
    invoice_no = models.CharField(max_length=32, db_index=True)
    method = models.CharField(max_length=40)
    # The payer's phone or wallet card, masked by the relay ("091•••678"). The
    # full number went to the gateway and is kept nowhere. ``db_default`` as
    # well: the previous release, still serving for the minute a live update
    # overlaps, mirrors top-ups with an INSERT that names no such column.
    payer_hint = models.CharField(max_length=32, blank=True, default="", db_default="")
    amount = models.DecimalField(max_digits=12, decimal_places=3)
    status = models.CharField(max_length=16, choices=Status.choices, default=Status.PENDING)
    provider_transaction_id = models.CharField(max_length=128, blank=True)
    test_mode = models.BooleanField(default=False)
    error_code = models.CharField(max_length=64, blank=True)
    requested_by = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.SET_NULL,
        related_name="+",
        blank=True,
        null=True,
    )
    # Decided when the top-up starts, from the setting as it was then — so
    # flipping the switch later changes the next top-up, never a payment
    # already under way.
    record_as_expense = models.BooleanField(default=True)
    relay_created_at = models.DateTimeField()
    paid_at = models.DateTimeField(blank=True, null=True)
    expense = models.OneToOneField(
        "expenses.Expense",
        on_delete=models.SET_NULL,
        related_name="wallet_topup",
        blank=True,
        null=True,
    )
    # Set once the expense is booked, and never cleared: a booked expense that
    # is later cancelled must not be booked again behind the owner's back.
    expense_booked_at = models.DateTimeField(blank=True, null=True)
    # Why booking failed, when it did (a closed period, say); retried by the sync.
    expense_error = models.CharField(max_length=255, blank=True)
    synced_at = models.DateTimeField(blank=True, null=True)

    class Meta:
        ordering = ["-relay_created_at", "-id"]
        indexes = [
            # The sync's question: which top-ups can still change, or were paid
            # and still owe the books an expense.
            models.Index(fields=["status", "relay_created_at"], name="wallet_topup_status_idx"),
        ]

    def __str__(self) -> str:
        return f"{self.invoice_no} {self.amount} {self.status}"
