"""Microsoft SQL Server source transport (pyodbc — optional ``migration`` extra).

This is the most common legacy POS backend (AboGhris, Tajer, …). The driver is
optional; install it with ``pip install pointy-backend[migration]``.
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

    def _create_connection(self):
        try:
            import pyodbc
        except ImportError as exc:
            raise DriverNotInstalled(
                "The SQL Server driver (pyodbc) is not installed. "
                "Install it with: pip install pointy-backend[migration]"
            ) from exc

        driver = self.options.get("odbc_driver") or _DEFAULT_ODBC_DRIVER
        server = self.config.get("host") or ""
        port = self.config.get("port")
        if port:
            server = f"{server},{port}"
        encrypt = self.options.get("encrypt", "yes")
        trust_certificate = self.options.get("trust_server_certificate", "yes")
        connection_string = (
            f"DRIVER={{{driver}}};"
            f"SERVER={server};"
            f"DATABASE={self.config.get('database') or ''};"
            f"UID={self.config.get('username') or ''};"
            f"PWD={self.config.get('password') or ''};"
            f"Encrypt={encrypt};"
            f"TrustServerCertificate={trust_certificate};"
        )
        try:
            # ``readonly=True`` advertises read-only intent to the driver.
            return pyodbc.connect(
                connection_string,
                timeout=CONNECT_TIMEOUT_SECONDS,
                readonly=True,
            )
        except Exception as exc:  # noqa: BLE001 - pyodbc.Error and friends
            # Never echo the connection string (it carries the password).
            raise TransportError(f"Could not connect to SQL Server: {exc}") from exc
