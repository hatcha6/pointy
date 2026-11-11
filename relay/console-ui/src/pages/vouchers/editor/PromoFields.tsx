import { fromLocalInput, nowISO, parsePrice, price, toLocalInput, type DocPromo } from "../../../lib/catalogDraft";
import { Field } from "../../../components/ui";

/** How long a promotion runs, from its start. */
const lengths = [
  { hours: 24, label: "يوم" },
  { hours: 72, label: "3 أيام" },
  { hours: 168, label: "أسبوع" },
  { hours: 720, label: "شهر" },
];

/** A promotion's badge and its window: when it starts, and how long it runs. */
export function PromoWindow({ promo, onChange }: { promo: DocPromo; onChange: (next: DocPromo) => void }) {
  const lasts = (hours: number) => {
    const start = new Date(promo.starts_at).getTime();
    const from = Number.isNaN(start) ? Date.now() : start;
    onChange({ ...promo, ends_at: new Date(from + hours * 3600_000).toISOString().replace(/\.\d{3}Z$/, "Z") });
  };
  return (
    <>
      <Field label="الشارة" help="كلمة قصيرة تظهر على البطاقة عند المتجر: «عرض»، «خصم 10%».">
        <input className="input" value={promo.badge} maxLength={24} onChange={(e) => onChange({ ...promo, badge: e.target.value })} />
      </Field>
      <div className="form-grid">
        <Field label="يبدأ">
          <input
            className="input"
            type="datetime-local"
            value={toLocalInput(promo.starts_at)}
            onChange={(e) => onChange({ ...promo, starts_at: fromLocalInput(e.target.value) })}
          />
        </Field>
        <Field label="ينتهي">
          <input
            className="input"
            type="datetime-local"
            value={toLocalInput(promo.ends_at)}
            onChange={(e) => onChange({ ...promo, ends_at: fromLocalInput(e.target.value) })}
          />
        </Field>
      </div>
      <div className="chips">
        <button type="button" className="chip" onClick={() => onChange({ ...promo, starts_at: nowISO() })}>
          يبدأ الآن
        </button>
        {lengths.map((l) => (
          <button type="button" key={l.hours} className="chip" onClick={() => lasts(l.hours)}>
            مدته {l.label}
          </button>
        ))}
      </div>
    </>
  );
}

/** A new promotion: starts now, runs a week. */
export function newPromo(badge = "عرض"): DocPromo {
  return { badge, starts_at: nowISO(), ends_at: nowISO(168) };
}

/** `percent` off a regular price, as the catalog writes a price; "" when that leaves nothing off. */
export function discounted(regular: string, percent: number): string {
  const n = Number(regular);
  if (!Number.isFinite(n) || percent <= 0) return "";
  const cut = price(n * (1 - percent / 100));
  return Number(cut) < n ? cut : "";
}

/** A price box: what is typed stays as typed; `onPrice` hears a price or "" (emptied) only. */
export function PriceInput({ id, value, onChange, invalid, placeholder }: { id?: string; value: string; onChange: (raw: string) => void; invalid?: boolean; placeholder?: string }) {
  return (
    <input
      id={id}
      className={`input num ${invalid ? "invalid" : ""}`}
      inputMode="decimal"
      dir="ltr"
      placeholder={placeholder}
      value={value}
      onChange={(e) => onChange(e.target.value)}
      onBlur={(e) => {
        const parsed = parsePrice(e.target.value);
        if (parsed !== null && parsed !== e.target.value) onChange(parsed);
      }}
    />
  );
}
