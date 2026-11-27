import { useEffect, useMemo, useState } from "react";
import { ArrowRight, Package, Plus, Save, Trash2, X } from "lucide-react";
import { api } from "../../lib/api";
import { cardKeys, type BundleEvaluation, type CardBundle, type CardBundleTier } from "../../lib/cards";
import { useCatalogItems } from "../../lib/picker";
import { Button, Card, Field, Notice } from "../../components/ui";
import { Combobox, type ComboOption } from "../../components/Combobox";
import { Dialog } from "../../components/dialog";
import { PasskeyHint, useAction } from "../../components/guarded";
import { BundleArt } from "./BundleArt";
import { BundleFigures } from "./BundleFigures";
import { BundlePreview } from "./BundlePreview";

const PATH = "/v1/customers/admin/bundles";

function emptyBundle(): CardBundle {
  return {
    key: "",
    name: "",
    tagline: "",
    rank: 1,
    art: {},
    tiers: [{ key: "", saving: "", parts: [[], []] }],
  };
}

/** A key as the relay takes it: lowercase letters, digits, - and _. */
function keyOf(value: string): string {
  return value
    .toLowerCase()
    .replace(/\s+/g, "-")
    .replace(/[^a-z0-9_-]/g, "")
    .slice(0, 64);
}

/** Composes one bundle: what it is, its sizes and their cards, its art; the figures and the app's view follow every change. */
export function BundleEditor({ bundle, taken, onDone }: { bundle: CardBundle | null; taken: CardBundle[]; onDone: () => void }) {
  const [draft, setDraft] = useState<CardBundle>(() => (bundle ? structuredClone(bundle) : emptyBundle()));
  const [evaluation, setEvaluation] = useState<BundleEvaluation | null>(null);
  const [confirm, setConfirm] = useState<"save" | "delete" | null>(null);
  const save = useAction({ invalidate: [cardKeys.bundles], success: bundle ? "حُفظت الباقة" : "أُنشئت الباقة", passkey: true });
  const remove = useAction({ invalidate: [cardKeys.bundles], success: "حُذفت الباقة", passkey: true });
  const catalog = useCatalogItems();

  const options: ComboOption[] = useMemo(() => {
    const brands = new Map((catalog.data?.brands ?? []).map((b) => [b.key, b.name]));
    return (catalog.data?.items ?? []).map((item) => ({
      value: item.key,
      label: item.name,
      sub: item.price ? `${item.price} د.ل` : item.key,
      group: brands.get(item.brand) ?? item.brand,
    }));
  }, [catalog.data]);

  // The figures follow the draft, a moment after the last change.
  useEffect(() => {
    let live = true;
    const timer = window.setTimeout(() => {
      api
        .post<{ evaluation: BundleEvaluation }>(`${PATH}/evaluate`, { bundle: draft })
        .then((answer) => live && setEvaluation(answer.evaluation))
        .catch(() => live && setEvaluation(null));
    }, 350);
    return () => {
      live = false;
      window.clearTimeout(timer);
    };
  }, [draft]);

  const set = (patch: Partial<CardBundle>) => setDraft((d) => ({ ...d, ...patch }));
  const setTier = (index: number, tier: CardBundleTier) => setDraft((d) => ({ ...d, tiers: d.tiers.map((t, i) => (i === index ? tier : t)) }));
  const keyTaken = !bundle && taken.some((b) => b.key === draft.key);
  const tierKeys = draft.tiers.map((t) => t.key);
  const ready =
    draft.key !== "" &&
    !keyTaken &&
    draft.name.trim() !== "" &&
    draft.tiers.length > 0 &&
    draft.tiers.every((t) => t.key && /^\d+(\.\d{1,3})?$/.test(t.saving) && t.parts.length >= 2 && t.parts.every((p) => p.length > 0)) &&
    new Set(tierKeys).size === tierKeys.length;

  async function submit() {
    const body = { bundle: { ...draft, name: draft.name.trim(), tagline: draft.tagline.trim() } };
    if (await save.run("PUT", `${PATH}/${encodeURIComponent(draft.key)}`, body)) onDone();
  }

  async function destroy() {
    if (!bundle) return;
    if (await remove.run("DELETE", `${PATH}/${encodeURIComponent(bundle.key)}`)) onDone();
  }

  return (
    <div className="bundle-editor">
      <div className="page-head">
        <div className="titles">
          <Button size="sm" icon={<ArrowRight />} onClick={onDone}>
            الباقات
          </Button>
          <h1>{bundle ? bundle.name : "باقة جديدة"}</h1>
        </div>
      </div>

      <Card title="الباقة">
        <div className="form">
          <Field
            label="المفتاح"
            htmlFor="bundle-key"
            help={bundle ? "لا يتغيّر بعد الإنشاء: الطلبات تحمله." : "حروف إنجليزية صغيرة وأرقام، مثل gamer."}
            error={keyTaken ? "مستخدم لباقة أخرى." : null}
          >
            <input
              id="bundle-key"
              className="input"
              dir="ltr"
              value={draft.key}
              disabled={!!bundle}
              onChange={(e) => set({ key: keyOf(e.target.value) })}
              placeholder="gamer"
            />
          </Field>
          <Field label="الاسم" htmlFor="bundle-name">
            <input id="bundle-name" className="input" maxLength={60} value={draft.name} onChange={(e) => set({ name: e.target.value })} placeholder="باقة اللاعب" />
          </Field>
          <Field label="السطر التعريفي" htmlFor="bundle-tagline" help="ما فيها، في سطر.">
            <input
              id="bundle-tagline"
              className="input"
              maxLength={120}
              value={draft.tagline}
              onChange={(e) => set({ tagline: e.target.value })}
              placeholder="شدّات ببجي مع رصيد خطك"
            />
          </Field>
          <Field label="الترتيب" htmlFor="bundle-rank" help="الأصغر يظهر أولاً.">
            <input
              id="bundle-rank"
              className="input"
              inputMode="numeric"
              dir="ltr"
              value={String(draft.rank)}
              onChange={(e) => set({ rank: Number(e.target.value.replace(/\D/g, "").slice(0, 4)) || 0 })}
            />
          </Field>
        </div>
      </Card>

      {draft.tiers.map((tier, index) => (
        <TierCard
          key={index}
          index={index}
          tier={tier}
          bundleKey={draft.key}
          options={options}
          evaluation={evaluation?.tiers[index]}
          onChange={(next) => setTier(index, next)}
          onRemove={draft.tiers.length > 1 ? () => set({ tiers: draft.tiers.filter((_, i) => i !== index) }) : undefined}
        />
      ))}
      <div className="bundle-add">
        <Button
          icon={<Plus />}
          disabled={draft.tiers.length >= 8}
          onClick={() => {
            const last = draft.tiers[draft.tiers.length - 1];
            set({ tiers: [...draft.tiers, { key: "", saving: "", parts: last ? last.parts.map((p) => [...p]) : [[], []] }] });
          }}
        >
          حجم آخر
        </Button>
      </div>

      <BundleArt bundle={draft} evaluation={evaluation} onChange={(art) => set({ art })} />

      <BundlePreview bundle={draft} evaluation={evaluation} />

      {evaluation && evaluation.warnings.length > 0 && (
        <Notice tone="warning" icon={<Package />}>
          {evaluation.warnings.join(" · ")}
        </Notice>
      )}

      <div className="bundle-actions">
        <Button variant="primary" size="lg" icon={<Save />} disabled={!ready} onClick={() => setConfirm("save")}>
          {bundle ? "حفظ" : "إنشاء"}
        </Button>
        {bundle && (
          <Button size="lg" icon={<Trash2 />} onClick={() => setConfirm("delete")}>
            حذف
          </Button>
        )}
      </div>

      <Dialog
        open={confirm !== null}
        onClose={() => setConfirm(null)}
        busy={save.busy || remove.busy}
        icon={confirm === "delete" ? <Trash2 /> : <Package />}
        iconTone={confirm === "delete" ? "danger" : undefined}
        title={confirm === "delete" ? `حذف «${bundle?.name}»؟` : `${bundle ? "حفظ" : "إنشاء"} «${draft.name.trim()}»؟`}
        footer={
          <>
            <Button
              variant={confirm === "delete" ? "danger" : "primary"}
              size="lg"
              onClick={() => void (confirm === "delete" ? destroy() : submit())}
              loading={save.busy || remove.busy}
            >
              تأكيد
            </Button>
            <Button size="lg" onClick={() => setConfirm(null)} disabled={save.busy || remove.busy}>
              تراجع
            </Button>
          </>
        }
      >
        <p>
          {confirm === "delete"
            ? "تختفي من التطبيق عند فتحه التالي. الطلبات السابقة تبقى كما هي."
            : "تظهر في التطبيق بهذه الأسعار عند فتحه التالي، دون تحديث."}
        </p>
        <PasskeyHint />
        {(save.error || remove.error) && <p className="error-text">{save.error ?? remove.error}</p>}
      </Dialog>
    </div>
  );
}

function TierCard({
  index,
  tier,
  bundleKey,
  options,
  evaluation,
  onChange,
  onRemove,
}: {
  index: number;
  tier: CardBundleTier;
  bundleKey: string;
  options: ComboOption[];
  evaluation: BundleEvaluation["tiers"][number] | undefined;
  onChange: (tier: CardBundleTier) => void;
  onRemove?: () => void;
}) {
  const setPart = (p: number, items: string[]) => onChange({ ...tier, parts: tier.parts.map((part, i) => (i === p ? items : part)) });
  const views = new Map((evaluation?.parts ?? []).flat().map((v) => [v.item, v]));
  return (
    <Card
      title={`الحجم ${index + 1}`}
      actions={
        onRemove && (
          <Button size="sm" icon={<Trash2 />} onClick={onRemove}>
            حذف الحجم
          </Button>
        )
      }
    >
      <div className="form bundle-tier-head">
        <Field label="مفتاح الحجم" htmlFor={`tier-key-${index}`} help="ما يطلبه التطبيق، مثل gamer-60.">
          <input
            id={`tier-key-${index}`}
            className="input"
            dir="ltr"
            value={tier.key}
            onChange={(e) => onChange({ ...tier, key: keyOf(e.target.value) })}
            placeholder={bundleKey ? `${bundleKey}-${index + 1}` : "gamer-60"}
          />
        </Field>
        <Field label="التوفير (د.ل)" htmlFor={`tier-saving-${index}`} help="يُخصم من مجموع أسعار البطاقات، ويُحسب على بطاقة اللعبة.">
          <input
            id={`tier-saving-${index}`}
            className="input amount"
            inputMode="decimal"
            dir="ltr"
            value={tier.saving}
            onChange={(e) => onChange({ ...tier, saving: e.target.value.replace(/[^\d.]/g, "").slice(0, 9) })}
            placeholder="0.750"
          />
        </Field>
      </div>

      <div className="bundle-parts">
        {tier.parts.map((part, p) => (
          <div key={p} className="bundle-part">
            <div className="bundle-part-head">
              <strong>البطاقة {p + 1}</strong>
              <span className="muted small">{part.length > 1 ? "يختار الزبون واحدة" : "ثابتة"}</span>
              {tier.parts.length > 2 && (
                <Button size="sm" icon={<X />} onClick={() => onChange({ ...tier, parts: tier.parts.filter((_, i) => i !== p) })}>
                  إزالة
                </Button>
              )}
            </div>
            <div className="chips">
              {part.map((item) => {
                const view = views.get(item);
                const bad = view && (!view.found || !view.available || view.to_account);
                return (
                  <span key={item} className={`chip bundle-chip${bad ? " bad" : ""}`}>
                    <span>{view?.found ? `${view.brand_name} ${view.label}` : item}</span>
                    {view?.price && (
                      <span className="muted small" dir="ltr">
                        {view.price}
                      </span>
                    )}
                    <button type="button" aria-label="إزالة" onClick={() => setPart(p, part.filter((i) => i !== item))}>
                      <X />
                    </button>
                  </span>
                );
              })}
            </div>
            {part.length < 6 && (
              <Combobox
                value=""
                onChange={(item) => item && !part.includes(item) && setPart(p, [...part, item])}
                options={options}
                placeholder={part.length ? "خيار آخر (شبكة أخرى بنفس القيمة)" : "ابحث عن بطاقة"}
                ariaLabel={`أضف إلى البطاقة ${p + 1}`}
              />
            )}
          </div>
        ))}
        {tier.parts.length < 4 && (
          <Button size="sm" icon={<Plus />} onClick={() => onChange({ ...tier, parts: [...tier.parts, []] })}>
            بطاقة أخرى في الباقة
          </Button>
        )}
      </div>

      <BundleFigures evaluation={evaluation} />
    </Card>
  );
}
