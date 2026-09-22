"""Loader contract + shared helpers.

A loader translates one canonical record into a Pointy row, idempotently. The
single policy across every loader:

* **Write path** — direct ORM ``update_or_create`` keyed on the identity-map
  resolved row (falling back to a declared natural key on first insert). Writes
  never go through DRF viewsets/services, which would re-trigger number
  autogeneration / uniqueness validators or live side effects (stock movements,
  discount usage) that are wrong for a historical import.
* **Idempotency / FK resolution** — via the :class:`IdentityResolver`. Loaders
  call ``resolver.existing(...)`` to find the row a re-run should update and
  ``resolver.remember(...)`` to record what a source key became.
* **Dry run** — loaders are mode-agnostic. The engine runs the whole dry run
  inside a transaction it rolls back, so a loader's real ORM writes give genuine
  DB-constraint + FK checks without persisting anything; ``resolver.remember``
  keeps an in-memory shadow so children still resolve.

A loader returns a :class:`LoadOutcome` on success (optionally carrying warning
issues) and raises :class:`LoaderError` for a per-record failure; the engine
turns either into the run summary + ``MigrationIssue`` rows.
"""

from __future__ import annotations

import abc
from dataclasses import dataclass, field
from decimal import Decimal, InvalidOperation

# Outcome actions (also the keys in MigrationRun.summary[entity]).
CREATED = "created"
UPDATED = "updated"
SKIPPED = "skipped"
FAILED = "failed"

WARNING = "warning"
ERROR = "error"


@dataclass
class Issue:
    severity: str
    code: str
    message: str
    source_key: str = ""
    detail: dict = field(default_factory=dict)


@dataclass
class LoadOutcome:
    action: str
    target_pk: int | None = None
    issues: list[Issue] = field(default_factory=list)


class LoaderError(Exception):
    """A single record could not be loaded; the engine records it as an error."""

    def __init__(self, message: str, *, code: str = "load_error", detail: dict | None = None):
        super().__init__(message)
        self.code = code
        self.detail = detail or {}


class BaseLoader(abc.ABC):
    entity_type: str = ""
    implemented: bool = True

    @abc.abstractmethod
    def load(self, record, resolver, *, dry_run: bool) -> LoadOutcome: ...


class NotImplementedLoader(BaseLoader):
    """Placeholder for entities whose loader lands when a real dump arrives.

    The IR and ordering already exist, so filling these in later is a localised
    change. If a connector emits one of these entities today, the engine records
    a clear, non-fatal "not supported yet" error per record.
    """

    implemented = False

    def load(self, record, resolver, *, dry_run: bool) -> LoadOutcome:
        raise LoaderError(
            f"نقل سجلات {self.entity_type!r} غير مدعوم بعد.",
            code="not_implemented",
        )


def make_stub_loader(entity: str) -> BaseLoader:
    return type(
        f"{entity.title().replace('_', '')}StubLoader",
        (NotImplementedLoader,),
        {"entity_type": entity},
    )()


# --- shared value coercion ---------------------------------------------------


def clean_str(value) -> str:
    return "" if value is None else str(value).strip()


def to_decimal(value, default: Decimal = Decimal("0")) -> Decimal:
    if value is None or value == "":
        return default
    try:
        return Decimal(str(value))
    except (InvalidOperation, ValueError):
        return default


def to_bool(value, default: bool = True) -> bool:
    if value is None:
        return default
    if isinstance(value, str):
        return value.strip().lower() in ("1", "true", "yes", "y", "t")
    return bool(value)
