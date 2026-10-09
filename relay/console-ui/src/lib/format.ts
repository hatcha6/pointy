// Arabic text, Latin digits: what Libyan shops read on receipts and bank apps.
const LOCALE = "ar-LY-u-nu-latn";

// Numbers read 3,185.75 — the grouping Libyan receipts and bank apps use
// (ar-LY itself would print 3.185,75).
const moneyFormat = new Intl.NumberFormat("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 3 });
const intFormat = new Intl.NumberFormat("en-US");
const dateFormat = new Intl.DateTimeFormat(LOCALE, { year: "numeric", month: "short", day: "numeric" });
const dateTimeFormat = new Intl.DateTimeFormat(LOCALE, {
  year: "numeric",
  month: "short",
  day: "numeric",
  hour: "2-digit",
  minute: "2-digit",
});
const relative = new Intl.RelativeTimeFormat(LOCALE, { numeric: "auto" });

export function money(value: string | number | null | undefined, currency = "د.ل"): string {
  if (value === null || value === undefined || value === "") return "—";
  const n = typeof value === "number" ? value : Number(value);
  if (!Number.isFinite(n)) return String(value);
  return `${moneyFormat.format(n)} ${currency}`;
}

export function signedMoney(value: string | number): string {
  const n = Number(value);
  if (!Number.isFinite(n)) return String(value);
  return (n > 0 ? "+" : n < 0 ? "−" : "") + money(Math.abs(n));
}

export function count(value: number | null | undefined): string {
  return value === null || value === undefined ? "—" : intFormat.format(value);
}

export function date(value: string | null | undefined): string {
  if (!value) return "—";
  const d = new Date(value);
  return Number.isNaN(d.getTime()) ? "—" : dateFormat.format(d);
}

export function dateTime(value: string | null | undefined): string {
  if (!value) return "—";
  const d = new Date(value);
  return Number.isNaN(d.getTime()) ? "—" : dateTimeFormat.format(d);
}

/** "قبل 5 دقائق", "بعد 3 أيام". */
export function ago(value: string | null | undefined, now = Date.now()): string {
  if (!value) return "—";
  const t = new Date(value).getTime();
  if (Number.isNaN(t)) return "—";
  const seconds = Math.round((t - now) / 1000);
  const abs = Math.abs(seconds);
  if (abs < 45) return "الآن";
  if (abs < 3600) return relative.format(Math.round(seconds / 60), "minute");
  if (abs < 86400) return relative.format(Math.round(seconds / 3600), "hour");
  if (abs < 86400 * 45) return relative.format(Math.round(seconds / 86400), "day");
  if (abs < 86400 * 365) return relative.format(Math.round(seconds / (86400 * 30)), "month");
  return relative.format(Math.round(seconds / (86400 * 365)), "year");
}

export function daysUntil(value: string | null | undefined, now = Date.now()): number | null {
  if (!value) return null;
  const t = new Date(value).getTime();
  return Number.isNaN(t) ? null : Math.floor((t - now) / 86400000);
}

/** A shop id shortened for tables: the full id stays copyable. */
export function shortId(id: string): string {
  return id.length > 10 ? id.slice(0, 8) : id;
}

/** Validates a positive amount with at most two decimals (what the wallet books). */
export function parseAmount(raw: string): string | null {
  const cleaned = raw.trim().replace(/[٠-٩]/g, (d) => String("٠١٢٣٤٥٦٧٨٩".indexOf(d))).replace(/[,،\s]/g, "").replace("٫", ".");
  if (!/^\d+(\.\d{1,2})?$/.test(cleaned)) return null;
  if (Number(cleaned) <= 0) return null;
  return cleaned;
}

/** "يوم", "يومين", "3 أيام", "11 يوماً". */
export function days(n: number): string {
  const a = Math.abs(n);
  if (a === 1) return "يوم";
  if (a === 2) return "يومين";
  if (a >= 3 && a <= 10) return `${a} أيام`;
  return `${a} يوماً`;
}
