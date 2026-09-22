"""The ordered plan of what gets migrated, and in what order.

``ENTITY_PLAN`` is the single source of truth for dependency ordering. The
engine walks it top-to-bottom so a record's foreign keys are always resolvable
by the time it loads (categories before products, variants before stock,
customers/suppliers before sales/POs, …). The order is asserted to be a valid
topological sort at import time, so a future edit that puts an entity before its
dependency fails loudly rather than at runtime.

Entity-type strings are the contract shared by connectors (``supported_entities``),
loaders (``LOADER_REGISTRY`` keys), the engine, and the run's
``selected_entities``. Keep them stable.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from . import canonical

# --- entity-type constants ---------------------------------------------------
UNIT = "unit"
CATEGORY = "category"
PRODUCT = "product"
VARIANT = "variant"
STOCK = "stock"
CUSTOMER = "customer"
SUPPLIER = "supplier"
PURCHASE_ORDER = "purchase_order"
SALE = "sale"
PAYMENT = "payment"
EMPLOYEE = "employee"
EXPENSE = "expense"
EXPENSE_CATEGORY = "expense_category"
PRODUCT_UNIT = "product_unit"
SUPPLIER_PAYMENT = "supplier_payment"
SALE_RETURN = "sale_return"
MONEY_ACCOUNT = "money_account"
PAYROLL_RUN = "payroll_run"
PARTY_BALANCE = "party_balance"


@dataclass(frozen=True)
class EntitySpec:
    entity_type: str
    label: str
    canonical: type
    dependencies: tuple[str, ...] = field(default_factory=tuple)
    # False while only the IR + a stub loader exist (transactional entities this
    # pass). Surfaced in the systems catalogue so the UI can mark them.
    implemented: bool = True


ENTITY_PLAN: tuple[EntitySpec, ...] = (
    EntitySpec(UNIT, "Units of measure", canonical.CanonicalUnit),
    EntitySpec(CATEGORY, "Categories", canonical.CanonicalCategory),
    EntitySpec(PRODUCT, "Products", canonical.CanonicalProduct, (UNIT, CATEGORY)),
    EntitySpec(VARIANT, "Product variants", canonical.CanonicalVariant, (PRODUCT,)),
    EntitySpec(
        PRODUCT_UNIT,
        "Product units",
        canonical.CanonicalProductUnit,
        (UNIT, PRODUCT),
    ),
    EntitySpec(STOCK, "Stock levels", canonical.CanonicalStock, (VARIANT,)),
    EntitySpec(CUSTOMER, "Customers", canonical.CanonicalCustomer),
    EntitySpec(SUPPLIER, "Suppliers", canonical.CanonicalSupplier),
    EntitySpec(
        PURCHASE_ORDER,
        "Purchase orders",
        canonical.CanonicalPurchaseOrder,
        (SUPPLIER, VARIANT),
    ),
    # What each party owes (or is owed) carried as a balance in its own right,
    # rather than as the arithmetic of invoices nobody asked for. Placed before
    # the transactional entities so an opening document exists before any
    # receipt tries to allocate against it.
    EntitySpec(
        PARTY_BALANCE,
        "Customer & supplier balances",
        canonical.CanonicalPartyBalance,
        (CUSTOMER, SUPPLIER),
    ),
    EntitySpec(
        SUPPLIER_PAYMENT,
        "Supplier payments",
        canonical.CanonicalSupplierPayment,
        (SUPPLIER,),
    ),
    EntitySpec(
        SALE,
        "Sales",
        canonical.CanonicalSale,
        (CUSTOMER, VARIANT),
    ),
    # Returns come off invoices, so every sale must already exist.
    EntitySpec(
        SALE_RETURN,
        "Sales returns",
        canonical.CanonicalSaleReturn,
        (SALE,),
    ),
    # Receipts settle invoices, so they follow both the sales and the returns
    # that changed what those invoices are worth.
    EntitySpec(PAYMENT, "Payments", canonical.CanonicalPayment, (SALE, CUSTOMER)),
    EntitySpec(EMPLOYEE, "Employees", canonical.CanonicalEmployee),
    EntitySpec(
        PAYROLL_RUN,
        "Payroll runs",
        canonical.CanonicalPayrollRun,
        (EMPLOYEE,),
    ),
    EntitySpec(
        EXPENSE_CATEGORY,
        "Expense categories",
        canonical.CanonicalExpenseCategory,
    ),
    EntitySpec(EXPENSE, "Expenses", canonical.CanonicalExpense, (EXPENSE_CATEGORY,)),
    EntitySpec(MONEY_ACCOUNT, "Money accounts", canonical.CanonicalMoneyAccount),
)

ENTITY_PLAN_BY_TYPE: dict[str, EntitySpec] = {spec.entity_type: spec for spec in ENTITY_PLAN}


def _assert_topologically_ordered() -> None:
    """Every dependency must appear earlier in ENTITY_PLAN than the dependant."""
    seen: set[str] = set()
    for spec in ENTITY_PLAN:
        for dependency in spec.dependencies:
            if dependency not in ENTITY_PLAN_BY_TYPE:
                raise AssertionError(
                    f"ENTITY_PLAN: {spec.entity_type!r} depends on unknown entity {dependency!r}"
                )
            if dependency not in seen:
                raise AssertionError(
                    f"ENTITY_PLAN is out of order: {spec.entity_type!r} depends "
                    f"on {dependency!r}, which must come earlier"
                )
        seen.add(spec.entity_type)


_assert_topologically_ordered()


def ordered_entities(selected: list[str] | None = None) -> list[EntitySpec]:
    """ENTITY_PLAN specs, optionally filtered to a selection, in plan order."""
    if selected is None:
        return list(ENTITY_PLAN)
    chosen = set(selected)
    return [spec for spec in ENTITY_PLAN if spec.entity_type in chosen]


def all_entity_types() -> list[str]:
    return [spec.entity_type for spec in ENTITY_PLAN]


@dataclass(frozen=True)
class Selection:
    """A requested set of entities, made coherent.

    A selection is not just a filter: ``sale`` without ``product`` is not "sales
    only", it is every sale line failing to resolve a variant. So a requested set
    is *closed* over ``EntitySpec.dependencies`` before the engine sees it, and
    what the closure had to add is reported rather than applied silently — the
    owner who ticked three boxes is owed the sentence that says a fourth came
    with them.
    """

    #: The entities that will actually run, in ENTITY_PLAN order.
    entities: tuple[str, ...]
    #: What the caller asked for (minus anything unrecognised).
    requested: tuple[str, ...]
    #: Pulled in because something requested depends on them.
    added: tuple[str, ...]
    #: Names that are not entities at all.
    unknown: tuple[str, ...]

    def __contains__(self, entity_type: str) -> bool:
        return entity_type in self.entities

    def as_dict(self) -> dict:
        return {
            "entities": list(self.entities),
            "requested": list(self.requested),
            "added": list(self.added),
            "unknown": list(self.unknown),
        }


def dependency_closure(selected) -> set[str]:
    """``selected`` plus every entity it transitively depends on."""
    closed: set[str] = set()
    pending = [entity for entity in (selected or []) if entity in ENTITY_PLAN_BY_TYPE]
    while pending:
        entity = pending.pop()
        if entity in closed:
            continue
        closed.add(entity)
        pending.extend(ENTITY_PLAN_BY_TYPE[entity].dependencies)
    return closed


def resolve_selection(selected, *, available=None) -> Selection:
    """Close a requested selection over its dependencies and order it.

    ``available`` is what the source can actually produce (a connector's
    ``supported_entities``); anything outside it is dropped, because a
    dependency the file does not contain is not something we can add.
    ``selected`` of ``None`` or empty means "everything available".
    """
    universe = set(available) if available is not None else set(all_entity_types())
    requested_raw = list(selected or [])
    unknown = tuple(
        dict.fromkeys(entity for entity in requested_raw if entity not in ENTITY_PLAN_BY_TYPE)
    )
    requested = {entity for entity in requested_raw if entity in ENTITY_PLAN_BY_TYPE}
    if not requested:
        requested = set(universe)
    closed = dependency_closure(requested) & universe
    requested &= universe
    return Selection(
        entities=tuple(spec.entity_type for spec in ENTITY_PLAN if spec.entity_type in closed),
        requested=tuple(
            spec.entity_type for spec in ENTITY_PLAN if spec.entity_type in requested
        ),
        added=tuple(
            spec.entity_type
            for spec in ENTITY_PLAN
            if spec.entity_type in closed - requested
        ),
        unknown=unknown,
    )
