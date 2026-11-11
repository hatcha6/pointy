// The catalog as the operator edits it in the console: the published
// document, changed a field at a time, kept as a draft in this browser until
// it is published as a new version. Nothing here reaches a shop before the
// publish (and its passkey tap); the relay validates the whole document then.
//
// The types name what the editor reads and writes. Everything else an entry
// carries (a redeem block, a target, a market price, the supplier mapping)
// rides along untouched.

import { useCallback, useEffect, useMemo, useState } from "react";

export type DocPromo = { price?: string; retail_price?: string; badge: string; starts_at: string; ends_at: string };

export type DocItem = {
  key: string;
  country?: string;
  face_value?: string;
  face_currency?: string;
  label?: string;
  price: string;
  retail_price: string;
  price_mode?: string;
  sort?: number;
  active?: boolean;
  promo?: DocPromo | null;
  supplier?: unknown;
  suppliers?: unknown[];
  [key: string]: unknown;
};

export type DocBrand = {
  key: string;
  name: string;
  aliases?: string[];
  category: string;
  sort?: number;
  featured?: boolean;
  badge?: string;
  redeem_hint?: string;
  platform?: string;
  logo?: { display?: string; print?: string };
  active?: boolean;
  items: DocItem[];
  [key: string]: unknown;
};

export type DocCategory = { key: string; name: string; sort?: number; active?: boolean };

export type Doc = {
  price_mode?: string;
  categories: DocCategory[];
  countries?: { code: string; name?: string; flag?: string }[];
  brands: DocBrand[];
  [key: string]: unknown;
};

export const KEY_PATTERN = /^[a-z0-9][a-z0-9_-]{0,47}$/;
const PRICE_PATTERN = /^\d{1,9}(\.\d{1,2})?$/;

// ---------- the draft ----------

const STORE = "console-catalog-draft";

type Stored = { base: string; doc: Doc };

function readStored(): Stored | null {
  try {
    const raw = localStorage.getItem(STORE);
    const value = raw ? (JSON.parse(raw) as Stored) : null;
    return value && typeof value.base === "string" && value.doc && Array.isArray(value.doc.brands) ? value : null;
  } catch {
    return null;
  }
}

/**
 * The draft over the published document `published` (version `base`). It
 * survives a reload and a closed tab (a phone drops pages freely); `stale`
 * says the catalog was published again since the draft was started.
 */
export function useCatalogDraft(published: Doc | null | undefined, base: string | undefined) {
  const [stored, setStored] = useState<Stored | null>(readStored);
  const [unsaved, setUnsaved] = useState(false);

  useEffect(() => {
    try {
      if (stored) localStorage.setItem(STORE, JSON.stringify(stored));
      else localStorage.removeItem(STORE);
      setUnsaved(false);
    } catch {
      // Private mode, or a catalog larger than the browser keeps: the draft
      // lives as long as this page does, and the editor says so.
      setUnsaved(stored !== null);
    }
  }, [stored]);

  const doc = stored?.doc ?? published ?? null;
  const update = useCallback(
    (change: (doc: Doc) => Doc) => {
      setStored((current) => {
        const from = current?.doc ?? published;
        if (!from || base === undefined) return current;
        const next = change(from);
        return next === from ? current : { base: current?.base ?? base, doc: next };
      });
    },
    [published, base],
  );
  const discard = useCallback(() => setStored(null), []);
  return useMemo(
    () => ({ doc, update, discard, editing: stored !== null, stale: stored !== null && base !== undefined && stored.base !== base, unsaved }),
    [doc, update, discard, stored, base, unsaved],
  );
}

// ---------- changes, each returning a new document ----------

export function editBrand(doc: Doc, key: string, change: (brand: DocBrand) => DocBrand | null): Doc {
  const brands: DocBrand[] = [];
  for (const brand of doc.brands) {
    if (brand.key !== key) brands.push(brand);
    else {
      const next = change(brand);
      if (next) brands.push(next);
    }
  }
  return { ...doc, brands };
}

export function editItem(doc: Doc, brandKey: string, itemKey: string, change: (item: DocItem) => DocItem | null): Doc {
  return editBrand(doc, brandKey, (brand) => {
    const items: DocItem[] = [];
    for (const item of brand.items) {
      if (item.key !== itemKey) items.push(item);
      else {
        const next = change(item);
        if (next) items.push(next);
      }
    }
    return { ...brand, items };
  });
}

/** Changes every item in `keys` at once; an item `change` returns unchanged stays the same object. */
export function editItems(doc: Doc, keys: ReadonlySet<string>, change: (item: DocItem, brand: DocBrand) => DocItem): Doc {
  let touched = false;
  const brands = doc.brands.map((brand) => {
    let brandTouched = false;
    const items = brand.items.map((item) => {
      if (!keys.has(item.key)) return item;
      const next = change(item, brand);
      if (next !== item) brandTouched = true;
      return next;
    });
    if (!brandTouched) return brand;
    touched = true;
    return { ...brand, items };
  });
  return touched ? { ...doc, brands } : doc;
}

/** A field set to "" or undefined leaves the entry, so the document stays as a hand would write it. */
export function clean<T extends Record<string, unknown>>(entry: T): T {
  const out: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(entry)) {
    if (value === undefined || value === null || value === "") continue;
    out[key] = value;
  }
  return out as T;
}

export function allKeys(doc: Doc): Set<string> {
  const keys = new Set<string>();
  for (const b of doc.brands) {
    keys.add(b.key);
    for (const i of b.items) keys.add(i.key);
  }
  return keys;
}

/** A key nothing in the catalog uses yet: "itunes-us-10", then "itunes-us-10-2". */
export function freeKey(wanted: string, taken: ReadonlySet<string>): string {
  const base = wanted.toLowerCase().replace(/[^a-z0-9_-]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 44) || "item";
  if (!taken.has(base)) return base;
  for (let n = 2; ; n++) if (!taken.has(`${base}-${n}`)) return `${base}-${n}`;
}

// ---------- prices ----------

export const isActive = (flag: boolean | undefined) => flag !== false;

export function isAuto(doc: Doc, item: DocItem): boolean {
  return (item.price_mode || doc.price_mode || "static").toLowerCase() === "auto";
}

/** A price as the catalog writes it: two decimals at most, no trailing zeros forced. */
export function price(value: number): string {
  return (Math.round(value * 100) / 100).toFixed(2);
}

/** Rounds to a step of dinars (0.25, 0.5, 1); 0 keeps the piastres. */
export function roundTo(value: number, step: number): number {
  return step > 0 ? Math.round(value / step) * step : Math.round(value * 100) / 100;
}

/** What the operator typed as a price, in the catalog's form; null when it is not one. */
export function parsePrice(raw: string): string | null {
  const cleaned = raw
    .trim()
    .replace(/[٠-٩]/g, (d) => String("٠١٢٣٤٥٦٧٨٩".indexOf(d)))
    .replace(/[,،\s]/g, "")
    .replace("٫", ".");
  if (!PRICE_PATTERN.test(cleaned)) return null;
  return cleaned;
}

export type Adjust = { by: "percent" | "amount"; value: number; direction: 1 | -1; step: number };

export function adjust(current: string, a: Adjust): string {
  const n = Number(current);
  const moved = a.by === "percent" ? n * (1 + (a.direction * a.value) / 100) : n + a.direction * a.value;
  return price(Math.max(0, roundTo(moved, a.step)));
}

// ---------- promotions ----------

export type PromoState = "none" | "scheduled" | "running" | "ended";

export function promoState(promo: DocPromo | null | undefined, now = Date.now()): PromoState {
  if (!promo) return "none";
  const start = new Date(promo.starts_at).getTime();
  const end = new Date(promo.ends_at).getTime();
  if (now < start) return "scheduled";
  return now < end ? "running" : "ended";
}

/** An instant as <input type="datetime-local"> wants it, in this device's time. */
export function toLocalInput(iso: string): string {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

export function fromLocalInput(local: string): string {
  const d = new Date(local);
  return Number.isNaN(d.getTime()) ? "" : d.toISOString().replace(/\.\d{3}Z$/, "Z");
}

/** Now, to the minute, as the catalog writes an instant. */
export function nowISO(offsetHours = 0): string {
  const d = new Date(Date.now() + offsetHours * 3600_000);
  d.setSeconds(0, 0);
  return d.toISOString().replace(/\.\d{3}Z$/, "Z");
}

/**
 * What is wrong with an item as written, in the operator's words: the rules
 * the relay enforces at publish (vouchers.validateItem), said before it.
 */
export function itemProblems(item: DocItem): string[] {
  const out: string[] = [];
  const p = PRICE_PATTERN.test(item.price ?? "") ? Number(item.price) : null;
  const r = PRICE_PATTERN.test(item.retail_price ?? "") ? Number(item.retail_price) : null;
  if (p === null) out.push("سعر المتجر رقم بخانتين عشريتين على الأكثر.");
  if (r === null) out.push("سعر الزبون رقم بخانتين عشريتين على الأكثر.");
  if (p !== null && r !== null && r < p) out.push("سعر الزبون أقل من سعر المتجر: المتجر يبيع بخسارة.");
  if (!(item.label ?? "").trim() && !(item.face_value ?? "").trim()) out.push("الصنف يحتاج اسماً أو قيمة.");
  const promo = item.promo;
  if (promo) {
    const pp = promo.price ? (PRICE_PATTERN.test(promo.price) ? Number(promo.price) : NaN) : null;
    const pr = promo.retail_price ? (PRICE_PATTERN.test(promo.retail_price) ? Number(promo.retail_price) : NaN) : null;
    if (!promo.badge?.trim()) out.push("العرض يحتاج شارة (كلمة تظهر على البطاقة).");
    else if ([...promo.badge.trim()].length > 24) out.push("شارة العرض 24 حرفاً على الأكثر.");
    if (pp === null && pr === null) out.push("العرض يغيّر سعر المتجر أو سعر الزبون أو كليهما.");
    if (Number.isNaN(pp) || Number.isNaN(pr)) out.push("سعر العرض رقم بخانتين عشريتين على الأكثر.");
    if (pp !== null && p !== null && pp >= p) out.push("سعر المتجر في العرض يجب أن يكون أقل من سعره المعتاد.");
    if (pr !== null && r !== null && pr >= r) out.push("سعر الزبون في العرض يجب أن يكون أقل من سعره المعتاد.");
    const cost = pp ?? p;
    const sell = pr ?? r;
    if (cost !== null && sell !== null && sell < cost) out.push("في العرض يبيع المتجر بأقل مما يدفع.");
    const start = new Date(promo.starts_at).getTime();
    const end = new Date(promo.ends_at).getTime();
    if (Number.isNaN(start) || Number.isNaN(end)) out.push("للعرض بداية ونهاية.");
    else if (end <= start) out.push("نهاية العرض بعد بدايته.");
  }
  return out;
}

/** "brands[3].items[2].promo.price" as the relay reports a problem, said with the names it points at. */
export function describeProblem(doc: Doc, problem: string): string {
  const match = /^"?brands\[(\d+)\](?:\.items\[(\d+)\])?\.?([^":]*)"?:?\s*(.*)$/.exec(problem);
  if (!match) return problem;
  const brand = doc.brands[Number(match[1])];
  if (!brand) return problem;
  const item = match[2] !== undefined ? brand.items[Number(match[2])] : undefined;
  const where = item ? `${brand.name} — ${item.label || item.key}` : brand.name;
  return `${where} (${match[3] || "?"}): ${match[4]}`;
}
