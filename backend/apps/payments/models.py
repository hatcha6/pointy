from django.conf import settings
from django.db import models
from django.core.validators import MinValueValidator
from django.db.models import Q
from django.utils import timezone

from apps.core.models import TimeStampedModel
from apps.documents.guards import DocumentQuerySetMixin
from apps.documents.models import DocumentMixin
from apps.sales.models import Order, RegisterSession


class PaymentQuerySet(DocumentQuerySetMixin, models.QuerySet):
    def money_received(self):
        """Payments that brought money in: every tender but the ones that
        settle a debt without money moving.

        A salary deduction settles a staff purchase out of the employee's wages
        and puts nothing in a drawer or a bank; an account-credit payment spends
        money the shop already owed the customer. A figure that means "what
        customers paid us" leaves both out. Balances do not — to an invoice they
        are as much a payment as cash.
        """
        return self.exclude(method__in=Payment.NON_MONEY_METHODS)

    def takings(self):
        """What a till took, net of what it gave back by cancelling a payment.

        Every tender taken, plus every cancellation's counter payment — the
        drawer that hands the money back over the counter is the one that
        wrote it (``documents.reverse``), so that is the drawer it comes out of.

        Not a refund's negative rows. A return reaches the drawer once already,
        through ``OrderAdjustment.cash_amount``, and migration ``0007`` gave
        historical refund rows their order's session, so summing every signed
        row would take each refund out twice. A counter payment is told apart
        by ``reverses``, never by its reference: whoever takes a payment can
        type any reference, and a drawer that trusted one could be emptied by
        typing.
        """
        return self.filter(Q(amount__gt=0) | Q(reverses__isnull=False))


class Payment(DocumentMixin, TimeStampedModel):
    """Money collected against an order — or given back, as a negative row.

    A payment has no draft state: money either moved or it did not. It is a
    document from the moment it exists, which is what stops a ``PATCH`` from
    quietly rewriting what a customer paid, and a ``DELETE`` from making a
    settled invoice unpaid again with nothing to show for it. Undoing one is a
    *counter payment*, the same shape a refund already takes.
    """

    objects = PaymentQuerySet.as_manager()

    class Method(models.TextChoices):
        CASH = "cash", "Cash"
        CARD = "card", "Card"
        TRANSFER = "transfer", "Transfer"
        # A staff purchase settled out of the employee's wages when their
        # payroll run is paid (``apps.employees.staff_purchases``). No money
        # moves: the wage paid out is smaller instead, so this lands in no
        # drawer and no bank, and no till can tender it —
        # ``ShopSettings.payment_method_enabled`` knows only the three above.
        # Not "payroll": that word already names the wages-paid line of the
        # money position and the reports, and money *in* must not read as
        # money *out*.
        SALARY_DEDUCTION = "salary_deduction", "Salary deduction"
        # Credit the shop already owed the customer (an opening balance or an
        # adjustment in their favour, ``apps.balances``) spent against what
        # they owe. Written only by ``apps.balances.customers.apply_customer_credit``,
        # always linked to the credit it drew on by a ``CustomerCreditApplication``.
        # No money moves, so it lands in no drawer, no bank and no "money
        # received" figure, and no till can tender it.
        ACCOUNT_CREDIT = "account_credit", "Account credit"

    #: What a till can take: every method but the ones only a service writes.
    TILL_METHODS = (Method.CASH, Method.CARD, Method.TRANSFER)
    #: Settle a debt without any money arriving. Every figure about money
    #: received leaves these out (``PaymentQuerySet.money_received``).
    NON_MONEY_METHODS = (Method.SALARY_DEDUCTION, Method.ACCOUNT_CREDIT)

    @classmethod
    def till_method_choices(cls):
        """``TILL_METHODS`` as field choices, for every endpoint a till writes."""
        return [(method.value, method.label) for method in cls.TILL_METHODS]

    order = models.ForeignKey(Order, on_delete=models.PROTECT, related_name="payments")
    method = models.CharField(max_length=16, choices=Method.choices)
    amount = models.DecimalField(max_digits=10, decimal_places=2)
    commission_percent = models.DecimalField(
        max_digits=5,
        decimal_places=2,
        default=0,
        validators=[MinValueValidator(0)],
    )
    commission_amount = models.DecimalField(max_digits=10, decimal_places=2, default=0)
    external_reference = models.CharField(max_length=128, blank=True)
    # Set on a cancellation's counter payment only, to the payment it gives
    # back. One writer (``documents.reverse``), frozen from birth and offered to
    # no serializer, because it is what puts that money back through a drawer
    # (``PaymentQuerySet.takings``). The ``cancel:<pk>`` reference says the same
    # thing for people to read, but it is free text and stays editable.
    reverses = models.ForeignKey(
        "self",
        on_delete=models.SET_NULL,
        related_name="reversals",
        blank=True,
        null=True,
    )
    card_receipt_data = models.JSONField(default=dict, blank=True)
    # Set when a card payment's receipt is captured: links the payment to the
    # deduped PaymentCard (and, through it, a customer). Nullable so cash/transfer
    # and the refund/migration paths leave it empty.
    card = models.ForeignKey(
        "customers.PaymentCard",
        on_delete=models.SET_NULL,
        related_name="payments",
        blank=True,
        null=True,
    )
    # Which of the shop's bank accounts this money landed in.
    #
    # NULL is the ordinary answer and means exactly what it meant before this
    # column existed: "the shop has not said", so the money position routes it
    # to the default account of its kind. A shop that never opens a second bank
    # account never writes anything here and sees the figures it saw yesterday.
    #
    # Only a bank account is ever named. Cash goes in the drawer — there is one
    # of those per till, and the drawer already attributes it (``register_session``).
    money_account = models.ForeignKey(
        "treasury.MoneyAccount",
        on_delete=models.PROTECT,
        related_name="payments",
        blank=True,
        null=True,
    )
    # Audit + cash-drawer attribution. ``register_session`` is the session that
    # COLLECTED this payment: it defaults to the order's session at checkout, but
    # a debt invoice settled in a later shift is attributed to the COLLECTING
    # shift's drawer (see RegisterSession.cash_sales_total). ``paid_at`` is when
    # money changed hands; ``created_by`` is who recorded it.
    register_session = models.ForeignKey(
        RegisterSession,
        on_delete=models.PROTECT,
        related_name="payments",
        blank=True,
        null=True,
    )
    created_by = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.SET_NULL,
        related_name="payments_taken",
        blank=True,
        null=True,
    )
    paid_at = models.DateTimeField(default=timezone.now)

    class Meta:
        ordering = ["-created_at"]
        # Payment-mix dashboard and payment-method reports group by method over a
        # date range.
        indexes = [
            models.Index(
                fields=["method", "-created_at"],
                name="payments_method_created_idx",
            ),
            # ``paid_at`` is the money date (apps.core.money_dates): the money
            # position, its drill-down and the profit report's commission line
            # all range-scan it, and the drill-down orders by it. Without this
            # they seq-scan the busiest table in the shop.
            models.Index(
                fields=["method", "-paid_at"],
                name="payments_method_paid_idx",
            ),
            # The money position now asks the same range question once per bank
            # account ("what landed in THIS one"), so the account joins the
            # method in front of the date.
            models.Index(
                fields=["money_account", "method", "-paid_at"],
                name="payments_account_paid_idx",
            ),
        ]

    def __str__(self) -> str:
        return f"{self.method} {self.amount} for {self.order_id}"


class CardTerminal(TimeStampedModel):
    """One card machine standing on the counter, and the bank behind it.

    A shop with two terminals from two banks has always had a problem this
    system could not express: both produce "card" payments, and both were
    routed to whichever bank account happened to be the default. The owner
    reconciling a statement then found one bank's total containing the other
    bank's takings.

    The terminal id is what closes it, because it is already the one field on a
    receipt that identifies *which machine took this payment* — the same field
    the trust check reads. So the shop names its terminals once, says which
    account each one feeds, and every scanned slip routes itself.

    This model is also the single statement of which terminals the shop owns.
    ``ShopSettings.trusted_card_terminal_ids`` is kept as a MIRROR of the
    active rows (``apps.payments.terminals`` is the only writer) so that older
    clients, which know only that list, keep working — both reading it and
    PATCHing it.
    """

    # Stored normalised (upper case, no spaces) because that is the only form
    # two spellings of the same machine can be compared in. See
    # ``card_receipts.ocr.normalize_terminal_id``.
    terminal_id = models.CharField(max_length=64, unique=True)
    # What the cashier calls it — "الصندوق الأمامي", "ماكينة الجمهورية". Blank
    # is fine; the id is shown then.
    label = models.CharField(max_length=120, blank=True)
    # The bank account this machine settles into. NULL means "not said yet",
    # which routes exactly as it did before: to the default bank account.
    money_account = models.ForeignKey(
        "treasury.MoneyAccount",
        on_delete=models.SET_NULL,
        related_name="card_terminals",
        blank=True,
        null=True,
    )
    is_active = models.BooleanField(default=True)
    display_order = models.PositiveIntegerField(default=0)

    class Meta:
        ordering = ["display_order", "terminal_id"]

    def __str__(self) -> str:
        return self.label or self.terminal_id

    @property
    def display_name(self) -> str:
        return self.label or self.terminal_id


class MoamalatLink(TimeStampedModel):
    """The shop's link to its Moamalat merchant-portal account (one row).

    Holds a live portal token so card payments can be checked against the
    terminal's own transactions as they happen. The token is a ~15-minute
    sliding session with no refresh and an OTP on every login, so it is kept
    warm by two independent holders — this backend and the relay — on their own
    clocks (``tools/moamalat-capture/TOKEN_CUSTODY_DESIGN.md``,
    ``apps.payments.moamalat``).

    Only the username is kept. **The password is never stored**: OTP is
    mandatory on every login, so a stored password would buy nothing unattended
    and would only be a secret at rest. The token lives sealed in
    ``secrets_encrypted``; ``token_id`` is its name on both holders — every
    state change is compare-and-set on it, so an answer about a replaced token
    is dropped.
    """

    class State(models.TextChoices):
        UNLINKED = "unlinked", "Unlinked"
        ALIVE = "alive", "Alive"
        NEEDS_REAUTH = "needs_reauth", "Needs re-link"

    username = models.CharField(max_length=120, blank=True)
    mid = models.CharField(max_length=32, blank=True)
    merchant_name = models.CharField(max_length=200, blank=True)
    # The token, and an OTP challenge in flight; sealed (SecretBox).
    secrets_encrypted = models.TextField(blank=True, default="")
    token_id = models.CharField(max_length=64, blank=True)
    state = models.CharField(max_length=16, choices=State.choices, default=State.UNLINKED)
    linked_by = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.SET_NULL,
        related_name="+",
        blank=True,
        null=True,
    )
    linked_at = models.DateTimeField(blank=True, null=True)
    # Card payments from here on are checked. Set at the first link and kept
    # across re-links, so payments taken while the token was dead are still
    # swept once it lives again.
    verify_since = models.DateTimeField(blank=True, null=True)
    # This backend's own keepalive, on this backend's own clock.
    last_ok_at = models.DateTimeField(blank=True, null=True)
    last_attempt_at = models.DateTimeField(blank=True, null=True)
    failures = models.PositiveIntegerField(default=0)
    last_error = models.CharField(max_length=300, blank=True)
    next_poke_at = models.DateTimeField(blank=True, null=True)
    died_at = models.DateTimeField(blank=True, null=True)
    # Who saw the token die: "backend" or "relay".
    death_source = models.CharField(max_length=16, blank=True)
    # The relay's copy, as last read: which token it holds and its state.
    relay_token_id = models.CharField(max_length=64, blank=True)
    relay_state = models.CharField(max_length=16, blank=True)
    relay_last_ok_at = models.DateTimeField(blank=True, null=True)
    relay_checked_at = models.DateTimeField(blank=True, null=True)
    relay_error = models.CharField(max_length=300, blank=True)
    # A till has a checkout open: poll every few seconds until then.
    hot_until = models.DateTimeField(blank=True, null=True)
    # When the current hot stretch began: no stretch outlives
    # ``watch.MAX_HOT_STRETCH`` from here, whatever the tills keep asking.
    hot_since = models.DateTimeField(blank=True, null=True)
    last_fetch_at = models.DateTimeField(blank=True, null=True)
    last_fetch_error = models.CharField(max_length=300, blank=True)

    class Meta:
        permissions = [
            ("manage_moamalat_link", "Can link the shop's Moamalat merchant account"),
        ]

    def __str__(self) -> str:
        return f"Moamalat {self.mid or '-'} ({self.state})"


class MoamalatTransaction(TimeStampedModel):
    """One card transaction as the shop's Moamalat account reports it.

    Read from the portal's transaction list (``/transformerch``) and matched to
    the card payment it proves. The RRN is the processor's own unique id, so a
    transaction can prove at most one payment.
    """

    rrn = models.CharField(max_length=32, unique=True)
    mid = models.CharField(max_length=32, blank=True)
    terminal_id = models.CharField(max_length=32, blank=True)
    amount = models.DecimalField(max_digits=12, decimal_places=3)
    # The terminal's local sale time, read in the shop's business timezone.
    transaction_at = models.DateTimeField()
    processing_date = models.DateField(blank=True, null=True)
    settlement_amount = models.DecimalField(max_digits=12, decimal_places=3, blank=True, null=True)
    transaction_type = models.CharField(max_length=16, blank=True)
    card_mask = models.CharField(max_length=32, blank=True)
    payment = models.OneToOneField(
        Payment,
        on_delete=models.SET_NULL,
        related_name="moamalat_transaction",
        blank=True,
        null=True,
    )
    matched_at = models.DateTimeField(blank=True, null=True)

    class Meta:
        ordering = ["-transaction_at"]
        indexes = [
            models.Index(fields=["payment", "-transaction_at"], name="payments_moamalat_open_idx"),
        ]

    def __str__(self) -> str:
        return f"{self.rrn} {self.amount}"
