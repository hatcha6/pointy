"""AboGhris (SQL Server) connector — STUB.

Metadata + a placeholder ``VersionSpec`` are declared so the system appears in
the picker and ``check_compatibility`` can run against a live database. Real
table/column names and the ``extract`` mappings land once a database dump is
provided; ``required_tables`` below are placeholders and will report as missing
until then.

To implement: replace ``required_tables`` with the real schema (one VersionSpec
per distinct schema; identical market versions share one), then implement
``extract`` to map each supported entity's rows to the canonical IR — using
``reference_sqlite.ReferenceSqliteConnector`` as the template.
"""

from __future__ import annotations

from ..entity_plan import CATEGORY, CUSTOMER, PRODUCT, STOCK, SUPPLIER
from ..exceptions import MigrationError
from .base import BaseConnector, ExtractContext, RequiredTable, VersionSpec


class AboGhrisMssqlConnector(BaseConnector):
    system_key = "aboghris_mssql"
    display_name = "AboGhris (SQL Server)"
    implemented = False
    required_transport = "mssql"
    supported_entities = (CATEGORY, PRODUCT, STOCK, CUSTOMER, SUPPLIER)
    versions = (
        # Placeholder — refine with the real schema from a client dump.
        VersionSpec(
            version_key="aboghris-unknown",
            required_tables=(
                RequiredTable("Items"),
                RequiredTable("Groups"),
            ),
        ),
    )

    def extract(self, entity_type: str, transport, ctx: ExtractContext):
        raise MigrationError(
            "The AboGhris connector is not implemented yet. "
            "Provide a database dump to enable importing."
        )
