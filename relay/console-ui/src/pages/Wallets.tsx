import { useMemo } from "react";
import { useQuery } from "@tanstack/react-query";
import { Search, Wallet2 } from "lucide-react";
import { api } from "../lib/api";
import { useInstallations, useWallets } from "../lib/queries";
import { useRouter, useSearchParam } from "../lib/router";
import { matches } from "../lib/search";
import { money } from "../lib/format";
import { account as accountLabels } from "../lib/labels";
import { Card, Empty, Money, Segmented, Skeleton } from "../components/ui";
import { DataTable, Stacked, type Column } from "../components/DataTable";
import { PageHeader } from "../components/PageHeader";
import { ConfigList, testOrLive, yesNo } from "../components/ConfigList";
import { BankAccountsCard } from "../components/BankAccountsCard";

type Row = { id: string; name: string; main: number; sms: number; vouchers: number };
type Sort = "main" | "sms" | "vouchers" | "name";

export function Wallets() {
  const { navigate } = useRouter();
  const wallets = useWallets();
  const installations = useInstallations();
  const [query, setQuery] = useSearchParam("q");
  const [sort, setSort] = useSearchParam("sort");
  const order = (sort || "main") as Sort;
  const config = useQuery({ queryKey: ["wallet", "config"], queryFn: () => api.get<Record<string, unknown>>("/v1/wallet/admin/config"), retry: false });

  const { rows, totals } = useMemo(() => {
    const byShop = new Map<string, Row>();
    const names = new Map((installations.data ?? []).map((i) => [i.id, i.shop_name]));
    for (const w of wallets.data?.wallets ?? []) {
      const row = byShop.get(w.installation_id) ?? { id: w.installation_id, name: w.shop_name || names.get(w.installation_id) || "", main: 0, sms: 0, vouchers: 0 };
      if (w.account === "main" || w.account === "sms" || w.account === "vouchers") row[w.account] = Number(w.balance) || 0;
      byShop.set(w.installation_id, row);
    }
    const list = [...byShop.values()];
    const totals = list.reduce((t, r) => ({ main: t.main + r.main, sms: t.sms + r.sms, vouchers: t.vouchers + r.vouchers }), { main: 0, sms: 0, vouchers: 0 });
    return { rows: list, totals };
  }, [wallets.data, installations.data]);

  const shown = rows
    .filter((r) => matches(query, r.name, r.id))
    .sort((a, b) => (order === "name" ? a.name.localeCompare(b.name, "ar") : b[order] - a[order]));

  const columns: Column<Row>[] = [
    { key: "shop", header: "المتجر", mobile: "title", cell: (r) => <Stacked title={r.name || "متجر بلا اسم"} sub={r.id} mono /> },
    { key: "main", header: accountLabels.main, align: "end", mobile: "trailing", cell: (r) => <Money value={r.main} /> },
    { key: "sms", header: accountLabels.sms, align: "end", cell: (r) => <Money value={r.sms} /> },
    { key: "vouchers", header: accountLabels.vouchers, align: "end", cell: (r) => <Money value={r.vouchers} /> },
  ];

  return (
    <>
      <PageHeader title="المحافظ" description="أرصدة كل متجر في حساباته الثلاثة. هذا مال المتاجر الذي تحمله الشركة." />
      <div className="grid kpis" style={{ marginBottom: 16 }}>
        {(["main", "sms", "vouchers"] as const).map((k) => (
          <div key={k} className="card kpi money">
            <div className="kpi-label">{accountLabels[k]}</div>
            <div className="kpi-value">{wallets.isLoading ? <Skeleton height={28} width={110} /> : <Money value={totals[k]} />}</div>
          </div>
        ))}
        <div className="card kpi">
          <div className="kpi-label">المجموع المحمول</div>
          <div className="kpi-value">{money(totals.main + totals.sms + totals.vouchers)}</div>
          <div className="kpi-foot">{rows.length} متجراً لديه رصيد</div>
        </div>
      </div>
      <div className="stack">
        <Card tight>
          <div className="toolbar stacks">
            <div className="search-input">
              <Search />
              <input className="input" placeholder="اسم المتجر أو رقمه" value={query} onChange={(e) => setQuery(e.target.value)} />
            </div>
            <Segmented<Sort>
              value={order}
              onChange={(v) => setSort(v === "main" ? "" : v)}
              options={[
                { id: "main", label: "الأكبر محفظة" },
                { id: "sms", label: "الأكبر رسائل" },
                { id: "vouchers", label: "الأكبر بطاقات" },
                { id: "name", label: "بالاسم" },
              ]}
            />
          </div>
          <DataTable
            rows={shown}
            columns={columns}
            rowKey={(r) => r.id}
            loading={wallets.isLoading}
            onRowClick={(r) => navigate(`/shops/${encodeURIComponent(r.id)}?tab=wallet`)}
            empty={<Empty icon={<Wallet2 />} title="لا محافظ بعد" />}
          />
        </Card>
        <BankAccountsCard />
        <Card title="بوابة الدفع (دفع)" hint="لا يظهر هنا أي مفتاح">
          {config.isLoading ? (
            <Skeleton height={80} />
          ) : config.isError ? (
            <Empty title="الإعداد غير متاح" />
          ) : (
            <ConfigList
              data={config.data}
              hide={["plans"]}
              fields={{
                test_mode: { label: "الوضع", render: testOrLive },
                key_environment: { label: "بيئة المفتاح" },
                api_key_set: { label: "المفتاح مضبوط", render: yesNo },
                dafa_base_url: { label: "عنوان دفع" },
                public_url: { label: "العنوان العام للخادم" },
                webhook_base: { label: "عنوان الإشعارات" },
                min: { label: "أقل شحنة", render: (v) => money(String(v)) },
                max: { label: "أكبر شحنة", render: (v) => money(String(v)) },
                quick_amounts: { label: "مبالغ سريعة" },
                methods: { label: "طرق الدفع" },
                sms_price: { label: "سعر جزء الرسالة", render: (v) => money(String(v)) },
                rate_limit: { label: "حد الطلبات" },
                request_timeout: { label: "مهلة الطلب" },
                store_supports_wallets: { label: "المخزن يدعم المحافظ", render: yesNo },
              }}
            />
          )}
        </Card>
      </div>
    </>
  );
}
