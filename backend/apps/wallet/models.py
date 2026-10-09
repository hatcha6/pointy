"""The shop's side of its Daftar wallet.

The wallet itself — the balance and its ledger — lives on the relay, because
it is the shop's prepaid money with the company and the company's services
draw on it. What lives here is what only the shop knows: who started each
top-up and each spend, whether the shop keeps the wallet in its own books, and
what each movement was booked as there (``apps.wallet.books``). Those links
are what make each booking happen once, however many times a movement is read
back.
"""

from django.conf import settings
from django.db import models

from apps.core.models import TimeStampedModel


class WalletSettings(TimeStampedModel):
    """The shop's wallet preferences. One row."""

    # On by default: the owner asked for the bookkeeping to be automatic, and a
    # card payment to the company that is not in the books is money the shop's
    # figures cannot explain. The name is from when a top-up was booked as an
    # expense, kept for the app; it now means "keep the wallet in the books"
    # (see ``apps.wallet.books``).
    record_topups_as_expenses = models.BooleanField(default=True)
    # Where the wallet's spending (SMS, plans) is filed. Empty until the first
    # booking, which files it under «خدمات دفتر» (created then) and remembers
    # that category, so renaming it later does not start a second one.
    expense_category = models.ForeignKey(
        "expenses.ExpenseCategory",
        on_delete=models.SET_NULL,
        related_name="+",
        blank=True,
        null=True,
    )
    # The wallet as an account in the shop's money position («محفظة دفتر»):
    # top-ups move money into it, spending comes out of it. Made on first
    # need and remembered here, like the category, so renaming it never
    # starts a second one.
    money_account = models.ForeignKey(
        "treasury.MoneyAccount",
        on_delete=models.SET_NULL,
        related_name="+",
        blank=True,
        null=True,
    )
    # When these books started keeping the wallet as an account rather than
    # booking each top-up as an expense. Set once, by the first booking after.
    books_switched_at = models.DateTimeField(blank=True, null=True)
    # How much of the wallet, at that moment, had already been booked as an
    # expense when it was topped up. Spending it books nothing more (it would
    # be counted twice); what is left of it is consumed first.
    prebooked_balance = models.DecimalField(
        max_digits=14, decimal_places=3, blank=True, null=True
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
        # A bank transfer waiting for the company to find it on its statement,
        # and one it turned down (with the reason in ``error_detail``).
        REVIEW = "review", "In review"
        REJECTED = "rejected", "Rejected"

    #: Statuses the relay can still move: a checkout nobody came back from can
    #: be paid late, or reconciled by the company; a bank transfer is decided
    #: by the company, which may still credit one it rejected when the money
    #: turns up after all.
    OPEN_STATUSES = (Status.PENDING, Status.EXPIRED, Status.REVIEW, Status.REJECTED)
    #: The method a bank transfer to the company's account is recorded under.
    METHOD_BANK_TRANSFER = "bank_transfer"

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
    # Why the company turned a bank transfer down, as its operator wrote it:
    # what the owner is told. ``db_default``: the release before this one
    # inserts without it.
    error_detail = models.CharField(max_length=500, blank=True, default="", db_default="")
    # When a bank transfer was confirmed or rejected, as this shop first saw
    # it: what the owner's notification is about, for a few days.
    decided_at = models.DateTimeField(blank=True, null=True)
    requested_by = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.SET_NULL,
        related_name="+",
        blank=True,
        null=True,
    )
    # Decided when the top-up starts, from the setting as it was then — so
    # flipping the switch later changes the next top-up, never a payment
    # already under way. The name is the app's, from when this meant "book it
    # as an expense"; it now means "keep this money in the books".
    record_as_expense = models.BooleanField(default=True)
    relay_created_at = models.DateTimeField()
    paid_at = models.DateTimeField(blank=True, null=True)
    # How a top-up was booked before the wallet was an account in the books:
    # an expense. Kept for those top-ups; nothing books one any more.
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
    # How a paid top-up is booked now: money moved from the bank into the
    # wallet's account (``apps.wallet.books``). Once, like the expense was:
    # ``transfer_booked_at`` is never cleared, so a transfer somebody deleted
    # is not booked again behind the owner's back.
    transfer = models.OneToOneField(
        "treasury.MoneyTransfer",
        on_delete=models.SET_NULL,
        related_name="wallet_topup",
        blank=True,
        null=True,
    )
    transfer_booked_at = models.DateTimeField(blank=True, null=True)
    # Why booking failed, when it did (a closed period, say); retried by the
    # sync. The name is from when a top-up became an expense.
    expense_error = models.CharField(max_length=255, blank=True)
    synced_at = models.DateTimeField(blank=True, null=True)

    @property
    def is_booked(self) -> bool:
        """Booked into the shop's books, either way it ever was."""
        return self.expense_booked_at is not None or self.transfer_booked_at is not None

    class Meta:
        ordering = ["-relay_created_at", "-id"]
        indexes = [
            # The sync's question: which top-ups can still change, or were paid
            # and still owe the books an expense.
            models.Index(fields=["status", "relay_created_at"], name="wallet_topup_status_idx"),
        ]

    def __str__(self) -> str:
        return f"{self.invoice_no} {self.amount} {self.status}"


class WalletSpend(TimeStampedModel):
    """One time the shop spent its main wallet, and what that became in its books.

    Money moved into the SMS balance, a plan paid for, money moved into the
    voucher balance: each is one movement on the relay, named by the key it
    was made under, and booked here once (``apps.wallet.books``) — the first
    two as spending, the last as a move into the voucher float.
    """

    class Kind(models.TextChoices):
        SMS = "sms", "Moved into the SMS balance"
        PLAN = "plan", "A plan paid for"
        VOUCHERS = "vouchers", "Moved into the voucher balance"

    kind = models.CharField(max_length=16, choices=Kind.choices)
    # The relay's own reference for the movement ("transfer:<key>",
    # "plan:<key>"): what makes a replayed answer the same row.
    relay_reference = models.CharField(max_length=128)
    amount = models.DecimalField(max_digits=12, decimal_places=3)
    # What the books call it («رصيد الرسائل», «اشتراك المساعد الذكي حتى …»).
    description = models.CharField(max_length=255)
    # The business day it happened on the relay.
    happened_on = models.DateField()
    requested_by = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.SET_NULL,
        related_name="+",
        blank=True,
        null=True,
    )
    # Decided when it happens, from the setting as it was then, like a
    # top-up's ``record_as_expense``: off means nothing is booked for it.
    record_in_books = models.BooleanField(default=True)
    # The part of it paid from money already booked as an expense when it was
    # topped up (``WalletSettings.prebooked_balance``): nothing more is booked
    # for that part.
    prebooked_amount = models.DecimalField(max_digits=12, decimal_places=3, default=0)
    expense = models.OneToOneField(
        "expenses.Expense",
        on_delete=models.SET_NULL,
        related_name="wallet_spend",
        blank=True,
        null=True,
    )
    transfer = models.OneToOneField(
        "treasury.MoneyTransfer",
        on_delete=models.SET_NULL,
        related_name="wallet_spend",
        blank=True,
        null=True,
    )
    # Set once it is booked (or there was nothing to book), never cleared.
    booked_at = models.DateTimeField(blank=True, null=True)
    # Why booking failed, when it did; retried by the sync.
    error = models.CharField(max_length=255, blank=True)

    class Meta:
        ordering = ["-happened_on", "-id"]
        constraints = [
            models.UniqueConstraint(
                fields=["kind", "relay_reference"], name="wallet_unique_spend"
            )
        ]
        indexes = [
            # The sync's question: which spending still owes the books a row.
            models.Index(fields=["booked_at", "created_at"], name="wallet_spend_owed_idx"),
        ]

    def __str__(self) -> str:
        return f"{self.kind} {self.amount} {self.relay_reference}"
