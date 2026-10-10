// What publishing a catalog would change, against the one published now:
// brands and items that appear or disappear, and items whose price, retail
// price or availability moves. Said before the passkey tap, so a stale file
// cannot quietly take forty cards off every shop.

type Doc = Record<string, any>;

export type ItemChange = { brand: string; item: string; label: string; field: "price" | "retail_price" | "active"; before: string; after: string };

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
  }
  diff.empty = !diff.brandsAdded.length && !diff.brandsRemoved.length && !diff.itemsAdded.length && !diff.itemsRemoved.length && !diff.changed.length;
  return diff;
}
