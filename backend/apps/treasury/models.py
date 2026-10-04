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

from datetime import time
from decimal import Decimal

from django.conf import settings
from django.core.exceptions import ValidationError
from django.core.validators import MaxValueValidator, MinValueValidator
from django.db import models
from django.utils import timezone

from apps.core.models import TimeStampedModel
from apps.documents.guards import DocumentQuerySetMixin
from apps.documents.models import DocumentMixin

from .settlement_calendar import DEFAULT_SETTLEMENT_WEEKDAYS


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
        # Card takings the card processor (Moamalat) is holding before it pays
        # them into the bank. The shop's money, already earned, but not yet in
        # any account whose statement the owner can read — so it is its own
        # place, between the sale and the bank. Never a default and never named
        # on a payment: which card payments it holds is a rule about the bank
        # they settle into (``apps.treasury.clearing``), and money leaves it
        # only by a recorded ``CardSettlement``.
        CLEARING = "clearing", "Card takings held by the processor"

    name = models.CharField(max_length=120)
    kind = models.CharField(max_length=8, choices=Kind.choices, db_index=True)
    # Bank-only descriptive fields; blank for a cash box.
    bank_name = models.CharField(max_length=120, blank=True)
    # Which bank, as the Central Bank's own register names it. An OPAQUE string
    # here on purpose: the register — slug, Arabic name, English name and the
    # trademark image — lives in the client, beside the logo files it points at
    # (``frontend/lib/src/shared/payments/libyan_banks.dart``), and mirroring it
    # into Python would create a second list to keep in step with the first. A
    # slug this build has never heard of is not an error; the client falls back
    # to ``bank_name``, exactly as it already does for a bank whose trademark is
    # not bundled.
    bank_slug = models.CharField(max_length=32, blank=True)
    account_number = models.CharField(max_length=64, blank=True)
    # Stored unformatted (no spaces) and never validated against a checksum
    # here: a Libyan IBAN a shop reads off its own statement is the number the
    # customer must transfer to, and refusing to save one because this build
    # disagrees about its check digits would leave the shop unable to record
    # the only string that matters.
    iban = models.CharField(max_length=34, blank=True)
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

    # --- Clearing accounts only -------------------------------------------
    # Blank / defaulted on every other kind, and every one with a database
    # default: an older backend inserting a cash box during a live update names
    # none of these columns.
    #
    # The bank the processor pays this account's takings into. Fixed once set:
    # which card payments the account holds is decided by it, so changing it
    # would move takings that were already paid out.
    settles_into = models.ForeignKey(
        "self",
        on_delete=models.PROTECT,
        related_name="clearing_accounts",
        blank=True,
        null=True,
    )
    # Whether card payments that name no bank at all are held here too. True
    # for the clearing account of the bank untagged money fell back to when it
    # was opened — and frozen then, so a later change of default bank cannot
    # move takings between accounts after the fact.
    holds_untagged_card = models.BooleanField(default=False, db_default=False)
    # When the processor closes its day, on the shop's clock. Midnight for
    # Moamalat. Shapes the expected dates only, never which payments are held.
    settlement_cutoff = models.TimeField(default=time(0, 0), db_default=time(0, 0))
    # The weekdays the processor pays into the bank (Python numbering,
    # Monday=0), written like ``apps.attendance`` writes a work week.
    settlement_weekdays = models.CharField(
        max_length=32,
        default=DEFAULT_SETTLEMENT_WEEKDAYS,
        db_default=DEFAULT_SETTLEMENT_WEEKDAYS,
    )
    # How many settlement days after a processor day its money lands.
    settlement_lag_days = models.PositiveSmallIntegerField(
        default=1,
        db_default=1,
        validators=[MaxValueValidator(10)],
    )
    # The last processor day this account held, once the shop stopped routing
    # card takings through it. Takings after it go straight to the bank again.
    closed_on = models.DateField(blank=True, null=True)

    class Meta:
        ordering = ["display_order", "name"]
        constraints = [
            models.UniqueConstraint(
                fields=["kind"],
                condition=models.Q(is_default=True),
                name="treasury_one_default_account_per_kind",
            ),
            # One open holding account per bank: two would both claim the same
            # card payments.
            models.UniqueConstraint(
                fields=["settles_into"],
                condition=models.Q(kind="clearing", closed_on__isnull=True),
                name="treasury_one_open_clearing_per_bank",
            ),
            # And only one may hold the payments that name no bank.
            models.UniqueConstraint(
                fields=["holds_untagged_card"],
                condition=models.Q(
                    kind="clearing",
                    holds_untagged_card=True,
                    closed_on__isnull=True,
                ),
                name="treasury_one_open_untagged_clearing",
            ),
        ]

    def __str__(self) -> str:
        return f"{self.name} ({self.get_kind_display()})"

    @property
    def is_cash(self) -> bool:
        return self.kind == self.Kind.CASH

    @property
    def is_clearing(self) -> bool:
        return self.kind == self.Kind.CLEARING


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


class CardSettlementQuerySet(DocumentQuerySetMixin, models.QuerySet):
    pass


class CardSettlement(DocumentMixin, TimeStampedModel):
    """The processor paying held card takings into the bank.

    The one way money leaves a clearing account. It names the card payments it
    paid for (``lines``), so a held balance is always "these sales, not yet
    paid" rather than a number nobody can take apart — and a day the processor
    never paid stays visibly unpaid instead of disappearing into a transfer.

    Three figures, all stored when it is recorded (the payments behind them are
    frozen documents, so they cannot drift):

    * ``expected_amount`` — what the covered payments should have brought in,
      net of the fee Pointy estimated at each sale;
    * ``amount_received`` — what actually reached the bank, from the SMS or the
      statement. This is what the bank account gains;
    * ``difference`` — received minus expected. Negative when the processor
      kept more than the estimate (a higher fee), positive when it kept less.
      Shown as its own line, never folded into the takings.

    Born submitted, undone by cancelling (which releases its payments back to
    held), never edited: the money either arrived or it did not.
    """

    objects = CardSettlementQuerySet.as_manager()

    clearing_account = models.ForeignKey(
        MoneyAccount,
        on_delete=models.PROTECT,
        related_name="settlements_out",
    )
    # Where the money landed — the clearing account's bank at the time. Kept
    # on the row so a bank's balance sums its settlements without a join.
    bank_account = models.ForeignKey(
        MoneyAccount,
        on_delete=models.PROTECT,
        related_name="settlements_in",
    )
    settled_on = models.DateField(default=timezone.localdate, db_index=True)
    amount_received = models.DecimalField(max_digits=12, decimal_places=2)
    expected_amount = models.DecimalField(max_digits=12, decimal_places=2)
    gross_amount = models.DecimalField(max_digits=12, decimal_places=2)
    commission_amount = models.DecimalField(max_digits=12, decimal_places=2)
    difference = models.DecimalField(max_digits=12, decimal_places=2)
    payment_count = models.PositiveIntegerField(default=0)
    # The processor days covered, for display ("from Thursday to Saturday").
    first_day = models.DateField(blank=True, null=True)
    last_day = models.DateField(blank=True, null=True)
    reference = models.CharField(max_length=128, blank=True)
    note = models.TextField(blank=True)
    created_by = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.SET_NULL,
        related_name="card_settlements",
        blank=True,
        null=True,
    )

    class Meta:
        ordering = ["-settled_on", "-created_at"]
        permissions = [
            (
                "cancel_cardsettlement",
                "Cancel a recorded card settlement and hold its payments again",
            ),
        ]
        indexes = [
            models.Index(
                fields=["clearing_account", "doc_status", "settled_on"],
                name="treasury_settle_clearing_idx",
            ),
            models.Index(
                fields=["bank_account", "doc_status", "settled_on"],
                name="treasury_settle_bank_idx",
            ),
        ]

    def __str__(self) -> str:
        return f"settlement {self.amount_received} on {self.settled_on}"


class CardSettlementLine(models.Model):
    """One card payment a settlement paid for.

    ``is_live`` mirrors the settlement's state so the database itself refuses
    to let a payment be paid out twice: the partial unique index covers live
    lines only, and cancelling a settlement switches its lines off — which is
    what puts those payments back among the held ones.
    """

    settlement = models.ForeignKey(
        CardSettlement,
        on_delete=models.CASCADE,
        related_name="lines",
    )
    payment = models.ForeignKey(
        "payments.Payment",
        on_delete=models.PROTECT,
        related_name="settlement_lines",
    )
    is_live = models.BooleanField(default=True, db_default=True)

    class Meta:
        constraints = [
            models.UniqueConstraint(
                fields=["payment"],
                condition=models.Q(is_live=True),
                name="treasury_payment_settled_once",
            ),
        ]

    def __str__(self) -> str:
        return f"payment {self.payment_id} in settlement {self.settlement_id}"
