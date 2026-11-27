// Offer terms as the relay prices them (control/customer_offer_terms.go) and
// the app words them (cards/lib/src/features/offers): the builder's preview
// shows what a customer will see and pay. Amounts are dinars as decimals.

export type OfferKind = "percent" | "amount" | "tiered" | "bundle";
export type OfferTier = { min_order: string; value: string };
export type OfferScope = { categories?: string[]; brands?: string[]; items?: string[] };

export type OfferTerms = {
  kind: OfferKind;
  value: string;
  max_discount: string;
  min_order: string;
  tiers?: OfferTier[];
  tier_unit?: "percent" | "amount";
  buy_quantity?: number;
  get_quantity?: number;
  get_percent?: string;
  scope?: OfferScope;
  badge?: string;
};

export type OfferLine = { unit: number; quantity: number; category?: string; brand?: string; item?: string };

const num = (v: string | number | undefined) => {
  const n = Number(v ?? 0);
  return Number.isFinite(n) ? n : 0;
};

/** Down to the dirham, as the relay rounds. */
const dirham = (v: number) => Math.floor(v * 1000 + 1e-6) / 1000;

export function scopeIsEverything(scope?: OfferScope): boolean {
  return !scope || (!scope.categories?.length && !scope.brands?.length && !scope.items?.length);
}

export function scopeCovers(scope: OfferScope | undefined, line: OfferLine): boolean {
  if (scopeIsEverything(scope)) return true;
  const has = (list: string[] | undefined, v?: string) => !!v && !!list?.includes(v);
  return has(scope!.categories, line.category) || has(scope!.brands, line.brand) || has(scope!.items, line.item);
}

export function tierFor(terms: OfferTerms, subtotal: number): OfferTier | undefined {
  let best: OfferTier | undefined;
  for (const tier of sortedTiers(terms)) if (subtotal >= num(tier.min_order)) best = tier;
  return best;
}

export function sortedTiers(terms: OfferTerms): OfferTier[] {
  return [...(terms.tiers ?? [])].sort((a, b) => num(a.min_order) - num(b.min_order));
}

/** What the offer takes off a line: nothing out of scope or below its minimum. */
export function discountOn(terms: OfferTerms, line: OfferLine): number {
  const subtotal = line.unit * line.quantity;
  if (subtotal <= 0 || !scopeCovers(terms.scope, line) || subtotal < num(terms.min_order)) return 0;
  let off = 0;
  let capped = true;
  switch (terms.kind) {
    case "percent":
      off = (subtotal * num(terms.value)) / 100;
      break;
    case "amount":
      off = num(terms.value);
      capped = false;
      break;
    case "tiered": {
      const tier = tierFor(terms, subtotal);
      if (!tier) return 0;
      if (terms.tier_unit === "amount") {
        off = num(tier.value);
        capped = false;
      } else off = (subtotal * num(tier.value)) / 100;
      break;
    }
    case "bundle": {
      const buy = terms.buy_quantity ?? 0;
      const get = terms.get_quantity ?? 0;
      if (buy <= 0 || get <= 0) return 0;
      const discounted = Math.floor(line.quantity / (buy + get)) * get;
      off = (line.unit * discounted * num(terms.get_percent || 100)) / 100;
      break;
    }
  }
  if (capped && num(terms.max_discount) > 0) off = Math.min(off, num(terms.max_discount));
  return dirham(Math.min(off, subtotal));
}

const pctText = (v: string | number) => `${Number(num(v).toFixed(2))}٪`;
const dinarText = (v: string | number) => `${num(v).toFixed(2)} د.ل`;

/** The badge the app writes on what the offer covers. */
export function badgeText(terms: OfferTerms): string {
  if (terms.badge?.trim()) return terms.badge.trim();
  switch (terms.kind) {
    case "percent":
      return `خصم ${pctText(terms.value)}`;
    case "amount":
      return `خصم ${dinarText(terms.value)}`;
    case "tiered": {
      const top = sortedTiers(terms).at(-1)?.value ?? terms.value;
      return `خصم حتى ${terms.tier_unit === "amount" ? dinarText(top) : pctText(top)}`;
    }
    case "bundle":
      return num(terms.get_percent || 100) >= 100
        ? `اشترِ ${terms.buy_quantity ?? 0} واحصل على ${terms.get_quantity ?? 0} مجاناً`
        : `اشترِ ${terms.buy_quantity ?? 0} والتالي بخصم ${pctText(terms.get_percent ?? 0)}`;
  }
}

/** A nudge to a better deal on a line, as the checkout shows it. */
export function nudgeText(terms: OfferTerms, line: OfferLine): string | null {
  if (!scopeCovers(terms.scope, line)) return null;
  const subtotal = line.unit * line.quantity;
  switch (terms.kind) {
    case "bundle": {
      const group = (terms.buy_quantity ?? 0) + (terms.get_quantity ?? 0);
      if (group <= 0 || (line.quantity >= group && line.quantity % group === 0)) return null;
      return `أضف ${group - (line.quantity % group)} لتحصل على العرض`;
    }
    case "tiered": {
      const next = sortedTiers(terms).find((t) => subtotal < num(t.min_order));
      if (!next) return null;
      const value = terms.tier_unit === "amount" ? dinarText(next.value) : pctText(next.value);
      return `أضف ${dinarText(num(next.min_order) - subtotal)} لتحصل على ${value}`;
    }
    default:
      return subtotal < num(terms.min_order) ? `على الطلبات من ${dinarText(terms.min_order)} فأكثر` : null;
  }
}

/** What is wrong with terms, in words; empty when they can be made. */
export function termsProblems(terms: OfferTerms): string[] {
  const out: string[] = [];
  const limit = (v: string, unit: "percent" | "amount") => (unit === "percent" ? num(v) > 0 && num(v) <= 90 : num(v) > 0 && num(v) <= 500);
  switch (terms.kind) {
    case "percent":
      if (!limit(terms.value, "percent")) out.push("النسبة بين 0 و90٪.");
      break;
    case "amount":
      if (!limit(terms.value, "amount")) out.push("المبلغ بين 0 و500 د.ل.");
      break;
    case "tiered": {
      const tiers = sortedTiers(terms);
      if (tiers.length === 0 || tiers.length > 5) out.push("من مستوى إلى خمسة مستويات.");
      tiers.forEach((t, i) => {
        if (!limit(t.value, terms.tier_unit ?? "percent")) out.push(`المستوى ${i + 1}: الخصم ${terms.tier_unit === "amount" ? "بين 0 و500 د.ل" : "بين 0 و90٪"}.`);
        if (i > 0 && (num(t.min_order) <= num(tiers[i - 1].min_order) || num(t.value) <= num(tiers[i - 1].value)))
          out.push(`المستوى ${i + 1}: يبدأ بطلب أكبر ويعطي أكثر من الذي قبله.`);
      });
      break;
    }
    case "bundle":
      if (!(terms.buy_quantity! >= 1 && terms.buy_quantity! <= 10 && terms.get_quantity! >= 1 && terms.get_quantity! <= 10))
        out.push("اشترِ واحصل: من 1 إلى 10 كروت لكلٍّ منهما.");
      if (!(num(terms.get_percent || 100) > 0 && num(terms.get_percent || 100) <= 100)) out.push("خصم الكروت المضافة بين 0 و100٪.");
      break;
  }
  if ((terms.badge ?? "").trim().length > 24) out.push("الشارة 24 حرفاً على الأكثر.");
  return out;
}

export const offerKindInfo: Record<OfferKind, { label: string; example: string }> = {
  percent: { label: "نسبة مئوية", example: "خصم 15٪ حتى 5 د.ل" },
  amount: { label: "مبلغ ثابت", example: "خصم 3 د.ل على طلب من 20" },
  tiered: { label: "كلما زاد الطلب", example: "5٪ من 20، 10٪ من 50، 15٪ من 100" },
  bundle: { label: "اشترِ واحصل", example: "اشترِ 2 واحصل على 1 مجاناً" },
};
