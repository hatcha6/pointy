"""Error types for the data-migration subsystem.

Every failure a person could see is wrapped in one of these with a message
written for them rather than for a log — the migration screen shows these
verbatim, and "this is a ZIP, we need the database itself" is a next step where
a stack trace is a dead end.
"""

from __future__ import annotations


class MigrationError(Exception):
    """Base error for everything under :mod:`apps.migration`."""


class TransportError(MigrationError):
    """A source-database transport failed to connect, introspect, or read."""


class CompatibilityError(MigrationError):
    """The chosen connector is not compatible with the connected database."""

    def __init__(self, report):
        self.report = report
        missing = ", ".join(getattr(report, "missing_tables", []) or []) or "—"
        super().__init__(
            f"The source database is not compatible with this system. Missing tables: {missing}."
        )
