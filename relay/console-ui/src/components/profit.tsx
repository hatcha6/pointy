import { money } from "../lib/format";

/** A profit with its share of the base it is earned on ("12.5%" of our cost, of the shop's price). */
export function ProfitCell({ value, of }: { value?: number; of?: number }) {
  if (value === undefined || !Number.isFinite(value)) return <span className="faint">—</span>;
  const pct = of !== undefined && of > 0 ? (value / of) * 100 : undefined;
  return (
    <span className="price-cell">
      <span className={value < 0 ? "negative" : value === 0 ? "faint" : "positive"}>{money(value.toFixed(2))}</span>
      {pct !== undefined && <span className="faint num" style={{ fontSize: 12 }}>{pct.toFixed(1)}%</span>}
    </span>
  );
}
