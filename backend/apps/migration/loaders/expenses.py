"""Expense loader.

Stub this pass. Implement with direct ORM writes against
``apps.expenses.models.Expense``, ``get_or_create``-ing the ``ExpenseCategory``
by name first (FK is PROTECT). Do not link a register cash movement for
historical expenses.
"""

from __future__ import annotations

from ..entity_plan import EXPENSE
from .base import NotImplementedLoader


class ExpenseLoader(NotImplementedLoader):
    entity_type = EXPENSE
