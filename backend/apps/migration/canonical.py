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
from datetime import datetime
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


@dataclass
class CanonicalPayment(CanonicalRecord):
    sale_source_key: str = ""
    method: str = "cash"  # cash | card | transfer
    amount: Decimal = Decimal("0")
    occurred_at: datetime | None = None


@dataclass
class CanonicalPurchaseLine:
    variant_source_key: str
    quantity: int = 1
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
class CanonicalEmployee(CanonicalRecord):
    full_name: str = ""
    phone: str = ""
    email: str = ""
    job_title: str = ""
    department: str = ""
    employment_type: str = "full_time"
    status: str = "active"


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
