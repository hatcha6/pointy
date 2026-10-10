import type { ReactNode } from "react";
import { useCompact } from "../lib/media";
import { Empty, Skeleton } from "./ui";

/**
 * One column of a list. On a phone the list becomes cards, and each column
 * says where it goes there:
 *   title     the card's heading (start side)
 *   trailing  beside the heading (end side): an amount, a status
 *   subtitle  under the heading
 *   meta      a label/value pair in the card's grid (the default)
 *   actions   the buttons row at the bottom
 *   hide      not on phones
 */
export type Column<T> = {
  key: string;
  header: ReactNode;
  cell: (row: T) => ReactNode;
  align?: "end";
  mobile?: "title" | "trailing" | "subtitle" | "meta" | "actions" | "hide";
  /** Hidden below 1100px when the table runs out of room, and on phones
   *  unless `mobile` places it. */
  wideOnly?: boolean;
};

export function DataTable<T>({
  rows,
  columns,
  rowKey,
  onRowClick,
  loading,
  empty,
  skeletonRows = 6,
}: {
  rows: T[];
  columns: Column<T>[];
  rowKey: (row: T) => string;
  onRowClick?: (row: T) => void;
  loading?: boolean;
  empty?: ReactNode;
  skeletonRows?: number;
}) {
  const compact = useCompact();
  if (!loading && rows.length === 0) return <>{empty ?? <Empty title="لا شيء هنا" />}</>;

  if (compact) {
    const place = (c: Column<T>) => c.mobile ?? (c.wideOnly ? "hide" : "meta");
    const of = (where: string) => columns.filter((c) => place(c) === where);
    const [title, trailing, subtitle, meta, actions] = ["title", "trailing", "subtitle", "meta", "actions"].map(of);
    if (loading) {
      return (
        <div className="mlist">
          {Array.from({ length: Math.min(skeletonRows, 4) }, (_, i) => (
            <div key={i} className="mcard">
              <Skeleton height={16} width="60%" />
              <Skeleton height={12} width="40%" />
            </div>
          ))}
        </div>
      );
    }
    return (
      <div className="mlist">
        {rows.map((row) => (
          <div
            key={rowKey(row)}
            className={`mcard ${onRowClick ? "clickable" : ""}`}
            onClick={onRowClick ? () => onRowClick(row) : undefined}
            role={onRowClick ? "button" : undefined}
            tabIndex={onRowClick ? 0 : undefined}
            onKeyDown={onRowClick ? (e) => e.key === "Enter" && onRowClick(row) : undefined}
          >
            <div className="mcard-top">
              <div className="mcard-title">{title.map((c) => <div key={c.key}>{c.cell(row)}</div>)}</div>
              {trailing.length > 0 && <div className="mcard-trailing">{trailing.map((c) => <div key={c.key}>{c.cell(row)}</div>)}</div>}
            </div>
            {subtitle.length > 0 && <div className="mcard-sub">{subtitle.map((c) => <div key={c.key}>{c.cell(row)}</div>)}</div>}
            {meta.length > 0 && (
              <dl className="mcard-meta">
                {meta.map((c) => (
                  <div key={c.key}>
                    <dt>{c.header}</dt>
                    <dd>{c.cell(row)}</dd>
                  </div>
                ))}
              </dl>
            )}
            {actions.length > 0 && (
              <div className="mcard-actions" onClick={(e) => e.stopPropagation()}>
                {actions.map((c) => <div key={c.key}>{c.cell(row)}</div>)}
              </div>
            )}
          </div>
        ))}
      </div>
    );
  }

  return (
    <div className="table-wrap">
      <table className="table">
        <thead>
          <tr>
            {columns.map((c) => (
              <th key={c.key} className={[c.align === "end" ? "end" : "", c.wideOnly ? "wide-only" : ""].join(" ")}>
                {c.header}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {loading
            ? Array.from({ length: skeletonRows }, (_, r) => (
                <tr key={r}>
                  {columns.map((c, i) => (
                    <td key={c.key} className={c.wideOnly ? "wide-only" : ""}>
                      <div className="skeleton" style={{ height: 14, width: i === 0 ? "70%" : "50%" }} />
                    </td>
                  ))}
                </tr>
              ))
            : rows.map((row) => (
                <tr
                  key={rowKey(row)}
                  className={onRowClick ? "clickable" : ""}
                  onClick={onRowClick ? () => onRowClick(row) : undefined}
                  // A row that opens something is reachable by Tab and opened by Enter.
                  tabIndex={onRowClick ? 0 : undefined}
                  onKeyDown={
                    onRowClick
                      ? (e) => {
                          if ((e.key === "Enter" || e.key === " ") && e.target === e.currentTarget) {
                            e.preventDefault();
                            onRowClick(row);
                          }
                        }
                      : undefined
                  }
                >
                  {columns.map((c) => (
                    <td
                      key={c.key}
                      className={[c.align === "end" ? "end" : "", c.wideOnly ? "wide-only" : "", c.mobile === "actions" ? "actions-cell" : ""].join(" ")}
                      onClick={c.mobile === "actions" ? (e) => e.stopPropagation() : undefined}
                    >
                      {c.cell(row)}
                    </td>
                  ))}
                </tr>
              ))}
        </tbody>
      </table>
    </div>
  );
}

/** Two-line cell: a bold line and a muted one. */
export function Stacked({ title, sub, mono }: { title: ReactNode; sub?: ReactNode; mono?: boolean }) {
  return (
    <div className="stacked">
      <strong>{title}</strong>
      {sub && <span className={mono ? "mono" : ""}>{sub}</span>}
    </div>
  );
}
