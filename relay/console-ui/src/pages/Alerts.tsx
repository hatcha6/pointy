import { useState } from "react";
import { Unavailable } from "../components/Unavailable";
import { BellRing, RotateCcw, Send } from "lucide-react";
import { keys, useAlerts } from "../lib/queries";
import { dateTime } from "../lib/format";
import { Badge, Button, Card, CopyText, Notice, Skeleton } from "../components/ui";
import { useAction } from "../components/guarded";
import { Dialog } from "../components/dialog";

export function Alerts({ embedded }: { embedded?: boolean } = {}) {
  const alerts = useAlerts();
  const test = useAction({ success: "أُرسل تنبيه تجريبي." });
  const setup = useAction({ invalidate: [keys.alerts], success: "أُنشئت قناة التنبيهات." });
  const rotate = useAction({ invalidate: [keys.alerts], success: "تغيّر الموضوع. اشترك به من جديد على الهواتف." });
  const [rotating, setRotating] = useState(false);
  const data = alerts.data;
  return (
    <>
      <div className="page-head" hidden={embedded}>
        <div className="titles">
          <h1>التنبيهات</h1>
          <p>قناة ntfy التي تصل هواتف الشركة: أرصدة الموردين المنخفضة، رفض المورّدين، ونتيجة كل دفعة شحن.</p>
        </div>
      </div>
      <Card title="قناة الشركة" actions={data?.configured ? <Badge tone="success" dot>تعمل</Badge> : undefined}>
        {alerts.isLoading ? (
          <Skeleton height={80} />
        ) : alerts.isError ? (
          <Unavailable feature="alerts" error={alerts.error} onRetry={() => void alerts.refetch()} />
        ) : data?.configured ? (
          <div className="stack">
            <dl className="facts">
              <div className="fact">
                <dt>الموضوع</dt>
                <dd>
                  <CopyText value={data.topic ?? ""} />
                </dd>
              </div>
              <div className="fact">
                <dt>رابط الاشتراك</dt>
                <dd>
                  <CopyText value={data.subscribe_url ?? ""} display={<span className="mono">{data.subscribe_url}</span>} />
                </dd>
              </div>
              <div className="fact">
                <dt>آخر تغيير</dt>
                <dd>
                  {data.actor || "—"} · {dateTime(data.updated_at)}
                </dd>
              </div>
            </dl>
            <Notice tone="info" icon={<BellRing />}>
              في تطبيق ntfy على الهاتف: + ثم اسم الموضوع أعلاه. من يعرف الاسم يقرأ التنبيهات، فلا تشاركه. إن فُقد هاتف مشترك فغيّر الموضوع.
            </Notice>
            <div>
              <div className="row">
                <Button icon={<Send />} loading={test.busy} onClick={() => void test.run("POST", "/v1/alerts/test")}>
                  أرسل تنبيهاً تجريبياً
                </Button>
                <Button variant="danger" icon={<RotateCcw />} onClick={() => setRotating(true)}>
                  غيّر الموضوع
                </Button>
              </div>
            </div>
          </div>
        ) : (
          <div className="stack">
            <p className="muted">لم تُنشأ قناة بعد.</p>
            <div>
              <Button variant="primary" icon={<BellRing />} loading={setup.busy} onClick={() => void setup.run("POST", "/v1/alerts/topic")}>
                أنشئ القناة
              </Button>
            </div>
          </div>
        )}
      </Card>
      <Dialog
        open={rotating}
        onClose={() => setRotating(false)}
        busy={rotate.busy}
        title="تغيير موضوع التنبيهات"
        icon={<RotateCcw />}
        iconTone="danger"
        footer={
          <>
            <Button
              variant="danger"
              className="solid"
              size="lg"
              loading={rotate.busy}
              onClick={async () => {
                if (await rotate.run("POST", "/v1/alerts/topic")) setRotating(false);
              }}
            >
              غيّره الآن
            </Button>
            <Button size="lg" onClick={() => setRotating(false)} disabled={rotate.busy}>
              إلغاء
            </Button>
          </>
        }
      >
        <p>كل هاتف مشترك بالموضوع الحالي يتوقف عن تلقي التنبيهات حتى يشترك بالموضوع الجديد. استخدمه إن فُقد هاتف أو تسرّب الاسم.</p>
      </Dialog>
    </>
  );
}
