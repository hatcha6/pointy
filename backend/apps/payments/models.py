from django.conf import settings
from django.db import models
from django.core.validators import MinValueValidator
from django.utils import timezone

from apps.core.models import TimeStampedModel
from apps.documents.guards import DocumentQuerySetMixin
from apps.documents.models import DocumentMixin
from apps.sales.models import Order, RegisterSession


class PaymentQuerySet(DocumentQuerySetMixin, models.QuerySet):
    def money_received(self):
        """Payments that brought money in: every tender but a salary deduction.

        A salary deduction settles a staff purchase out of the employee's wages
        and puts nothing in a drawer or a bank, so a figure that means "what
        customers paid us" leaves it out. Balances and statements do not — to an
        invoice it is as much a payment as cash.
        """
        return self.exclude(method=Payment.Method.SALARY_DEDUCTION)


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

    #: What a till can take: every method but the one only payroll writes.
    TILL_METHODS = (Method.CASH, Method.CARD, Method.TRANSFER)

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
