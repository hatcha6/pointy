"""The canonical intermediate representation (IR).

Connectors translate a vendor schema into these vendor-neutral records;
loaders translate them into Pointy rows. The IR is the contract between the two
halves, so adding a new source system means writing a connector that emits
these — and nothing else changes.

Every record carries a ``source_key``: a stable identifier for the row in the
*source* system (its primary key, code, etc.). The identity map is keyed on it,
which is what makes imports idempotent and lets later entities resolve their
foreign keys (a sale's customer/variant) to already-imported Pointy ids.

Cross-entity references are expressed as ``*_source_key`` fields — never as
Pointy ids — because at extract time the destination ids do not exist yet.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import date, datetime
from decimal import Decimal


@dataclass
class CanonicalRecord:
    #: Stable identifier of this row in the source system.
    source_key: str
    #: The untouched source row, for diagnostics / issue detail.
    raw: dict = field(default_factory=dict, repr=False)


# --- master data -------------------------------------------------------------


@dataclass
class CanonicalUnit(CanonicalRecord):
    code: str = ""
    name: str = ""
    abbreviation: str = ""
    dimension: str = "count"  # count | weight | volume | length
    allows_fractional: bool = False


@dataclass
class CanonicalCategory(CanonicalRecord):
    name: str = ""
    parent_source_key: str | None = None
    description: str = ""
    is_active: bool = True


@dataclass
class CanonicalProduct(CanonicalRecord):
    name: str = ""
    description: str = ""
    unit: str = "piece"
    is_active: bool = True
    is_service: bool = False
    is_prepared: bool = False
    category_source_keys: list[str] = field(default_factory=list)
    # When the source has no separate variant table, these product-level fields
    # seed a default variant (see the catalog loader).
    sku: str = ""
    barcode: str = ""
    unit_price: Decimal | None = None


@dataclass
class CanonicalVariant(CanonicalRecord):
    product_source_key: str = ""
    sku: str = ""
    unit_price: Decimal = Decimal("0")
    name: str = ""
    barcode: str = ""
    is_active: bool = True
    is_default: bool = False


@dataclass
class CanonicalStock(CanonicalRecord):
    variant_source_key: str = ""
    quantity_on_hand: Decimal = Decimal("0")
    reorder_level: int | None = None
    #: Cost of one **base unit**, when the source knows it — a moving-average or
    #: last-purchase cost off the item card.
    #:
    #: Without this an imported shop starts with stock it cannot value: the
    #: valuation ledger has no opening balance, so the first sale of every
    #: product falls through to the last-purchase fallback and reports a profit
    #: equal to the whole selling price. The quantity alone was never the whole
    #: of "this is what the shop has".
    unit_cost: Decimal | None = None


@dataclass
class CanonicalProductUnit(CanonicalRecord):
    """An extra sellable/purchasable unit for a product (box, carton, …) with
    its conversion to the base unit and an optional own price."""

    product_source_key: str = ""
    unit_source_key: str = ""
    factor_to_base: Decimal = Decimal("1")
    price: Decimal | None = None
    is_sellable: bool = True
    is_purchasable: bool = True
    display_order: int = 0
    #: Packaging barcodes (the carton EAN) that ring up this unit when scanned.
    barcodes: list[str] = field(default_factory=list)
    #: Make this unit the product's pre-selected purchasing unit (only applied
    #: when the product has no default purchase unit yet).
    set_default_purchase: bool = False


@dataclass
class CanonicalCustomer(CanonicalRecord):
    full_name: str = ""
    phone: str = ""
    email: str = ""
    notes: str = ""
    is_active: bool = True


@dataclass
class CanonicalSupplier(CanonicalRecord):
    name: str = ""
    contact_name: str = ""
    phone: str = ""
    email: str = ""
    address: str = ""
    notes: str = ""
    is_active: bool = True


@dataclass
class CanonicalPartyBalance(CanonicalRecord):
    """What a customer owes the shop, or the shop owes a supplier, as a figure.

    Legacy systems keep two numbers per party: the balance they were opened
    with, and the balance they stand at now. Which one Pointy should start them
    on depends entirely on whether the documents in between are being imported:

    * bringing the history over → carry the **opening** balance, and let the
      invoices and receipts move it to today's figure themselves;
    * leaving the history behind → carry the **current** balance, because
      nothing else is coming that would ever move it.

    Getting that backwards is silent and expensive — a shop that imports only
    its parties and gets ``opening`` starts every customer on a debt from years
    ago, and one that imports the full history and gets ``current`` counts every
    invoice twice. So the basis is chosen from the run's scope (see
    ``scopes.resolve_party_balance_basis``), recorded on the record, and
    reported in the run summary rather than assumed.
    """

    #: ``customer`` or ``supplier``.
    party_kind: str = "customer"
    party_source_key: str = ""
    #: Always positive; ``party_kind`` is the side. A customer's amount is what
    #: they owe the shop (receivable); a supplier's is what the shop owes them.
    amount: Decimal = Decimal("0")
    #: When the balance is struck. Dated before the shop's history so an
    #: inherited debt does not read as having been incurred this morning.
    as_of: datetime | None = None
    #: ``opening`` or ``current`` — which of the source's two figures this is.
    basis: str = "opening"
    #: For the issue log, so a problem names a person and not a key.
    party_name: str = ""


# --- transactional ----------------------------------------------------------


@dataclass
class CanonicalSaleLine:
    variant_source_key: str
    quantity: Decimal = Decimal("1")
    unit_price: Decimal = Decimal("0")
    unit_cost: Decimal = Decimal("0")
    discount_total: Decimal = Decimal("0")
    notes: str = ""


@dataclass
class CanonicalSale(CanonicalRecord):
    customer_source_key: str | None = None
    receipt_number: str = ""
    status: str = "paid"  # open | paid | void
    discount_total: Decimal = Decimal("0")
    payment_method: str = "cash"  # cash | card | transfer
    occurred_at: datetime | None = None
    lines: list[CanonicalSaleLine] = field(default_factory=list)
    #: ``standard`` (paid at the counter) or ``credit`` (آجل — issued unpaid or
    #: part-paid, and owed). A source that settles on the customer's *account*
    #: rather than per invoice is why this is not inferred from ``amount_paid``:
    #: an آجل invoice with nothing yet received against it and a cash sale that
    #: was paid in full are both "one payment short of settled" arithmetically,
    #: and only the source knows which one it is.
    sale_type: str = "standard"  # standard | credit
    #: How much was actually taken against this invoice. ``None`` means "settled
    #: in full", which keeps every existing connector's behaviour unchanged.
    amount_paid: Decimal | None = None
    #: When a credit invoice falls due. Ignored for a standard sale.
    due_date: date | None = None


@dataclass
class CanonicalPayment(CanonicalRecord):
    #: Either a payment against one invoice (``sale_source_key``) or a receipt
    #: against a customer's *account* (``customer_source_key``), which is how
    #: every legacy system that posts to a party ledger records one. An account
    #: receipt is allocated across that customer's open credit invoices, oldest
    #: first, by the loader.
    sale_source_key: str = ""
    customer_source_key: str | None = None
    method: str = "cash"  # cash | card | transfer
    amount: Decimal = Decimal("0")
    occurred_at: datetime | None = None
    reference: str = ""


@dataclass
class CanonicalSaleReturnLine:
    variant_source_key: str
    quantity: Decimal = Decimal("1")
    unit_price: Decimal = Decimal("0")


@dataclass
class CanonicalSaleReturn(CanonicalRecord):
    """Goods coming back off a sale that was already imported.

    Pointy hangs a return on the invoice it reverses, so ``sale_source_key`` is
    required — a source that files returns as standalone documents has to say
    which sale each one belongs to (matching them is the connector's job, and
    the connector is the only thing that knows how its own system files them).
    """

    sale_source_key: str = ""
    occurred_at: datetime | None = None
    reason: str = ""
    refund_method: str = "cash"
    lines: list[CanonicalSaleReturnLine] = field(default_factory=list)


@dataclass
class CanonicalMoneyAccount(CanonicalRecord):
    """A drawer, safe or bank account the shop keeps money in.

    Only the *opening* balance is carried. Every movement after it already
    arrives as a sale, an expense or a supplier payment, and ``apps.treasury``
    derives the balance from those — so importing a source's own running total
    on top would state the same dinars twice.
    """

    name: str = ""
    kind: str = "cash"  # cash | bank
    opening_balance: Decimal = Decimal("0")
    opening_at: date | None = None
    is_default: bool = False
    is_active: bool = True
    notes: str = ""


@dataclass
class CanonicalPurchaseLine:
    variant_source_key: str
    # Decimal, like CanonicalSaleLine: PurchaseLine.quantity is Decimal(12, 3)
    # so fractional units (half a tray, 2.5 kg) are a real purchase.
    quantity: Decimal = Decimal("1")
    unit_cost: Decimal = Decimal("0")


@dataclass
class CanonicalPurchaseOrder(CanonicalRecord):
    supplier_source_key: str = ""
    status: str = "received"
    supplier_invoice_number: str = ""
    discount_total: Decimal = Decimal("0")
    occurred_at: datetime | None = None
    lines: list[CanonicalPurchaseLine] = field(default_factory=list)


@dataclass
class CanonicalSupplierPayment(CanonicalRecord):
    supplier_source_key: str = ""
    amount: Decimal = Decimal("0")
    method: str = "cash"  # cash | card | transfer | bank_transfer | …
    reference: str = ""
    notes: str = ""
    occurred_at: datetime | None = None


@dataclass
class CanonicalEmployee(CanonicalRecord):
    full_name: str = ""
    phone: str = ""
    email: str = ""
    job_title: str = ""
    department: str = ""
    employment_type: str = "full_time"
    status: str = "active"
    hire_date: date | None = None
    notes: str = ""
    #: What this person is paid. Present means the loader also writes a
    #: compensation plan, because an employee with no pay rate is a contact
    #: card: payroll cannot run for them, which is the reason to import them.
    pay_amount: Decimal | None = None
    pay_type: str = "monthly_salary"
    salary_type: str = "monthly_fixed"
    #: Hourly rate and standard day, when the source keeps them alongside the
    #: monthly figure.
    standard_daily_hours: Decimal | None = None


@dataclass
class CanonicalPayrollLine:
    employee_source_key: str
    gross_amount: Decimal = Decimal("0")
    additions: Decimal = Decimal("0")
    deductions: Decimal = Decimal("0")
    net_amount: Decimal = Decimal("0")
    description: str = ""


@dataclass
class CanonicalPayrollRun(CanonicalRecord):
    period_start: date | None = None
    period_end: date | None = None
    payment_date: date | None = None
    notes: str = ""
    lines: list[CanonicalPayrollLine] = field(default_factory=list)


@dataclass
class CanonicalExpenseCategory(CanonicalRecord):
    name: str = ""
    is_active: bool = True


@dataclass
class CanonicalExpense(CanonicalRecord):
    category_name: str = ""
    description: str = ""
    amount: Decimal = Decimal("0")
    payment_method: str = "cash"
    occurred_at: datetime | None = None
    reference: str = ""
