"""Connector framework — the per-vendor, per-version interpreter.

A connector knows how to read one family of source systems and emit the
canonical IR. The two-axis design (transport × connector) means a connector
never touches a driver directly: it only reads through a :class:`BaseTransport`.

**Versions.** Each connector declares one or more :class:`VersionSpec`s — the
tables/columns a given market version must have. ``check_compatibility``
introspects the live schema and reports exactly what is missing. Market
versions whose schema is identical collapse to a single ``VersionSpec`` (so one
connector covers many versions), and "is this version supported?" is answered
from the actual database rather than guessed — which the dry run then confirms.
"""

from __future__ import annotations

import abc
from collections.abc import Iterator
from dataclasses import dataclass, field


@dataclass
class ExtractContext:
    """Read-only context handed to ``extract`` (no resolver — connectors only
    read the source and emit canonical records keyed by source key)."""

    source: object = None
    # Per-run options chosen in the UI (e.g. stock_source).
    run_options: dict = field(default_factory=dict)
    # Scratch space for a connector to memoise cross-entity lookups for one run
    # (e.g. group the BARCODE table by item once and reuse it).
    cache: dict = field(default_factory=dict)


@dataclass(frozen=True)
class RequiredTable:
    name: str
    required_columns: tuple[str, ...] = ()


@dataclass(frozen=True)
class VersionSpec:
    version_key: str
    required_tables: tuple[RequiredTable, ...] = ()


@dataclass
class CompatibilityReport:
    compatible: bool
    detected_version: str | None = None
    missing_tables: list[str] = field(default_factory=list)
    missing_columns: dict[str, list[str]] = field(default_factory=dict)
    supported_entities: list[str] = field(default_factory=list)
    notes: list[str] = field(default_factory=list)

    def as_dict(self) -> dict:
        return {
            "compatible": self.compatible,
            "detected_version": self.detected_version,
            "missing_tables": self.missing_tables,
            "missing_columns": self.missing_columns,
            "supported_entities": self.supported_entities,
            "notes": self.notes,
        }


class BaseConnector(abc.ABC):
    #: Stable key stored on ``MigrationSource.system_key``.
    system_key: str = ""
    display_name: str = ""
    #: False for vendor stubs whose ``extract`` is not written yet. Surfaced in
    #: the systems catalogue so the UI can mark "compatibility only, no import".
    implemented: bool = True
    #: Required transport kind ("mssql", "postgres", "sqlite", "mongo").
    required_transport: str = ""
    #: Canonical entity types this connector can extract (ENTITY_PLAN keys).
    supported_entities: tuple[str, ...] = ()
    #: Declared schema variants this connector recognises.
    versions: tuple[VersionSpec, ...] = ()
    #: What this vendor's file looks like *before* preparation, when that is a
    #: different shape from what :attr:`versions` describes. Fahd is the reason
    #: this exists: a freshly converted Fahd database has a catalogue and a
    #: 4.6M-row audit log but no invoice tables at all, because Fahd wipes them
    #: at year carry-over — the invoices only exist as log text until
    #: :meth:`prepare` rebuilds them. Empty means the file is already in its
    #: final shape and :attr:`versions` applies directly.
    raw_versions: tuple[VersionSpec, ...] = ()

    def prepare(self, source_path, output_path, *, tracker=None, stage_key="prepare") -> dict:
        """Turn a raw converted file into the shape :attr:`versions` expects.

        Only called for connectors that declared :attr:`raw_versions` and matched
        one. Returns a stats dict for the report. The default is a connector
        whose file needs no vendor-specific work.
        """
        raise NotImplementedError

    def check_compatibility(self, transport) -> CompatibilityReport:
        """Default: match each declared version against the live schema and pick
        the best fit. Override only for runtime/value-based detection."""
        return self._match(transport, self.versions)

    def check_raw(self, transport) -> CompatibilityReport:
        """Same matching, against :attr:`raw_versions` — the pre-preparation shape."""
        return self._match(transport, self.raw_versions)

    def _match(self, transport, versions) -> CompatibilityReport:
        if not versions:
            return CompatibilityReport(
                compatible=False,
                supported_entities=list(self.supported_entities),
                notes=["This connector has no version specifications yet."],
            )

        present_tables = {name.lower() for name in transport.list_tables()}
        best = None  # (score, version, missing_tables, missing_columns)
        for version in versions:
            missing_tables: list[str] = []
            missing_columns: dict[str, list[str]] = {}
            for required in version.required_tables:
                if required.name.lower() not in present_tables:
                    missing_tables.append(required.name)
                    continue
                if required.required_columns:
                    columns = transport.describe_table(required.name).column_names()
                    absent = [
                        column
                        for column in required.required_columns
                        if column.lower() not in columns
                    ]
                    if absent:
                        missing_columns[required.name] = absent
            score = len(missing_tables) + sum(len(cols) for cols in missing_columns.values())
            if best is None or score < best[0]:
                best = (score, version, missing_tables, missing_columns)

        score, version, missing_tables, missing_columns = best
        compatible = score == 0
        return CompatibilityReport(
            compatible=compatible,
            detected_version=version.version_key if compatible else None,
            missing_tables=missing_tables,
            missing_columns=missing_columns,
            supported_entities=list(self.supported_entities),
        )

    @abc.abstractmethod
    def extract(self, entity_type: str, transport, ctx: ExtractContext) -> Iterator:
        """Yield canonical records for ``entity_type``."""
