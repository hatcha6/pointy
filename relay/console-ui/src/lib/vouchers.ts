// The card shop as the relay's admin routes describe it.

import { money } from "./format";
import { supplier } from "./labels";

export type ShopItem = {
  key: string;
  country: string;
  label: string;
  face_value: string;
  face_currency: string;
  unit_price: string;
  retail_price: string;
  regular_unit_price?: string;
  regular_retail_price?: string;
  promo?: { badge: string; ends_at: string } | null;
  available: boolean;
  rank: number;
};

export type ShopBrand = {
  key: string;
  name: string;
  category: string;
  rank: number;
  featured: boolean;
  badge?: string;
  logo?: string;
  print_logo?: string;
  items: ShopItem[];
};

export type ShopView = {
  version: string;
  currency: string;
  test_mode: boolean;
  generated_at: string;
  categories: { key: string; name: string; rank: number }[];
  countries: { code: string; name: string; flag?: string }[];
  brands: ShopBrand[];
};

export type Offer = { name: string; price: string; currency: string; in_stock: boolean };

export type SupplierOption = {
  supplier: string;
  ref: string;
  max_cost?: string;
  offer?: Offer | null;
  cost_lyd?: string;
  candidate: boolean;
  rank: number;
  reason?: string;
};

export type Supply = {
  item: string;
  brand: string;
  name: string;
  supplier: string;
  ref: string;
  max_cost?: string;
  offer?: Offer | null;
  available: boolean;
  reason?: string;
  winner?: string;
  suppliers?: SupplierOption[];
};

export type CatalogRecord = { id: string; sha256: string; actor: string; note: string; created_at: string; document?: unknown };

export type CatalogAnswer = { catalog: CatalogRecord | null; view: ShopView | null; supply: Supply[] };

export type SupplierOffer = {
  /** The supplier's price before its last change, and when it changed. */
  previous_price?: string;
  price_changed_at?: string | null;
  supplier: string;
  ref: string;
  name: string;
  group?: string;
  price: string;
  currency: string;
  in_stock: boolean;
  synced_at: string;
  cost_lyd?: string;
};

/** Why a supplier cannot sell an item: the relay's English sentence, in Arabic where known. */
const reasonPrefixes: [string, string][] = [
  ["the item is not on sale", "الصنف غير معروض للبيع"],
  ["the item names no supplier", "الصنف بلا مورّد"],
  ["test mode buys from nobody", "الوضع التجريبي لا يشتري من أحد"],
  ["the relay does not buy from", "الخادم غير مضبوط للشراء من هذا المورّد"],
  ["the price at Reloadly is not known", "سعر Reloadly غير معروف بعد"],
  ["the supplier no longer sells this card", "المورّد لم يعد يبيع هذه البطاقة"],
  ["the supplier is out of stock", "نفدت لدى المورّد"],
  ["no code left in the company's stock", "نفد مخزوننا من هذه البطاقة"],
  ["this relay keeps no stock", "الخادم لا يحفظ مخزوناً"],
];

/** "the supplier's price 163.76 LYD is above max_cost 163.47", or "… 10.70 USD (107.00 LYD) …". */
const overGuard = /^the supplier's price (\S+) (\S*) ?(?:\((\S+) LYD\) )?is above max_cost (\S+)$/;

/** Several suppliers each give their reason: "bnplus: …; reloadly: …". */
const perSupplier = /^([a-z0-9_]+): (.*)$/;

function oneReason(reason: string): string {
  const over = overGuard.exec(reason);
  if (over) {
    const [, price, currency, lyd, guard] = over;
    const cost = lyd ?? (currency === "" || currency.toUpperCase() === "LYD" ? price : undefined);
    const quoted = cost === undefined ? `${price} ${currency}` : money(cost);
    return `سعر المورّد ${quoted} أعلى من حد التكلفة ${money(guard)}`;
  }
  for (const [prefix, arabic] of reasonPrefixes) if (reason.startsWith(prefix)) return arabic;
  return reason;
}

export function reasonText(reason?: string): string {
  if (!reason) return "";
  const parts = reason.split("; ");
  if (parts.length > 1 || perSupplier.test(reason)) {
    return parts
      .map((part) => {
        const named = perSupplier.exec(part);
        return named ? `${supplier[named[1]] ?? named[1]}: ${oneReason(named[2])}` : oneReason(part);
      })
      .join(" · ");
  }
  return oneReason(reason);
}
