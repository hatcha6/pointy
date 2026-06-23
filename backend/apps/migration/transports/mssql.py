"""Microsoft SQL Server source transport (pyodbc — base dependency).

This is the most common legacy POS backend (AboGhris, Tajer, Fahd, …).

**Modern vs legacy servers.** The default ``ODBC Driver 18 for SQL Server`` only
talks to SQL Server 2008+. Genuinely old systems (e.g. Fahd on SQL Server 2000)
need a legacy driver — **FreeTDS** (cross-platform) or the built-in Windows
``SQL Server`` driver. Those speak the TDS protocol directly and don't accept the
``Encrypt`` / ``TrustServerCertificate`` keywords, so for any non-"ODBC Driver"
driver this transport omits them, passes the port separately, and lets the
source set ``options.tds_version`` (``"7.0"`` for SQL Server 2000). Point a
source at FreeTDS with ``options = {"odbc_driver": "FreeTDS", "tds_version":
"7.0", "encoding": "cp1256"}``.
"""

from __future__ import annotations

from ..exceptions import DriverNotInstalled, TransportError
from .base import CONNECT_TIMEOUT_SECONDS
from .sql_base import SqlTransport

_DEFAULT_ODBC_DRIVER = "ODBC Driver 18 for SQL Server"


class MssqlTransport(SqlTransport):
    kind = "mssql"
    param_style = "qmark"  # pyodbc uses ? placeholders

    def _quote_identifier(self, name: str) -> str:
        # SQL Server delimits identifiers with [brackets].
        return "[" + str(name).replace("]", "]]") + "]"

    def _build_connection_string(self) -> str:
        driver = self.options.get("odbc_driver") or _DEFAULT_ODBC_DRIVER
        # Only the modern "ODBC Driver NN for SQL Server" understands the TLS
        # keywords and the ``host,port`` server syntax; FreeTDS / the legacy
        # "SQL Server" driver want a separate PORT and reject the TLS keywords.
        is_modern = "odbc driver" in driver.lower()
        host = self.config.get("host") or ""
        port = self.config.get("port")

        parts = [f"DRIVER={{{driver}}}"]
        if is_modern and port:
            parts.append(f"SERVER={host},{port}")
        else:
            parts.append(f"SERVER={host}")
            if port:
                parts.append(f"PORT={port}")
        parts.append(f"DATABASE={self.config.get('database') or ''}")
        parts.append(f"UID={self.config.get('username') or ''}")
        parts.append(f"PWD={self.config.get('password') or ''}")

        tds_version = self.options.get("tds_version")
        if tds_version:
            parts.append(f"TDS_Version={tds_version}")
        if is_modern:
            parts.append(f"Encrypt={self.options.get('encrypt', 'yes')}")
            parts.append(
                f"TrustServerCertificate={self.options.get('trust_server_certificate', 'yes')}"
            )
        return ";".join(parts) + ";"

    def _create_connection(self):
        try:
            import pyodbc
        except ImportError as exc:
            raise DriverNotInstalled(
                "The SQL Server driver (pyodbc) is not installed. "
                "Install it with: pip install pointy-backend[migration]"
            ) from exc

        try:
            # ``readonly=True`` advertises read-only intent to the driver.
            return pyodbc.connect(
                self._build_connection_string(),
                timeout=CONNECT_TIMEOUT_SECONDS,
                readonly=True,
            )
        except Exception as exc:  # noqa: BLE001 - pyodbc.Error and friends
            # Never echo the connection string (it carries the password).
            raise TransportError(f"Could not connect to SQL Server: {exc}") from exc
