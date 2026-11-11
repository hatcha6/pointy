import { useMemo, useState } from "react";
import { Layers, TriangleAlert } from "lucide-react";
import { adjust, clean, editItems, isAuto, itemProblems, type Doc, type DocBrand, type DocItem, type DocPromo } from "../../../lib/catalogDraft";
import { count, money } from "../../../lib/format";
import { Button, Field, Notice, Segmented } from "../../../components/ui";
import { Dialog } from "../../../components/dialog";
import { PromoWindow, discounted, newPromo } from "./PromoFields";

type Action = "prices" | "promo" | "show" | "mode";
type Target = { brand: DocBrand; item: DocItem };

const steps = [
  { id: "0", label: "بلا تقريب" },
  { id: "0.25", label: "ربع دينار" },
  { id: "0.5", label: "نصف دينار" },
  { id: "1", label: "دينار" },
];

/** The number a box holds; NaN when it is not one. */
const numberOf = (raw: string) => (raw.trim() === "" ? NaN : Number(raw.replace(",", ".").replace("٫", ".")));

/**
 * One change to many cards at once: the ones the editor's search and filters
 * show, or one brand's. A card the change would break (a customer price
 * under the shop's, a promotion that is no discount) is left as it was, and
 * the sheet says how many before anything is applied.
 */
export function BulkSheet({ doc, targets, scope, onApply, onClose }: {
  doc: Doc;
  targets: Target[];
  /** What the cards are, in a few words: "علامة آيتونز", "نتائج البحث". */
  scope: string;
  onApply: (change: (doc: Doc) => Doc, done: string) => void;
  onClose: () => void;
}) {
  const [action, setAction] = useState<Action>("prices");
  // prices
  const [field, setField] = useState<"both" | "price" | "retail_price">("both");
  const [direction, setDirection] = useState<"1" | "-1">("1");
  const [by, setBy] = useState<"percent" | "amount">("percent");
  const [value, setValue] = useState("");
  const [step, setStep] = useState("0");
  // promotion
  const [promoMode, setPromoMode] = useState<"set" | "clear">("set");
  const [shopOff, setShopOff] = useState("");
  const [retailOff, setRetailOff] = useState("10");
  const [promo, setPromo] = useState<DocPromo>(() => newPromo("خصم 10%"));
  // visibility, price mode
  const [show, setShow] = useState<"show" | "hide">("hide");
  const [mode, setMode] = useState<"" | "static" | "auto">("auto");

  /** The change to one card, or the same card when there is nothing to change. */
  const change = useMemo<((item: DocItem) => DocItem) | null>(() => {
    if (action === "prices") {
      const amount = numberOf(value);
      if (!(amount > 0)) return null;
      const a = { by, value: amount, direction: Number(direction) as 1 | -1, step: Number(step) };
      return (item) => ({
        ...item,
        price: field === "retail_price" ? item.price : adjust(item.price, a),
        retail_price: field === "price" ? item.retail_price : adjust(item.retail_price, a),
      });
    }
    if (action === "promo") {
      if (promoMode === "clear") return (item) => (item.promo ? (({ promo: _gone, ...rest }) => rest as DocItem)(item) : item);
      const shop = numberOf(shopOff);
      const retail = numberOf(retailOff);
      if (!(shop > 0) && !(retail > 0)) return null;
      return (item) => ({
        ...item,
        promo: clean({
          ...promo,
          badge: promo.badge.trim(),
          price: shop > 0 ? discounted(item.price, shop) : "",
          retail_price: retail > 0 ? discounted(item.retail_price, retail) : "",
        }) as DocPromo,
      });
    }
    if (action === "show") {
      return (item) => {
        if ((item.active !== false) === (show === "show")) return item;
        const { active: _was, ...rest } = item;
        return (show === "show" ? rest : { ...rest, active: false }) as DocItem;
      };
    }
    return (item) => {
      if ((item.price_mode ?? "") === mode) return item;
      const { price_mode: _was, ...rest } = item;
      return (mode ? { ...rest, price_mode: mode } : rest) as DocItem;
    };
  }, [action, field, direction, by, value, step, promoMode, shopOff, retailOff, promo, show, mode]);

  const plan = useMemo(() => {
    const changed: { target: Target; next: DocItem }[] = [];
    let broken = 0;
    if (change) {
      for (const target of targets) {
        const next = change(target.item);
        if (next === target.item || JSON.stringify(next) === JSON.stringify(target.item)) continue;
        // A card that was sound and would not be is left alone.
        if (itemProblems(next).length > 0 && itemProblems(target.item).length === 0) broken++;
        else changed.push({ target, next });
      }
    }
    return { changed, broken };
  }, [change, targets]);
  const autoPriced = action === "prices" ? targets.filter((t) => isAuto(doc, t.item)).length : 0;

  function apply() {
    const next = new Map(plan.changed.map((c) => [c.target.item.key, c.next]));
    onApply((current) => editItems(current, new Set(next.keys()), (item) => next.get(item.key) ?? item), `عُدّل ${count(next.size)} صنفاً في المسودة.`);
  }

  return (
    <Dialog
      open
      onClose={onClose}
      title="تعديل جماعي"
      subtitle={`${count(targets.length)} صنفاً — ${scope}`}
      icon={<Layers />}
      footer={
        <>
          <Button variant="primary" size="lg" disabled={plan.changed.length === 0} onClick={apply}>
            {plan.changed.length ? `طبّق على ${count(plan.changed.length)} صنفاً` : "لا تغيير"}
          </Button>
          <Button size="lg" onClick={onClose}>
            إلغاء
          </Button>
        </>
      }
    >
      <div className="form">
        <Segmented<Action>
          value={action}
          onChange={setAction}
          options={[
            { id: "prices", label: "الأسعار" },
            { id: "promo", label: "عرض وخصم" },
            { id: "show", label: "الإظهار" },
            { id: "mode", label: "التسعير" },
          ]}
        />
        {action === "prices" && (
          <>
            <Field label="أي سعر">
              <Segmented
                value={field}
                onChange={setField}
                options={[
                  { id: "both", label: "السعران" },
                  { id: "price", label: "سعر المتجر" },
                  { id: "retail_price", label: "سعر الزبون" },
                ]}
              />
            </Field>
            <div className="form-grid">
              <Field label="الاتجاه">
                <Segmented value={direction} onChange={setDirection} options={[{ id: "1", label: "رفع" }, { id: "-1", label: "خفض" }]} />
              </Field>
              <Field label="بمقدار">
                <div className="row" style={{ flexWrap: "nowrap" }}>
                  <input className="input num" dir="ltr" inputMode="decimal" placeholder={by === "percent" ? "5" : "0.50"} value={value} onChange={(e) => setValue(e.target.value)} />
                  <Segmented value={by} onChange={setBy} options={[{ id: "percent", label: "%" }, { id: "amount", label: "د.ل" }]} />
                </div>
              </Field>
            </div>
            <Field label="تقريب السعر الجديد إلى">
              <div className="chips">
                {steps.map((s) => (
                  <button type="button" key={s.id} className={`chip ${step === s.id ? "on" : ""}`} onClick={() => setStep(s.id)}>
                    {s.label}
                  </button>
                ))}
              </div>
            </Field>
            {autoPriced > 0 && (
              <Notice tone="info" icon={<TriangleAlert />}>
                {count(autoPriced)} منها سعرها تلقائي: يتغير سعرها المكتوب (الاحتياطي) فقط، لا ما تدفعه المتاجر الآن. هامشها من صفحة «التسعير».
              </Notice>
            )}
          </>
        )}
        {action === "promo" && (
          <>
            <Segmented value={promoMode} onChange={setPromoMode} options={[{ id: "set", label: "ضع عرضاً" }, { id: "clear", label: "أزل العروض" }]} />
            {promoMode === "set" && (
              <>
                <div className="form-grid">
                  <Field label="خصم للزبون %" help="من سعر الزبون. فارغ: لا يتغير.">
                    <input
                      className="input num"
                      dir="ltr"
                      inputMode="decimal"
                      value={retailOff}
                      onChange={(e) => {
                        setRetailOff(e.target.value);
                        const n = numberOf(e.target.value);
                        if (/^(عرض|خصم \d+(\.\d+)?%)$/.test(promo.badge) && n > 0) setPromo({ ...promo, badge: `خصم ${n}%` });
                      }}
                    />
                  </Field>
                  <Field label="خصم للمتجر %" help="من سعر المتجر: ربح أكبر له. فارغ: لا يتغير.">
                    <input className="input num" dir="ltr" inputMode="decimal" value={shopOff} onChange={(e) => setShopOff(e.target.value)} />
                  </Field>
                </div>
                <PromoWindow promo={promo} onChange={setPromo} />
              </>
            )}
          </>
        )}
        {action === "show" && (
          <Segmented value={show} onChange={setShow} options={[{ id: "hide", label: "أخفِها عن المتاجر" }, { id: "show", label: "أظهرها" }]} />
        )}
        {action === "mode" && (
          <Field label="طريقة التسعير" help="التلقائي يحسبه الخادم من تكلفة أرخص مورّد وهامش صفحة «التسعير».">
            <Segmented
              value={mode}
              onChange={setMode}
              options={[
                { id: "auto", label: "تلقائي" },
                { id: "static", label: "ثابت" },
                { id: "", label: "حسب الكتالوج" },
              ]}
            />
          </Field>
        )}

        {plan.changed.length > 0 && (action === "prices" || (action === "promo" && promoMode === "set")) && (
          <div className="bulk-preview">
            <strong>مثال مما سيتغير</strong>
            {plan.changed.slice(0, 4).map(({ target, next }) => (
              <div key={target.item.key} className="bulk-row">
                <span>
                  {target.brand.name} · {target.item.label || target.item.key}
                </span>
                {action === "prices" ? (
                  <span className="num">
                    {money(target.item.price)} ← <b>{money(next.price)}</b> · {money(target.item.retail_price)} ← <b>{money(next.retail_price)}</b>
                  </span>
                ) : (
                  <span className="num">
                    {next.promo?.price && (
                      <>
                        المتجر {money(target.item.price)} ← <b>{money(next.promo.price)}</b>{" "}
                      </>
                    )}
                    {next.promo?.retail_price && (
                      <>
                        الزبون {money(target.item.retail_price)} ← <b>{money(next.promo.retail_price)}</b>
                      </>
                    )}
                  </span>
                )}
              </div>
            ))}
          </div>
        )}
        {plan.broken > 0 && (
          <Notice tone="warning" icon={<TriangleAlert />}>
            {count(plan.broken)} صنفاً تُترك كما هي: التعديل يجعل سعر الزبون أقل من سعر المتجر، أو يجعل العرض بلا خصم أو بخسارة للمتجر.
          </Notice>
        )}
      </div>
    </Dialog>
  );
}
