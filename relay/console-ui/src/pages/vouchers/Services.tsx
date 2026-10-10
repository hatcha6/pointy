import { useEffect, useState } from "react";
import { Unavailable } from "../../components/Unavailable";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { Activity, Calculator, Globe2, Languages, RefreshCw, Search, TriangleAlert } from "lucide-react";
import { api, qs } from "../../lib/api";
import { useSearchParam } from "../../lib/router";
import { matches } from "../../lib/search";
import { count, money } from "../../lib/format";
import { Badge, Button, Card, Empty, Field, Money, Notice, Segmented, Skeleton, Tabs, TimeAgo } from "../../components/ui";
import { DataTable, Stacked, type Column } from "../../components/DataTable";
import { PageHeader } from "../../components/PageHeader";
import { ConfigList, testOrLive, yesNo } from "../../components/ConfigList";
import { useAction } from "../../components/guarded";
import { useToast } from "../../components/toast";

type Amount = { amount: string; receive: string; receive_currency: string; unit_price?: string; retail_price?: string };
type Operator = { id: number; name: string; name_en: string; mode: string; amount_currency: string; receive_currency: string; approximate: boolean; min?: string; max?: string; amounts: Amount[] };
type Plan = { id: number; amount: string; description: string; description_en: string; unit_price?: string; retail_price?: string };
type Biller = { id: number; name: string; name_en: string; type: string; service: string; mode: string; requires_invoice: boolean; amount_currency: string; min?: string; max?: string; plans?: Plan[] };
type Country = { code: string; name: string; name_en: string; dial: string; currency: string; currency_name: string; popular: boolean; airtime?: Operator[]; bills?: Biller[] };
type Directory = { version: string; generated_at: string; currency: string; test_mode: boolean; configured: boolean; priced: boolean; popular: string[]; countries: Country[] };
type Stats = Record<string, unknown> & { rejected?: { at: string; reason: string } | null; stale?: boolean; read_at?: string };
type QuoteAnswer = {
  quote: { kind: string; name: string; unit_price: string; retail_price: string; receive: string; approximate: boolean };
  cost_lyd: string;
  order_in_dollars: boolean;
  order_amount: string;
  order_currency: string;
  order_cost_usd: string;
};
type QuoteInput = { kind: "airtime" | "bill"; id: string; amount: string; currency: string; amountId: string };

type Tab = "status" | "directory" | "quote" | "names";

export function Services() {
  const [tab, setTab] = useSearchParam("tab");
  const current = (tab || "directory") as Tab;
  const [quote, setQuote] = useState<QuoteInput | null>(null);
  return (
    <>
      <PageHeader title="الشحن والفواتير" description="شحن الرصيد المباشر ودفع الفواتير عبر Reloadly: ما يُعرض للمتاجر، وكم يكلّف، وكم يدفع المتجر والزبون." />
      <Tabs<Tab>
        value={current}
        onChange={(t) => setTab(t === "directory" ? "" : t)}
        tabs={[
          { id: "directory", label: "الدليل", icon: <Globe2 width={16} /> },
          { id: "quote", label: "حساب سعر", icon: <Calculator width={16} /> },
          { id: "status", label: "الحالة", icon: <Activity width={16} /> },
          { id: "names", label: "أسماء ناقصة", icon: <Languages width={16} /> },
        ]}
      />
      {current === "directory" && (
        <DirectoryTab
          onQuote={(q) => {
            setQuote(q);
            setTab("quote");
          }}
        />
      )}
      {current === "quote" && <QuoteTab preset={quote} />}
      {current === "status" && <StatusTab />}
      {current === "names" && <NamesTab />}
    </>
  );
}

function useDirectory() {
  return useQuery({
    queryKey: ["services", "directory"],
    queryFn: () => api.get<{ directory: Directory; stats: Stats }>("/v1/services/admin/directory"),
    retry: false,
    staleTime: 5 * 60_000,
  });
}

function DirectoryTab({ onQuote }: { onQuote: (q: QuoteInput) => void }) {
  const directory = useDirectory();
  const [code, setCode] = useSearchParam("country");
  const [query, setQuery] = useState("");
  const countries = directory.data?.directory.countries ?? [];
  const selected = countries.find((c) => c.code === code) ?? countries.find((c) => c.popular) ?? countries[0];
  const shown = countries.filter((c) => matches(query, c.name, c.name_en, c.code));

  if (directory.isLoading) return <Skeleton height={300} />;
  if (directory.isError) return <Unavailable feature="services" error={directory.error} onRetry={() => void directory.refetch()} />;
  const d = directory.data!.directory;
  return (
    <div className="stack">
      {(!d.priced || d.test_mode) && (
        <Notice tone="warning" icon={<TriangleAlert />}>
          {!d.priced ? "الأسعار غير محسوبة: سعر الدولار غير مضبوط في التسعير. " : ""}
          {d.test_mode ? "الوضع تجريبي." : ""}
        </Notice>
      )}
      <div className="grid side">
        <div className="stack">
          {selected && <CountryCard country={selected} currency={d.currency} onQuote={onQuote} />}
        </div>
        <Card tight title={`${count(countries.length)} دولة`}>
          <div className="toolbar">
            <div className="search-input">
              <Search />
              <input className="input" placeholder="دولة" value={query} onChange={(e) => setQuery(e.target.value)} />
            </div>
          </div>
          <div className="mlist" style={{ maxHeight: 520, overflowY: "auto" }}>
            {shown.map((c) => (
              <div key={c.code} className={`mcard clickable ${c.code === selected?.code ? "selected" : ""}`} onClick={() => setCode(c.code)} role="button" tabIndex={0}>
                <div className="mcard-top">
                  <div className="mcard-title">
                    <Stacked title={c.name} sub={`${c.code} · ${c.dial}`} />
                  </div>
                  <div className="mcard-trailing">
                    <span className="faint" style={{ fontSize: 12 }}>
                      {c.airtime?.length ?? 0} شحن · {c.bills?.length ?? 0} فواتير
                    </span>
                  </div>
                </div>
              </div>
            ))}
          </div>
        </Card>
      </div>
    </div>
  );
}

function CountryCard({ country, currency, onQuote }: { country: Country; currency: string; onQuote: (q: QuoteInput) => void }) {
  const [kind, setKind] = useState<"airtime" | "bills">(country.airtime?.length ? "airtime" : "bills");
  useEffect(() => setKind(country.airtime?.length ? "airtime" : "bills"), [country.code, country.airtime?.length]);
  return (
    <Card
      tight
      title={
        <span>
          {country.name} <span className="faint mono">{country.code}</span>
        </span>
      }
      actions={
        <Segmented
          value={kind}
          onChange={setKind}
          options={[
            { id: "airtime", label: `شحن ${country.airtime?.length ?? 0}` },
            { id: "bills", label: `فواتير ${country.bills?.length ?? 0}` },
          ]}
        />
      }
    >
      {kind === "airtime" ? (
        (country.airtime ?? []).length === 0 ? (
          <Empty title="لا مشغّلين" />
        ) : (
          (country.airtime ?? []).map((op) => (
            <div key={op.id} className="op-block">
              <div className="op-head">
                <Stacked title={op.name} sub={`${op.name_en} · #${op.id} · ${op.mode}`} />
                {op.approximate && <Badge tone="warning">تقريبي</Badge>}
              </div>
              <DataTable
                rows={op.amounts}
                rowKey={(a) => a.amount}
                columns={[
                  { key: "amount", header: "المبلغ", mobile: "title", cell: (a) => <span className="num">{a.amount} {op.amount_currency}</span> },
                  { key: "shop", header: "يدفع المتجر", align: "end", mobile: "trailing", cell: (a) => (a.unit_price ? <Money value={a.unit_price} currency={currency === "LYD" ? undefined : currency} /> : "—") },
                  { key: "receive", header: "يستلم", cell: (a) => <span className="num">{a.receive} {a.receive_currency}</span> },
                  { key: "retail", header: "للزبون", align: "end", cell: (a) => (a.retail_price ? <Money value={a.retail_price} /> : "—") },
                  {
                    key: "q",
                    header: "",
                    mobile: "actions",
                    cell: (a) => (
                      <Button size="sm" icon={<Calculator />} onClick={() => onQuote({ kind: "airtime", id: String(op.id), amount: a.amount, currency: op.amount_currency, amountId: "" })}>
                        احسب
                      </Button>
                    ),
                  },
                ]}
              />
            </div>
          ))
        )
      ) : (country.bills ?? []).length === 0 ? (
        <Empty title="لا مفوترين" />
      ) : (
        <DataTable
          rows={country.bills ?? []}
          rowKey={(b) => String(b.id)}
          columns={[
            { key: "name", header: "المفوتر", mobile: "title", cell: (b) => <Stacked title={b.name} sub={`${b.name_en} · #${b.id}`} /> },
            { key: "type", header: "النوع", mobile: "trailing", cell: (b) => <Badge tone="outline">{b.service || b.type}</Badge> },
            { key: "mode", header: "المبالغ", cell: (b) => (b.plans?.length ? `${b.plans.length} باقة` : b.min || b.max ? `${b.min ?? "?"}–${b.max ?? "?"} ${b.amount_currency}` : b.mode) },
            { key: "invoice", header: "يتطلب فاتورة", cell: (b) => (b.requires_invoice ? "نعم" : "لا") },
            {
              key: "q",
              header: "",
              mobile: "actions",
              cell: (b) => (
                <Button size="sm" icon={<Calculator />} onClick={() => onQuote({ kind: "bill", id: String(b.id), amount: b.plans?.[0]?.amount ?? b.min ?? "", currency: b.amount_currency, amountId: b.plans?.[0] ? String(b.plans[0].id) : "" })}>
                  احسب
                </Button>
              ),
            },
          ]}
        />
      )}
    </Card>
  );
}

function QuoteTab({ preset }: { preset: QuoteInput | null }) {
  const [input, setInput] = useState<QuoteInput>(preset ?? { kind: "airtime", id: "", amount: "", currency: "", amountId: "" });
  const [answer, setAnswer] = useState<QuoteAnswer | null>(null);
  const run = useAction<QuoteAnswer>({});
  useEffect(() => {
    if (preset) setInput(preset);
  }, [preset]);
  const valid = /^\d+$/.test(input.id) && /^\d+(\.\d+)?$/.test(input.amount);

  async function quote() {
    const body: Record<string, unknown> = { kind: input.kind, amount: input.amount };
    if (input.kind === "airtime") body.operator_id = Number(input.id);
    else body.biller_id = Number(input.id);
    if (input.currency) body.amount_currency = input.currency;
    if (input.amountId) body.amount_id = Number(input.amountId);
    const result = await run.run("POST", "/v1/services/admin/quote", body);
    setAnswer(result ?? null);
  }

  return (
    <div className="grid two">
      <Card title="حساب سعر">
        <form
          className="form"
          onSubmit={(e) => {
            e.preventDefault();
            if (valid) void quote();
          }}
        >
          <Segmented
            value={input.kind}
            onChange={(kind) => setInput({ ...input, kind })}
            options={[
              { id: "airtime", label: "شحن رصيد" },
              { id: "bill", label: "فاتورة" },
            ]}
          />
          <div className="form-row">
            <Field label={input.kind === "airtime" ? "رقم المشغّل" : "رقم المفوتر"} htmlFor="qid">
              <input id="qid" className="input num" inputMode="numeric" value={input.id} onChange={(e) => setInput({ ...input, id: e.target.value.replace(/\D/g, "") })} />
            </Field>
            <Field label="المبلغ" htmlFor="qamt">
              <input id="qamt" className="input num" inputMode="decimal" value={input.amount} onChange={(e) => setInput({ ...input, amount: e.target.value.trim() })} />
            </Field>
          </div>
          <div className="form-row">
            <Field label="العملة (اختياري)" htmlFor="qcur" help="عملة المشغّل افتراضياً.">
              <input id="qcur" className="input mono" value={input.currency} onChange={(e) => setInput({ ...input, currency: e.target.value.trim().toUpperCase() })} />
            </Field>
            {input.kind === "bill" && (
              <Field label="رقم الباقة (اختياري)" htmlFor="qplan">
                <input id="qplan" className="input num" value={input.amountId} onChange={(e) => setInput({ ...input, amountId: e.target.value.replace(/\D/g, "") })} />
              </Field>
            )}
          </div>
          <Button variant="primary" type="submit" icon={<Calculator />} loading={run.busy} disabled={!valid}>
            احسب
          </Button>
        </form>
      </Card>
      <Card title="النتيجة">
        {!answer ? (
          <p className="muted">اختر مبلغاً من الدليل أو أدخل الأرقام واضغط «احسب».</p>
        ) : (
          <dl className="facts">
            <div className="fact" style={{ gridColumn: "1 / -1" }}>
              <dt>الخدمة</dt>
              <dd>
                {answer.quote.name} {answer.quote.approximate && <Badge tone="warning">تقريبي</Badge>}
              </dd>
            </div>
            <div className="fact">
              <dt>يدفع المتجر</dt>
              <dd>
                <Money value={answer.quote.unit_price} />
              </dd>
            </div>
            <div className="fact">
              <dt>السعر المقترح للزبون</dt>
              <dd>
                <Money value={answer.quote.retail_price} />
              </dd>
            </div>
            <div className="fact">
              <dt>تكلفة الشركة</dt>
              <dd>{money(answer.cost_lyd)}</dd>
            </div>
            <div className="fact">
              <dt>ربح الشركة</dt>
              <dd className={Number(answer.quote.unit_price) - Number(answer.cost_lyd) < 0 ? "negative" : "positive"}>
                {money((Number(answer.quote.unit_price) - Number(answer.cost_lyd)).toFixed(3))}
              </dd>
            </div>
            <div className="fact">
              <dt>يستلم الزبون</dt>
              <dd className="num">{answer.quote.receive}</dd>
            </div>
            <div className="fact">
              <dt>يُطلب من Reloadly</dt>
              <dd className="num">
                {answer.order_amount} {answer.order_currency}
                {answer.order_in_dollars && answer.order_cost_usd ? ` (${answer.order_cost_usd} USD)` : ""}
              </dd>
            </div>
          </dl>
        )}
      </Card>
    </div>
  );
}

function StatusTab() {
  const queryClient = useQueryClient();
  const toast = useToast();
  const config = useQuery({ queryKey: ["services", "config"], queryFn: () => api.get<{ stats: Stats }>("/v1/services/admin/config").then((r) => r.stats), retry: false });
  const [refreshing, setRefreshing] = useState(false);
  const stats = config.data;

  async function refresh(accept: boolean) {
    setRefreshing(true);
    try {
      await api.get("/v1/services/admin/directory" + qs({ refresh: 1, accept: accept ? 1 : undefined }));
      toast.success("قُرئ دليل Reloadly من جديد.");
      await queryClient.invalidateQueries({ queryKey: ["services"] });
    } catch (e) {
      toast.error("لم يُقرأ الدليل.", (e as Error).message);
    } finally {
      setRefreshing(false);
    }
  }

  return (
    <div className="stack">
      {stats?.rejected && (
        <Notice tone="danger" icon={<TriangleAlert />}>
          رُفضت آخر قراءة للدليل (<TimeAgo value={stats.rejected.at} />): {stats.rejected.reason}. إن كان Reloadly قد قلّص عروضه فعلاً فاقبلها.
          <div style={{ marginTop: 8 }}>
            <Button size="sm" variant="danger" loading={refreshing} onClick={() => void refresh(true)}>
              اقرأ واقبل الدليل الأصغر
            </Button>
          </div>
        </Notice>
      )}
      <Card
        title="حالة الخدمات"
        actions={
          <Button size="sm" icon={<RefreshCw />} loading={refreshing} onClick={() => void refresh(false)}>
            اقرأ الدليل الآن
          </Button>
        }
      >
        {config.isLoading ? (
          <Skeleton height={100} />
        ) : config.isError ? (
          <Empty title="الخدمات غير متاحة" />
        ) : (
          <ConfigList
            data={stats}
            hide={["rejected", "structure", "build"]}
            fields={{
              configured: { label: "مضبوط", render: yesNo },
              test_mode: { label: "الوضع", render: testOrLive },
              sandbox: { label: "بيئة Reloadly التجريبية", render: yesNo },
              supplier: { label: "المورّد" },
              loaded: { label: "الدليل محمّل", render: yesNo },
              read_at: { label: "قُرئ", render: (v) => <TimeAgo value={String(v)} /> },
              stale: { label: "قديم", render: (v) => (v ? <Badge tone="warning">نعم</Badge> : <Badge tone="success">لا</Badge>) },
              stale_after: { label: "يُعدّ قديماً بعد" },
              interval: { label: "يُقرأ كل" },
              last_error: { label: "آخر خطأ" },
              last_try: { label: "آخر محاولة", render: (v) => <TimeAgo value={String(v)} /> },
              changed_at: { label: "تغيّر", render: (v) => <TimeAgo value={String(v)} /> },
              untranslated: { label: "أسماء بلا ترجمة" },
              short_deliveries: { label: "تسليمات ناقصة" },
            }}
          />
        )}
      </Card>
    </div>
  );
}

function NamesTab() {
  const names = useQuery({
    queryKey: ["services", "names"],
    queryFn: () => api.get<{ missing: { kind: string; name: string; country?: string }[] }>("/v1/services/admin/names?missing=1").then((r) => r.missing ?? []),
    retry: false,
  });
  const kinds: Record<string, string> = { operator: "مشغّل", biller: "مفوتر", plan: "باقة" };
  const columns: Column<{ kind: string; name: string; country?: string }>[] = [
    { key: "name", header: "الاسم كما يكتبه Reloadly", mobile: "title", cell: (n) => <span dir="ltr">{n.name}</span> },
    { key: "kind", header: "النوع", mobile: "trailing", cell: (n) => <Badge tone="outline">{kinds[n.kind] ?? n.kind}</Badge> },
    { key: "country", header: "الدولة", cell: (n) => <span className="mono">{n.country || "—"}</span> },
  ];
  return (
    <Card tight title="أسماء بلا تهجئة عربية" hint="تظهر للمتاجر بالحروف اللاتينية حتى تُضاف إلى جداول الترجمة في الكود">
      <DataTable rows={names.data ?? []} columns={columns} rowKey={(n) => `${n.kind}:${n.country}:${n.name}`} loading={names.isLoading} empty={<Empty icon={<Languages />} title="كل الأسماء مترجمة" />} />
    </Card>
  );
}
