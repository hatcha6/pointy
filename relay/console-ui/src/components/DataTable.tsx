import { useEffect, useLayoutEffect, useRef, useState, type ReactNode } from "react";
import { ChevronLeft, ChevronRight } from "lucide-react";
import { useCompact } from "../lib/media";
import { count } from "../lib/format";
import { Empty, Skeleton } from "./ui";

/** Rows a list draws at once. A longer one is paged: the browser lays out a
 *  page, never the whole list. */
export const PAGE_SIZE = 50;

/**
 * Which page of a list is showing. It goes back to the first page when
 * `resetKey` changes (a new search, another filter), and never points past
 * the end when the list shrinks under it.
 */
export function usePage(total: number, size: number, resetKey?: unknown) {
  const [page, setPage] = useState(0);
  const key = useRef(resetKey);
  const last = size > 0 ? Math.max(0, Math.ceil(total / size) - 1) : 0;
  let current = Math.min(page, last);
  if (key.current !== resetKey) current = 0;
  useEffect(() => {
    key.current = resetKey;
    if (page !== current) setPage(current);
  }, [resetKey, page, current]);
  const start = size > 0 ? current * size : 0;
  const end = size > 0 ? Math.min(total, start + size) : total;
  return { page: current, setPage, last, start, end };
}

/** "1–50 من 1,234", and the way to the next and the previous page. */
export function Pager({ page, last, start, end, total, onPage, unit = "" }: {
  page: number;
  last: number;
  start: number;
  end: number;
  total: number;
  onPage: (page: number) => void;
  unit?: string;
}) {
  if (last === 0) return null;
  return (
    <nav className="pager" aria-label="الصفحات">
      <span className="pager-range num">
        {count(start + 1)}–{count(end)} من {count(total)} {unit}
      </span>
      <div className="pager-buttons">
        <button type="button" className="btn sm" disabled={page === 0} onClick={() => onPage(page - 1)}>
          <ChevronRight />
          السابق
        </button>
        <span className="pager-page num">
          {count(page + 1)} / {count(last + 1)}
        </span>
        <button type="button" className="btn sm" disabled={page === last} onClick={() => onPage(page + 1)}>
          التالي
          <ChevronLeft />
        </button>
      </div>
    </nav>
  );
}

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
  /** Hidden when the table is narrower than 1000px, and on phones unless
   *  `mobile` places it. */
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
  pageSize = PAGE_SIZE,
  resetKey,
}: {
  rows: T[];
  columns: Column<T>[];
  rowKey: (row: T) => string;
  onRowClick?: (row: T) => void;
  loading?: boolean;
  empty?: ReactNode;
  skeletonRows?: number;
  /** Rows per page; 0 draws every row (a short list that must print whole). */
  pageSize?: number;
  /** Changing it returns the list to its first page: pass the search and filters. */
  resetKey?: unknown;
}) {
  const phone = useCompact();
  const all = rows;
  const paging = usePage(all.length, pageSize, resetKey);
  rows = paging.last > 0 ? all.slice(paging.start, paging.end) : all;
  const { ref, overflows } = useOverflow(phone ? null : rows);
  const compact = phone || overflows;
  const top = useRef<HTMLDivElement>(null);
  const pager = (
    <Pager
      {...paging}
      total={all.length}
      onPage={(page) => {
        paging.setPage(page);
        // The next page starts at its first row, not where the last one ended.
        const box = top.current?.getBoundingClientRect();
        if (box && box.top < 0) top.current?.scrollIntoView({ block: "start" });
      }}
    />
  );
  if (!loading && all.length === 0) return <>{empty ?? <Empty title="لا شيء هنا" />}</>;

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
      <>
      <div className="pager-anchor" ref={top} />
      <div className="mlist" ref={ref}>
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
      {pager}
      </>
    );
  }

  return (
    <>
    <div className="pager-anchor" ref={top} />
    <div className="table-wrap" ref={ref}>
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
    {!loading && pager}
    </>
  );
}

/**
 * Whether the table is wider than the room it has. A tablet, a narrow window
 * or a split screen can leave a many-column table too little width even
 * though the window is not a phone's; the list then reads as cards there too
 * instead of scrolling sideways. The width the table needed is remembered, so
 * it comes back as soon as there is that much room again.
 */
function useOverflow(rows: unknown) {
  const ref = useRef<HTMLDivElement>(null);
  const needed = useRef(0);
  const [overflows, setOverflows] = useState(false);
  useLayoutEffect(() => {
    const el = ref.current;
    if (!el || rows === null) return;
    const check = () => {
      if (!overflows && el.scrollWidth > el.clientWidth + 1) {
        needed.current = el.scrollWidth;
        setOverflows(true);
      } else if (overflows && el.clientWidth >= needed.current) {
        setOverflows(false);
      }
    };
    check();
    const observer = new ResizeObserver(check);
    observer.observe(el);
    return () => observer.disconnect();
  }, [rows, overflows]);
  return { ref, overflows: rows !== null && overflows };
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
