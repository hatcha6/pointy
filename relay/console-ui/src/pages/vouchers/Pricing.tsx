import { useEffect, useMemo, useState, type ReactNode } from "react";
import { useQuery } from "@tanstack/react-query";
import { ArrowLeft, Braces, ChevronDown, Eye, History, Plus, RotateCcw, Save, Trash2, TriangleAlert, X } from "lucide-react";
import { api } from "../../lib/api";
import { describeError } from "../../lib/errors";
import { dateTime, money } from "../../lib/format";
import { Badge, Button, Card, Field, Notice, Segmented, Skeleton, TimeAgo } from "../../components/ui";
import { DataTable, Stacked } from "../../components/DataTable";
import { PageHeader } from "../../components/PageHeader";
import { PasskeyHint, useAction } from "../../components/guarded";

// The prices every shop pays for cards, airtime and bills come from here.
// What most visits need is up front — where the dollar rate comes from, the
// margin, the service fees — with a live preview of what a few real items
// would sell for. The rarer knobs fold away, and the raw document is one
// click further for what the form does not cover.

type Doc = Record<string, any>;
type SettingsAnswer = { stored: boolean; settings: Doc; record: { id: string; actor: string; note: string; created_at: string } | null; priced: boolean; demo_defaults: string[] };
type HistoryRow = { id: string; sha256: string; actor: string; note: string; created_at: string };
type Sample = { kind: "card" | "airtime" | "bill"; cost: string; currency: "USD" | "LYD" };
type SampleResult = Sample & { cost_lyd?: string; shop_pays?: string; retail?: string; company_keeps?: string; shop_earns?: string; fee?: string; problem?: string };
type Preview = { valid: boolean; problem?: string; rate?: { rate?: string; source?: string; problem?: string }; samples: SampleResult[] };

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

/** Every leaf of a document by its path: "margin.fixed_lyd" → "0.50". */
function flatten(doc: unknown, prefix = "", out: Record<string, string> = {}): Record<string, string> {
  if (Array.isArray(doc)) {
    out[prefix] = JSON.stringify(doc);
  } else if (doc && typeof doc === "object") {
    for (const [k, v] of Object.entries(doc)) flatten(v, prefix ? `${prefix}.${k}` : k, out);
  } else if (prefix) {
    out[prefix] = doc == null ? "" : String(doc);
  }
  return out;
}

/** What each knob is called, for the list of changes before publishing. */
const names: Record<string, string> = {
  usd_rate: "سعر الدولار اليدوي",
  usd_rate_source: "مصدر سعر الدولار",
  usd_rate_series: "سلسلة السعر",
  usd_rate_bank_code: "رمز المصرف",
  usd_rate_buffer_percent: "هامش الأمان على السعر",
  usd_rate_max_age: "أقصى عمر للسعر",
  funding_percent: "رسوم تمويل Reloadly",
  "margin.fixed_lyd": "ربح ثابت لكل بيعة",
  "margin.min_margin_lyd": "أقل هامش للبيعة",
  "margin.shop_share_percent": "حصة المتجر من الهامش",
  "margin.round_step": "تقريب سعر الزبون",
  "margin.min_shop_margin": "أقل ربح للمتجر",
  "margin.brackets": "شرائح الهامش",
  "airtime.order_mode": "طريقة طلب شحن الرصيد",
  "airtime.usd_buffer_percent": "تقريب طلب الدولار (شحن الرصيد)",
  "airtime.service_fee_lyd": "رسوم خدمة شحن الرصيد",
  "bills.order_mode": "طريقة طلب الفواتير",
  "bills.usd_buffer_percent": "تقريب طلب الدولار (الفواتير)",
  "bills.service_fee_lyd": "رسوم خدمة الفواتير",
  retail_step: "تقريب أسعار الزبون (قديم)",
  min_shop_margin: "أقل ربح للمتجر (قديم)",
  popular: "الدول الأكثر طلباً",
};

/** Coded values as they read in the list of changes. */
const valueLabels: Record<string, string> = {
  fulus: "تلقائي",
  manual: "يدوي",
  cash: "السوق الموازي",
  bank: "مصرف",
  usd: "بالدولار",
  local: "بالعملة المحلية",
  auto: "تلقائي",
  ...Object.fromEntries(["12h", "24h", "48h", "72h"].map((d) => [d, d])),
};

function shown(value: string): string {
  if (!value) return "الافتراضي";
  return valueLabels[value] ?? value;
}

/** The relay's reasons for having no dollar rate, in Arabic. */
function rateProblem(problem: string): string {
  if (problem.includes("stale")) return "سعر fulus.ly قديم أكثر من المسموح، فلا يُصدَّق.";
  if (problem.includes("could not be read")) return "تعذّرت قراءة أسعار fulus.ly الآن.";
  if (problem.includes("does not read")) return "سعر fulus.ly وصل بصيغة غير مفهومة.";
  if (problem.includes("no fulus.ly")) return "لم يصل أي سعر من fulus.ly لهذه السلسلة بعد.";
  return problem;
}

const ageLabels: Record<string, string> = { "12h": "12 ساعة", "24h": "يوم", "48h": "يومان", "72h": "3 أيام" };

const kindLabels: Record<Sample["kind"], string> = { card: "بطاقة", airtime: "شحن رصيد", bill: "فاتورة" };

const defaultSamples: Sample[] = [
  { kind: "card", cost: "10", currency: "USD" },
  { kind: "card", cost: "50", currency: "LYD" },
  { kind: "airtime", cost: "5", currency: "USD" },
  { kind: "bill", cost: "100", currency: "LYD" },
];

function loadSamples(): Sample[] {
  try {
    const saved = JSON.parse(localStorage.getItem("console-pricing-samples") ?? "null");
    return Array.isArray(saved) && saved.length ? saved : defaultSamples;
  } catch {
    return defaultSamples;
  }
}

function usePreview(settings: Doc | null, samples: Sample[]) {
  const body = settings ? JSON.stringify({ settings, samples }) : "";
  const [debounced, setDebounced] = useState(body);
  useEffect(() => {
    const id = window.setTimeout(() => setDebounced(body), 350);
    return () => window.clearTimeout(id);
  }, [body]);
  return useQuery({
    queryKey: ["vouchers", "settings", "preview", debounced],
    queryFn: () => api.post<Preview>("/v1/vouchers/admin/settings/preview", JSON.parse(debounced)),
    enabled: !!debounced,
    placeholderData: (previous) => previous,
    staleTime: 30_000,
    retry: false,
  });
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
  const [rawMode, setRawMode] = useState(false);
  const [note, setNote] = useState("");
  const [showChanges, setShowChanges] = useState(false);
  const [samples, setSamples] = useState<Sample[]>(loadSamples);
  const publish = useAction<{ unchanged?: boolean }>({ passkey: true, invalidate: [["vouchers"], ["services"]], success: "نُشرت إعدادات التسعير." });

  useEffect(() => {
    if (answer.data) {
      setDoc(answer.data.settings ?? {});
      setJson(JSON.stringify(answer.data.settings ?? {}, null, 2));
    }
  }, [answer.data]);

  useEffect(() => {
    try {
      localStorage.setItem("console-pricing-samples", JSON.stringify(samples));
    } catch {
      /* private mode */
    }
  }, [samples]);

  const published = answer.data?.settings ?? null;
  const jsonError = useMemo(() => {
    try {
      JSON.parse(json || "{}");
      return null;
    } catch (e) {
      return (e as Error).message;
    }
  }, [json]);
  const current: Doc = rawMode && !jsonError ? JSON.parse(json || "{}") : doc;
  const changes = useMemo(() => {
    const before = flatten(published ?? {});
    const after = flatten(current);
    return [...new Set([...Object.keys(before), ...Object.keys(after)])]
      .filter((path) => (before[path] ?? "") !== (after[path] ?? ""))
      .map((path) => ({ path, before: before[path] ?? "", after: after[path] ?? "" }));
  }, [published, current]);
  const changed = changes.length > 0;
  const demo = new Set(answer.data?.demo_defaults ?? []);

  const draftPreview = usePreview(answer.data ? current : null, samples);
  const publishedPreview = usePreview(changed && published ? published : null, samples);

  const update = (path: string, value: unknown) => {
    const next = set(doc, path, value);
    setDoc(next);
    setJson(JSON.stringify(next, null, 2));
  };

  function discard() {
    setDoc(published ?? {});
    setJson(JSON.stringify(published ?? {}, null, 2));
    setShowChanges(false);
  }

  async function submit() {
    if (await publish.run("PUT", "/v1/vouchers/admin/settings", { ...current, note: note.trim() })) {
      setNote("");
      setShowChanges(false);
    }
  }

  const num = (path: string, label: string, help?: string, suffix?: string) => (
    <NumberField key={path} path={path} label={label} help={help} suffix={suffix} value={get(doc, path)} demo={demo.has(path) || demo.has(path.split(".")[0])} onChange={update} />
  );

  const source = String(get(doc, "usd_rate_source") ?? "fulus");
  const series = String(get(doc, "usd_rate_series") ?? "cash");
  const rate = draftPreview.data?.rate;

  return (
    <>
      <PageHeader
        title="التسعير"
        description="من هنا تُحسب أسعار البطاقات وشحن الرصيد والفواتير لكل المتاجر. عدّل وشاهد الأثر فوراً، ثم انشر — كل نشر يبقى في السجل."
        actions={
          <Button variant={rawMode ? "primary" : "ghost"} icon={<Braces />} onClick={() => {
            if (rawMode && !jsonError) setDoc(JSON.parse(json || "{}"));
            setRawMode(!rawMode);
          }}>
            {rawMode ? "العودة للنموذج" : "تحرير المستند"}
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
        <div className="pricing-layout">
          <div className="stack">
            <RateStatus rate={rate} priced={answer.data?.priced} record={answer.data?.record ?? null} />
            {demo.size > 0 && (
              <Notice tone="money" icon={<TriangleAlert />}>
                {demo.size} من الإعدادات ما زالت على القيم التجريبية التي لم يقرّرها أحد — معلّمة بنقطة برتقالية. راجعها قبل البيع الفعلي.
              </Notice>
            )}

            {rawMode ? (
              <Card title="المستند كاملاً" hint="يشمل ما ليس في النموذج: هوامش البطاقات، هوامش كل خدمة…">
                <textarea className="textarea code" value={json} onChange={(e) => setJson(e.target.value)} spellCheck={false} />
                {jsonError && <p className="error-text" style={{ marginTop: 8 }}>{jsonError}</p>}
              </Card>
            ) : (
              <>
                <Card title="سعر الدولار" hint="تكاليف Reloadly بالدولار تُحوّل به">
                  <div className="form">
                    <Field label="من أين يأتي السعر؟">
                      <Segmented
                        value={source}
                        onChange={(v) => update("usd_rate_source", v)}
                        options={[
                          { id: "fulus", label: "تلقائي من fulus.ly" },
                          { id: "manual", label: "أكتبه بنفسي" },
                        ]}
                      />
                    </Field>
                    {source === "manual" ? (
                      <div className="form-grid">{num("usd_rate", "دينار لكل دولار", "ما تدفعه الشركة لدولار واحد.", "د.ل")}</div>
                    ) : (
                      <>
                        <Field label="أي سعر؟">
                          <Segmented
                            value={series}
                            onChange={(v) => update("usd_rate_series", v)}
                            options={[
                              { id: "cash", label: "السوق الموازي (نقداً)" },
                              { id: "bank", label: "سعر مصرف محدّد" },
                            ]}
                          />
                        </Field>
                        <div className="form-grid">
                          {series === "bank" && (
                            <TextField path="usd_rate_bank_code" label="رمز المصرف في fulus.ly" value={get(doc, "usd_rate_bank_code")} onChange={update} placeholder="nab" />
                          )}
                          {num("usd_rate_buffer_percent", "هامش أمان فوق السعر", "يحميك إن ارتفع الدولار قبل التحديث التالي.", "%")}
                        </div>
                      </>
                    )}
                    <div className="form-grid">{num("funding_percent", "رسوم تمويل حساب Reloadly", "ما يكلّفه شحن حساب Reloadly نفسه.", "%")}</div>
                    <Disclosure label="خيارات متقدمة" hint="عمر السعر، السعر الاحتياطي">
                      <div className="form">
                        <Field label="أقصى عمر للسعر التلقائي" help="أقدم من هذا = لا يُصدَّق، فيُستعمل السعر الاحتياطي أو يتوقف البيع.">
                          <div className="chips">
                            {["12h", "24h", "48h", "72h"].map((d) => (
                              <button type="button" key={d} className={`chip ${String(get(doc, "usd_rate_max_age") ?? "48h") === d ? "on" : ""}`} onClick={() => update("usd_rate_max_age", d)}>
                                {ageLabels[d]}
                              </button>
                            ))}
                          </div>
                        </Field>
                        {source !== "manual" && <div className="form-grid">{num("usd_rate", "سعر احتياطي يدوي", "يُستعمل فقط إن تعذّر السعر التلقائي. فارغ = يتوقف بيع Reloadly.", "د.ل")}</div>}
                      </div>
                    </Disclosure>
                  </div>
                </Card>

                <Card title="هامش الربح" hint={demo.has("margin") ? <DemoDot /> : undefined}>
                  <p className="card-lead muted">الهامش يُقسم بين الشركة والمتجر: المتجر يشتري بالتكلفة وجزء من الهامش، ويبيع للزبون بالتكلفة والهامش كاملاً.</p>
                  <div className="form-grid">
                    {num("margin.fixed_lyd", "ربح ثابت لكل بيعة", undefined, "د.ل")}
                    {num("margin.shop_share_percent", "حصة المتجر من الهامش", undefined, "%")}
                    {num("margin.min_margin_lyd", "أقل هامش للبيعة", undefined, "د.ل")}
                  </div>
                  <Disclosure label="شرائح الهامش والتقريب" hint="نسبة تدريجية من التكلفة، تقريب سعر الزبون">
                    <div className="form-grid">
                      {num("margin.round_step", "تقريب سعر الزبون لأعلى إلى", undefined, "د.ل")}
                      {num("margin.min_shop_margin", "أقل ربح للمتجر", undefined, "د.ل")}
                    </div>
                    <Brackets value={get(doc, "margin.brackets") ?? []} onChange={(v) => update("margin.brackets", v)} />
                  </Disclosure>
                </Card>

                <div className="grid two">
                  <ServiceCard title="شحن الرصيد المباشر" prefix="airtime" doc={doc} demo={demo} update={update} num={num} modes={[["usd", "بالدولار (يحتفظ بعمولة Reloadly)"], ["local", "بالعملة المحلية (المبلغ بالضبط)"]]} />
                  <ServiceCard title="الفواتير" prefix="bills" doc={doc} demo={demo} update={update} num={num} modes={[["auto", "تلقائي (بالدولار حيث أرخص)"], ["local", "دائماً بالمبلغ المحلي"]]} />
                </div>

                <Disclosure label="إعدادات عامة" hint="الدول الأكثر طلباً، إعدادات قديمة" asCard>
                  <div className="form-grid">
                    <TextField
                      path="popular"
                      label="الدول الأكثر طلباً"
                      help="تظهر أولاً في شاشة المتجر. رموز الدول مفصولة بفواصل، مثل ML,NE"
                      value={(get(doc, "popular") ?? []).join(",")}
                      onChange={(p, v) => update(p, String(v).split(",").map((s) => s.trim().toUpperCase()).filter(Boolean))}
                      demo={demo.has("popular")}
                    />
                    {num("retail_step", "تقريب أسعار الزبون (قديم)", "يُفضَّل ضبطه في الهامش.", "د.ل")}
                    {num("min_shop_margin", "أقل ربح للمتجر (قديم)", undefined, "د.ل")}
                  </div>
                </Disclosure>
              </>
            )}

            <Card tight title="النسخ المنشورة" hint={<History width={14} />}>
              <DataTable
                rows={history.data ?? []}
                columns={[
                  { key: "id", header: "النسخة", mobile: "title", cell: (h) => <Stacked title={h.note || "بلا وصف"} sub={<span className="mono">{h.id.slice(0, 8)}</span>} /> },
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

          <PreviewPanel
            samples={samples}
            setSamples={setSamples}
            draft={draftPreview.data}
            before={changed ? publishedPreview.data : undefined}
            loading={draftPreview.isFetching}
          />
        </div>
      )}

      {changed && (
        <div className="publish-bar" role="region" aria-label="تغييرات لم تُنشر">
          <div className="publish-inner">
            <div className="publish-head">
              <strong>{changes.length === 1 ? "تغيير واحد لم يُنشر" : `${changes.length} تغييرات لم تُنشر`}</strong>
              <button type="button" className="disclosure" aria-expanded={showChanges} onClick={() => setShowChanges((v) => !v)}>
                <ChevronDown width={15} className={showChanges ? "flip" : ""} />
                {showChanges ? "إخفاء" : "ما الذي تغيّر؟"}
              </button>
            </div>
            {showChanges && (
              <ul className="change-list">
                {changes.map((c) => (
                  <li key={c.path}>
                    <span>{names[c.path] ?? <span className="mono">{c.path}</span>}</span>
                    <span className="change-values">
                      <del>{shown(c.before)}</del>
                      <ArrowLeft width={13} />
                      <ins>{shown(c.after)}</ins>
                    </span>
                  </li>
                ))}
              </ul>
            )}
            {draftPreview.data && !draftPreview.data.valid && (
              <p className="error-text">
                <TriangleAlert width={14} /> {draftPreview.data.problem}
              </p>
            )}
            <div className="publish-row">
              <input className="input" value={note} onChange={(e) => setNote(e.target.value)} maxLength={300} placeholder="ما الذي تغيّر ولماذا؟ (يُحفظ مع النسخة)" />
              <Button variant="primary" icon={<Save />} disabled={!!(rawMode && jsonError) || draftPreview.data?.valid === false} loading={publish.busy} onClick={() => void submit()}>
                نشر
              </Button>
              <Button variant="ghost" icon={<RotateCcw />} onClick={discard} disabled={publish.busy}>
                تراجع
              </Button>
            </div>
            <PasskeyHint />
          </div>
        </div>
      )}
    </>
  );
}

function RateStatus({ rate, priced, record }: { rate?: Preview["rate"]; priced?: boolean; record: SettingsAnswer["record"] }) {
  const ok = !!rate?.rate;
  return (
    <div className={`rate-status ${ok ? "" : "bad"}`}>
      <div>
        <span className="muted">الدولار يُحسب الآن بـ</span>
        <strong className="num">{ok ? money(Number(rate!.rate).toFixed(3)) : "—"}</strong>
        <span className="muted">
          {ok ? (rate!.source === "manual" ? "سعر يدوي" : "من fulus.ly مع هامش الأمان") : "لا سعر: Reloadly لا يبيع شيئاً"}
        </span>
        {rate?.problem && <span className="rate-problem">{rateProblem(rate.problem)}</span>}
      </div>
      <div className="rate-meta">
        {!priced && <Badge tone="warning">غير مسعّر</Badge>}
        {record ? (
          <span className="muted">
            آخر نشر <TimeAgo value={record.created_at} /> بيد {record.actor || "—"}
          </span>
        ) : (
          <span className="muted">لم يُنشر شيء بعد — القيم التجريبية تعمل</span>
        )}
      </div>
    </div>
  );
}

/** What a few items would sell for: the draft, and the published price beside it. */
function PreviewPanel({ samples, setSamples, draft, before, loading }: {
  samples: Sample[];
  setSamples: (s: Sample[]) => void;
  draft?: Preview;
  before?: Preview;
  loading: boolean;
}) {
  const [editing, setEditing] = useState(false);
  const edit = (i: number, patch: Partial<Sample>) => setSamples(samples.map((s, j) => (j === i ? { ...s, ...patch } : s)));
  return (
    <aside className="preview-panel">
      <Card
        title={
          <span className="row" style={{ gap: 6 }}>
            <Eye width={17} /> معاينة الأسعار
          </span>
        }
        hint={loading ? "يُحسب…" : before ? "قبل ← بعد" : undefined}
        actions={
          <Button size="sm" variant="ghost" onClick={() => setEditing(!editing)}>
            {editing ? "تم" : "تغيير الأمثلة"}
          </Button>
        }
        tight
      >
        <ul className="preview-list">
          {samples.map((s, i) => {
            const r = draft?.samples[i];
            const b = before?.samples[i];
            return (
              <li key={i}>
                {editing ? (
                  <div className="preview-edit">
                    <select className="select" value={s.kind} onChange={(e) => edit(i, { kind: e.target.value as Sample["kind"] })}>
                      {Object.entries(kindLabels).map(([k, l]) => (
                        <option key={k} value={k}>
                          {l}
                        </option>
                      ))}
                    </select>
                    <input className="input num" inputMode="decimal" value={s.cost} onChange={(e) => edit(i, { cost: e.target.value })} />
                    <select className="select" value={s.currency} onChange={(e) => edit(i, { currency: e.target.value as Sample["currency"] })}>
                      <option value="USD">$</option>
                      <option value="LYD">د.ل</option>
                    </select>
                    <Button size="sm" variant="ghost" icon={<X />} aria-label="حذف" onClick={() => setSamples(samples.filter((_, j) => j !== i))} />
                  </div>
                ) : (
                  <div className="preview-title">
                    <strong>
                      {kindLabels[s.kind]} {s.currency === "USD" ? `${s.cost}$` : money(s.cost)}
                    </strong>
                    {r?.cost_lyd && s.currency === "USD" && <span className="faint">تكلفتنا {money(r.cost_lyd)}</span>}
                  </div>
                )}
                {r?.problem ? (
                  <span className="muted preview-problem">{r.problem === "no_rate" ? "لا سعر دولار — لا يُباع" : "لا يُحسب بهذه الإعدادات"}</span>
                ) : r?.shop_pays ? (
                  <dl className="preview-prices">
                    <div>
                      <dt>المتجر يدفع</dt>
                      <dd>
                        <Was before={b?.shop_pays} now={r.shop_pays} />
                      </dd>
                    </div>
                    <div>
                      <dt>الزبون يدفع</dt>
                      <dd>
                        <Was before={b?.retail} now={r.retail!} />
                      </dd>
                    </div>
                    <div>
                      <dt>ربحنا</dt>
                      <dd className="positive">
                        <Was before={b?.company_keeps} now={r.company_keeps!} />
                      </dd>
                    </div>
                    <div>
                      <dt>ربح المتجر</dt>
                      <dd>
                        <Was before={b?.shop_earns} now={r.shop_earns!} />
                      </dd>
                    </div>
                  </dl>
                ) : (
                  <Skeleton height={40} />
                )}
              </li>
            );
          })}
        </ul>
        {editing && samples.length < 8 && (
          <div className="preview-add">
            <Button size="sm" icon={<Plus />} onClick={() => setSamples([...samples, { kind: "card", cost: "20", currency: "USD" }])}>
              مثال
            </Button>
            <Button size="sm" variant="ghost" onClick={() => setSamples(defaultSamples)}>
              الأمثلة الأصلية
            </Button>
          </div>
        )}
      </Card>
    </aside>
  );
}

function Was({ before, now }: { before?: string; now: string }) {
  const moved = before !== undefined && Number(before) !== Number(now);
  return (
    <span className="was">
      {moved && <del>{money(before)}</del>}
      <span className={moved ? (Number(now) > Number(before) ? "up" : "down") : ""}>{money(now)}</span>
    </span>
  );
}

function ServiceCard({ title, prefix, doc, demo, update, num, modes }: {
  title: string;
  prefix: "airtime" | "bills";
  doc: Doc;
  demo: Set<string>;
  update: (path: string, value: unknown) => void;
  num: (path: string, label: string, help?: string, suffix?: string) => ReactNode;
  modes: [string, string][];
}) {
  return (
    <Card title={title}>
      <div className="form">
        <Field label={<>طريقة الطلب{demo.has(`${prefix}.order_mode`) && <DemoDot />}</>}>
          <Segmented value={String(get(doc, `${prefix}.order_mode`) ?? modes[0][0])} onChange={(v) => update(`${prefix}.order_mode`, v)} options={modes.map(([id, l]) => ({ id, label: l }))} />
        </Field>
        {num(`${prefix}.service_fee_lyd`, "رسوم خدمة ثابتة", "تُضاف لسعر المتجر والزبون، وتبقى للشركة.", "د.ل")}
        <Disclosure label="متقدم" hint="تقريب طلب الدولار">
          {num(`${prefix}.usd_buffer_percent`, "تقريب طلب الدولار لأعلى", "حتى لا يستلم الزبون أقل مما طلب.", "%")}
        </Disclosure>
      </div>
    </Card>
  );
}

/** Folded knobs: closed until asked for. */
function Disclosure({ label, hint, children, asCard }: { label: string; hint?: string; children: ReactNode; asCard?: boolean }) {
  const [open, setOpen] = useState(false);
  const body = (
    <>
      <button type="button" className="disclosure" aria-expanded={open} onClick={() => setOpen(!open)}>
        <ChevronDown width={16} className={open ? "flip" : ""} />
        {label}
        {hint && <span className="muted">{hint}</span>}
      </button>
      {open && <div className="disclosure-body pricing-more">{children}</div>}
    </>
  );
  return asCard ? <div className="card disclosure-card">{body}</div> : <div className="disclosure-wrap">{body}</div>;
}

function DemoDot() {
  return <span className="demo-dot" title="قيمة تجريبية لم يقرّرها أحد" aria-label="قيمة تجريبية" />;
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
    <Field label={<>{label}{demo && <DemoDot />}</>} help={help} error={invalid ? "رقم موجب" : null} htmlFor={path}>
      <div className="input-affix">
        <input id={path} className={`input num ${invalid ? "invalid" : ""}`} inputMode="decimal" value={text} placeholder="الافتراضي" onChange={(e) => onChange(path, e.target.value.trim())} />
        {suffix && <span className="affix">{suffix}</span>}
      </div>
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
    <Field label={<>{label}{demo && <DemoDot />}</>} help={help} htmlFor={path}>
      <input id={path} className="input mono" dir="ltr" value={value == null ? "" : String(value)} placeholder={placeholder} onChange={(e) => onChange(path, e.target.value)} />
    </Field>
  );
}

type Bracket = { up_to_lyd: string; percent: string };

/** Marginal percentages of cost, by bracket; the last one is open. */
function Brackets({ value, onChange }: { value: Bracket[]; onChange: (v: Bracket[]) => void }): ReactNode {
  const rows = value.length ? value : [];
  const edit = (i: number, key: keyof Bracket, v: string) => onChange(rows.map((r, j) => (j === i ? { ...r, [key]: v.trim() } : r)));
  let from = "0";
  return (
    <div style={{ marginTop: 16 }}>
      <div className="field-label" style={{ marginBottom: 8 }}>
        شرائح الهامش — نسبة من التكلفة، كل شريحة على جزئها فقط
      </div>
      <div className="brackets">
        {rows.map((r, i) => {
          const start = from;
          from = r.up_to_lyd || "∞";
          return (
            <div key={i} className="bracket-row">
              <span className="muted">من {start} إلى</span>
              <input className="input num" dir="ltr" placeholder={i === rows.length - 1 ? "∞" : "د.ل"} value={r.up_to_lyd ?? ""} onChange={(e) => edit(i, "up_to_lyd", e.target.value)} />
              <span className="muted">د.ل ←</span>
              <input className="input num" dir="ltr" placeholder="%" value={r.percent ?? ""} onChange={(e) => edit(i, "percent", e.target.value)} />
              <span className="muted">%</span>
              <Button size="sm" variant="ghost" icon={<Trash2 />} onClick={() => onChange(rows.filter((_, j) => j !== i))} aria-label="حذف" />
            </div>
          );
        })}
        <div>
          <Button size="sm" icon={<Plus />} onClick={() => onChange([...rows, { up_to_lyd: "", percent: "" }])}>
            شريحة
          </Button>
        </div>
      </div>
    </div>
  );
}
