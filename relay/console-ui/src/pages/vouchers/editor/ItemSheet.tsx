import { useState } from "react";
import { Copy, Package, Trash2, TriangleAlert } from "lucide-react";
import { clean, isActive, itemProblems, parsePrice, promoState, type Doc, type DocBrand, type DocItem } from "../../../lib/catalogDraft";
import { money } from "../../../lib/format";
import { Button, Field, Notice, Segmented, Switch } from "../../../components/ui";
import { Dialog } from "../../../components/dialog";
import { ProfitCell } from "../../../components/profit";
import { PriceInput, PromoWindow, discounted, newPromo } from "./PromoFields";

const KEY = /^[a-z0-9][a-z0-9_-]{0,47}$/;

/**
 * One card, every field of it. Saving writes the draft, not the shops: the
 * publish at the foot of the editor does that.
 */
export function ItemSheet({ doc, brand, item, isNew, cost, livePrice, takenKeys, onSave, onDelete, onDuplicate, onClose }: {
  doc: Doc;
  brand: DocBrand;
  item: DocItem;
  isNew: boolean;
  /** What the card costs the company now, when a supplier's price is known. */
  cost?: number;
  /** What shops pay now for a card the relay prices itself. */
  livePrice?: string;
  takenKeys: ReadonlySet<string>;
  onSave: (next: DocItem) => void;
  onDelete: () => void;
  onDuplicate: () => void;
  onClose: () => void;
}) {
  const [draft, setDraft] = useState<DocItem>(item);
  const [supplierText, setSupplierText] = useState(() => JSON.stringify(item.suppliers ?? item.supplier ?? {}, null, 2));
  const [confirmDelete, setConfirmDelete] = useState(false);
  const set = (patch: Partial<DocItem>) => setDraft((d) => ({ ...d, ...patch }));
  const promo = draft.promo ?? null;
  const setPromo = (patch: Partial<NonNullable<DocItem["promo"]>>) => set({ promo: { ...(promo ?? newPromo()), ...patch } });

  let supplierError = "";
  let supplierValue: unknown;
  try {
    supplierValue = JSON.parse(supplierText);
    if (!supplierValue || typeof supplierValue !== "object") supplierError = "المورّد كائن JSON، أو قائمة منها.";
  } catch (e) {
    supplierError = `JSON غير صالح: ${(e as Error).message}`;
  }

  const problems = itemProblems(draft);
  if (isNew && !KEY.test(draft.key)) problems.push("المعرّف: حروف إنجليزية صغيرة وأرقام و - و _ (حتى 48).");
  else if (isNew && takenKeys.has(draft.key)) problems.push("هذا المعرّف مستعمل في الكتالوج.");
  if (supplierError) problems.push(supplierError);

  const mode = (draft.price_mode ?? "") as "" | "static" | "auto";
  const auto = (mode || doc.price_mode || "static") === "auto";
  const shop = Number(draft.price);
  const retail = Number(draft.retail_price);
  const state = promoState(promo);

  function save() {
    const { supplier: _one, suppliers: _many, ...rest } = draft;
    const mapping = Array.isArray(supplierValue) ? { suppliers: supplierValue as unknown[] } : { supplier: supplierValue };
    const next = clean({
      ...rest,
      price: parsePrice(draft.price) ?? draft.price,
      retail_price: parsePrice(draft.retail_price) ?? draft.retail_price,
      label: draft.label?.trim(),
      promo: promo ? clean({ ...promo, badge: promo.badge.trim() }) : undefined,
      ...mapping,
    }) as DocItem;
    // "Shown" is the default: only a hidden item says so.
    if (next.active !== false) delete next.active;
    onSave(next);
  }

  return (
    <Dialog
      open
      onClose={onClose}
      dirty={draft !== item}
      title={isNew ? "صنف جديد" : draft.label || draft.key}
      subtitle={<>{brand.name} · <span className="mono">{draft.key || "…"}</span></>}
      icon={<Package />}
      footer={
        <>
          <Button variant="primary" size="lg" disabled={problems.length > 0} onClick={save}>
            {isNew ? "أضف إلى المسودة" : "احفظ في المسودة"}
          </Button>
          <Button size="lg" onClick={onClose}>
            إلغاء
          </Button>
        </>
      }
    >
      <div className="form">
        {isNew && (
          <Field label="المعرّف" htmlFor="it-key" help="لا يتغير بعد النشر: به تعرفه المتاجر والمخزون.">
            <input id="it-key" className="input mono" dir="ltr" value={draft.key} onChange={(e) => set({ key: e.target.value.trim().toLowerCase() })} />
          </Field>
        )}
        <Field label="الاسم على البطاقة" htmlFor="it-label" help="يُترك فارغاً ليُكتب من القيمة («10 دولار»).">
          <input id="it-label" className="input" value={draft.label ?? ""} maxLength={40} onChange={(e) => set({ label: e.target.value })} />
        </Field>
        <div className="form-grid">
          <Field label="يدفع المتجر" htmlFor="it-price">
            <PriceInput id="it-price" value={draft.price} onChange={(price) => set({ price })} invalid={parsePrice(draft.price) === null} />
          </Field>
          <Field label="يدفع الزبون" htmlFor="it-retail">
            <PriceInput id="it-retail" value={draft.retail_price} onChange={(retail_price) => set({ retail_price })} invalid={parsePrice(draft.retail_price) === null} />
          </Field>
        </div>
        <div className="edit-split">
          <div>
            <span>تكلفتنا</span>
            <strong>{cost !== undefined ? money(cost.toFixed(2)) : "—"}</strong>
          </div>
          <div>
            <span>ربحنا</span>
            <ProfitCell value={cost !== undefined && Number.isFinite(shop) ? shop - cost : undefined} of={cost} />
          </div>
          <div>
            <span>ربح المتجر</span>
            <ProfitCell value={Number.isFinite(shop) && Number.isFinite(retail) ? retail - shop : undefined} of={shop} />
          </div>
        </div>
        <Field label="التسعير">
          <Segmented
            value={mode}
            onChange={(next) => set({ price_mode: next || undefined })}
            options={[
              { id: "", label: `حسب الكتالوج (${(doc.price_mode || "static") === "auto" ? "تلقائي" : "ثابت"})` },
              { id: "static", label: "ثابت" },
              { id: "auto", label: "تلقائي" },
            ]}
          />
        </Field>
        {auto && (
          <Notice tone="info" icon={<TriangleAlert />}>
            سعره تلقائي: يحسبه الخادم من تكلفة أرخص مورّد{livePrice ? `، وهو الآن ${money(livePrice)} للمتجر` : ""}. السعران أعلاه يُستعملان فقط حين لا تُعرف التكلفة.
          </Notice>
        )}
        <div className="switch-row">
          <div className="text">
            ظاهر للمتاجر
            <span>المخفي يبقى في الكتالوج ولا يُباع.</span>
          </div>
          <Switch on={isActive(draft.active)} onChange={(on) => set({ active: on ? undefined : false })} label="ظاهر للمتاجر" />
        </div>

        <div className="switch-row">
          <div className="text">
            عرض مؤقت
            <span>{state === "running" ? "يعمل الآن" : state === "scheduled" ? "مجدول" : state === "ended" ? "انتهى" : "سعر أقل لمدة محددة"}</span>
          </div>
          <Switch on={!!promo} onChange={(on) => set({ promo: on ? newPromo() : undefined })} label="عرض مؤقت" />
        </div>
        {promo && (
          <>
            <div className="form-grid">
              <Field label="المتجر يدفع في العرض" help="فارغ: لا يتغير.">
                <PriceInput value={promo.price ?? ""} placeholder={draft.price} onChange={(price) => setPromo({ price: price || undefined })} />
              </Field>
              <Field label="الزبون يدفع في العرض" help="فارغ: لا يتغير.">
                <PriceInput value={promo.retail_price ?? ""} placeholder={draft.retail_price} onChange={(retail_price) => setPromo({ retail_price: retail_price || undefined })} />
              </Field>
            </div>
            <div className="chips">
              {[5, 10, 15, 20].map((percent) => (
                <button
                  type="button"
                  key={percent}
                  className="chip"
                  onClick={() =>
                    setPromo({
                      price: discounted(draft.price, percent) || undefined,
                      retail_price: discounted(draft.retail_price, percent) || undefined,
                      badge: promo.badge && promo.badge !== "عرض" && !/^خصم \d+%$/.test(promo.badge) ? promo.badge : `خصم ${percent}%`,
                    })
                  }
                >
                  خصم {percent}%
                </button>
              ))}
            </div>
            <PromoWindow promo={promo} onChange={(next) => set({ promo: next })} />
          </>
        )}

        <details className="edit-more">
          <summary>القيمة والمورّد والترتيب</summary>
          <div className="form">
            <div className="form-grid">
              <Field label="القيمة">
                <input className="input num" dir="ltr" inputMode="decimal" value={draft.face_value ?? ""} onChange={(e) => set({ face_value: e.target.value.trim() })} />
              </Field>
              <Field label="عملتها" help="USD، LYD…">
                <input className="input mono" dir="ltr" maxLength={3} value={draft.face_currency ?? ""} onChange={(e) => set({ face_currency: e.target.value.trim().toUpperCase() })} />
              </Field>
              <Field label="الدولة" help="رمز من حرفين، أو WW.">
                <input className="input mono" dir="ltr" maxLength={2} value={draft.country ?? ""} onChange={(e) => set({ country: e.target.value.trim().toUpperCase() })} />
              </Field>
              <Field label="الترتيب" help="الأصغر أولاً.">
                <input className="input num" dir="ltr" type="number" value={draft.sort ?? ""} onChange={(e) => set({ sort: e.target.value === "" ? undefined : Number(e.target.value) })} />
              </Field>
            </div>
            <Field label="المورّد (JSON)" help="من أين تُشترى البطاقة: كائن واحد، أو قائمة موردين يُشترى من أرخصهم." error={supplierError || null}>
              <textarea className="textarea code" dir="ltr" rows={6} spellCheck={false} value={supplierText} onChange={(e) => setSupplierText(e.target.value)} />
            </Field>
          </div>
        </details>

        {problems.length > 0 && (
          <Notice tone="warning" icon={<TriangleAlert />}>
            {problems.map((p) => (
              <div key={p}>{p}</div>
            ))}
          </Notice>
        )}
        {!isNew && (
          <div className="row">
            <Button size="sm" icon={<Copy />} onClick={onDuplicate}>
              انسخه صنفاً جديداً
            </Button>
            {confirmDelete ? (
              <Button size="sm" variant="danger" icon={<Trash2 />} onClick={onDelete}>
                أكّد الحذف
              </Button>
            ) : (
              <Button size="sm" variant="ghost" icon={<Trash2 />} onClick={() => setConfirmDelete(true)}>
                احذف الصنف
              </Button>
            )}
          </div>
        )}
      </div>
    </Dialog>
  );
}
