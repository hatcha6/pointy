import { useEffect, useState } from "react";
import { CalendarCheck2 } from "lucide-react";
import { Dialog } from "./dialog";
import { Button, Field, Switch } from "./ui";
import { useAction } from "./guarded";
import { date } from "../lib/format";
import { keys } from "../lib/queries";
import type { Installation } from "../lib/types";

const lengths = [1, 3, 6, 12];

function addMonths(from: Date, months: number): Date {
  const d = new Date(from);
  d.setMonth(d.getMonth() + months);
  return d;
}

/**
 * Extends or sets a shop's subscription and its add-ons in one audited change.
 * A length counts from the current end while the shop is still paid up, so an
 * early renewal never loses days.
 */
export function SubscriptionDialog({ shop, open, onClose }: { shop: Installation; open: boolean; onClose: () => void }) {
  const currentEnd = shop.subscription_ends_at ? new Date(shop.subscription_ends_at) : null;
  const base = currentEnd && shop.subscription_active && currentEnd.getTime() > Date.now() ? currentEnd : new Date();
  const [months, setMonths] = useState<number | null>(1);
  const [customDate, setCustomDate] = useState("");
  const [remote, setRemote] = useState(true);
  const [ai, setAi] = useState(shop.ai_enabled);
  const [reason, setReason] = useState("");
  const action = useAction({
    invalidate: [keys.installations, keys.installation(shop.id), keys.installationAudit(shop.id)],
    success: "حُدّث الاشتراك.",
  });

  useEffect(() => {
    if (open) {
      setMonths(1);
      setCustomDate("");
      setRemote(true);
      setAi(shop.ai_enabled);
      setReason("");
    }
  }, [open, shop]);

  const end = months ? addMonths(base, months) : customDate ? new Date(customDate + "T23:59:59") : null;

  async function submit() {
    if (!end) return;
    const body: Record<string, unknown> = {
      subscription_active: true,
      subscription_ends_at: end.toISOString(),
      relay_enabled: remote,
      ai_enabled: ai,
      reason: reason.trim() || (months ? `اشتراك ${months} ${months === 1 ? "شهر" : months === 2 ? "شهران" : months <= 10 ? "أشهر" : "شهراً"}` : `اشتراك حتى ${date(end.toISOString())}`),
    };
    const result = await action.run("PATCH", `/v1/installations/${encodeURIComponent(shop.id)}/subscription`, body);
    if (result) onClose();
  }

  return (
    <Dialog
      open={open}
      onClose={onClose}
      busy={action.busy}
      title="الاشتراك"
      subtitle={shop.shop_name || shop.id}
      icon={<CalendarCheck2 />}
      footer={
        <>
          <Button variant="primary" size="lg" loading={action.busy} disabled={!end} onClick={submit} autoFocus>
            {end ? `فعّل حتى ${date(end.toISOString())}` : "اختر المدة"}
          </Button>
          <Button size="lg" onClick={onClose} disabled={action.busy}>
            إلغاء
          </Button>
        </>
      }
    >
      <div className="form">
        <Field label="المدة" help={`تُحسب من ${base === currentEnd ? "نهاية الاشتراك الحالي " + date(currentEnd?.toISOString()) : "اليوم"}.`}>
          <div className="chips">
            {lengths.map((n) => (
              <button
                type="button"
                key={n}
                className={`chip ${months === n ? "on" : ""}`}
                onClick={() => {
                  setMonths(n);
                  setCustomDate("");
                }}
              >
                {n === 12 ? "سنة" : n === 1 ? "شهر" : `${n} أشهر`}
              </button>
            ))}
            <input
              type="date"
              className="input"
              style={{ width: 170, height: 32 }}
              value={customDate}
              aria-label="تاريخ محدد"
              onChange={(e) => {
                setCustomDate(e.target.value);
                setMonths(null);
              }}
            />
          </div>
        </Field>
        <div>
          <div className="switch-row">
            <div className="text">
              الوصول عن بعد
              <span>الهواتف تصل إلى المتجر عبر الخادم.</span>
            </div>
            <Switch on={remote} onChange={setRemote} label="الوصول عن بعد" />
          </div>
          <div className="switch-row">
            <div className="text">
              المساعد الذكي
              <span>المحادثة وقراءة الفواتير بالذكاء الاصطناعي.</span>
            </div>
            <Switch on={ai} onChange={setAi} label="المساعد الذكي" />
          </div>
          <p className="faint" style={{ fontSize: 12.5, paddingTop: 10 }}>
            الرسائل النصية ليست جزءاً من الاشتراك: تُدفع كل رسالة من رصيد الرسائل في محفظة المتجر.
          </p>
        </div>
        <Field label="ملاحظة (اختياري)" htmlFor="subreason" help="تُحفظ في سجل تغييرات المتجر.">
          <input id="subreason" className="input" value={reason} onChange={(e) => setReason(e.target.value)} maxLength={200} />
        </Field>
      </div>
    </Dialog>
  );
}
