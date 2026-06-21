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
    EntitySpec(
        SALE,
        "Sales",
        canonical.CanonicalSale,
        (CUSTOMER, VARIANT),
    ),
    EntitySpec(PAYMENT, "Payments", canonical.CanonicalPayment, (SALE,), implemented=False),
    EntitySpec(EMPLOYEE, "Employees", canonical.CanonicalEmployee, implemented=False),
    EntitySpec(
        EXPENSE_CATEGORY,
        "Expense categories",
        canonical.CanonicalExpenseCategory,
    ),
    EntitySpec(EXPENSE, "Expenses", canonical.CanonicalExpense, (EXPENSE_CATEGORY,)),
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
