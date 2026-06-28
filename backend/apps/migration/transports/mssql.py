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

# Well-known credentials that legacy POS installers (AboGhris, Tajer, MDS/MSDE
# bundles, …) leave on the SQL Server instance they provision. SQL Server itself
# ships with NO default password — these are *vendor* defaults. We only ever try
# them against the source the operator has explicitly configured for migration,
# as a fallback when they didn't supply a login (the shop owner rarely knows the
# password the POS vendor set years ago). Ordered most- to least-likely; kept
# short on purpose so this stays "try the obvious vendor defaults", not a
# brute-force. ``None`` username means Windows/trusted auth.
_VENDOR_DEFAULT_CREDENTIALS: tuple[tuple[str | None, str], ...] = (
    (None, ""),        # Windows / trusted auth (the install default)
    ("sa", ""),        # blank sa — common on MSDE / SQL Server 2000 (Fahd)
    ("sa", "sa"),
    ("sa", "123"),
    ("sa", "1234"),
    ("sa", "12345"),
    ("sa", "123456"),
    ("sa", "password"),
    ("sa", "P@ssw0rd"),
)


class MssqlTransport(SqlTransport):
    kind = "mssql"
    param_style = "qmark"  # pyodbc uses ? placeholders

    def _quote_identifier(self, name: str) -> str:
        # SQL Server delimits identifiers with [brackets].
        return "[" + str(name).replace("]", "]]") + "]"

    def _build_connection_string(
        self, username: str | None = None, password: str | None = None
    ) -> str:
        """Build the ODBC string. ``username``/``password`` default to the
        configured credentials; a ``None`` username switches to Windows/trusted
        auth (used by the default-credential fallback)."""
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
        if username is None:
            parts.append("Trusted_Connection=yes")
        else:
            parts.append(f"UID={username}")
            parts.append(f"PWD={password or ''}")

        tds_version = self.options.get("tds_version")
        if tds_version:
            parts.append(f"TDS_Version={tds_version}")
        if is_modern:
            parts.append(f"Encrypt={self.options.get('encrypt', 'yes')}")
            parts.append(
                f"TrustServerCertificate={self.options.get('trust_server_certificate', 'yes')}"
            )
        return ";".join(parts) + ";"

    def _credential_candidates(self) -> list[tuple[str | None, str]]:
        """The credentials to try, in order. If the operator supplied a login we
        use only that. If they left it blank we fall back to the known vendor
        defaults — but only when ``try_default_credentials`` is enabled (default
        on, since the migration operator is on-site and authorized)."""
        username = self.config.get("username")
        password = self.config.get("password") or ""
        if username:
            return [(username, password)]
        if self.options.get("try_default_credentials", True):
            return list(_VENDOR_DEFAULT_CREDENTIALS)
        # No login and fallback disabled: attempt trusted auth only.
        return [(None, "")]

    def _create_connection(self):
        try:
            import pyodbc
        except ImportError as exc:
            raise DriverNotInstalled(
                "The SQL Server driver (pyodbc) is not installed. "
                "Install it with: pip install pointy-backend[migration]"
            ) from exc

        last_exc: Exception | None = None
        for username, password in self._credential_candidates():
            try:
                # ``readonly=True`` advertises read-only intent to the driver.
                return pyodbc.connect(
                    self._build_connection_string(username, password),
                    timeout=CONNECT_TIMEOUT_SECONDS,
                    readonly=True,
                )
            except Exception as exc:  # noqa: BLE001 - pyodbc.Error and friends
                last_exc = exc
                continue
        # Never echo the connection string (it carries the password).
        raise TransportError(
            f"Could not connect to SQL Server: {last_exc}"
        ) from last_exc
