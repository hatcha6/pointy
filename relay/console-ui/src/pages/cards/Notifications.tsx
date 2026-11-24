import { useState } from "react";
import { BellRing, Send } from "lucide-react";
import { cardAudience, cardKeys, useCardNotifications, useCardSummary } from "../../lib/cards";
import { useSearchParam } from "../../lib/router";
import { segmentInfo, segmentOrder, useSegments, type SegmentKey } from "../../lib/segments";
import { count } from "../../lib/format";
import { Button, Card, Notice, Segmented } from "../../components/ui";
import { Dialog } from "../../components/dialog";
import { useAction } from "../../components/guarded";
import { Unavailable } from "../../components/Unavailable";
import { NotificationForm, emptyNotification, type NotificationDraft } from "../../components/cards/NotificationForm";
import { NotificationsTable } from "./CustomerDetail";

type Audience = "all" | "ios" | "play" | "apk" | "segments";

const audienceHint: Record<Audience, string> = {
  all: "كل جهاز ثبّت التطبيق ووافق على الإشعارات، دخل بحسابه أم لا.",
  ios: "تطبيق الآيفون يبيع خدمات الاتصالات والإنترنت فقط: لا تعلن فيه عن الألعاب وبطاقات الهدايا.",
  play: "أندرويد المثبّت من جوجل بلاي. يبيع خدمات الاتصالات والإنترنت فقط: لا تعلن فيه عن الألعاب وبطاقات الهدايا.",
  apk: "أندرويد المثبّت من موقعنا.",
  segments: "زبائن الشرائح المختارة ممن تصلهم الإشعارات، على أي تطبيق.",
};

/** Notifications to the app's users: compose, send, and what was sent. */
export function Notifications() {
  const summary = useCardSummary();
  const log = useCardNotifications({ limit: "200" });
  const [draft, setDraft] = useState<NotificationDraft>(emptyNotification);
  // Opened from the segments page: those segments, chosen.
  const [segmentsParam] = useSearchParam("segments");
  const [chosen, setChosen] = useState<SegmentKey[]>(() =>
    segmentsParam.split(",").filter((k): k is SegmentKey => k in segmentInfo),
  );
  const [audience, setAudience] = useState<Audience>(chosen.length ? "segments" : "all");
  const segments = useSegments();
  const reach = (segments.data?.segments ?? []).filter((s) => chosen.includes(s.key)).reduce((n, s) => n + s.reachable, 0);
  const toggle = (key: SegmentKey) => setChosen((c) => (c.includes(key) ? c.filter((k) => k !== key) : [...c, key]));
  const audienceName = audience === "segments" ? `${reach.toLocaleString("ar-LY")} زبوناً في ${chosen.length.toLocaleString("ar-LY")} شريحة` : cardAudience[audience];
  const [confirming, setConfirming] = useState(false);
  const send = useAction({ invalidate: [cardKeys.all], success: "أُرسل الإشعار" });
  const configured = log.data?.push_configured ?? summary.data?.push_configured;
  const ready = !!draft.title.trim() && !!draft.body.trim() && (audience !== "segments" || reach > 0);

  async function submit() {
    const result = await send.run("POST", "/v1/customers/admin/notifications", {
      ...draft,
      audience,
      ...(audience === "segments" ? { segments: chosen } : {}),
    });
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
              { id: "segments", label: "شرائح" },
            ]}
          />
          {audience === "segments" && (
            <div className="chips">
              {segmentOrder.map((key) => {
                const s = segments.data?.segments.find((x) => x.key === key);
                return (
                  <button key={key} type="button" className={`chip ${chosen.includes(key) ? "on" : ""}`} onClick={() => toggle(key)} disabled={!s?.reachable}>
                    {segmentInfo[key].label} · {count(s?.reachable ?? 0)}
                  </button>
                );
              })}
            </div>
          )}
          <p className="muted">
            {audienceHint[audience]}
            {audience === "all" && summary.data ? ` (${count(summary.data.stats.with_push)} زبوناً مسجّلاً يستقبلها، وغيرهم ممن لم يدخل.)` : ""}
          </p>
        </div>
        <NotificationForm draft={draft} onChange={setDraft} />
        <div className="row" style={{ marginTop: 16 }}>
          <Button variant="primary" size="lg" icon={<Send />} disabled={!ready || configured === false} onClick={() => setConfirming(true)}>
            إرسال إلى {audienceName}
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
        title={`إرسال إلى ${audienceName}؟`}
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
