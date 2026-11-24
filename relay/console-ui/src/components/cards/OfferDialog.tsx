import { useEffect, useState } from "react";
import { TicketPercent } from "lucide-react";
import { Dialog } from "../dialog";
import { Button, Field, Segmented } from "../ui";
import { useAction } from "../guarded";
import { count, money } from "../../lib/format";
import { emptyOffer, segmentInfo, segmentKeys, segmentOrder, type OfferDraft, type SegmentKey, type SegmentStats } from "../../lib/segments";

/**
 * A discount for chosen segments: what it takes off, for how long, and who is
 * held out to measure it. Who gets it is fixed when it is made: the customers
 * in those segments now.
 */
export function OfferDialog({
  open,
  onClose,
  initial,
  stats,
  pushConfigured,
}: {
  open: boolean;
  onClose: () => void;
  initial?: Partial<OfferDraft>;
  stats: SegmentStats[];
  pushConfigured: boolean;
}) {
  const [draft, setDraft] = useState<OfferDraft>(emptyOffer);
  const save = useAction({ invalidate: [segmentKeys.all], success: "أُنشئ العرض", passkey: true });
  useEffect(() => {
    if (open) setDraft({ ...emptyOffer, ...initial });
  }, [open, initial]);
  const set = (patch: Partial<OfferDraft>) => setDraft((d) => ({ ...d, ...patch }));
  const toggle = (key: SegmentKey) =>
    set({ segments: draft.segments.includes(key) ? draft.segments.filter((k) => k !== key) : [...draft.segments, key] });

  const chosen = stats.filter((s) => draft.segments.includes(s.key));
  const people = chosen.reduce((n, s) => n + s.customers, 0);
  const reachable = chosen.reduce((n, s) => n + s.reachable, 0);
  const holdout = Math.min(Math.max(Number(draft.holdout) || 0, 0), 50);
  const given = people - Math.floor((people * holdout) / 100);
  const value = Number(draft.value);
  const valid =
    !!draft.name.trim() &&
    !!draft.title.trim() &&
    draft.segments.length > 0 &&
    value > 0 &&
    (draft.kind === "amount" || value <= 90) &&
    Number(draft.days) > 0 &&
    given > 0;
  const notify = !!draft.notifyTitle.trim() && !!draft.notifyBody.trim();

  async function submit() {
    const ends = new Date(Date.now() + Number(draft.days) * 24 * 3600_000);
    const result = await save.run("POST", "/v1/customers/admin/offers", {
      name: draft.name.trim(),
      title: draft.title.trim(),
      description: draft.description.trim(),
      kind: draft.kind,
      value: draft.value,
      max_discount: draft.kind === "percent" ? draft.maxDiscount || "0" : "0",
      min_order: draft.minOrder || "0",
      segments: draft.segments,
      uses_per_customer: Number(draft.usesPerCustomer) || 1,
      max_redemptions: Number(draft.maxRedemptions) || 0,
      ends_at: ends.toISOString(),
      holdout_percent: holdout,
      notify: notify ? { title: draft.notifyTitle.trim(), body: draft.notifyBody.trim() } : undefined,
    });
    if (result) onClose();
  }

  return (
    <Dialog
      open={open}
      onClose={onClose}
      busy={save.busy}
      dirty={!!draft.name || !!draft.title}
      wide
      icon={<TicketPercent />}
      iconTone="money"
      title="عرض لشرائح الزبائن"
      subtitle="يحصل عليه من في هذه الشرائح الآن، ويراه في التطبيق عند الشراء."
      footer={
        <>
          <Button variant="primary" size="lg" onClick={() => void submit()} loading={save.busy} disabled={!valid}>
            إنشاء العرض ({count(given)} زبوناً)
          </Button>
          <Button size="lg" onClick={onClose} disabled={save.busy}>
            تراجع
          </Button>
        </>
      }
    >
      <div className="form">
        <Field label="لمن" help={people ? `${count(people)} زبوناً، ${count(reachable)} منهم يستقبلون الإشعارات.` : "اختر شريحة أو أكثر."}>
          <div className="chips">
            {segmentOrder.map((key) => {
              const s = stats.find((x) => x.key === key);
              return (
                <button key={key} type="button" className={`chip ${draft.segments.includes(key) ? "on" : ""}`} onClick={() => toggle(key)}>
                  {segmentInfo[key].label} · {count(s?.customers ?? 0)}
                </button>
              );
            })}
          </div>
        </Field>
        <Field label="الاسم" htmlFor="offer-name" help="لك أنت، في اللوحة.">
          <input id="offer-name" className="input" maxLength={120} value={draft.name} onChange={(e) => set({ name: e.target.value })} placeholder="استرجاع المهددين — نوفمبر" />
        </Field>
        <Field label="ما يراه الزبون" htmlFor="offer-title" help="عنوان العرض في صفحة الدفع.">
          <input id="offer-title" className="input" maxLength={120} value={draft.title} onChange={(e) => set({ title: e.target.value })} placeholder="خصم 10٪ على طلبك القادم" />
        </Field>
        <Field label="الخصم">
          <Segmented<"percent" | "amount">
            value={draft.kind}
            onChange={(kind) => set({ kind })}
            options={[
              { id: "percent", label: "نسبة مئوية" },
              { id: "amount", label: "مبلغ ثابت" },
            ]}
          />
        </Field>
        <div className="form-row">
          <Field label={draft.kind === "percent" ? "النسبة ٪" : "المبلغ (د.ل)"} htmlFor="offer-value" error={draft.kind === "percent" && value > 90 ? "90٪ على الأكثر." : null}>
            <input id="offer-value" className="input" inputMode="decimal" value={draft.value} onChange={(e) => set({ value: e.target.value })} />
          </Field>
          {draft.kind === "percent" && (
            <Field label="أقصى خصم للطلب (د.ل)" htmlFor="offer-cap" help="فارغ: بلا حدّ.">
              <input id="offer-cap" className="input" inputMode="decimal" value={draft.maxDiscount} onChange={(e) => set({ maxDiscount: e.target.value })} />
            </Field>
          )}
          <Field label="أقل طلب (د.ل)" htmlFor="offer-min" help="فارغ: أي طلب.">
            <input id="offer-min" className="input" inputMode="decimal" value={draft.minOrder} onChange={(e) => set({ minOrder: e.target.value })} />
          </Field>
        </div>
        <div className="form-row">
          <Field label="المدة (أيام)" htmlFor="offer-days">
            <input id="offer-days" className="input" inputMode="numeric" value={draft.days} onChange={(e) => set({ days: e.target.value })} />
          </Field>
          <Field label="مرات الاستخدام للزبون" htmlFor="offer-uses">
            <input id="offer-uses" className="input" inputMode="numeric" value={draft.usesPerCustomer} onChange={(e) => set({ usesPerCustomer: e.target.value })} />
          </Field>
          <Field label="حدّ الاستخدام الكلي" htmlFor="offer-max" help="فارغ: بلا حدّ.">
            <input id="offer-max" className="input" inputMode="numeric" value={draft.maxRedemptions} onChange={(e) => set({ maxRedemptions: e.target.value })} />
          </Field>
        </div>
        <Field
          label="مجموعة المقارنة ٪"
          htmlFor="offer-holdout"
          help={`نسبة تُختار عشوائياً ولا تحصل على العرض. ما يشترونه بدونه هو ما يُقاس به أثر العرض: هل جلب طلبات جديدة أم أعطى خصماً لمن كان سيشتري؟ ${holdout ? `(${count(people - given)} زبوناً)` : "0: بلا قياس."}`}
        >
          <input id="offer-holdout" className="input" inputMode="numeric" value={draft.holdout} onChange={(e) => set({ holdout: e.target.value })} />
        </Field>
        {pushConfigured && (
          <>
            <Field label="إشعار للمستفيدين" htmlFor="offer-notify-title" help="اختياري: يصل لمن حصل على العرض فقط، لا لمجموعة المقارنة.">
              <input id="offer-notify-title" className="input" maxLength={120} value={draft.notifyTitle} onChange={(e) => set({ notifyTitle: e.target.value })} placeholder="هدية لك" />
            </Field>
            <Field label="نص الإشعار" htmlFor="offer-notify-body">
              <textarea id="offer-notify-body" className="input" rows={2} maxLength={300} value={draft.notifyBody} onChange={(e) => set({ notifyBody: e.target.value })} placeholder={draft.title || "خصم على طلبك القادم، لأيام فقط."} />
            </Field>
          </>
        )}
        {chosen.length > 0 && (
          <p className="muted">
            متوسط طلب هذه الشرائح {money(chosen[0].average_order)}
            {draft.kind === "percent" && value > 0 ? `: الخصم عليه نحو ${money((Number(chosen[0].average_order) * value) / 100)}.` : "."}
          </p>
        )}
        {save.error && <p className="error-text">{save.error}</p>}
      </div>
    </Dialog>
  );
}
