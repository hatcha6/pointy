"""Tajer (SQL Server) connector — STUB.

Same shape as the AboGhris stub: declares metadata + a placeholder
``VersionSpec`` so the system is listed and compatibility can be probed, but
``extract`` is not implemented until a database dump is available. Use
``reference_sqlite.ReferenceSqliteConnector`` as the implementation template.
"""

from __future__ import annotations

from ..entity_plan import CATEGORY, CUSTOMER, PRODUCT, STOCK, SUPPLIER
from ..exceptions import MigrationError
from .base import BaseConnector, ExtractContext, RequiredTable, VersionSpec


class TajerMssqlConnector(BaseConnector):
    system_key = "tajer_mssql"
    display_name = "Tajer (SQL Server)"
    implemented = False
    required_transport = "mssql"
    supported_entities = (CATEGORY, PRODUCT, STOCK, CUSTOMER, SUPPLIER)
    versions = (
        # Placeholder — refine with the real schema from a client dump.
        VersionSpec(
            version_key="tajer-unknown",
            required_tables=(
                RequiredTable("tbl_Products"),
                RequiredTable("tbl_Categories"),
            ),
        ),
    )

    def extract(self, entity_type: str, transport, ctx: ExtractContext):
        raise MigrationError(
            "The Tajer connector is not implemented yet. "
            "Provide a database dump to enable importing."
        )
