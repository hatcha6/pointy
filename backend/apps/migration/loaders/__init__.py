"""Loader registry — one loader per entity type.

Master-data loaders are fully implemented; transactional loaders are stubs that
raise a clear "not supported yet" per record until a real source dump arrives.
The registry is the engine's single lookup from ``entity_type`` to its loader.
"""

from __future__ import annotations

from .base import BaseLoader, LoaderError, LoadOutcome
from .catalog import CategoryLoader, ProductLoader, UnitLoader, VariantLoader
from .customers import CustomerLoader
from .employees import EmployeeLoader
from .expenses import ExpenseLoader
from .inventory import StockLoader
from .purchasing import PurchaseOrderLoader, SupplierLoader
from .sales import PaymentLoader, SaleLoader

_LOADER_CLASSES = (
    # master data (implemented)
    UnitLoader,
    CategoryLoader,
    ProductLoader,
    VariantLoader,
    StockLoader,
    CustomerLoader,
    SupplierLoader,
    # transactional (stubs)
    PurchaseOrderLoader,
    SaleLoader,
    PaymentLoader,
    EmployeeLoader,
    ExpenseLoader,
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
