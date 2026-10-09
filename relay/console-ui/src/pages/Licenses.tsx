import { useState } from "react";
import { Download, KeyRound, TriangleAlert } from "lucide-react";
import { date } from "../lib/format";
import { saveText } from "../lib/files";
import { Button, Card, CopyText, Field, Notice, Switch } from "../components/ui";
import { PageHeader } from "../components/PageHeader";
import { PasskeyHint, useAction } from "../components/guarded";

type Minted = { tokens: string[]; count: number; expires_at?: string | null };

const durations = [
  { id: "", label: "بلا اشتراك" },
  { id: "30d", label: "شهر" },
  { id: "3mo", label: "3 أشهر" },
  { id: "6mo", label: "6 أشهر" },
  { id: "1y", label: "سنة" },
  { id: "perpetual", label: "دائم" },
];

const expiries = [
  { id: "", label: "لا ينتهي" },
  { id: "168h", label: "أسبوع" },
  { id: "720h", label: "30 يوماً" },
  { id: "2160h", label: "90 يوماً" },
];

/**
 * Single-use license keys: a shop's on-prem server redeems one on first boot
 * and is enrolled (and, with a subscription baked in, activated) at once.
 */
export function Licenses() {
  const [count, setCount] = useState(1);
  const [expires, setExpires] = useState("");
  const [duration, setDuration] = useState("1y");
  const [relay, setRelay] = useState(true);
  const [ai, setAi] = useState(false);
  const [minted, setMinted] = useState<Minted | null>(null);
  const run = useAction<Minted>({ passkey: true, success: "صدرت المفاتيح." });

  async function mint() {
    const body: Record<string, unknown> = { count };
    if (expires) body.expires_in = expires;
    // No duration = plain keys: the operator activates the shop later. (An
    // empty duration WITH services would mean a perpetual subscription.)
    if (duration) body.subscription = { relay_enabled: relay, ai_enabled: ai, duration };
    const result = await run.run("POST", "/v1/enrollment/tokens", body);
    if (result) setMinted(result);
  }

  return (
    <>
      <PageHeader title="مفاتيح الترخيص" description="مفتاح لكل متجر جديد. يُدخله المتجر عند أول تشغيل فيُسجَّل ويُفعَّل اشتراكه مباشرة." />
      <div className="grid two">
        <Card title="إصدار مفاتيح">
          <div className="form">
            <Field label="العدد" htmlFor="lcount" help="من 1 إلى 1000. كل مفتاح يُستخدم مرة واحدة.">
              <input
                id="lcount"
                className="input num"
                type="number"
                min={1}
                max={1000}
                value={count}
                onChange={(e) => setCount(Math.max(1, Math.min(1000, Number(e.target.value) || 1)))}
              />
            </Field>
            <Field label="الاشتراك المضمَّن" help="يبدأ من لحظة استخدام المفتاح، لا من الآن.">
              <div className="chips">
                {durations.map((d) => (
                  <button type="button" key={d.id} className={`chip ${duration === d.id ? "on" : ""}`} onClick={() => setDuration(d.id)}>
                    {d.label}
                  </button>
                ))}
              </div>
            </Field>
            {duration && <div>
              <div className="switch-row">
                <div className="text">
                  الوصول عن بعد
                  <span>يعمل فور التفعيل.</span>
                </div>
                <Switch on={relay} onChange={setRelay} label="الوصول عن بعد" />
              </div>
              <div className="switch-row">
                <div className="text">المساعد الذكي</div>
                <Switch on={ai} onChange={setAi} label="المساعد الذكي" />
              </div>
            </div>}
            <Field label="صلاحية المفتاح نفسه">
              <div className="chips">
                {expiries.map((d) => (
                  <button type="button" key={d.id} className={`chip ${expires === d.id ? "on" : ""}`} onClick={() => setExpires(d.id)}>
                    {d.label}
                  </button>
                ))}
              </div>
            </Field>
            {duration && !relay && !ai && (
              <Notice tone="warning" icon={<TriangleAlert />}>
                اشتراك بلا أي خدمة لا يفيد المتجر شيئاً. فعّل الوصول عن بعد أو المساعد.
              </Notice>
            )}
            <Button variant="primary" size="lg" icon={<KeyRound />} loading={run.busy} onClick={mint}>
              {count === 1 ? "أصدر مفتاحاً" : `أصدر ${count} مفاتيح`}
            </Button>
            <PasskeyHint />
          </div>
        </Card>
        <Card
          title="المفاتيح الصادرة"
          actions={
            minted && (
              <Button size="sm" icon={<Download />} onClick={() => saveText(minted.tokens.join("\n") + "\n", `pointy-licenses-${new Date().toISOString().slice(0, 10)}.txt`)}>
                تنزيل
              </Button>
            )
          }
        >
          {!minted ? (
            <p className="muted">تظهر هنا مرة واحدة بعد الإصدار. لا يحفظها الخادم بصيغتها الأصلية، فانسخها أو نزّلها.</p>
          ) : (
            <div className="form">
              <Notice tone="warning" icon={<TriangleAlert />}>
                لن تظهر هذه المفاتيح مرة أخرى.
                {minted.expires_at ? ` تنتهي صلاحيتها ${date(minted.expires_at)}.` : ""}
              </Notice>
              <div className="secret-list">
                {minted.tokens.map((t) => (
                  <CopyText key={t} value={t} />
                ))}
              </div>
              {minted.tokens.length > 1 && <CopyText value={minted.tokens.join("\n")} display={<span>نسخ الكل ({minted.tokens.length})</span>} />}
            </div>
          )}
        </Card>
      </div>
    </>
  );
}
