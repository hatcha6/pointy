import { DataTable, type Column } from "./DataTable";
import { ConfigValue } from "./ConfigList";
import { Empty } from "./ui";

type Row = Record<string, unknown>;

function isRowList(value: unknown): value is Row[] {
  return Array.isArray(value) && value.length > 0 && value.every((v) => v && typeof v === "object" && !Array.isArray(v));
}

/** Finds the list worth tabling in a supplier's answer, wherever it sits. */
function findRows(value: unknown, depth = 0): Row[] | null {
  if (isRowList(value)) return value;
  if (depth > 3 || !value || typeof value !== "object") return null;
  for (const inner of Object.values(value as Row)) {
    const found = findRows(inner, depth + 1);
    if (found) return found;
  }
  return null;
}

/**
 * Shows an answer whose shape the console does not know (a supplier's own
 * API): the first list of records as a table, the rest as readable JSON.
 */
export function AutoView({ data }: { data: unknown }) {
  const rows = findRows(data);
  if (!rows) {
    if (data === null || data === undefined || (Array.isArray(data) && data.length === 0)) return <Empty title="لا نتائج" />;
    return <pre className="code-block">{JSON.stringify(data, null, 2)}</pre>;
  }
  const keys = [...new Set(rows.slice(0, 50).flatMap((r) => Object.keys(r)))].slice(0, 8);
  const columns: Column<Row>[] = keys.map((key, i) => ({
    key,
    header: <span className="mono">{key}</span>,
    mobile: i === 0 ? "title" : "meta",
    cell: (row) => <ConfigValue value={row[key]} />,
  }));
  return <DataTable rows={rows} columns={columns} rowKey={(r) => String(rows.indexOf(r))} />;
}
