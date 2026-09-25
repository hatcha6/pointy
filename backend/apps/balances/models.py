"""What a customer, a supplier or an employee owes, when no document can say so.

A receivable in this system is the sum of the آجل invoices nobody has settled,
and a payable the sum of the unpaid purchase orders. That is the right rule and
it stays the rule — but it leaves no way to write down a debt that has no
document behind it: the balance a customer carried over from the paper ledger
the day the shop started using Pointy, the money a supplier was advanced before
anyone typed him in, a service done for a customer that is not on the price
list. Shops kept those on paper beside the system, which is exactly the
second ledger the system exists to replace.

A **balance entry** is that debt as a document of its own. It says who, which
way (they owe us, or we owe them), how much, from what day, and why. It is
numbered, it names the person who wrote it, it is never edited, and it is
retracted only by cancelling it with a reason — and only while nothing has been
settled against it. After that, the correction is a second entry the other way,
which is how a ledger has always been put right.

What an entry is **not**: a sale, a purchase, stock, or money. It never reaches
revenue, cost, the drawer or the bank. It changes one thing — what a party owes
— and every figure that states what a party owes reads it.

How each direction is carried, and why they differ:

* **A customer who owes us** is carried on an ``Order`` of the non-sale type
  ``ACCOUNT_ENTRY`` (see ``sales.Order.SaleType``). A payment must name an
  order, and this debt has to be collectable at the till, by the same dialog,
  into the same drawer, with the same proof of payment, as an آجل invoice.
* **A customer we owe** is credit, spent automatically against whatever they
  owe (``customers.apply_customer_credit``) through non-money
  ``ACCOUNT_CREDIT`` payments. What is left of it is derived from its
  :class:`CustomerCreditApplication` rows, never stored.
* **A supplier we owe** is an open item that supplier payments settle directly
  (``SupplierPayment.balance_entry``).
* **A supplier who owes us** is a ``SupplierCredit`` — the note the shop already
  spends against purchase orders — so the purchase-order payment dialog offers
  it with no change at all.
* **An employee, either way,** is settled by payroll: the next run pays what
  the shop owes them and deducts what they owe it
  (``employees.PayrollAdjustment.AdjustmentType.ACCOUNT_BALANCE``), and what is
  left of an entry is derived from the paid runs and the cash settlements that
  name it (:class:`EmployeeBalanceAllocation`), never stored.

And a balance someone is owed can be settled with money, not only against the
next invoice: a **refund** entry hands a customer the credit the shop holds
for them in cash, or takes in the cash a supplier pays back. It is the one
kind of entry that moves money, so it carries the drawer movement that moved
it (``cash_movement``) — the drawer, the money position and the Z-report all
see the cash through that row — and, like any payment, it is final once made.
"""

from decimal import Decimal

from django.conf import settings
from django.core.validators import MinValueValidator
from django.db import models, transaction
from django.utils import timezone

from apps.core.models import TimeStampedModel
from apps.documents.guards import DocumentQuerySetMixin
from apps.documents.models import DocumentMixin

MONEY = Decimal("0.01")


class BalanceEntryQuerySet(DocumentQuerySetMixin, models.QuerySet):
    pass


class BalanceEntry(DocumentMixin, TimeStampedModel):
    """Fields and numbering shared by both sides. Abstract."""

    class Kind(models.TextChoices):
        #: The position the party was in when the shop started keeping its
        #: books here. At most one live one per party.
        OPENING = "opening", "Opening balance"
        #: A later correction for something no invoice could carry.
        ADJUSTMENT = "adjustment", "Balance adjustment"
        #: A balance settled with money: the shop paying a customer the credit
        #: it held for them, or a supplier paying back what they owed. Written
        #: only by the refund services, with its drawer movement.
        REFUND = "refund", "Refund"

    class Direction(models.TextChoices):
        # Named from the shop's side, the way an owner says it — "عليه لنا" and
        # "له علينا" — rather than debit and credit, which flip meaning between
        # a customer's account and a supplier's and have caught out every
        # reader who met them there.
        THEY_OWE_US = "they_owe_us", "They owe us"
        WE_OWE_THEM = "we_owe_them", "We owe them"

    #: ``B{date}{n}`` from ``PARTY_BALANCE_SERIES`` — gapless, like every
    #: numbered document here, and shared by both sides so one number names
    #: one entry.
    number = models.CharField(max_length=32, unique=True, blank=True)
    kind = models.CharField(max_length=16, choices=Kind.choices)
    direction = models.CharField(max_length=16, choices=Direction.choices)
    # Ten digits, like every money column it becomes part of: the carrier
    # order's total, a supplier credit, a supplier payment.
    amount = models.DecimalField(
        max_digits=10,
        decimal_places=2,
        validators=[MinValueValidator(MONEY)],
    )
    #: The day the balance applies from — the money date (``apps.core.money_dates``).
    #: An opening balance is usually dated the day the shop started, which may
    #: be before the entry was typed; it can never be in the future, and a date
    #: inside a closed period is refused like any other write there.
    effective_date = models.DateField()
    #: Why. Required for an adjustment: a debt with no reason attached is the
    #: exact thing an owner cannot explain to the customer holding the
    #: statement.
    note = models.TextField(blank=True)
    created_by = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.SET_NULL,
        related_name="%(app_label)s_%(class)s_created",
        blank=True,
        null=True,
    )

    class Meta:
        abstract = True
        ordering = ["-effective_date", "-id"]

    def __str__(self) -> str:
        return self.number or f"{self._meta.verbose_name} {self.pk}"

    @property
    def signed_amount(self) -> Decimal:
        """Positive when the party owes the shop, negative when the shop owes
        them — the sign every balance in this app is stated in."""
        if self.direction == self.Direction.THEY_OWE_US:
            return self.amount
        return -self.amount

    def save(self, *args, **kwargs):
        if self.number:
            return super().save(*args, **kwargs)
        # The number and the row it belongs to are written as one unit, so a
        # write that fails gives its number back (``apps.documents.numbering``).
        from apps.documents.numbering import (
            PARTY_BALANCE_SERIES,
            next_document_number,
        )

        with transaction.atomic():
            issued_at = self.created_at or timezone.now()
            self.number = (
                f"B{issued_at:%Y%m%d}"
                f"{next_document_number(PARTY_BALANCE_SERIES):06d}"
            )
            update_fields = kwargs.get("update_fields")
            if update_fields is not None and "number" not in update_fields:
                kwargs["update_fields"] = [*update_fields, "number"]
            return super().save(*args, **kwargs)


class CustomerBalanceEntry(BalanceEntry):
    customer = models.ForeignKey(
        "customers.Customer",
        on_delete=models.PROTECT,
        related_name="balance_entries",
    )
    # Set exactly when the customer owes us: the ``ACCOUNT_ENTRY`` order that
    # carries the debt, so the till can collect it. Null for credit.
    order = models.OneToOneField(
        "sales.Order",
        on_delete=models.PROTECT,
        related_name="balance_entry",
        blank=True,
        null=True,
    )
    # A refund's cash leaving the drawer. Linked so the expenses ledger can
    # leave it out — handing a customer money the shop owed them is not the
    # shop spending money.
    cash_movement = models.OneToOneField(
        "sales.RegisterCashMovement",
        on_delete=models.PROTECT,
        related_name="customer_balance_entry",
        blank=True,
        null=True,
    )

    objects = BalanceEntryQuerySet.as_manager()

    class Meta(BalanceEntry.Meta):
        verbose_name = "customer balance entry"
        verbose_name_plural = "customer balance entries"
        permissions = [
            (
                "cancel_customerbalanceentry",
                "Cancel an opening balance or adjustment on a customer's account",
            ),
        ]
        indexes = [
            # "What credit does this customer still hold?" — asked on every
            # account collection and every آجل sale to a customer with credit.
            models.Index(
                fields=["customer", "direction", "doc_status"],
                name="balances_customer_open_idx",
            ),
        ]


class CustomerCreditApplication(TimeStampedModel):
    """Credit the shop owed a customer, spent against something they owed.

    One row per payment it produced: an ``ACCOUNT_CREDIT`` payment on the debt
    (an invoice or an account entry), for exactly this amount. The link is what
    makes the credit's remainder a derivation — the entry's amount less what
    its applications have spent — rather than a stored figure that has to be
    kept in step by hand, and it is the audit answer to "which invoice did that
    credit go to?".

    Never edited or deleted. A credit-funded invoice that is later returned
    gives the goods' value back in cash (``sales.services.refund_tender``); the
    application stays, because the credit was genuinely spent.
    """

    entry = models.ForeignKey(
        CustomerBalanceEntry,
        on_delete=models.PROTECT,
        related_name="applications",
    )
    payment = models.OneToOneField(
        "payments.Payment",
        on_delete=models.PROTECT,
        related_name="credit_application",
    )
    amount = models.DecimalField(
        max_digits=10,
        decimal_places=2,
        validators=[MinValueValidator(MONEY)],
    )

    class Meta:
        ordering = ["created_at", "id"]

    def __str__(self) -> str:
        return f"{self.amount} of {self.entry_id} -> payment {self.payment_id}"


class SupplierBalanceEntry(BalanceEntry):
    supplier = models.ForeignKey(
        "purchasing.Supplier",
        on_delete=models.PROTECT,
        related_name="balance_entries",
    )
    # A refund's cash coming into the drawer from the supplier.
    cash_movement = models.OneToOneField(
        "sales.RegisterCashMovement",
        on_delete=models.PROTECT,
        related_name="supplier_balance_entry",
        blank=True,
        null=True,
    )

    objects = BalanceEntryQuerySet.as_manager()

    class Meta(BalanceEntry.Meta):
        verbose_name = "supplier balance entry"
        verbose_name_plural = "supplier balance entries"
        permissions = [
            (
                "cancel_supplierbalanceentry",
                "Cancel an opening balance or adjustment on a supplier's account",
            ),
        ]
        indexes = [
            models.Index(
                fields=["supplier", "direction", "doc_status"],
                name="balances_supplier_open_idx",
            ),
        ]


class EmployeeBalanceEntry(BalanceEntry):
    """A balance on an employee's account, settled through payroll.

    The next payroll run pays what the shop owes and deducts what the employee
    owes (``apps.balances.employees.refresh_payroll_balance_adjustments``);
    paying the run is what settles it, and voiding the run gives it back. Cash
    can settle it too, through a drawer, like a customer's refund.
    """

    employee = models.ForeignKey(
        "employees.Employee",
        on_delete=models.PROTECT,
        related_name="balance_entries",
    )
    #: The most one payroll run deducts from a debt the employee owes; empty
    #: means as much as the pay can carry. The instalment of a loan, for a
    #: debt that is not one — a large opening balance against a small wage
    #: would otherwise take a whole month's pay.
    payroll_deduction_limit = models.DecimalField(
        max_digits=10,
        decimal_places=2,
        blank=True,
        null=True,
        validators=[MinValueValidator(MONEY)],
    )
    # A cash settlement's money moving through the drawer: out when the shop
    # pays the employee what it owed them, in when the employee pays back.
    cash_movement = models.OneToOneField(
        "sales.RegisterCashMovement",
        on_delete=models.PROTECT,
        related_name="employee_balance_entry",
        blank=True,
        null=True,
    )

    objects = BalanceEntryQuerySet.as_manager()

    class Meta(BalanceEntry.Meta):
        verbose_name = "employee balance entry"
        verbose_name_plural = "employee balance entries"
        permissions = [
            (
                "cancel_employeebalanceentry",
                "Cancel an opening balance or adjustment on an employee's account",
            ),
        ]
        indexes = [
            # "What is still open on this employee's account?" — asked for every
            # line of every payroll run that is drafted, approved or paid.
            models.Index(
                fields=["employee", "direction", "doc_status"],
                name="balances_employee_open_idx",
            ),
        ]


class EmployeeBalanceAllocation(TimeStampedModel):
    """Part of a cash settlement, set against one entry it settled.

    A settlement is taken oldest entry first, and each row says how much of
    it went to which entry — so an entry's remainder is a derivation (its
    amount less its paid payroll deductions or additions and its cash
    allocations), and "which debt did that cash pay?" has an answer. Never
    edited or deleted: the settlement moved money and is final.
    """

    entry = models.ForeignKey(
        EmployeeBalanceEntry,
        on_delete=models.PROTECT,
        related_name="cash_settlements",
    )
    #: The ``refund``-kind entry that carries the cash.
    refund = models.ForeignKey(
        EmployeeBalanceEntry,
        on_delete=models.PROTECT,
        related_name="allocations",
    )
    amount = models.DecimalField(
        max_digits=10,
        decimal_places=2,
        validators=[MinValueValidator(MONEY)],
    )

    class Meta:
        ordering = ["created_at", "id"]

    def __str__(self) -> str:
        return f"{self.amount} of {self.entry_id} by {self.refund_id}"
