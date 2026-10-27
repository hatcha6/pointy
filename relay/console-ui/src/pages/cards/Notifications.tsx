import { useState } from "react";
import { BellRing, Send } from "lucide-react";
import { cardAudience, cardKeys, useCardNotifications, useCardSummary } from "../../lib/cards";
import { count } from "../../lib/format";
import { Button, Card, Notice, Segmented } from "../../components/ui";
import { Dialog } from "../../components/dialog";
import { useAction } from "../../components/guarded";
import { Unavailable } from "../../components/Unavailable";
import { NotificationForm, emptyNotification, type NotificationDraft } from "../../components/cards/NotificationForm";
import { NotificationsTable } from "./CustomerDetail";

type Audience = "all" | "ios" | "play" | "apk";

const audienceHint: Record<Audience, string> = {
  all: "كل جهاز ثبّت التطبيق ووافق على الإشعارات، دخل بحسابه أم لا.",
  ios: "تطبيق الآيفون يبيع خدمات الاتصالات والإنترنت فقط: لا تعلن فيه عن الألعاب وبطاقات الهدايا.",
  play: "أندرويد المثبّت من جوجل بلاي.",
  apk: "أندرويد المثبّت من موقعنا.",
};

/** Notifications to the app's users: compose, send, and what was sent. */
export function Notifications() {
  const summary = useCardSummary();
  const log = useCardNotifications({ limit: "200" });
  const [draft, setDraft] = useState<NotificationDraft>(emptyNotification);
  const [audience, setAudience] = useState<Audience>("all");
  const [confirming, setConfirming] = useState(false);
  const send = useAction({ invalidate: [cardKeys.all], success: "أُرسل الإشعار" });
  const configured = log.data?.push_configured ?? summary.data?.push_configured;
  const ready = !!draft.title.trim() && !!draft.body.trim();

  async function submit() {
    const result = await send.run("POST", "/v1/customers/admin/notifications", { ...draft, audience });
    setConfirming(false);
    if (result) setDraft(emptyNotification);
  }

  return (
    <>
      <div className="page-head">
        <div className="titles">
          <h1>إشعارات دفتر كروت</h1>
          <p>رسالة تظهر على هواتف مستخدمي التطبيق. لزبون واحد، افتح ملفه من صفحة الزبائن.</p>
        </div>
      </div>

      {configured === false && (
        <div style={{ marginBottom: 16 }}>
        <Notice tone="warning" icon={<BellRing />}>
          الإرسال غير مفعّل على الخادم: أضف مفتاح حساب الخدمة من Firebase في <span className="mono">POINTY_RELAY_FCM_SERVICE_ACCOUNT</span> ثم أعد تشغيله.
        </Notice>
        </div>
      )}

      <Card title="إشعار جديد">
        <div className="form" style={{ marginBottom: 16 }}>
          <Segmented<Audience>
            value={audience}
            onChange={setAudience}
            options={[
              { id: "all", label: "الجميع" },
              { id: "ios", label: "آيفون" },
              { id: "play", label: "بلاي" },
              { id: "apk", label: "أندرويد (الموقع)" },
            ]}
          />
          <p className="muted">
            {audienceHint[audience]}
            {audience === "all" && summary.data ? ` (${count(summary.data.stats.with_push)} زبوناً مسجّلاً يستقبلها، وغيرهم ممن لم يدخل.)` : ""}
          </p>
        </div>
        <NotificationForm draft={draft} onChange={setDraft} />
        <div className="row" style={{ marginTop: 16 }}>
          <Button variant="primary" size="lg" icon={<Send />} disabled={!ready || configured === false} onClick={() => setConfirming(true)}>
            إرسال إلى {cardAudience[audience]}
          </Button>
        </div>
      </Card>

      <Card tight title="ما أُرسل" className="gap-top">
        {log.isError ? (
          <Unavailable feature="customers" error={log.error} onRetry={() => void log.refetch()} />
        ) : (
          <NotificationsTable notifications={log.data?.notifications ?? []} showAudience />
        )}
      </Card>

      <Dialog
        open={confirming}
        onClose={() => setConfirming(false)}
        busy={send.busy}
        icon={<Send />}
        title={`إرسال إلى ${cardAudience[audience]}؟`}
        footer={
          <>
            <Button variant="primary" size="lg" onClick={() => void submit()} loading={send.busy}>
              إرسال الآن
            </Button>
            <Button size="lg" onClick={() => setConfirming(false)} disabled={send.busy}>
              تراجع
            </Button>
          </>
        }
      >
        <p>
          «{draft.title}» يصل خلال ثوانٍ ولا يمكن سحبه بعد الإرسال.
        </p>
        {send.error && <p className="error-text">{send.error}</p>}
      </Dialog>
    </>
  );
}
