"""Where the shop's money physically is.

Pointy already knows every money *event* — a cash sale, a card payment, a
drawer pay-out, a supplier settlement, a payroll run. What it has never known
is where the money ended up once the shift closed: cash left the drawer and
left the model with it, and ``transfer``/``bank_transfer`` were string labels
on three unrelated enums pointing at no account at all.

These three models close that. A ``MoneyAccount`` is a place money sits (the
cash box, a bank account). A ``MoneyTransfer`` is the shop moving its own money
between those places — the bank deposit, the owner's draw, the capital put in.
A ``MoneyCount`` is what somebody actually found when they looked.

Deliberately *not* a ledger: no accounts tree, no debits and credits, no
journal. The balance of an account is derived from the money events that
already exist (see ``position.py``), so nothing has to be posted twice and no
existing write path changes. What is stored here is only what the events cannot
tell us: the starting balance, the moves between our own accounts, and the
counts that prove — or disprove — the arithmetic.
"""

from decimal import Decimal

from django.conf import settings
from django.core.exceptions import ValidationError
from django.core.validators import MinValueValidator
from django.db import models
from django.utils import timezone

from apps.core.models import TimeStampedModel


class MoneyAccount(TimeStampedModel):
    """A place the shop's money sits: the cash box, or a bank account."""

    class Kind(models.TextChoices):
        CASH = "cash", "Cash"
        BANK = "bank", "Bank"
        # Money the shop has already paid to a resale provider and not yet
        # spent — an agency float. It is the shop's money, sitting somewhere
        # else, which is exactly what this model is for. Unlike cash and bank
        # it is never a *default*: no untagged payment lands in a float, and
        # every movement into or out of one names its provider.
        PROVIDER = "provider", "Provider float"

    name = models.CharField(max_length=120)
    kind = models.CharField(max_length=8, choices=Kind.choices, db_index=True)
    # Bank-only descriptive fields; blank for a cash box.
    bank_name = models.CharField(max_length=120, blank=True)
    account_number = models.CharField(max_length=64, blank=True)
    # What the account held on ``opening_at``. Derived flows are only counted
    # from that day onward, so a shop that has been trading for years starts
    # from a number its owner actually recognises instead of from a replay of
    # history nobody trusts.
    opening_balance = models.DecimalField(max_digits=12, decimal_places=2, default=0)
    opening_at = models.DateField(default=timezone.localdate)
    # The account of its kind that untagged money events land in. Exactly one
    # per kind may hold this (enforced below), because every derived flow is
    # routed by payment method, not by a per-transaction account tag.
    is_default = models.BooleanField(default=False)
    is_active = models.BooleanField(default=True)
    display_order = models.PositiveIntegerField(default=0)
    notes = models.TextField(blank=True)

    class Meta:
        ordering = ["display_order", "name"]
        constraints = [
            models.UniqueConstraint(
                fields=["kind"],
                condition=models.Q(is_default=True),
                name="treasury_one_default_account_per_kind",
            ),
        ]

    def __str__(self) -> str:
        return f"{self.name} ({self.get_kind_display()})"

    @property
    def is_cash(self) -> bool:
        return self.kind == self.Kind.CASH


class MoneyTransfer(TimeStampedModel):
    """The shop moving its own money, with no sale or purchase behind it.

    Three shapes, distinguished by which side is set:

    * both sides — a transfer between our own accounts (the bank deposit that
      takes the week's takings out of the cash box);
    * ``to_account`` only — money coming in from outside (the owner putting
      capital in);
    * ``from_account`` only — money going out (the owner drawing money).

    None of these is revenue or an expense, which is exactly why they cannot be
    inferred from the existing money events and have to be recorded.
    """

    class Kind(models.TextChoices):
        TRANSFER = "transfer", "Transfer between accounts"
        DEPOSIT = "deposit", "Deposit from outside"
        WITHDRAWAL = "withdrawal", "Withdrawal to outside"

    from_account = models.ForeignKey(
        MoneyAccount,
        on_delete=models.PROTECT,
        related_name="transfers_out",
        blank=True,
        null=True,
    )
    to_account = models.ForeignKey(
        MoneyAccount,
        on_delete=models.PROTECT,
        related_name="transfers_in",
        blank=True,
        null=True,
    )
    amount = models.DecimalField(
        max_digits=12,
        decimal_places=2,
        validators=[MinValueValidator(Decimal("0.01"))],
    )
    moved_at = models.DateField(default=timezone.localdate, db_index=True)
    reason = models.CharField(max_length=255, blank=True)
    reference = models.CharField(max_length=128, blank=True)
    created_by = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.SET_NULL,
        related_name="money_transfers",
        blank=True,
        null=True,
    )

    class Meta:
        ordering = ["-moved_at", "-created_at"]
        constraints = [
            models.CheckConstraint(
                condition=models.Q(from_account__isnull=False)
                | models.Q(to_account__isnull=False),
                name="treasury_transfer_has_a_side",
            ),
        ]
        indexes = [
            models.Index(fields=["moved_at"], name="treasury_transfer_moved_idx"),
        ]

    def __str__(self) -> str:
        return f"{self.kind} {self.amount}"

    @property
    def kind(self) -> str:
        if self.from_account_id and self.to_account_id:
            return self.Kind.TRANSFER
        if self.to_account_id:
            return self.Kind.DEPOSIT
        return self.Kind.WITHDRAWAL

    def clean(self):
        super().clean()
        if not self.from_account_id and not self.to_account_id:
            raise ValidationError("A transfer needs a source, a destination, or both.")
        if (
            self.from_account_id
            and self.to_account_id
            and self.from_account_id == self.to_account_id
        ):
            raise ValidationError("A transfer cannot move money to the same account.")


class MoneyCount(TimeStampedModel):
    """What somebody actually found in an account when they looked.

    ``expected_amount`` and ``variance`` are snapshotted at the moment of the
    count rather than recomputed on read: the whole point of a count is to
    record the disagreement as it stood, and a later backdated expense must not
    quietly make a past variance disappear.
    """

    account = models.ForeignKey(
        MoneyAccount,
        on_delete=models.PROTECT,
        related_name="counts",
    )
    counted_amount = models.DecimalField(max_digits=12, decimal_places=2)
    expected_amount = models.DecimalField(max_digits=12, decimal_places=2)
    variance = models.DecimalField(max_digits=12, decimal_places=2)
    counted_at = models.DateTimeField(default=timezone.now, db_index=True)
    note = models.TextField(blank=True)
    created_by = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.SET_NULL,
        related_name="money_counts",
        blank=True,
        null=True,
    )

    class Meta:
        ordering = ["-counted_at", "-created_at"]
        indexes = [
            models.Index(
                fields=["account", "-counted_at"],
                name="treasury_count_account_idx",
            ),
        ]

    def __str__(self) -> str:
        return f"count {self.counted_amount} on {self.account_id}"

    @property
    def has_variance(self) -> bool:
        return self.variance != Decimal("0.00")
