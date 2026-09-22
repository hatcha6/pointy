"""Loader registry — one loader per entity type.

The registry is the engine's single lookup from ``entity_type`` to its loader.
Every entity in ``ENTITY_PLAN`` has a real loader; a source that carries
something none of them covers is a missing *connector* mapping, not a missing
loader.
"""

from __future__ import annotations

from .base import BaseLoader, LoaderError, LoadOutcome
from .catalog import (
    CategoryLoader,
    ProductLoader,
    ProductUnitLoader,
    UnitLoader,
    VariantLoader,
)
from .customers import CustomerLoader
from .employees import EmployeeLoader, PayrollRunLoader
from .expenses import ExpenseCategoryLoader, ExpenseLoader
from .inventory import StockLoader
from .parties import PartyBalanceLoader
from .purchasing import PurchaseOrderLoader, SupplierLoader, SupplierPaymentLoader
from .sales import PaymentLoader, SaleLoader, SaleReturnLoader
from .treasury import MoneyAccountLoader

_LOADER_CLASSES = (
    # master data
    UnitLoader,
    CategoryLoader,
    ProductLoader,
    VariantLoader,
    ProductUnitLoader,
    StockLoader,
    CustomerLoader,
    SupplierLoader,
    ExpenseCategoryLoader,
    EmployeeLoader,
    MoneyAccountLoader,
    # transactional
    PartyBalanceLoader,
    PurchaseOrderLoader,
    SupplierPaymentLoader,
    SaleLoader,
    SaleReturnLoader,
    PaymentLoader,
    ExpenseLoader,
    PayrollRunLoader,
)

LOADER_REGISTRY: dict[str, BaseLoader] = {
    loader_class.entity_type: loader_class() for loader_class in _LOADER_CLASSES
}


def get_loader(entity_type: str) -> BaseLoader | None:
    return LOADER_REGISTRY.get(entity_type)


__all__ = [
    "BaseLoader",
    "LoaderError",
    "LoadOutcome",
    "LOADER_REGISTRY",
    "get_loader",
]
