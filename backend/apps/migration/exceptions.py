"""Error types for the data-migration subsystem.

These intentionally mirror the friendly-message style of
``apps.attendance.biotime.BioTimeError``: every failure that crosses the
network or touches a third-party driver is wrapped in one of these with a
human-readable message, and raw DSNs / credentials are never echoed into the
message so they cannot leak into a stored run report.
"""

from __future__ import annotations


class MigrationError(Exception):
    """Base error for everything under :mod:`apps.migration`."""


class TransportError(MigrationError):
    """A source-database transport failed to connect, introspect, or read."""


class DriverNotInstalled(TransportError):
    """The optional Python driver for a source transport is not installed.

    The message tells the operator exactly which extra to install, e.g.
    ``pip install pointy-backend[migration]``.
    """


class CompatibilityError(MigrationError):
    """The chosen connector is not compatible with the connected database."""

    def __init__(self, report):
        self.report = report
        missing = ", ".join(getattr(report, "missing_tables", []) or []) or "—"
        super().__init__(
            f"The source database is not compatible with this system. Missing tables: {missing}."
        )
