import { ArrowDownRight, ArrowUpRight, ChevronLeft } from "lucide-react";
import { money } from "../../lib/format";
import { Link } from "../../lib/router";
import { lineCategory, monthLabel, trackedLinks, type Direction, type FinanceLine, type FinanceSummary } from "../../lib/finance";

/**
 * The change against the period before. `good` says which way is good news:
 * more income is, more expense is not.
 */
export function Delta({ value, good = "up", suffix = "عن الفترة السابقة" }: { value: number | null; good?: "up" | "down"; suffix?: string }) {
  if (value === null || !Number.isFinite(value)) return <span className="delta flat">لا مقارنة</span>;
  const rounded = Math.round(Math.abs(value));
  if (rounded === 0) return <span className="delta flat">كما كانت {suffix}</span>;
  const up = value > 0;
  const tone = up === (good === "up") ? "good" : "bad";
  return (
    <span className={`delta ${tone}`}>
      {up ? <ArrowUpRight /> : <ArrowDownRight />}
      {rounded > 999 ? "+999" : rounded}% {suffix}
    </span>
  );
}

/** Income and expense per month, side by side, with the month's net under it. */
export function MonthlyChart({ months }: { months: FinanceSummary["months"] }) {
  const peak = Math.max(1, ...months.flatMap((m) => [Number(m.income), Number(m.expense)]));
  const showYear = new Set(months.map((m) => m.month.slice(0, 4))).size > 1;
  return (
    <div className="mchart" aria-label="الدخل والمصروف شهرياً">
      <div className="mchart-bars" role="list">
        {months.map((m) => {
          const net = Number(m.net);
          return (
            <div key={m.month} className="mchart-col" aria-label={`${monthLabel(m.month, showYear)}: الدخل ${money(m.income)}، المصروف ${money(m.expense)}، الصافي ${money(m.net)}`} role="listitem">
              <div className="mchart-pair">
                <div className="bar income" style={{ height: `${(Number(m.income) / peak) * 100}%` }} title={`الدخل ${money(m.income)}`} />
                <div className="bar expense" style={{ height: `${(Number(m.expense) / peak) * 100}%` }} title={`المصروف ${money(m.expense)}`} />
              </div>
              <div className="mchart-label">{monthLabel(m.month, showYear)}</div>
              <div className={`mchart-net ${net > 0 ? "positive" : net < 0 ? "negative" : "faint"}`}>{net === 0 ? "—" : compact(net)}</div>
            </div>
          );
        })}
      </div>
      <div className="mchart-legend">
        <span>
          <i className="income" /> الدخل
        </span>
        <span>
          <i className="expense" /> المصروف
        </span>
        <span className="muted">الرقم تحت كل شهر: صافيه</span>
      </div>
    </div>
  );
}

const compactFormat = new Intl.NumberFormat("en-US", { notation: "compact", maximumFractionDigits: 1 });

function compact(n: number): string {
  const abs = Math.abs(n);
  return (n > 0 ? "+" : "−") + (abs < 1000 ? String(Math.round(abs)) : compactFormat.format(abs));
}

/** Where money came from or went, largest first, each with its share. */
export function Breakdown({ direction, lines, total, ledgerQuery }: { direction: Direction; lines: FinanceLine[]; total: string; ledgerQuery: string }) {
  const sum = Number(total) || 1;
  return (
    <ul className="breakdown">
      {lines.map((line) => {
        const category = lineCategory(direction, line);
        const Icon = category.icon;
        const share = (Number(line.amount) / sum) * 100;
        const to =
          line.source === "tracked"
            ? trackedLinks[line.key]
            : `/ledger?direction=${direction}&category=${encodeURIComponent(line.key)}${ledgerQuery}`;
        const body = (
          <>
            <div className={`b-icon ${direction}`}>
              <Icon />
            </div>
            <div className="b-main">
              <div className="b-top">
                <strong>{category.label}</strong>
                <span className={`b-source ${line.source}`}>{line.source === "tracked" ? "تلقائي" : line.count ? `${line.count} قيد` : "يدوي"}</span>
                <span className="spacer" />
                <span className="money">{money(line.amount)}</span>
              </div>
              <div className="b-bar">
                <span className={direction} style={{ width: `${Math.max(share, 1.5)}%` }} />
              </div>
            </div>
            <span className="b-share">{share < 1 ? "‎<1%" : `${Math.round(share)}%`}</span>
            {to && <ChevronLeft className="b-go" />}
          </>
        );
        return <li key={line.source + line.key}>{to ? <Link to={to}>{body}</Link> : <div>{body}</div>}</li>;
      })}
    </ul>
  );
}
