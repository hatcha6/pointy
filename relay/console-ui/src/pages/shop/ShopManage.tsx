import { channelLabel } from "../../lib/labels";
import { useEffect, useState } from "react";
import { FileDown, Pencil, Pin, PinOff, Rocket, WifiOff } from "lucide-react";
import { agentQuiet, updateErrorText, updateStatus, useArtifacts } from "../../lib/updates";
import { ChannelPicker, VersionPicker } from "../../components/updates";
import { keys, useFleet } from "../../lib/queries";
import { fetchBlob, saveBlob } from "../../lib/files";
import { describeError } from "../../lib/errors";
import { qs } from "../../lib/api";
import type { Installation } from "../../lib/types";
import { Badge, Button, Card, Field, Segmented, TimeAgo } from "../../components/ui";
import { Dialog } from "../../components/dialog";
import { PasskeyHint, useAction } from "../../components/guarded";
import { useToast } from "../../components/toast";

/** The shop's name as the relay and the console show it. */
export function RenameDialog({ shop, open, onClose }: { shop: Installation; open: boolean; onClose: () => void }) {
  const [name, setName] = useState(shop.shop_name);
  const run = useAction({ invalidate: [keys.installations, keys.installation(shop.id)], success: "حُفظ الاسم." });
  useEffect(() => {
    if (open) setName(shop.shop_name);
  }, [open, shop.shop_name]);
  return (
    <Dialog
      open={open}
      onClose={onClose}
      busy={run.busy}
      title="اسم المتجر"
      icon={<Pencil />}
      footer={
        <>
          <Button
            variant="primary"
            size="lg"
            loading={run.busy}
            disabled={!name.trim() || name.trim() === shop.shop_name}
            onClick={async () => {
              if (await run.run("PATCH", `/v1/installations/${encodeURIComponent(shop.id)}/metadata`, { shop_name: name.trim() })) onClose();
            }}
          >
            حفظ
          </Button>
          <Button size="lg" onClick={onClose} disabled={run.busy}>
            إلغاء
          </Button>
        </>
      }
    >
      <Field label="الاسم" htmlFor="rename">
        <input id="rename" className="input" value={name} onChange={(e) => setName(e.target.value)} maxLength={120} autoFocus />
      </Field>
    </Dialog>
  );
}

/** Which version this shop runs, which channel it follows, and a pin. */
export function UpdatesCard({ shopId }: { shopId: string }) {
  const fleet = useFleet();
  const entry = fleet.data?.installations.find((f) => f.id === shopId);
  const [editing, setEditing] = useState<"channel" | "pin" | null>(null);
  const unpin = useAction({ passkey: true, invalidate: [keys.fleet], success: "أُلغي التثبيت. يتبع المتجر قناته من جديد." });
  const status = entry ? updateStatus(entry) : null;
  return (
    <Card title="التحديثات" actions={entry && <Badge tone="info">القناة {channelLabel(entry.channel)}</Badge>}>
      {!entry ? (
        <p className="muted">{fleet.isLoading ? "…" : "لم يبلّغ وكيل التحديث عن هذا المتجر بعد."}</p>
      ) : (
        <>
          {agentQuiet(entry) && (
            <div className="cc-alarm quiet" style={{ marginBottom: 12 }}>
              <WifiOff width={15} /> وكيل التحديث لا يتصل منذ <TimeAgo value={entry.agent_last_seen_at} />. الجهاز مطفأ أو بلا إنترنت، أو توقف الوكيل.
            </div>
          )}
          <dl className="facts">
            <div className="fact">
              <dt>الإصدار</dt>
              <dd className="version-flow">
                <span className="mono">{entry.current_version || "—"}</span>
                {entry.assigned_version && entry.assigned_version !== entry.current_version && (
                  <>
                    <span className="faint">←</span>
                    <strong className="mono">{entry.assigned_version}</strong>
                  </>
                )}
              </dd>
            </div>
            <div className="fact">
              <dt>الحالة</dt>
              <dd>
                {status && (
                  <Badge tone={status.tone} dot>
                    {status.label}
                  </Badge>
                )}
              </dd>
            </div>
            <div className="fact">
              <dt>يتبع</dt>
              <dd>{entry.pinned_version ? <Badge tone="warning">مثبّت على {entry.pinned_version}</Badge> : `القناة ${channelLabel(entry.channel)}`}</dd>
            </div>
            <div className="fact">
              <dt>آخر ظهور للوكيل</dt>
              <dd>
                <TimeAgo value={entry.agent_last_seen_at} />
              </dd>
            </div>
          </dl>
          {status?.progress !== undefined && (
            <div className="progress" style={{ marginTop: 10 }}>
              <div style={{ width: `${status.progress}%` }} />
            </div>
          )}
          {entry.update_error && (
            <p className="update-error" dir="auto" title={entry.update_error}>
              {updateErrorText(entry.update_error)}
            </p>
          )}
          <div className="row" style={{ marginTop: 16 }}>
            <Button size="sm" icon={<Rocket />} onClick={() => setEditing("channel")}>
              تغيير القناة
            </Button>
            {entry.pinned_version ? (
              <Button
                size="sm"
                icon={<PinOff />}
                loading={unpin.busy}
                onClick={() => void unpin.run("PATCH", `/v1/installations/${encodeURIComponent(shopId)}/update`, { pinned_version: "" })}
              >
                إلغاء التثبيت
              </Button>
            ) : (
              <Button size="sm" icon={<Pin />} onClick={() => setEditing("pin")}>
                تثبيت إصدار
              </Button>
            )}
          </div>
        </>
      )}
      <UpdateDialog shopId={shopId} mode={editing} current={entry?.channel ?? "stable"} running={entry?.current_version} onClose={() => setEditing(null)} />
    </Card>
  );
}

function UpdateDialog({ shopId, mode, current, running, onClose }: { shopId: string; mode: "channel" | "pin" | null; current: string; running?: string; onClose: () => void }) {
  const [value, setValue] = useState("");
  const artifacts = useArtifacts();
  const fleet = useFleet();
  const run = useAction({ passkey: true, invalidate: [keys.fleet], success: mode === "pin" ? "ثُبّت الإصدار." : "تغيّرت القناة." });
  useEffect(() => {
    setValue(mode === "channel" ? current : "");
  }, [mode, current]);
  if (!mode) return null;
  const channel = mode === "channel";
  const target = fleet.data?.channels.find((c) => c.channel === value);
  return (
    <Dialog
      open
      onClose={onClose}
      busy={run.busy}
      title={channel ? "قناة التحديث" : "تثبيت إصدار"}
      subtitle={channel ? "يتبع المتجر إصدار هذه القناة ونسبة نشرها." : "يبقى المتجر على هذا الإصدار مهما تغيّرت قناته — للرجوع بمتجر واحد، أو لإبقائه على إصدار مجرّب."}
      icon={channel ? <Rocket /> : <Pin />}
      footer={
        <>
          <Button
            variant="primary"
            size="lg"
            loading={run.busy}
            disabled={!value.trim() || (channel && value === current)}
            onClick={async () => {
              const body = channel ? { channel: value.trim() } : { pinned_version: value.trim() };
              if (await run.run("PATCH", `/v1/installations/${encodeURIComponent(shopId)}/update`, body)) onClose();
            }}
          >
            {channel ? "حفظ" : value ? `ثبّت على ${value}` : "اختر إصداراً"}
          </Button>
          <Button size="lg" onClick={onClose} disabled={run.busy}>
            إلغاء
          </Button>
        </>
      }
    >
      <div className="form">
        {channel ? (
          <Field label="القناة" help={target ? `هذه القناة على ${target.target_version || "—"} الآن.` : value ? "لم يُنشر على هذه القناة شيء بعد: يبقى المتجر على إصداره." : undefined}>
            <ChannelPicker value={value} onChange={setValue} />
          </Field>
        ) : (
          <Field label="الإصدار" help="فقط الإصدارات التي حزمتها على الخادم.">
            <VersionPicker bundles={artifacts.data?.bundles ?? []} loading={artifacts.isLoading} value={value} onChange={setValue} channels={fleet.data?.channels} current={running} />
          </Field>
        )}
        <PasskeyHint />
      </div>
    </Dialog>
  );
}

const eventTypes = ["", "usage", "error", "performance", "security", "fraud_signal", "audit"];
const severities = ["", "debug", "info", "warning", "error", "critical"];

/** The shop's tracking/usage/error export, pulled live through its connector. */
export function DiagnosticsDialog({ shop, open, onClose }: { shop: Installation; open: boolean; onClose: () => void }) {
  const toast = useToast();
  const [format, setFormat] = useState<"json" | "csv">("json");
  const [from, setFrom] = useState("");
  const [to, setTo] = useState("");
  const [eventType, setEventType] = useState("");
  const [severity, setSeverity] = useState("");
  const [search, setSearch] = useState("");
  const [busy, setBusy] = useState(false);

  async function download() {
    setBusy(true);
    try {
      const path =
        `/v1/installations/${encodeURIComponent(shop.id)}/diagnostics-analytics` +
        qs({ format, from, to, event_type: eventType, severity, search: search.trim() });
      const { blob, name } = await fetchBlob(path);
      const stamp = new Date().toISOString().slice(0, 16).replace(/[:T]/g, "-");
      saveBlob(blob, name ?? `pointy-diagnostics-${shop.id.slice(0, 8)}-${stamp}.zip`);
      toast.success("نُزّل ملف التشخيص.");
      onClose();
    } catch (error) {
      const described = describeError(error);
      toast.error(described.title, described.detail ?? "المتجر غير متصل الآن، أو لم يُجب.");
    } finally {
      setBusy(false);
    }
  }

  return (
    <Dialog
      open={open}
      onClose={onClose}
      busy={busy}
      title="تنزيل بيانات التشخيص"
      subtitle={`${shop.shop_name} — تُسحب الآن من خادم المتجر عبر الموصّل`}
      icon={<FileDown />}
      footer={
        <>
          <Button variant="primary" size="lg" icon={<FileDown />} loading={busy} onClick={download}>
            تنزيل
          </Button>
          <Button size="lg" onClick={onClose} disabled={busy}>
            إلغاء
          </Button>
        </>
      }
    >
      <div className="form">
        <Field label="الصيغة">
          <Segmented value={format} onChange={setFormat} options={[{ id: "json", label: "JSON" }, { id: "csv", label: "CSV" }]} />
        </Field>
        <div className="form-row">
          <Field label="من" htmlFor="dfrom">
            <input id="dfrom" type="date" className="input" value={from} onChange={(e) => setFrom(e.target.value)} />
          </Field>
          <Field label="إلى" htmlFor="dto">
            <input id="dto" type="date" className="input" value={to} onChange={(e) => setTo(e.target.value)} />
          </Field>
        </div>
        <div className="form-row">
          <Field label="نوع الحدث" htmlFor="dtype">
            <select id="dtype" className="select" value={eventType} onChange={(e) => setEventType(e.target.value)}>
              {eventTypes.map((t) => (
                <option key={t} value={t}>
                  {t || "الكل"}
                </option>
              ))}
            </select>
          </Field>
          <Field label="الخطورة" htmlFor="dsev">
            <select id="dsev" className="select" value={severity} onChange={(e) => setSeverity(e.target.value)}>
              {severities.map((t) => (
                <option key={t} value={t}>
                  {t || "الكل"}
                </option>
              ))}
            </select>
          </Field>
        </div>
        <Field label="بحث" htmlFor="dsearch" help="اسم حدث أو رقم تتبّع أو مسار طلب.">
          <input id="dsearch" className="input" value={search} onChange={(e) => setSearch(e.target.value)} />
        </Field>
        <p className="faint" style={{ fontSize: 12.5 }}>
          يُسجَّل التنزيل في سجل العمليات باسمك.
        </p>
      </div>
    </Dialog>
  );
}
