import { useMemo, useState } from "react";
import { BadgePercent, Banknote, ChevronLeft, Gift, Layers, Plus, Search, Tag, TicketPercent, Trash2, X } from "lucide-react";
import { Link, useRouter } from "../../lib/router";
import { count, money } from "../../lib/format";
import { Button, Card, Field, Segmented } from "../../components/ui";
import { useAction } from "../../components/guarded";
import { OfferPreview } from "../../components/cards/OfferPreview";
import { useCatalogItems } from "../../lib/picker";
import { badgeText, discountOn, offerKindInfo, termsProblems, type OfferKind, type OfferTerms } from "../../lib/offers";
import { emptyOffer, segmentInfo, segmentKeys, segmentOrder, useSegments, type OfferDraft, type SegmentKey } from "../../lib/segments";

/** eSIMs are scoped by their own category, which the cards' catalog has not. */
const ESIM = { key: "esim", name: "شرائح eSIM" };

/** A draft handed over by the page that opens the builder (an insight). */
let handedOver: Partial<OfferDraft> | null = null;

/** Opens the builder, filled in with [prefill]. */
export function openOfferBuilder(navigate: (to: string) => void, prefill: Partial<OfferDraft> = {}) {
  handedOver = prefill;
  navigate("/cards/offers/new");
}

const kindIcons: Record<OfferKind, typeof Tag> = { percent: BadgePercent, amount: Banknote, tiered: Layers, bundle: Gift };

/** The draft as the relay takes it. */
function termsOf(d: OfferDraft): OfferTerms {
  return {
    kind: d.kind,
    value: d.value,
    max_discount: d.kind === "percent" || d.kind === "bundle" || (d.kind === "tiered" && d.tierUnit === "percent") ? d.maxDiscount || "0" : "0",
    min_order: d.minOrder || "0",
    tiers: d.kind === "tiered" ? d.tiers.map((t) => ({ min_order: t.min, value: t.value })) : undefined,
    tier_unit: d.kind === "tiered" ? d.tierUnit : undefined,
    buy_quantity: d.kind === "bundle" ? Number(d.buy) : undefined,
    get_quantity: d.kind === "bundle" ? Number(d.get) : undefined,
    get_percent: d.kind === "bundle" ? d.getPercent : undefined,
    scope: { categories: d.categories, brands: d.brands, items: d.items },
    badge: d.badge,
  };
}

/**
 * A new offer: what kind, how much, on which cards, for whom, for how long,
 * and how it reads in the app, beside a preview drawn as the app draws it.
 */
export function OfferBuilder() {
  const { navigate } = useRouter();
  const [draft, setDraft] = useState<OfferDraft>(() => {
    const start = { ...emptyOffer, ...handedOver };
    handedOver = null;
    return start;
  });
  const set = (patch: Partial<OfferDraft>) => setDraft((d) => ({ ...d, ...patch }));
  const segments = useSegments();
  const catalog = useCatalogItems();
  const save = useAction<{ offer: { id: string } }>({ invalidate: [segmentKeys.all], success: "أُنشئ العرض", passkey: true });

  const stats = segments.data?.segments ?? [];
  const everyone = draft.audience === "everyone";
  const chosen = stats.filter((s) => draft.segments.includes(s.key));
  const people = everyone ? (segments.data?.overview.customers ?? 0) : chosen.reduce((n, s) => n + s.customers, 0);
  const reachable = everyone ? (segments.data?.overview.reachable ?? 0) : chosen.reduce((n, s) => n + s.reachable, 0);
  const holdout = everyone ? 0 : Math.min(Math.max(Number(draft.holdout) || 0, 0), 50);
  const given = people - Math.floor((people * holdout) / 100);
  const terms = termsOf(draft);
  const problems = [
    ...termsProblems(terms),
    ...(!draft.name.trim() ? ["أعطِ العرض اسماً."] : []),
    ...(!draft.title.trim() ? ["اكتب ما يراه الزبون."] : []),
    ...(!everyone && draft.segments.length === 0 ? ["اختر شريحة أو أكثر، أو اجعله للجميع."] : []),
    ...(!everyone && draft.segments.length > 0 && given <= 0 ? ["لا زبون في هذه الشرائح يحصل على العرض."] : []),
    ...(!(Number(draft.days) > 0) ? ["المدة يوم على الأقل."] : []),
    ...cappedTiers(draft),
  ];
  const notify = !!draft.notifyTitle.trim() && !!draft.notifyBody.trim();
  const averageOrder = chosen.length ? Number(chosen[0].average_order) : Number(segments.data?.segments.find((s) => s.orders)?.average_order ?? 0);

  async function submit() {
    const ends = new Date(Date.now() + Number(draft.days) * 24 * 3600_000);
    const result = await save.run("POST", "/v1/customers/admin/offers", {
      name: draft.name.trim(),
      title: draft.title.trim(),
      description: draft.description.trim(),
      ...terms,
      audience: draft.audience,
      segments: everyone ? [] : draft.segments,
      uses_per_customer: Number(draft.usesPerCustomer) || 1,
      max_redemptions: Number(draft.maxRedemptions) || 0,
      ends_at: ends.toISOString(),
      holdout_percent: holdout,
      notify: notify ? { title: draft.notifyTitle.trim(), body: draft.notifyBody.trim() } : undefined,
    });
    if (result) navigate("/cards/offers");
  }

  return (
    <>
      <div className="crumbs">
        <Link to="/cards/offers">عروض الشرائح</Link>
        <ChevronLeft />
        <span>عرض جديد</span>
      </div>
      <div className="page-head">
        <div className="titles">
          <h1>عرض جديد</h1>
          <p>اختر نوع الخصم وما يشمله ومن يحصل عليه. المعاينة بجانبك كما سيظهر في التطبيق.</p>
        </div>
      </div>

      <div className="offer-builder">
        <div className="stack">
          <Card title="نوع العرض">
            <div className="offer-kinds" role="radiogroup">
              {(Object.keys(offerKindInfo) as OfferKind[]).map((kind) => {
                const Icon = kindIcons[kind];
                return (
                  <button key={kind} type="button" role="radio" aria-checked={draft.kind === kind} className={`offer-kind ${draft.kind === kind ? "on" : ""}`} onClick={() => set({ kind, maxDiscount: kind === "percent" ? "5" : "" })}>
                    <Icon />
                    <strong>{offerKindInfo[kind].label}</strong>
                    <span>{offerKindInfo[kind].example}</span>
                  </button>
                );
              })}
            </div>
          </Card>

          <Card title="الخصم">
            <div className="form">
              {draft.kind === "percent" && (
                <div className="form-row">
                  <Field label="النسبة ٪" htmlFor="o-value">
                    <input id="o-value" className="input" inputMode="decimal" value={draft.value} onChange={(e) => set({ value: e.target.value })} />
                  </Field>
                  <Field label="أقصى خصم للطلب (د.ل)" htmlFor="o-cap" help="فارغ: بلا حدّ. يحمي الهامش في الطلبات الكبيرة.">
                    <input id="o-cap" className="input" inputMode="decimal" value={draft.maxDiscount} onChange={(e) => set({ maxDiscount: e.target.value })} />
                  </Field>
                </div>
              )}
              {draft.kind === "amount" && (
                <Field label="المبلغ (د.ل)" htmlFor="o-value">
                  <input id="o-value" className="input" inputMode="decimal" value={draft.value} onChange={(e) => set({ value: e.target.value })} />
                </Field>
              )}
              {draft.kind === "tiered" && (
                <TierEditor draft={draft} set={set} />
              )}
              {draft.kind === "bundle" && (
                <>
                  <div className="form-row">
                    <Field label="اشترِ (كروت)" htmlFor="o-buy">
                      <input id="o-buy" className="input" inputMode="numeric" value={draft.buy} onChange={(e) => set({ buy: e.target.value })} />
                    </Field>
                    <Field label="واحصل على (كروت)" htmlFor="o-get">
                      <input id="o-get" className="input" inputMode="numeric" value={draft.get} onChange={(e) => set({ get: e.target.value })} />
                    </Field>
                  </div>
                  <Field label="الكروت المضافة" help="من الكرت نفسه في الطلب نفسه: كل مجموعة من (اشترِ + احصل) تأخذ الخصم.">
                    <Segmented<"free" | "percent">
                      value={Number(draft.getPercent) >= 100 ? "free" : "percent"}
                      onChange={(v) => set({ getPercent: v === "free" ? "100" : "50" })}
                      options={[
                        { id: "free", label: "مجاناً" },
                        { id: "percent", label: "بخصم" },
                      ]}
                    />
                  </Field>
                  {Number(draft.getPercent) < 100 && (
                    <Field label="خصم الكروت المضافة ٪" htmlFor="o-getp">
                      <input id="o-getp" className="input" inputMode="decimal" value={draft.getPercent} onChange={(e) => set({ getPercent: e.target.value })} />
                    </Field>
                  )}
                  <Field label="أقصى خصم للطلب (د.ل)" htmlFor="o-cap2" help="فارغ: بلا حدّ.">
                    <input id="o-cap2" className="input" inputMode="decimal" value={draft.maxDiscount} onChange={(e) => set({ maxDiscount: e.target.value })} />
                  </Field>
                </>
              )}
              {draft.kind !== "tiered" && (
                <Field label="أقل طلب (د.ل)" htmlFor="o-min" help="فارغ: أي طلب. حدّ أعلى قليلاً من متوسط الطلب يجعل الخصم يشتري طلباً أكبر.">
                  <input id="o-min" className="input" inputMode="decimal" value={draft.minOrder} onChange={(e) => set({ minOrder: e.target.value })} />
                </Field>
              )}
            </div>
          </Card>

          <Card title="على ماذا">
            <ScopePicker draft={draft} set={set} catalog={catalog.data} />
          </Card>

          <Card title="لمن">
            <div className="form">
              <Segmented<"segments" | "everyone">
                value={draft.audience}
                onChange={(audience) => set({ audience })}
                options={[
                  { id: "segments", label: "شرائح مختارة" },
                  { id: "everyone", label: "الجميع" },
                ]}
              />
              {everyone ? (
                <p className="muted">
                  كل زبون، ومن يدخل لاحقاً أيضاً. يراه من لم يسجّل الدخول على الكروت التي يشملها، ويستخدمه بعد الدخول. بلا مجموعة مقارنة.
                </p>
              ) : (
                <>
                  <Field label="الشرائح" help={people ? `${count(people)} زبوناً، ${count(reachable)} منهم يستقبلون الإشعارات.` : "اختر شريحة أو أكثر."}>
                    <div className="chips">
                      {segmentOrder.map((key) => {
                        const s = stats.find((x) => x.key === key);
                        const on = draft.segments.includes(key);
                        return (
                          <button
                            key={key}
                            type="button"
                            className={`chip ${on ? "on" : ""}`}
                            title={segmentInfo[key].about}
                            onClick={() => set({ segments: on ? draft.segments.filter((k) => k !== key) : [...draft.segments, key as SegmentKey] })}
                          >
                            {segmentInfo[key].label} · {count(s?.customers ?? 0)}
                          </button>
                        );
                      })}
                    </div>
                  </Field>
                  <Field
                    label="مجموعة المقارنة ٪"
                    htmlFor="o-holdout"
                    help={`نسبة تُختار عشوائياً ولا تحصل على العرض: ما يشترونه بدونه هو ما يُقاس به أثره. 10٪ تكفي غالباً.${holdout ? ` (${count(people - given)} زبوناً)` : ""}`}
                  >
                    <input id="o-holdout" className="input" inputMode="numeric" value={draft.holdout} onChange={(e) => set({ holdout: e.target.value })} />
                  </Field>
                </>
              )}
            </div>
          </Card>

          <Card title="المدة والحدود">
            <div className="form-row">
              <Field label="المدة (أيام)" htmlFor="o-days" help="عرض قصير يدفع للشراء الآن.">
                <input id="o-days" className="input" inputMode="numeric" value={draft.days} onChange={(e) => set({ days: e.target.value })} />
              </Field>
              <Field label="مرات الاستخدام للزبون" htmlFor="o-uses">
                <input id="o-uses" className="input" inputMode="numeric" value={draft.usesPerCustomer} onChange={(e) => set({ usesPerCustomer: e.target.value })} />
              </Field>
              <Field label="حدّ الاستخدام الكلي" htmlFor="o-max" help="فارغ: بلا حدّ. يضبط الميزانية.">
                <input id="o-max" className="input" inputMode="numeric" value={draft.maxRedemptions} onChange={(e) => set({ maxRedemptions: e.target.value })} />
              </Field>
            </div>
          </Card>

          <Card title="في التطبيق">
            <div className="form">
              <Field label="الاسم" htmlFor="o-name" help="لك أنت، في اللوحة.">
                <input id="o-name" className="input" maxLength={120} value={draft.name} onChange={(e) => set({ name: e.target.value })} placeholder="استرجاع المهددين — نوفمبر" />
              </Field>
              <Field label="العنوان" htmlFor="o-title" help="ما يقرؤه الزبون في صفحة الكرت وعند الدفع.">
                <input id="o-title" className="input" maxLength={120} value={draft.title} onChange={(e) => set({ title: e.target.value })} placeholder="خصم على طلبك القادم" />
              </Field>
              <Field label="سطر تحته" htmlFor="o-desc" help="اختياري.">
                <input id="o-desc" className="input" maxLength={200} value={draft.description} onChange={(e) => set({ description: e.target.value })} placeholder="لأنك من عملائنا" />
              </Field>
              <Field label="الشارة" htmlFor="o-badge" help={`على الكروت التي يشملها، ${draft.badge.length}/24. فارغة: «${badgeText({ ...terms, badge: "" })}».`}>
                <input id="o-badge" className="input" maxLength={24} value={draft.badge} onChange={(e) => set({ badge: e.target.value })} placeholder={badgeText({ ...terms, badge: "" })} />
              </Field>
            </div>
          </Card>

          {segments.data?.push_configured && (
            <Card title="إشعار">
              <div className="form">
                <Field label="العنوان" htmlFor="o-ntitle" help={`اختياري: يصل لـ${count(everyone ? reachable : Math.max(reachable - Math.floor((reachable * holdout) / 100), 0))} زبوناً تقريباً عند إنشاء العرض${everyone ? "" : "، لا لمجموعة المقارنة"}.`}>
                  <input id="o-ntitle" className="input" maxLength={120} value={draft.notifyTitle} onChange={(e) => set({ notifyTitle: e.target.value })} placeholder="هدية لك" />
                </Field>
                <Field label="النص" htmlFor="o-nbody">
                  <textarea id="o-nbody" className="input" rows={2} maxLength={300} value={draft.notifyBody} onChange={(e) => set({ notifyBody: e.target.value })} placeholder={draft.title || "خصم على طلبك القادم، لأيام فقط."} />
                </Field>
              </div>
            </Card>
          )}
        </div>

        <div className="offer-builder-preview stack">
          <OfferPreview terms={terms} title={draft.title} description={draft.description} forEveryone={everyone} days={Number(draft.days) || 0} catalog={catalog.data} />
          <Card tight>
            <div className="form" style={{ padding: 14 }}>
              <p style={{ margin: 0 }}>
                <strong>{everyone ? "للجميع" : `${count(given)} زبوناً`}</strong>
                {!everyone && holdout > 0 && <span className="muted"> · {count(people - given)} للمقارنة</span>}
              </p>
              {averageOrder > 0 && given > 0 && (
                <p className="muted" style={{ margin: 0 }}>
                  إن استخدمه 20٪ منهم بطلب بمتوسط {money(averageOrder)}، فكلفة الخصم نحو{" "}
                  {money(Math.round(given * 0.2) * typicalDiscount(terms, averageOrder))}.
                </p>
              )}
              {problems.length > 0 && (
                <ul className="offer-problems">
                  {problems.map((p) => (
                    <li key={p}>{p}</li>
                  ))}
                </ul>
              )}
              {save.error && <p className="error-text">{save.error}</p>}
              <Button variant="primary" size="lg" icon={<TicketPercent />} onClick={() => void submit()} loading={save.busy} disabled={problems.length > 0} block>
                إنشاء العرض
              </Button>
            </div>
          </Card>
        </div>
      </div>
    </>
  );
}

/** A cap that every tier above the first reaches at its own start makes
 *  them pointless: said, so the operator raises it or drops it. */
function cappedTiers(d: OfferDraft): string[] {
  const cap = Number(d.maxDiscount);
  if (d.kind !== "tiered" || d.tierUnit !== "percent" || !(cap > 0) || d.tiers.length < 2) return [];
  const second = d.tiers[1];
  return (Number(second.min) * Number(second.value)) / 100 > cap ? ["أقصى خصم للطلب يلغي المستويات الأعلى: ارفعه أو اتركه فارغاً."] : [];
}

/** What the offer takes off a typical order (a bundle: one full group). */
function typicalDiscount(terms: OfferTerms, averageOrder: number): number {
  const quantity = terms.kind === "bundle" ? (terms.buy_quantity ?? 1) + (terms.get_quantity ?? 1) : 1;
  const unit = terms.kind === "bundle" ? averageOrder / quantity : averageOrder;
  return discountOn({ ...terms, scope: undefined }, { unit, quantity });
}

/** A tiered offer's steps: from what order, how much off, up to five. */
function TierEditor({ draft, set }: { draft: OfferDraft; set: (patch: Partial<OfferDraft>) => void }) {
  const update = (i: number, patch: Partial<{ min: string; value: string }>) => set({ tiers: draft.tiers.map((t, j) => (j === i ? { ...t, ...patch } : t)) });
  return (
    <>
      <Field label="الخصم في كل مستوى">
        <Segmented<"percent" | "amount">
          value={draft.tierUnit}
          onChange={(tierUnit) => set({ tierUnit })}
          options={[
            { id: "percent", label: "نسبة ٪" },
            { id: "amount", label: "مبلغ د.ل" },
          ]}
        />
      </Field>
      <div className="tier-rows">
        <div className="tier-row tier-head" aria-hidden>
          <span />
          <span>من طلب (د.ل)</span>
          <span>{draft.tierUnit === "percent" ? "الخصم ٪" : "الخصم (د.ل)"}</span>
          <span />
        </div>
        {draft.tiers.map((tier, i) => (
          <div key={i} className="tier-row">
            <span className="tier-step">{i + 1}</span>
            <input className="input" inputMode="decimal" aria-label={`المستوى ${i + 1}: من طلب`} placeholder="من طلب (د.ل)" value={tier.min} onChange={(e) => update(i, { min: e.target.value })} />
            <input className="input" inputMode="decimal" aria-label={`المستوى ${i + 1}: الخصم`} placeholder={draft.tierUnit === "percent" ? "الخصم ٪" : "الخصم د.ل"} value={tier.value} onChange={(e) => update(i, { value: e.target.value })} />
            <Button size="sm" variant="ghost" icon={<Trash2 />} aria-label="حذف المستوى" disabled={draft.tiers.length <= 1} onClick={() => set({ tiers: draft.tiers.filter((_, j) => j !== i) })} />
          </div>
        ))}
      </div>
      {draft.tiers.length < 5 && (
        <Button
          size="sm"
          icon={<Plus />}
          onClick={() => {
            const last = draft.tiers.at(-1);
            set({ tiers: [...draft.tiers, { min: String((Number(last?.min) || 0) * 2 || 20), value: String((Number(last?.value) || 0) + 5) }] });
          }}
        >
          مستوى آخر
        </Button>
      )}
      {draft.tierUnit === "percent" && (
        <Field label="أقصى خصم للطلب (د.ل)" htmlFor="o-tcap" help="فارغ: بلا حدّ.">
          <input id="o-tcap" className="input" inputMode="decimal" value={draft.maxDiscount} onChange={(e) => set({ maxDiscount: e.target.value })} />
        </Field>
      )}
    </>
  );
}

/** What the offer covers: everything, or chosen categories, brands and cards. */
function ScopePicker({ draft, set, catalog }: { draft: OfferDraft; set: (patch: Partial<OfferDraft>) => void; catalog?: import("../../lib/picker").PickerList }) {
  const everything = !draft.categories.length && !draft.brands.length && !draft.items.length;
  const [some, setSome] = useState(!everything);
  const [query, setQuery] = useState("");
  const categories = useMemo(() => [...(catalog?.categories ?? []), ESIM], [catalog]);
  const brandName = useMemo(() => new Map((catalog?.brands ?? []).map((b) => [b.key, b.name])), [catalog]);
  const itemName = useMemo(() => new Map((catalog?.items ?? []).map((i) => [i.key, i.name])), [catalog]);
  const q = query.trim().toLowerCase();
  const brandHits = q ? (catalog?.brands ?? []).filter((b) => b.name.toLowerCase().includes(q) || b.key.includes(q)).slice(0, 30) : [];
  const itemHits = q ? (catalog?.items ?? []).filter((i) => i.name.toLowerCase().includes(q) || i.key.includes(q)).slice(0, 30) : [];
  const toggle = (field: "categories" | "brands" | "items", key: string) =>
    set({ [field]: draft[field].includes(key) ? draft[field].filter((k) => k !== key) : [...draft[field], key] } as Partial<OfferDraft>);
  const picked = [
    ...draft.categories.map((k) => ({ field: "categories" as const, key: k, label: `فئة: ${categories.find((c) => c.key === k)?.name ?? k}` })),
    ...draft.brands.map((k) => ({ field: "brands" as const, key: k, label: brandName.get(k) ?? k })),
    ...draft.items.map((k) => ({ field: "items" as const, key: k, label: itemName.get(k) ?? k })),
  ];
  return (
    <div className="form">
      <Segmented<"all" | "some">
        value={some ? "some" : "all"}
        onChange={(v) => {
          setSome(v === "some");
          if (v === "all") set({ categories: [], brands: [], items: [] });
        }}
        options={[
          { id: "all", label: "كل ما يُباع" },
          { id: "some", label: "فئات أو علامات أو كروت" },
        ]}
      />
      {some && (
        <>
          <Field label="الفئات">
            <div className="chips">
              {categories.map((c) => (
                <button key={c.key} type="button" className={`chip ${draft.categories.includes(c.key) ? "on" : ""}`} onClick={() => toggle("categories", c.key)}>
                  {c.name}
                </button>
              ))}
            </div>
          </Field>
          <Field label="علامات أو كروت بعينها" help="ابحث بالاسم: علامة تشمل كل كروتها، وكرت يشمل نفسه فقط.">
            <div className="search-input">
              <Search />
              <input className="input" value={query} onChange={(e) => setQuery(e.target.value)} placeholder="ببجي، آيتونز، ليبيانا 10…" />
            </div>
            {q && (
              <div className="pick-list">
                {brandHits.map((b) => (
                  <label key={`b-${b.key}`}>
                    <input type="checkbox" checked={draft.brands.includes(b.key)} onChange={() => toggle("brands", b.key)} />
                    {b.name} <span className="faint">علامة · كل كروتها</span>
                  </label>
                ))}
                {itemHits.map((i) => (
                  <label key={`i-${i.key}`}>
                    <input type="checkbox" checked={draft.items.includes(i.key)} onChange={() => toggle("items", i.key)} />
                    {i.name} {i.price && <span className="faint">{money(i.price)}</span>}
                  </label>
                ))}
                {brandHits.length + itemHits.length === 0 && <p className="muted" style={{ padding: 10, margin: 0 }}>لا نتائج.</p>}
              </div>
            )}
          </Field>
          {picked.length > 0 ? (
            <div className="picked-chips">
              {picked.map((p) => (
                <span key={`${p.field}-${p.key}`} className="picked-chip">
                  {p.label}
                  <button type="button" aria-label={`إزالة ${p.label}`} onClick={() => toggle(p.field, p.key)}>
                    <X />
                  </button>
                </span>
              ))}
            </div>
          ) : (
            <p className="muted" style={{ margin: 0 }}>لم تختر شيئاً بعد: العرض يشمل كل ما يُباع حتى تختار.</p>
          )}
        </>
      )}
    </div>
  );
}
