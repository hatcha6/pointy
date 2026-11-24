import { useMemo, useState } from "react";
import { Gift, Minus, Plus, Tag, TrendingUp } from "lucide-react";
import { money } from "../../lib/format";
import { badgeText, discountOn, nudgeText, scopeCovers, type OfferLine, type OfferTerms } from "../../lib/offers";
import type { PickerList } from "../../lib/picker";

/**
 * How the offer looks in «دفتر كروت», drawn the way the app draws it: the
 * badge on a card's tile, the banner on its page, and a checkout for a card
 * it covers, at a quantity the operator can change, priced as the relay
 * prices it.
 */
export function OfferPreview({
  terms,
  title,
  description,
  forEveryone,
  days,
  catalog,
}: {
  terms: OfferTerms;
  title: string;
  description: string;
  forEveryone: boolean;
  days: number;
  catalog?: PickerList;
}) {
  const brandOf = useMemo(() => new Map((catalog?.brands ?? []).map((b) => [b.key, b])), [catalog]);
  // The cards it covers, with a price to show.
  const covered = useMemo(() => {
    const out: { key: string; name: string; brand: string; category: string; price: number }[] = [];
    for (const item of catalog?.items ?? []) {
      const brand = brandOf.get(item.brand);
      const price = Number(item.price ?? 0);
      if (!brand || !(price > 0)) continue;
      const line: OfferLine = { unit: price, quantity: 1, category: brand.category, brand: item.brand, item: item.key };
      if (scopeCovers(terms.scope, line)) out.push({ key: item.key, name: item.name, brand: brand.name, category: brand.category ?? "", price });
      if (out.length >= 200) break;
    }
    return out;
  }, [catalog, brandOf, terms.scope]);
  const [picked, setPicked] = useState("");
  const [quantity, setQuantity] = useState(terms.kind === "bundle" ? (terms.buy_quantity ?? 1) + (terms.get_quantity ?? 1) : 1);
  const sample =
    covered.find((c) => c.key === picked) ??
    covered[0] ?? { key: "", name: "كرت تجريبي · 25 دينار", brand: "كرت تجريبي", category: "", price: 25 };
  const line: OfferLine = {
    unit: sample.price,
    quantity,
    category: sample.category,
    brand: catalog?.items.find((i) => i.key === sample.key)?.brand ?? "",
    item: sample.key,
  };
  // A sample card outside every list still shows the terms.
  const terms0 = covered.length ? terms : { ...terms, scope: undefined };
  const off = discountOn(terms0, line);
  const subtotal = line.unit * line.quantity;
  const nudge = nudgeText(terms0, line);
  const badge = badgeText(terms);
  const Icon = forEveryone ? Tag : Gift;
  const ends = days <= 1 ? "ينتهي اليوم" : days === 2 ? "ينتهي غداً" : days <= 7 ? `ينتهي خلال ${days} أيام` : "";

  return (
    <div className="offer-preview" dir="rtl">
      <div className="op-label">على الرف</div>
      <div className="op-shelf">
        <div className="op-tile">
          <div className="op-art">
            <span className="op-pill">
              <Icon /> {badge}
            </span>
            <span className="op-art-name">{sample.brand}</span>
          </div>
          <div className="op-tile-name">{sample.brand}</div>
          <div className="op-tile-price">من {money(sample.price)}</div>
        </div>
      </div>

      <div className="op-label">في صفحة الكرت</div>
      <div className="op-banner">
        <span className="op-banner-icon">
          <Icon />
        </span>
        <div>
          <div className="op-banner-head">
            <strong>{forEveryone ? "عرض" : "عرض لك"}</strong>
            <span className="op-pill">
              <Icon /> {badge}
            </span>
          </div>
          <div className="op-banner-title">{title || "عنوان العرض"}</div>
          {description && <div className="op-banner-sub">{description}</div>}
          {ends && <div className="op-banner-sub">{ends}</div>}
          {forEveryone && <div className="op-banner-sub">سجّل الدخول لتستفيد من العرض (لمن لم يدخل)</div>}
        </div>
      </div>

      <div className="op-label">عند الدفع</div>
      <div className="op-checkout">
        <div className="op-controls">
          <select className="select" value={sample.key} onChange={(e) => setPicked(e.target.value)} aria-label="كرت للمعاينة">
            {covered.length === 0 ? <option value="">{sample.name}</option> : covered.map((c) => <option key={c.key} value={c.key}>{c.name}</option>)}
          </select>
          <div className="op-stepper" aria-label="الكمية">
            <button type="button" onClick={() => setQuantity((q) => Math.min(q + 1, 10))} aria-label="زيادة">
              <Plus />
            </button>
            <span>{quantity}</span>
            <button type="button" onClick={() => setQuantity((q) => Math.max(q - 1, 1))} aria-label="إنقاص">
              <Minus />
            </button>
          </div>
        </div>
        {off > 0 && (
          <div className="op-row op-offer">
            <Icon />
            <div>
              <strong>{title || "عنوان العرض"}</strong>
              <span>وفّر {money(off)} مع هذا العرض</span>
            </div>
          </div>
        )}
        {nudge && (
          <div className="op-row op-nudge">
            <TrendingUp /> <strong>{nudge}</strong>
          </div>
        )}
        <div className="op-lines">
          <div>
            <span>السعر</span>
            <span>{money(subtotal)}</span>
          </div>
          {off > 0 && (
            <div className="op-discount">
              <span>الخصم</span>
              <span>− {money(off)}</span>
            </div>
          )}
          <div className="op-total">
            <span>المطلوب دفعه</span>
            <span>{money(subtotal - off)}</span>
          </div>
        </div>
        {covered.length === 0 && catalog && <p className="op-note">لا كرت بسعر معروف ضمن ما اخترته: المعاينة بكرت تجريبي.</p>}
      </div>
    </div>
  );
}
