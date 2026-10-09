import { useState } from "react";
import { Plug, PowerOff, Power } from "lucide-react";
import { keys, useIntegrations } from "../lib/queries";
import { dateTime } from "../lib/format";
import { Badge, Button, Card, Empty, Field, Notice, Skeleton } from "../components/ui";
import { Dialog } from "../components/dialog";
import { useAction } from "../components/guarded";

const providers: { id: string; name: string; detail: string }[] = [
  { id: "hdbox", name: "HD Box", detail: "شحن اشتراكات أجهزة الاستقبال" },
  { id: "lnet", name: "LNET", detail: "اشتراكات الإنترنت ودفعاتها" },
  { id: "qareeb", name: "قريب", detail: "بطاقات وخدمات قريب" },
];

export function Integrations() {
  const switches = useIntegrations();
  const [target, setTarget] = useState<{ id: string; name: string; disable: boolean } | null>(null);
  const state = new Map((switches.data ?? []).map((s) => [s.provider, s]));
  return (
    <>
      <div className="page-head">
        <div className="titles">
          <h1>التكاملات</h1>
          <p>إيقاف تكامل هنا يوقفه في كل المتاجر خلال دقائق — مثلاً عند طلب رسمي بالتوقف. يعود بضغطة.</p>
        </div>
      </div>
      {switches.isError ? (
        <Card>
          <Empty icon={<Plug />} title="مفاتيح التكاملات غير متاحة على هذا الخادم" />
        </Card>
      ) : (
        <div className="grid two">
          {providers.map((p) => {
            const s = state.get(p.id);
            const off = !!s?.disabled;
            return (
              <Card
                key={p.id}
                title={p.name}
                actions={off ? <Badge tone="danger" dot>موقوف في كل المتاجر</Badge> : <Badge tone="success" dot>يعمل</Badge>}
              >
                {switches.isLoading ? (
                  <Skeleton height={40} />
                ) : (
                  <div className="stack" style={{ gap: 12 }}>
                    <p className="muted">{p.detail}</p>
                    {s?.reason && (
                      <p style={{ fontSize: 13 }}>
                        آخر تغيير: «{s.reason}» — {s.actor || "—"} · {dateTime(s.updated_at)}
                      </p>
                    )}
                    <div>
                      <Button variant={off ? "primary" : "danger"} icon={off ? <Power /> : <PowerOff />} onClick={() => setTarget({ id: p.id, name: p.name, disable: !off })}>
                        {off ? "أعد التشغيل" : "أوقف في كل المتاجر"}
                      </Button>
                    </div>
                  </div>
                )}
              </Card>
            );
          })}
        </div>
      )}
      <SwitchDialog target={target} onClose={() => setTarget(null)} />
    </>
  );
}

function SwitchDialog({ target, onClose }: { target: { id: string; name: string; disable: boolean } | null; onClose: () => void }) {
  const [reason, setReason] = useState("");
  const run = useAction({ invalidate: [keys.integrations], success: target?.disable ? "أُوقف التكامل." : "أُعيد تشغيل التكامل." });
  if (!target) return null;
  return (
    <Dialog
      open
      onClose={() => {
        setReason("");
        onClose();
      }}
      busy={run.busy}
      title={target.disable ? `إيقاف ${target.name}` : `تشغيل ${target.name}`}
      icon={target.disable ? <PowerOff /> : <Power />}
      iconTone={target.disable ? "danger" : undefined}
      footer={
        <Button
          variant={target.disable ? "danger" : "primary"}
          className={target.disable ? "solid" : ""}
          size="lg"
          loading={run.busy}
          disabled={target.disable && !reason.trim()}
          onClick={async () => {
            const result = await run.run("PUT", `/v1/fleet/integrations/${target.id}`, { disabled: target.disable, reason: reason.trim() });
            if (result) {
              setReason("");
              onClose();
            }
          }}
        >
          {target.disable ? "أوقف الآن" : "شغّل"}
        </Button>
      }
    >
      <div className="form">
        {target.disable && (
          <Notice tone="warning" icon={<PowerOff />}>
            يختفي من كل المتاجر عند مزامنتها التالية (خلال 5 دقائق تقريباً).
          </Notice>
        )}
        <Field label={target.disable ? "السبب" : "السبب (اختياري)"} htmlFor="swreason">
          <input id="swreason" className="input" value={reason} onChange={(e) => setReason(e.target.value)} maxLength={200} autoFocus />
        </Field>
      </div>
    </Dialog>
  );
}
