"""Employee loader.

Stub this pass. Implement with direct ORM ``update_or_create`` on
``apps.employees.models.Employee`` keyed via the resolver; ``employee_number``
is auto-generated, so never match on it. Compensation plans / payroll history
can follow as their own entities once a source shape is known.
"""

from __future__ import annotations

from ..entity_plan import EMPLOYEE
from .base import NotImplementedLoader


class EmployeeLoader(NotImplementedLoader):
    entity_type = EMPLOYEE
