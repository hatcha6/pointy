import { useMemo } from "react";
import { BellRing } from "lucide-react";
import { Field } from "../ui";
import { Combobox } from "../Combobox";
import { useCatalog } from "../../pages/vouchers/Catalog";

export type NotificationDraft = { title: string; body: string; link: string; campaign: string };

export const emptyNotification: NotificationDraft = { title: "", body: "", link: "", campaign: "" };

const ORIGIN = "https://cards.dftr.ly";

/** Where tapping it goes: the app's own pages, or one brand's. */
const places = [
  { id: "", label: "يفتح التطبيق فقط" },
  { id: `${ORIGIN}/`, label: "الرئيسية" },
  { id: `${ORIGIN}/my-cards`, label: "كروتي" },
  { id: `${ORIGIN}/account`, label: "حسابي" },
];

/**
 * A notification's words and where it leads, beside how it shows on a
 * phone's lock screen.
 */
export function NotificationForm({ draft, onChange }: { draft: NotificationDraft; onChange: (next: NotificationDraft) => void }) {
  const catalog = useCatalog();
  const brands = catalog.data?.view?.brands ?? [];
  const brandKey = draft.link.startsWith(`${ORIGIN}/brand/`) ? draft.link.slice(`${ORIGIN}/brand/`.length) : "";
  const options = useMemo(
    () => [
      ...places.map((p) => ({ value: p.id, label: p.label, group: "التطبيق" })),
      ...brands.map((b) => ({ value: `${ORIGIN}/brand/${b.key}`, label: b.name, sub: b.key, group: "صفحة علامة" })),
    ],
    [brands],
  );
  const set = (patch: Partial<NotificationDraft>) => onChange({ ...draft, ...patch });

  return (
    <div className="notify-compose">
      <div className="form">
        <Field label="العنوان" htmlFor="notify-title" help={`${draft.title.length}/60 — العنوان القصير يُقرأ كاملاً على قفل الشاشة.`}>
          <input
            id="notify-title"
            className="input"
            maxLength={120}
            value={draft.title}
            onChange={(e) => set({ title: e.target.value })}
            placeholder="عرض اليوم على ليبيانا"
            autoFocus
          />
        </Field>
        <Field label="النص" htmlFor="notify-body" help={`${draft.body.length}/180`}>
          <textarea
            id="notify-body"
            className="input"
            rows={3}
            maxLength={500}
            value={draft.body}
            onChange={(e) => set({ body: e.target.value })}
            placeholder="اشحن رصيدك الآن واحصل على كرتك فوراً."
          />
        </Field>
        <Field label="عند الضغط" help={brandKey ? <bdi dir="ltr">{draft.link}</bdi> : undefined}>
          <Combobox
            value={draft.link}
            onChange={(link) => set({ link })}
            options={options}
            placeholder="يفتح التطبيق فقط"
          />
        </Field>
        <Field label="اسم الحملة" htmlFor="notify-campaign" help="اختياري: يظهر في تحليلات التطبيق مع من فتح الإشعار.">
          <input
            id="notify-campaign"
            className="input"
            maxLength={80}
            value={draft.campaign}
            onChange={(e) => set({ campaign: e.target.value.replace(/\s+/g, "-") })}
            placeholder="libyana-oct"
          />
        </Field>
      </div>
      <div className="notify-preview" aria-hidden>
        <div className="notify-phone">
          <div className="notify-time">9:41</div>
          <div className="notify-banner">
            <div className="notify-icon">
              <BellRing />
            </div>
            <div className="notify-text">
              <div className="notify-head">
                <strong>دفتر كروت</strong>
                <span>الآن</span>
              </div>
              <div className="notify-title">{draft.title || "العنوان"}</div>
              <div className="notify-body">{draft.body || "نص الإشعار يظهر هنا."}</div>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
