import { useMemo, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { BarChart3, ListOrdered, MessageSquare, Settings2 } from "lucide-react";
import { api, qs } from "../lib/api";
import { useInstallations } from "../lib/queries";
import { useRouter, useSearchParam } from "../lib/router";
import { count, money } from "../lib/format";
import { Badge, Card, Empty, Money, Segmented, Skeleton, Tabs, TimeAgo } from "../components/ui";
import { DataTable, Stacked, type Column } from "../components/DataTable";
import { PageHeader } from "../components/PageHeader";
import { ConfigList, testOrLive, yesNo } from "../components/ConfigList";

type UsageRow = {
  installation_id: string;
  shop_name: string;
  messages: number;
  sent: number;
  failed: number;
  delivered: number;
  undelivered: number;
  test: number;
  parts: number;
  cost: string;
  charged: string;
  last_sent_at: string | null;
};
type Usage = {
  from: string;
  to: string;
  installations: UsageRow[];
  totals: { installations: number; messages: number; sent: number; failed: number; delivered: number; test: number; parts: number; cost: string; charged: string };
};
type LogRow = {
  id: string;
  installation_id: string;
  shop_name: string;
  kind: string;
  recipient: string;
  status: string;
  test_mode: boolean;
  parts: number;
  cost: string;
  price: string;
  error_code: string;
  created_at: string | null;
  held_since: string | null;
};
type SmsConfig = {
  configured: boolean;
  test_mode: boolean;
  price: string;
  catalog: { kind: string; title?: string; consent_class: string; variables: number; configured: boolean; text_known: boolean }[];
  [key: string]: unknown;
};

const smsStatus: Record<string, { label: string; tone: "success" | "warning" | "danger" | "neutral" | "info" }> = {
  pending: { label: "قيد الإرسال", tone: "warning" },
  sent: { label: "أُرسلت", tone: "info" },
  delivered: { label: "وصلت", tone: "success" },
  undelivered: { label: "لم تصل", tone: "danger" },
  failed: { label: "فشلت", tone: "danger" },
};

type Tab = "usage" | "log" | "config";

export function Sms() {
  const [tab, setTab] = useSearchParam("tab");
  const current = (tab || "usage") as Tab;
  return (
    <>
      <PageHeader title="الرسائل النصية" description="تُرسل عبر حساب الشركة لدى رسالة، وتدفع كل متجر ثمن كل جزء من رصيد رسائله." />
      <Tabs<Tab>
        value={current}
        onChange={(t) => setTab(t === "usage" ? "" : t)}
        tabs={[
          { id: "usage", label: "الاستهلاك", icon: <BarChart3 width={16} /> },
          { id: "log", label: "السجل", icon: <ListOrdered width={16} /> },
          { id: "config", label: "الإعداد", icon: <Settings2 width={16} /> },
        ]}
      />
      {current === "usage" && <UsageTab />}
      {current === "log" && <LogTab />}
      {current === "config" && <ConfigTab />}
    </>
  );
}

function monthBounds(offset: number): { from: string; until: string; label: string } {
  const now = new Date();
  const start = new Date(now.getFullYear(), now.getMonth() + offset, 1);
  const next = new Date(now.getFullYear(), now.getMonth() + offset + 1, 1);
  const day = (d: Date) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-01`;
  return { from: day(start), until: day(next), label: start.toLocaleDateString("ar-LY-u-nu-latn", { month: "long", year: "numeric" }) };
}

function UsageTab() {
  const { navigate } = useRouter();
  const [offset, setOffset] = useState(0);
  const period = monthBounds(offset);
  // Days are Libyan calendar days; "to" is exclusive: the next month's first day.
  const usage = useQuery({
    queryKey: ["sms", "usage", period.from],
    queryFn: () => api.get<Usage>("/v1/sms/usage" + qs({ from: period.from, to: period.until })),
  });
  const t = usage.data?.totals;
  const margin = t ? Number(t.charged) - Number(t.cost) : 0;
  const columns: Column<UsageRow>[] = [
    { key: "shop", header: "المتجر", mobile: "title", cell: (r) => <Stacked title={r.shop_name || r.installation_id} sub={r.last_sent_at ? <>آخر إرسال <TimeAgo value={r.last_sent_at} /></> : undefined} /> },
    { key: "charged", header: "دفع المتجر", align: "end", mobile: "trailing", cell: (r) => <Money value={r.charged} /> },
    { key: "messages", header: "الرسائل", align: "end", cell: (r) => count(r.messages) },
    { key: "parts", header: "الأجزاء", align: "end", cell: (r) => count(r.parts) },
    { key: "delivered", header: "وصلت", align: "end", cell: (r) => count(r.delivered) },
    { key: "failed", header: "فشلت", align: "end", cell: (r) => (r.failed ? <span className="negative">{count(r.failed)}</span> : "0") },
    { key: "cost", header: "كلّفت الشركة", align: "end", wideOnly: true, mobile: "meta", cell: (r) => <Money value={r.cost} /> },
  ];
  return (
    <div className="stack">
      <div className="row" style={{ justifyContent: "space-between" }}>
        <Segmented
          value={String(offset)}
          onChange={(v) => setOffset(Number(v))}
          options={[-2, -1, 0].map((o) => ({ id: String(o), label: monthBounds(o).label }))}
        />
      </div>
      <div className="grid kpis">
        <div className="card kpi">
          <div className="kpi-label">الرسائل</div>
          <div className="kpi-value">{t ? count(t.messages) : <Skeleton height={28} width={60} />}</div>
          <div className="kpi-foot">{t ? `${count(t.parts)} جزءاً · ${count(t.installations)} متجراً` : ""}</div>
        </div>
        <div className="card kpi money">
          <div className="kpi-label">دفعت المتاجر</div>
          <div className="kpi-value">{t ? <Money value={t.charged} /> : <Skeleton height={28} width={90} />}</div>
        </div>
        <div className="card kpi">
          <div className="kpi-label">كلّفت الشركة</div>
          <div className="kpi-value">{t ? money(t.cost) : <Skeleton height={28} width={90} />}</div>
        </div>
        <div className={`card kpi ${margin < 0 ? "attention" : ""}`}>
          <div className="kpi-label">الهامش</div>
          <div className={`kpi-value ${margin < 0 ? "negative" : "positive"}`}>{t ? money(margin) : <Skeleton height={28} width={90} />}</div>
          {margin < 0 && <div className="kpi-foot">الرسائل تكلّف أكثر مما تدفعه المتاجر: ارفع سعر الجزء.</div>}
        </div>
      </div>
      <Card tight title="حسب المتجر" hint="الأكثر إرسالاً أولاً">
        <DataTable
          rows={usage.data?.installations ?? []}
          columns={columns}
          rowKey={(r) => r.installation_id}
          loading={usage.isLoading}
          onRowClick={(r) => navigate(`/shops/${encodeURIComponent(r.installation_id)}?tab=wallet`)}
          empty={<Empty icon={<MessageSquare />} title="لا رسائل في هذا الشهر" />}
        />
      </Card>
    </div>
  );
}

function LogTab() {
  const installations = useInstallations();
  const [status, setStatus] = useSearchParam("status");
  const [shop, setShop] = useSearchParam("shop");
  const config = useQuery({ queryKey: ["sms", "config"], queryFn: () => api.get<SmsConfig>("/v1/sms/config"), retry: false });
  const titles = useMemo(() => new Map((config.data?.catalog ?? []).map((k) => [k.kind, k.title || k.kind])), [config.data]);
  const log = useQuery({
    queryKey: ["sms", "log", status, shop],
    queryFn: () => api.get<{ messages: LogRow[] }>("/v1/sms/messages" + qs({ status, installation_id: shop, limit: 200 })).then((r) => r.messages ?? []),
    refetchInterval: 30_000,
  });
  const columns: Column<LogRow>[] = [
    {
      key: "what",
      header: "الرسالة",
      mobile: "title",
      cell: (r) => <Stacked title={titles.get(r.kind) ?? r.kind} sub={<span className="mono">{r.recipient}</span>} />,
    },
    {
      key: "status",
      header: "الحالة",
      mobile: "trailing",
      cell: (r) => {
        const s = r.held_since ? { label: "قيد التحقق", tone: "warning" as const } : smsStatus[r.status] ?? { label: r.status, tone: "neutral" as const };
        return (
          <div className="row" style={{ gap: 4 }}>
            <Badge tone={s.tone} dot>
              {s.label}
            </Badge>
            {r.test_mode && <Badge tone="warning">تجريبي</Badge>}
          </div>
        );
      },
    },
    { key: "shop", header: "المتجر", cell: (r) => r.shop_name || r.installation_id.slice(0, 8) },
    { key: "when", header: "الوقت", cell: (r) => <TimeAgo value={r.created_at} /> },
    { key: "parts", header: "الأجزاء", align: "end", cell: (r) => count(r.parts) },
    { key: "price", header: "دفع المتجر", align: "end", cell: (r) => <Money value={r.price || "0"} /> },
    { key: "error", header: "الخطأ", wideOnly: true, mobile: "subtitle", cell: (r) => (r.error_code ? <span className="faint mono">{r.error_code}</span> : null) },
  ];
  return (
    <Card tight>
      <div className="toolbar stacks">
        <Segmented
          value={status}
          onChange={setStatus}
          options={[{ id: "", label: "الكل" }, ...Object.entries(smsStatus).map(([id, s]) => ({ id, label: s.label }))]}
        />
        <select className="select" style={{ height: 36, maxWidth: 260 }} value={shop} onChange={(e) => setShop(e.target.value)} aria-label="المتجر">
          <option value="">كل المتاجر</option>
          {(installations.data ?? []).map((i) => (
            <option key={i.id} value={i.id}>
              {i.shop_name || i.id}
            </option>
          ))}
        </select>
      </div>
      <DataTable rows={log.data ?? []} columns={columns} rowKey={(r) => r.id} loading={log.isLoading} empty={<Empty icon={<MessageSquare />} title="لا رسائل بهذه الشروط" />} />
    </Card>
  );
}

function ConfigTab() {
  const config = useQuery({ queryKey: ["sms", "config"], queryFn: () => api.get<SmsConfig>("/v1/sms/config"), retry: false });
  const missing = (config.data?.catalog ?? []).filter((k) => !k.configured);
  const columns: Column<SmsConfig["catalog"][number]>[] = [
    { key: "kind", header: "النوع", mobile: "title", cell: (k) => <Stacked title={k.title || k.kind} sub={k.kind} mono /> },
    { key: "state", header: "القالب", mobile: "trailing", cell: (k) => (k.configured ? <Badge tone="success">معتمد</Badge> : <Badge tone="danger">ناقص</Badge>) },
    { key: "class", header: "الصنف", cell: (k) => (k.consent_class === "transactional" ? "معاملة" : k.consent_class === "marketing" ? "تسويق" : k.consent_class) },
    { key: "vars", header: "المتغيرات", align: "end", cell: (k) => count(k.variables) },
    { key: "text", header: "النص معروف", cell: (k) => (k.text_known ? "نعم" : <span className="faint">بعد أول إرسال</span>) },
  ];
  return (
    <div className="stack">
      <Card title="الإعداد" hint="لا يظهر هنا رمز رسالة">
        {config.isLoading ? (
          <Skeleton height={80} />
        ) : (
          <ConfigList
            data={config.data}
            hide={["catalog", "templates"]}
            fields={{
              configured: { label: "مضبوط", render: yesNo },
              test_mode: { label: "الوضع", render: testOrLive },
              price: { label: "سعر الجزء للمتجر", render: (v) => money(String(v)) },
              base_url: { label: "عنوان رسالة" },
              rate_limit: { label: "حد الدفعة لكل متجر" },
              request_timeout: { label: "مهلة الطلب" },
              max_variable_runes: { label: "أطول متغير" },
              delivery_sync_interval: { label: "مزامنة التسليم كل" },
            }}
          />
        )}
      </Card>
      <Card tight title="القوالب" hint={missing.length ? `${missing.length} بلا قالب معتمد` : "كلها معتمدة"}>
        <DataTable rows={config.data?.catalog ?? []} columns={columns} rowKey={(k) => k.kind} loading={config.isLoading} />
      </Card>
    </div>
  );
}
