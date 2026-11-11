// What publishing a catalog would change, against the one published now:
// brands and items that appear or disappear, and items whose price, retail
// price or availability moves. Said before the passkey tap, so a stale file
// cannot quietly take forty cards off every shop.

type Doc = Record<string, any>;

export type ItemChange = { brand: string; item: string; label: string; field: "price" | "retail_price" | "active" | "promo" | "other"; before: string; after: string };

export type CatalogDiff = {
  brandsAdded: string[];
  brandsRemoved: string[];
  itemsAdded: { brand: string; label: string }[];
  itemsRemoved: { brand: string; label: string }[];
  changed: ItemChange[];
  empty: boolean;
};

function itemsOf(doc: Doc | null | undefined): Map<string, { brand: string; label: string; item: Doc }> {
  const out = new Map<string, { brand: string; label: string; item: Doc }>();
  for (const b of (doc?.brands ?? []) as Doc[]) {
    for (const i of (b.items ?? []) as Doc[]) {
      out.set(`${b.key}/${i.key}`, { brand: String(b.name ?? b.key), label: String(i.label || i.key), item: i });
    }
  }
  return out;
}

/** A promotion as one line: "عرض 50.00 / 58.00 حتى 2026-10-08". */
function shownPromo(promo: Doc | null | undefined): string {
  if (!promo) return "";
  const prices = [promo.price, promo.retail_price].filter(Boolean).join(" / ");
  return `«${promo.badge ?? ""}» ${prices} حتى ${String(promo.ends_at ?? "").slice(0, 10)}`.trim();
}

/** Everything about an entry but the fields the diff already names. */
function rest(entry: Doc): string {
  const { price: _p, retail_price: _r, active: _a, promo: _o, ...others } = entry;
  return JSON.stringify(others);
}

const shownActive = (v: unknown) => (v === false ? "مخفي" : "ظاهر");

export function diffCatalog(before: Doc | null | undefined, after: Doc | null | undefined): CatalogDiff {
  const brandNames = (doc: Doc | null | undefined) => new Map(((doc?.brands ?? []) as Doc[]).map((b) => [String(b.key), String(b.name ?? b.key)]));
  const bBefore = brandNames(before);
  const bAfter = brandNames(after);
  const iBefore = itemsOf(before);
  const iAfter = itemsOf(after);
  const diff: CatalogDiff = {
    brandsAdded: [...bAfter].filter(([k]) => !bBefore.has(k)).map(([, n]) => n),
    brandsRemoved: [...bBefore].filter(([k]) => !bAfter.has(k)).map(([, n]) => n),
    itemsAdded: [...iAfter].filter(([k]) => !iBefore.has(k)).map(([, v]) => ({ brand: v.brand, label: v.label })),
    itemsRemoved: [...iBefore].filter(([k]) => !iAfter.has(k)).map(([, v]) => ({ brand: v.brand, label: v.label })),
    changed: [],
    empty: false,
  };
  for (const [key, now] of iAfter) {
    const was = iBefore.get(key);
    if (!was) continue;
    for (const field of ["price", "retail_price"] as const) {
      const a = String(was.item[field] ?? "");
      const b = String(now.item[field] ?? "");
      if (Number(a) !== Number(b) || (a === "") !== (b === "")) diff.changed.push({ brand: now.brand, item: key, label: now.label, field, before: a, after: b });
    }
    if ((was.item.active === false) !== (now.item.active === false)) {
      diff.changed.push({ brand: now.brand, item: key, label: now.label, field: "active", before: shownActive(was.item.active), after: shownActive(now.item.active) });
    }
    if (was.item === now.item) continue;
    const promoWas = shownPromo(was.item.promo);
    const promoNow = shownPromo(now.item.promo);
    if (promoWas !== promoNow) diff.changed.push({ brand: now.brand, item: key, label: now.label, field: "promo", before: promoWas, after: promoNow });
    else if (rest(was.item) !== rest(now.item)) diff.changed.push({ brand: now.brand, item: key, label: now.label, field: "other", before: "", after: "" });
  }
  // A brand's own fields (name, category, badge, logo…), its items aside.
  const brandsBefore = new Map(((before?.brands ?? []) as Doc[]).map((b) => [String(b.key), b]));
  for (const b of (after?.brands ?? []) as Doc[]) {
    const was = brandsBefore.get(String(b.key));
    if (was && was !== b && rest({ ...was, items: null }) !== rest({ ...b, items: null })) {
      diff.changed.push({ brand: String(b.name ?? b.key), item: String(b.key), label: "العلامة", field: "other", before: "", after: "" });
    }
  }
  if (JSON.stringify(before?.categories ?? []) !== JSON.stringify(after?.categories ?? [])) {
    diff.changed.push({ brand: "الفئات", item: "categories", label: "الترتيب والأسماء", field: "other", before: "", after: "" });
  }
  diff.empty = !diff.brandsAdded.length && !diff.brandsRemoved.length && !diff.itemsAdded.length && !diff.itemsRemoved.length && !diff.changed.length;
  return diff;
}
