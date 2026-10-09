import { useEffect, useState } from "react";
import { Laptop, LogOut, ShieldOff, ShieldCheck, Trash2, UserPlus, Link2 } from "lucide-react";
import { useMe, useOperators, keys } from "../lib/queries";
import { useSearchParam } from "../lib/router";
import { date } from "../lib/format";
import type { Operator } from "../lib/types";
import { Badge, Button, Card, CopyText, Field, Notice, Skeleton, TimeAgo, initials } from "../components/ui";
import { Dialog } from "../components/dialog";
import { DataTable } from "../components/DataTable";
import { PasskeyHint, useAction } from "../components/guarded";

function browserName(ua: string): string {
  const os = /iPhone|iPad/.test(ua) ? "iOS" : /Android/.test(ua) ? "Android" : /Mac/.test(ua) ? "macOS" : /Windows/.test(ua) ? "Windows" : /Linux/.test(ua) ? "Linux" : "";
  const browser = /Edg\//.test(ua) ? "Edge" : /Chrome\//.test(ua) ? "Chrome" : /Safari\//.test(ua) ? "Safari" : /Firefox\//.test(ua) ? "Firefox" : "متصفح";
  return os ? `${browser} على ${os}` : browser;
}

export function Operators() {
  const me = useMe();
  const operators = useOperators();
  const [doParam, setDo] = useSearchParam("do");
  const [inviteOpen, setInviteOpen] = useState(false);
  const [presetName, setPresetName] = useState("");
  const [toggle, setToggle] = useState<Operator | null>(null);
  const removePasskey = useAction({ passkey: true, invalidate: [keys.operators], success: "حُذف مفتاح المرور." });
  const endSession = useAction({ invalidate: [keys.operators], success: "أُنهيت الجلسة." });

  useEffect(() => {
    if (doParam === "invite") {
      setInviteOpen(true);
      setDo("");
    }
  }, [doParam, setDo]);

  return (
    <>
      <div className="page-head">
        <div className="titles">
          <h1>المشغّلون</h1>
          <p>من يستطيع دخول اللوحة، والأجهزة التي يدخل منها. أوقف أي جهاز مفقود فوراً.</p>
        </div>
        <div className="actions">
          <Button
            variant="primary"
            icon={<UserPlus />}
            onClick={() => {
              setPresetName("");
              setInviteOpen(true);
            }}
          >
            دعوة مشغّل
          </Button>
        </div>
      </div>
      <div className="stack">
        {operators.isLoading && <Skeleton height={180} />}
        {(operators.data ?? []).map((op) => {
          const self = op.id === me.data?.operator.id;
          return (
            <Card
              key={op.id}
              title={
                <span className="row">
                  <span className="avatar">{initials(op.name)}</span>
                  {op.name}
                  {self && <Badge tone="info">أنت</Badge>}
                  {op.disabled_at ? <Badge tone="danger">موقوف</Badge> : <Badge tone="success">فعّال</Badge>}
                </span>
              }
              hint={`أُضيف ${date(op.created_at)}${op.created_by ? " بواسطة " + op.created_by.replace(/^cli:/, "") : ""}`}
              actions={
                <div className="row">
                  <Button
                    size="sm"
                    icon={<Link2 />}
                    onClick={() => {
                      setPresetName(op.name);
                      setInviteOpen(true);
                    }}
                    disabled={!!op.disabled_at}
                  >
                    إضافة جهاز
                  </Button>
                  {!self && (
                    <Button size="sm" variant={op.disabled_at ? "default" : "danger"} icon={op.disabled_at ? <ShieldCheck /> : <ShieldOff />} onClick={() => setToggle(op)}>
                      {op.disabled_at ? "تفعيل" : "إيقاف"}
                    </Button>
                  )}
                </div>
              }
              tight
            >
              <DataTable
                rows={op.passkeys}
                rowKey={(pk) => pk.id}
                empty={<p className="muted" style={{ padding: 16 }}>لم يسجّل جهازاً بعد — أرسل له رابط دعوة.</p>}
                columns={[
                  {
                    key: "label",
                    header: "مفاتيح المرور",
                    mobile: "title",
                    cell: (pk) => (
                      <span className="row" style={{ gap: 8 }}>
                        <Laptop width={16} className="muted" />
                        {pk.label}
                      </span>
                    ),
                  },
                  { key: "used", header: "آخر استخدام", mobile: "trailing", cell: (pk) => <TimeAgo value={pk.last_used_at} /> },
                  { key: "added", header: "أُضيف", cell: (pk) => date(pk.created_at) },
                  {
                    key: "remove",
                    header: "",
                    mobile: "actions",
                    cell: (pk) => (
                      <Button
                        size="sm"
                        variant="danger"
                        icon={<Trash2 />}
                        disabled={self && op.passkeys.length <= 1}
                        loading={removePasskey.busy}
                        onClick={() => {
                          if (window.confirm(`حذف مفتاح «${pk.label}» لـ ${op.name}؟ لن يستطيع هذا الجهاز الدخول بعدها.`)) {
                            void removePasskey.run("DELETE", `/passkeys/${encodeURIComponent(pk.id)}`);
                          }
                        }}
                      >
                        حذف
                      </Button>
                    ),
                  },
                ]}
              />
              {op.sessions.length > 0 && (
                <DataTable
                  rows={op.sessions}
                  rowKey={(s) => s.id}
                  columns={[
                    {
                      key: "browser",
                      header: "الجلسات المفتوحة",
                      mobile: "title",
                      cell: (s) => (
                        <>
                          {browserName(s.user_agent)} {s.current && <Badge tone="info">هذه الجلسة</Badge>}
                        </>
                      ),
                    },
                    { key: "seen", header: "آخر نشاط", mobile: "trailing", cell: (s) => <TimeAgo value={s.last_seen_at} /> },
                    { key: "ip", header: "العنوان", cell: (s) => <span className="mono">{s.ip}</span> },
                    {
                      key: "end",
                      header: "",
                      mobile: "actions",
                      cell: (s) =>
                        s.current ? null : (
                          <Button size="sm" icon={<LogOut />} onClick={() => void endSession.run("DELETE", `/sessions/${s.id}`)}>
                            إنهاء
                          </Button>
                        ),
                    },
                  ]}
                />
              )}
            </Card>
          );
        })}
      </div>
      <InviteDialog open={inviteOpen} presetName={presetName} onClose={() => setInviteOpen(false)} />
      <ToggleOperator operator={toggle} onClose={() => setToggle(null)} />
    </>
  );
}

function InviteDialog({ open, presetName, onClose }: { open: boolean; presetName: string; onClose: () => void }) {
  const [name, setName] = useState(presetName);
  const [link, setLink] = useState<{ link: string; expires_at: string; created: boolean } | null>(null);
  const invite = useAction<{ link: string; expires_at: string; created: boolean }>({ passkey: true, invalidate: [keys.operators] });
  useEffect(() => {
    if (open) {
      setName(presetName);
      setLink(null);
    }
  }, [open, presetName]);
  return (
    <Dialog
      open={open}
      onClose={onClose}
      busy={invite.busy}
      title={link ? "رابط الدعوة جاهز" : presetName ? `إضافة جهاز لـ ${presetName}` : "دعوة مشغّل"}
      icon={<UserPlus />}
      footer={
        link ? (
          <Button variant="primary" size="lg" onClick={onClose}>
            تم
          </Button>
        ) : (
          <>
            <Button
              variant="primary"
              size="lg"
              loading={invite.busy}
              disabled={!name.trim()}
              onClick={async () => {
                const result = await invite.run("POST", "/operators/invite", { name: name.trim(), ttl_hours: 24 });
                if (result) setLink(result);
              }}
            >
              أنشئ رابط الدعوة
            </Button>
            <Button size="lg" onClick={onClose} disabled={invite.busy}>
              إلغاء
            </Button>
          </>
        )
      }
    >
      {link ? (
        <div className="form">
          <Notice tone="warning" icon={<ShieldCheck />}>
            الرابط يعمل مرة واحدة حتى {date(link.expires_at)}. من يفتحه أولاً يسجّل جهازه — أرسله بشكل خاص للشخص نفسه فقط.
          </Notice>
          <div className="summary">
            <CopyText value={link.link} display={<span className="mono" style={{ wordBreak: "break-all" }}>{link.link}</span>} />
          </div>
        </div>
      ) : (
        <div className="form">
          <Field label="الاسم" help="كما يظهر في سجل العمليات. اسم موجود = إضافة جهاز آخر له." htmlFor="opname">
            <input id="opname" className="input" value={name} onChange={(e) => setName(e.target.value)} maxLength={60} autoFocus />
          </Field>
          <PasskeyHint />
        </div>
      )}
    </Dialog>
  );
}

function ToggleOperator({ operator, onClose }: { operator: Operator | null; onClose: () => void }) {
  const run = useAction({ passkey: true, invalidate: [keys.operators], success: operator?.disabled_at ? "فُعّل المشغّل." : "أُوقف المشغّل وأُنهيت جلساته." });
  if (!operator) return null;
  const disabling = !operator.disabled_at;
  return (
    <Dialog
      open
      onClose={onClose}
      busy={run.busy}
      title={disabling ? `إيقاف ${operator.name}` : `تفعيل ${operator.name}`}
      icon={disabling ? <ShieldOff /> : <ShieldCheck />}
      iconTone={disabling ? "danger" : undefined}
      footer={
        <>
          <Button
            variant={disabling ? "danger" : "primary"}
            className={disabling ? "solid" : ""}
            size="lg"
            loading={run.busy}
            onClick={async () => {
              const result = await run.run("POST", `/operators/${encodeURIComponent(operator.id)}/${disabling ? "disable" : "enable"}`);
              if (result) onClose();
            }}
          >
            {disabling ? "أوقف الآن" : "فعّل"}
          </Button>
          <Button size="lg" onClick={onClose} disabled={run.busy}>
            إلغاء
          </Button>
        </>
      }
    >
      <p>{disabling ? "يخرج فوراً من كل أجهزته ولا يستطيع الدخول حتى تفعّله مجدداً. مفاتيحه تبقى محفوظة." : "يستطيع الدخول مجدداً بمفاتيحه المسجّلة."}</p>
      <PasskeyHint />
    </Dialog>
  );
}
