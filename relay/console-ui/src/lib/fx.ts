// The funding-aware dollar rate (relay/internal/vouchers/fx.go): what the
// console reads from GET /v1/vouchers/admin/fx and the preview.

export type FXExample = { usd: number; cost_lyd: string; shop_pays: string; retail: string; margin_percent: string };

export type FXBook = {
  supplier: string;
  rate: string;
  binding: "market" | "book";
  held_usd?: string;
  read_at?: string;
  covered_usd: string;
  cost_lyd: string;
  average: string;
  uncovered_usd: string;
  value_lyd?: string;
  gain_lyd?: string;
  examples: FXExample[];
};

export type FXQuote = {
  live: string;
  live_at: string | null;
  premium_percent: string;
  premium_source: "learned" | "setting";
  premium_from: string[];
  premium_high: boolean;
  replacement: string;
  peak: string;
  peak_raw: string;
  peak_at: string | null;
  momentum_percent: string;
  cushion_percent: string;
  market: string;
  binding: "replacement" | "peak";
  /** No fresh rate: priced from the last rate and top-up, full cushion. */
  fallback: boolean;
  shock_percent: string;
  shocked: boolean;
  books: FXBook[];
};

export type FXPolicy = {
  enabled: string;
  premium_source: string;
  premium_max_age_days: string;
  premium_top_ups: string;
  peak_days: string;
  fall_percent_per_day: string;
  release_hours: string;
  momentum_days: string;
  momentum_share_percent: string;
  cushion_cap_percent: string;
  book_floor: string;
  shock_percent: string;
};

export type SupplierFunding = {
  id: string;
  supplier: string;
  usd: string;
  lyd: string;
  method: string;
  reference?: string;
  market_rate?: string;
  note?: string;
  actor?: string;
  funded_at: string;
  created_at: string;
  voided_at?: string | null;
  void_reason?: string;
  void_actor?: string;
};

export type FXState = {
  enabled: boolean;
  policy: FXPolicy;
  series: { instrument: string; bank_code: string };
  quote?: FXQuote;
  after?: FXQuote;
  funding?: SupplierFunding;
  fundings?: SupplierFunding[];
  history?: { at: string; rate: string }[];
  source?: string;
  /** "manual" | "off" | "manual_fallback", or a reason no rate can price. */
  problem?: string;
  /** Why no fresh live rate was used (stale, never received). */
  rate_problem?: string;
};

export const fxKey = ["vouchers", "fx"];

/** Banks fulus.ly publishes a dollar series for, by their code. */
export const bankNames: Record<string, string> = {
  nab: "مصرف شمال أفريقيا",
};

export function seriesName(series: FXState["series"] | undefined): string {
  if (!series) return "—";
  if (series.instrument === "bank") return bankNames[series.bank_code] ?? `المصرف ${series.bank_code}`;
  return "السوق النقدي";
}

export const fundingMethods: { id: string; label: string }[] = [
  { id: "bnplus_usdt", label: "USDT من BN Plus" },
  { id: "bank_transfer", label: "تحويل مصرفي" },
  { id: "card", label: "بطاقة" },
  { id: "cash_exchange", label: "صرافة" },
  { id: "other", label: "أخرى" },
];

export const methodLabel = (id: string) => fundingMethods.find((m) => m.id === id)?.label ?? id;

/** Dollar suppliers a top-up can be recorded for. */
export const dollarSuppliers = ["fazer", "reloadly", "esimaccess"];

/** A rate as the console shows it: 2 places, Latin digits. */
export function rate(value: string | number | undefined | null): string {
  const n = Number(value);
  return value === undefined || value === null || value === "" || !Number.isFinite(n) ? "—" : n.toFixed(2);
}

export function pct(value: string | number | undefined | null, digits = 1): string {
  const n = Number(value);
  return value === undefined || value === null || value === "" || !Number.isFinite(n) ? "—" : `${n.toFixed(digits)}٪`;
}
