import { useEffect, useMemo, useState, type ReactNode } from "react";
import { useQuery } from "@tanstack/react-query";
import { Braces, History, PercentCircle, Plus, Save, Trash2, TriangleAlert } from "lucide-react";
import { api } from "../../lib/api";
import { describeError } from "../../lib/errors";
import { dateTime } from "../../lib/format";
import { Badge, Button, Card, Field, Notice, Segmented, Skeleton, Tabs, TimeAgo } from "../../components/ui";
import { DataTable, Stacked } from "../../components/DataTable";
import { PageHeader } from "../../components/PageHeader";
import { PasskeyHint, useAction } from "../../components/guarded";

type Doc = Record<string, any>;
type SettingsAnswer = { stored: boolean; settings: Doc; record: { id: string; actor: string; note: string; created_at: string } | null; priced: boolean; demo_defaults: string[] };
type HistoryRow = { id: string; sha256: string; actor: string; note: string; created_at: string };

function get(doc: Doc, path: string): any {
  return path.split(".").reduce((v, k) => (v == null ? undefined : v[k]), doc);
}

function set(doc: Doc, path: string, value: unknown): Doc {
  const keys = path.split(".");
  const out: Doc = structuredClone(doc);
  let node = out;
  keys.slice(0, -1).forEach((k) => {
    if (node[k] == null || typeof node[k] !== "object") node[k] = {};
    node = node[k];
  });
  const last = keys[keys.length - 1];
  if (value === "" || value === undefined || (Array.isArray(value) && value.length === 0)) delete node[last];
  else node[last] = value;
  return out;
}

const numberPattern = /^\d+(\.\d+)?$/;

export function Pricing() {
  const answer = useQuery({ queryKey: ["vouchers", "settings"], queryFn: () => api.get<SettingsAnswer>("/v1/vouchers/admin/settings"), retry: false });
  const history = useQuery({
    queryKey: ["vouchers", "settings", "history"],
    queryFn: () => api.get<{ history: HistoryRow[] }>("/v1/vouchers/admin/settings/history?limit=20").then((r) => r.history ?? []),
    retry: false,
  });
  const [doc, setDoc] = useState<Doc>({});
  const [json, setJson] = useState("");
  const [tab, setTab] = useState<"form" | "json">("form");
  const [note, setNote] = useState("");
  const publish = useAction<{ unchanged?: boolean }>({ passkey: true, invalidate: [["vouchers"], ["services"]], success: "نُشرت إعدادات التسعير." });

  useEffect(() => {
    if (answer.data) {
      setDoc(answer.data.settings ?? {});
      setJson(JSON.stringify(answer.data.settings ?? {}, null, 2));
    }
  }, [answer.data]);

  const original = useMemo(() => JSON.stringify(answer.data?.settings ?? {}), [answer.data]);
  const jsonError = useMemo(() => {
    try {
      JSON.parse(json || "{}");
      return null;
    } catch (e) {
      return (e as Error).message;
    }
  }, [json]);
  const current = tab === "json" && !jsonError ? JSON.parse(json || "{}") : doc;
  const changed = JSON.stringify(current) !== original;
  const demo = new Set(answer.data?.demo_defaults ?? []);

  const update = (path: string, value: unknown) => {
    const next = set(doc, path, value);
    setDoc(next);
    setJson(JSON.stringify(next, null, 2));
  };

  async function submit() {
    if (await publish.run("PUT", "/v1/vouchers/admin/settings", { ...current, note: note.trim() })) setNote("");
  }

  const num = (path: string, labelText: string, help?: string, suffix?: string) => (
    <NumberField key={path} path={path} label={labelText} help={help} suffix={suffix} value={get(doc, path)} demo={demo.has(path) || demo.has(path.split(".")[0])} onChange={update} />
  );

  return (
    <>
      <PageHeader
        title="التسعير"
        description="سعر الدولار والهوامش التي تُحسب منها أسعار البطاقات وشحن الرصيد والفواتير. كل نشر يبقى في السجل."
        actions={
          <Button variant="primary" icon={<Save />} disabled={!changed || !!(tab === "json" && jsonError)} loading={publish.busy} onClick={() => void submit()}>
            انشر الإعدادات
          </Button>
        }
      />
      {answer.isError ? (
        <Notice tone="danger" icon={<TriangleAlert />}>
          {describeError(answer.error).title} {(answer.error as Error)?.message}
        </Notice>
      ) : answer.isLoading ? (
        <Skeleton height={300} />
      ) : (
        <div className="stack">
          {!answer.data?.priced && (
            <Notice tone="warning" icon={<TriangleAlert />}>
              لا سعر دولار مضبوط: Reloadly لا يبيع شيئاً حتى يُضبط.
            </Notice>
          )}
          {demo.size > 0 && (
            <Notice tone="money" icon={<PercentCircle />}>
              {demo.size} من الإعدادات ما زالت على القيم التجريبية الافتراضية التي لم يقرّرها أحد (معلّمة «افتراضي» أدناه).
            </Notice>
          )}
          <Tabs
            value={tab}
            onChange={(t) => {
              if (t === "form" && !jsonError) setDoc(JSON.parse(json || "{}"));
              setTab(t);
            }}
            tabs={[
              { id: "form", label: "النموذج", icon: <PercentCircle width={16} /> },
              { id: "json", label: "JSON", icon: <Braces width={16} /> },
            ]}
          />
          {tab === "form" ? (
            <>
              <Card title="سعر الدولار">
                <div className="form-grid">
                  {num("usd_rate", "دينار لكل دولار", "ما تدفعه الشركة لدولار واحد. فارغ = غير مضبوط.")}
                  {num("funding_percent", "رسوم تمويل حساب Reloadly", undefined, "%")}
                  {num("usd_rate_buffer_percent", "هامش أمان على السعر", "عند قراءة السعر تلقائياً.", "%")}
                  <TextField path="usd_rate_source" label="مصدر السعر التلقائي" value={get(doc, "usd_rate_source")} onChange={update} placeholder="fulus" />
                  <TextField path="usd_rate_series" label="سلسلة السعر" value={get(doc, "usd_rate_series")} onChange={update} />
                  <TextField path="usd_rate_max_age" label="أقصى عمر للسعر" value={get(doc, "usd_rate_max_age")} onChange={update} placeholder="24h" />
                </div>
              </Card>
              <Card title="الهامش" hint={demo.has("margin") ? <Badge tone="money">افتراضي</Badge> : undefined}>
                <div className="form-grid">
                  {num("margin.fixed_lyd", "ربح ثابت لكل بيعة", undefined, "د.ل")}
                  {num("margin.min_margin_lyd", "أقل هامش للبيعة", undefined, "د.ل")}
                  {num("margin.shop_share_percent", "حصة المتجر من الهامش", undefined, "%")}
                  {num("margin.round_step", "تقريب سعر الزبون لأعلى إلى", undefined, "د.ل")}
                  {num("margin.min_shop_margin", "أقل ربح للمتجر", undefined, "د.ل")}
                </div>
                <Brackets value={get(doc, "margin.brackets") ?? []} onChange={(v) => update("margin.brackets", v)} />
              </Card>
              <div className="grid two">
                <Card title="شحن الرصيد المباشر">
                  <div className="form">
                    <ModeField path="airtime.order_mode" value={get(doc, "airtime.order_mode")} demo={demo.has("airtime.order_mode")} onChange={update} options={[["usd", "بالدولار (يحتفظ بعمولة Reloadly)"], ["local", "بالعملة المحلية (المبلغ بالضبط)"]]} />
                    {num("airtime.usd_buffer_percent", "تقريب طلب الدولار لأعلى", "حتى لا يستلم الزبون أقل مما طلب.", "%")}
                    {num("airtime.service_fee_lyd", "رسوم خدمة ثابتة", "تُضاف لسعر المتجر والزبون، وتبقى للشركة.", "د.ل")}
                  </div>
                </Card>
                <Card title="الفواتير">
                  <div className="form">
                    <ModeField path="bills.order_mode" value={get(doc, "bills.order_mode")} demo={demo.has("bills.order_mode")} onChange={update} options={[["auto", "تلقائي (بالدولار حيث أرخص)"], ["local", "دائماً بالمبلغ المحلي"]]} />
                    {num("bills.usd_buffer_percent", "تقريب طلب الدولار لأعلى", undefined, "%")}
                    {num("bills.service_fee_lyd", "رسوم خدمة ثابتة", undefined, "د.ل")}
                  </div>
                </Card>
              </div>
              <Card title="عام">
                <div className="form-grid">
                  {num("retail_step", "تقريب أسعار الزبون إلى", undefined, "د.ل")}
                  {num("min_shop_margin", "أقل ربح للمتجر", undefined, "د.ل")}
                  <TextField
                    path="popular"
                    label="الدول الأكثر طلباً"
                    help="رموز الدول مفصولة بفواصل، مثل ML,NE"
                    value={(get(doc, "popular") ?? []).join(",")}
                    onChange={(p, v) => update(p, String(v).split(",").map((s) => s.trim().toUpperCase()).filter(Boolean))}
                    demo={demo.has("popular")}
                  />
                </div>
              </Card>
            </>
          ) : (
            <Card title="المستند كاملاً" hint="يشمل ما ليس في النموذج: هوامش البطاقات، هوامش كل خدمة…">
              <textarea className="textarea code" value={json} onChange={(e) => setJson(e.target.value)} spellCheck={false} />
              {jsonError && <p className="error-text" style={{ color: "var(--danger)", marginTop: 8 }}>{jsonError}</p>}
            </Card>
          )}
          <Card title="النشر">
            <div className="form">
              <Field label="ما الذي تغيّر؟" htmlFor="pnote" help="يُحفظ مع النسخة.">
                <input id="pnote" className="input" value={note} onChange={(e) => setNote(e.target.value)} maxLength={300} />
              </Field>
              {publish.error && (
                <Notice tone="danger" icon={<TriangleAlert />}>
                  {publish.error}
                </Notice>
              )}
              <div className="row">
                <Button variant="primary" icon={<Save />} disabled={!changed || !!(tab === "json" && jsonError)} loading={publish.busy} onClick={() => void submit()}>
                  انشر الإعدادات
                </Button>
                {changed && (
                  <Button
                    variant="ghost"
                    onClick={() => {
                      setDoc(answer.data?.settings ?? {});
                      setJson(JSON.stringify(answer.data?.settings ?? {}, null, 2));
                    }}
                  >
                    تراجع عن التعديلات
                  </Button>
                )}
              </div>
              <PasskeyHint />
            </div>
          </Card>
          <Card tight title="النسخ المنشورة" hint={<History width={14} />}>
            <DataTable
              rows={history.data ?? []}
              columns={[
                { key: "id", header: "النسخة", mobile: "title", cell: (h) => <Stacked title={<span className="mono">{h.id.slice(0, 8)}</span>} sub={h.note} /> },
                { key: "when", header: "نُشرت", mobile: "trailing", cell: (h) => <TimeAgo value={h.created_at} /> },
                { key: "actor", header: "بواسطة", cell: (h) => h.actor || "—" },
                { key: "at", header: "الوقت", wideOnly: true, cell: (h) => dateTime(h.created_at) },
              ]}
              rowKey={(h) => h.id}
              loading={history.isLoading}
              skeletonRows={3}
            />
          </Card>
        </div>
      )}
    </>
  );
}

function DemoTag({ on }: { on?: boolean }) {
  return on ? (
    <>
      {" "}
      <Badge tone="money">افتراضي</Badge>
    </>
  ) : null;
}

function NumberField({ path, label, help, suffix, value, demo, onChange }: {
  path: string;
  label: string;
  help?: string;
  suffix?: string;
  value: unknown;
  demo?: boolean;
  onChange: (path: string, value: string) => void;
}) {
  const text = value == null ? "" : String(value);
  const invalid = text !== "" && !numberPattern.test(text);
  return (
    <Field label={label} help={help} error={invalid ? "رقم موجب" : null} htmlFor={path}>
      <div className="input-affix">
        <input id={path} className={`input num ${invalid ? "invalid" : ""}`} inputMode="decimal" value={text} placeholder="الافتراضي" onChange={(e) => onChange(path, e.target.value.trim())} />
        {suffix && <span className="affix">{suffix}</span>}
      </div>
      {demo && <Badge tone="money">افتراضي — لم يُقرَّر</Badge>}
    </Field>
  );
}

function TextField({ path, label, help, value, placeholder, demo, onChange }: {
  path: string;
  label: string;
  help?: string;
  value: unknown;
  placeholder?: string;
  demo?: boolean;
  onChange: (path: string, value: string) => void;
}) {
  return (
    <Field label={label} help={help} htmlFor={path}>
      <input id={path} className="input mono" value={value == null ? "" : String(value)} placeholder={placeholder} onChange={(e) => onChange(path, e.target.value)} />
      <DemoTag on={demo} />
    </Field>
  );
}

function ModeField({ path, value, options, demo, onChange }: { path: string; value: unknown; options: [string, string][]; demo?: boolean; onChange: (path: string, value: string) => void }) {
  return (
    <Field label={<>طريقة الطلب<DemoTag on={demo} /></>}>
      <Segmented value={String(value ?? options[0][0])} onChange={(v) => onChange(path, v)} options={options.map(([id, l]) => ({ id, label: l }))} />
    </Field>
  );
}

type Bracket = { up_to_lyd: string; percent: string };

/** Marginal percentages of cost, by bracket; the last one is open. */
function Brackets({ value, onChange }: { value: Bracket[]; onChange: (v: Bracket[]) => void }): ReactNode {
  const rows = value.length ? value : [];
  const edit = (i: number, key: keyof Bracket, v: string) => onChange(rows.map((r, j) => (j === i ? { ...r, [key]: v.trim() } : r)));
  return (
    <div style={{ marginTop: 18 }}>
      <div className="field-label" style={{ marginBottom: 8 }}>
        شرائح الهامش (نسبة من التكلفة، تدريجية)
      </div>
      <div className="stack" style={{ gap: 8 }}>
        {rows.map((r, i) => (
          <div key={i} className="row" style={{ flexWrap: "nowrap" }}>
            <span className="muted" style={{ minWidth: 48 }}>حتى</span>
            <input className="input num" style={{ maxWidth: 120 }} placeholder={i === rows.length - 1 ? "∞" : "د.ل"} value={r.up_to_lyd ?? ""} onChange={(e) => edit(i, "up_to_lyd", e.target.value)} />
            <input className="input num" style={{ maxWidth: 100 }} placeholder="%" value={r.percent ?? ""} onChange={(e) => edit(i, "percent", e.target.value)} />
            <span className="muted">%</span>
            <Button size="sm" variant="ghost" icon={<Trash2 />} onClick={() => onChange(rows.filter((_, j) => j !== i))} aria-label="حذف" />
          </div>
        ))}
        <div>
          <Button size="sm" icon={<Plus />} onClick={() => onChange([...rows, { up_to_lyd: "", percent: "" }])}>
            شريحة
          </Button>
        </div>
      </div>
    </div>
  );
}
