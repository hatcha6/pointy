"""What is actually in this file — answered before anyone commits to anything.

The old flow asked the owner to tick entity checkboxes reading "Sales",
"Customers", "Purchase orders" with no idea whether their file held five sales or
nine hundred thousand. This answers that first: real counts, and the date range
the history covers, so the screen can say

    ٣٤٬١١٢ صنف · ١٬٢٠٣ زبون · ٨٩٢٬٤٤١ فاتورة · من ٢٠١٩/٠٣ إلى ٢٠٢٦/٠٨

before the first row is written. It is also the honest place to find out that a
file the owner was sure contained ten years of sales contains none.

Deliberately cheap: ``COUNT(*)`` and ``MIN``/``MAX`` over a column, never an
extract. Anything a connector has not declared is simply absent from the result
rather than guessed at.
"""

from __future__ import annotations

from ..connectors import get_connector
from ..entity_plan import ENTITY_PLAN_BY_TYPE
from ..transports import build_transport


def analyze(source, prepared_path) -> dict:
    connector = get_connector(source.system_key)
    if connector is None:
        return {"entities": {}}

    plan = dict(getattr(connector, "analysis_tables", {}) or {})
    supported = set(connector.supported_entities)
    entities: dict[str, dict] = {}
    earliest = latest = None

    transport = build_transport("sqlite", {"database": str(prepared_path)})
    with transport:
        present = {name.lower() for name in transport.list_tables()}
        for entity_type, spec in plan.items():
            if entity_type not in supported:
                continue
            table, date_column = spec if isinstance(spec, (tuple, list)) else (spec, None)
            if table.lower() not in present:
                continue
            entry = {"count": _count(transport, table)}
            if date_column:
                first, last = _range(transport, table, date_column)
                if first:
                    entry["from"] = first
                    earliest = first if earliest is None else min(earliest, first)
                if last:
                    entry["to"] = last
                    latest = last if latest is None else max(latest, last)
            entities[entity_type] = entry

    result = {
        "entities": entities,
        "labels": {
            entity_type: ENTITY_PLAN_BY_TYPE[entity_type].label
            for entity_type in entities
            if entity_type in ENTITY_PLAN_BY_TYPE
        },
    }
    if earliest:
        result["history_from"] = earliest
    if latest:
        result["history_to"] = latest
    return result


def _count(transport, table) -> int:
    try:
        return transport.count(table)
    except Exception:  # noqa: BLE001 - a preview never fails the pipeline
        return 0


def _range(transport, table, column) -> tuple[str, str]:
    quoted_table = transport._quote_identifier(table)  # noqa: SLF001 - same package
    quoted_column = transport._quote_identifier(column)  # noqa: SLF001
    try:
        rows = list(
            transport.raw_query(
                f"SELECT MIN({quoted_column}), MAX({quoted_column}) "
                f"FROM {quoted_table} WHERE {quoted_column} IS NOT NULL "
                f"AND {quoted_column} != ''"
            )
        )
    except Exception:  # noqa: BLE001
        return "", ""
    if not rows:
        return "", ""
    values = list(rows[0].values())
    first = str(values[0])[:10] if values and values[0] else ""
    last = str(values[1])[:10] if len(values) > 1 and values[1] else ""
    return first, last
