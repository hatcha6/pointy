import { useMemo, useState } from "react";
import { Unavailable } from "../../components/Unavailable";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { ArrowLeftRight, Landmark, RefreshCw, Search, Settings2, Telescope, Trophy, Truck } from "lucide-react";
import { api, qs } from "../../lib/api";
import { useSearchParam } from "../../lib/router";
import { matches } from "../../lib/search";
import { count, money } from "../../lib/format";
import { label, supplier as supplierLabels } from "../../lib/labels";
import { reasonText, type SupplierOffer, type Supply } from "../../lib/vouchers";
import { Badge, Button, Card, Empty, Money, Notice, Segmented, Skeleton, Switch, Tabs, TimeAgo } from "../../components/ui";
import { ProfitCell } from "../../components/profit";
import { DataTable, Stacked, type Column } from "../../components/DataTable";
import { PageHeader } from "../../components/PageHeader";
import { AutoView } from "../../components/AutoView";
import { ConfigList, testOrLive, yesNo } from "../../components/ConfigList";
import { useAction } from "../../components/guarded";
import { useToast } from "../../components/toast";
import { useCatalog } from "./Catalog";

type Tab = "offers" | "compare" | "balances" | "bnplus" | "config";

export function Suppliers() {
  const [tab, setTab] = useSearchParam("tab");
  const current = (tab || "offers") as Tab;
  return (
    <>
      <PageHeader title="الموردون" description="ما يبيعه الموردون للشركة، ومن يُشترى منه كل صنف، وأرصدة الشركة لديهم." />
      <Tabs<Tab>
        value={current}
        onChange={(t) => setTab(t === "offers" ? "" : t)}
        tabs={[
          { id: "offers", label: "العروض", icon: <Truck width={16} /> },
          { id: "compare", label: "المقارنة", icon: <ArrowLeftRight width={16} /> },
          { id: "balances", label: "الأرصدة", icon: <Landmark width={16} /> },
          { id: "bnplus", label: "مستكشف BN Plus", icon: <Telescope width={16} /> },
          { id: "config", label: "الإعداد", icon: <Settings2 width={16} /> },
        ]}
      />
      {current === "offers" && <OffersTab />}
      {current === "compare" && <CompareTab />}
      {current === "balances" && <BalancesTab />}
      {current === "bnplus" && <BNPlusTab />}
      {current === "config" && <ConfigTab />}
    </>
  );
}

function OffersTab() {
  const queryClient = useQueryClient();
  const toast = useToast();
  const [supplier, setSupplier] = useSearchParam("supplier");
  const [query, setQuery] = useState("");
  const [stock, setStock] = useState<"" | "in" | "out" | "moved">("");
  const [grouped, setGrouped] = useState(true);
  const offers = useQuery({
    queryKey: ["vouchers", "offers", supplier],
    queryFn: () => api.get<{ offers: SupplierOffer[] }>("/v1/vouchers/admin/offers" + qs({ supplier })).then((r) => r.offers ?? []),
    retry: false,
  });
  const sync = useAction<{ synced: Record<string, number> }>({});
  const rows = (offers.data ?? []).filter(
    (o) =>
      matches(query, o.name, o.ref, o.group) &&
      (stock === "" || (stock === "moved" ? recentlyMoved(o) : stock === "in" ? o.in_stock : !o.in_stock)),
  );
  const moved = (offers.data ?? []).filter(recentlyMoved).length;
  // Grouped by brand (the supplier's group), biggest groups first; the rows
  // of a group stay in the supplier's order.
  const groups = useMemo(() => {
    const map = new Map<string, SupplierOffer[]>();
    for (const o of rows) {
      const key = o.group || "بلا مجموعة";
      map.set(key, [...(map.get(key) ?? []), o]);
    }
    return [...map.entries()].sort((a, b) => b[1].length - a[1].length || a[0].localeCompare(b[0]));
  }, [rows]);
  const columns: Column<SupplierOffer>[] = [
    { key: "name", header: "البطاقة", mobile: "title", cell: (o) => <Stacked title={o.name} sub={`${label(supplierLabels, o.supplier)} · ${o.ref}${o.group ? " · " + o.group : ""}`} /> },
    { key: "cost", header: "بالدينار", align: "end", mobile: "trailing", cell: (o) => (o.cost_lyd ? <Money value={Number(o.cost_lyd).toFixed(3)} /> : <span className="faint">—</span>) },
    {
      key: "price",
      header: "سعر المورّد",
      align: "end",
      cell: (o) => {
        const up = o.previous_price ? Number(o.price) > Number(o.previous_price) : false;
        return (
          <span className="price-cell">
            <span className="num nowrap">
              {supplierPrice(o.price)} {o.currency}
            </span>
            {o.previous_price && recentlyMoved(o) && (
              <span className={`price-move ${up ? "up" : "down"}`} title={`كان ${supplierPrice(o.previous_price)} — تغيّر ${o.price_changed_at ? new Date(o.price_changed_at).toLocaleDateString("ar-LY-u-nu-latn") : ""}`}>
                {up ? "▲" : "▼"} كان {supplierPrice(o.previous_price)}
              </span>
            )}
          </span>
        );
      },
    },
    { key: "stock", header: "المخزون", cell: (o) => (o.in_stock ? <Badge tone="success">متوفر</Badge> : <Badge tone="danger">نافد</Badge>) },
    { key: "synced", header: "قُرئ", wideOnly: true, cell: (o) => <TimeAgo value={o.synced_at} /> },
  ];
  return (
    <Card
      tight
      actions={
        <Button
          size="sm"
          icon={<RefreshCw />}
          loading={sync.busy}
          onClick={async () => {
            const result = await sync.run("POST", "/v1/vouchers/admin/offers/sync");
            if (!result) return;
            await queryClient.invalidateQueries({ queryKey: ["vouchers"] });
            const parts = Object.entries(result.synced ?? {}).map(([k, v]) => `${label(supplierLabels, k)}: ${v}`);
            toast.success("قُرئت العروض من جديد.", parts.join(" · "));
          }}
        >
          اقرأ العروض الآن
        </Button>
      }
      title={`${count(rows.length)} عرضاً`}
    >
      <div className="toolbar stacks">
        <div className="search-input">
          <Search />
          <input className="input" placeholder="اسم البطاقة أو رقمها" value={query} onChange={(e) => setQuery(e.target.value)} />
        </div>
        <Segmented
          value={supplier}
          onChange={setSupplier}
          options={[
            { id: "", label: "كل الموردين" },
            { id: "bnplus", label: "BN Plus" },
            { id: "reloadly", label: "Reloadly" },
          ]}
        />
        <Segmented
          value={stock}
          onChange={setStock}
          options={[
            { id: "", label: "الكل" },
            { id: "in", label: "متوفر" },
            { id: "out", label: "نافد" },
            { id: "moved", label: moved ? `تغيّر سعرها (${moved})` : "تغيّر سعرها" },
          ]}
        />
        <label className="row muted" style={{ fontSize: 13 }}>
          <Switch on={grouped} onChange={setGrouped} label="حسب العلامة" />
          حسب العلامة
        </label>
      </div>
      {offers.isError ? (
        <Unavailable feature="offers" error={offers.error} onRetry={() => void offers.refetch()} />
      ) : (
        grouped && !offers.isLoading && rows.length > 0 ? (
          <div className="offer-groups">
            {groups.map(([name, list]) => (
              <details key={name} className="offer-group" open={groups.length <= 6 || !!query || stock === "moved"}>
                <summary>
                  <strong>{name}</strong>
                  <span className="faint">{list.length} عرضاً</span>
                  {list.some(recentlyMoved) && <Badge tone="warning">تغيّر سعر</Badge>}
                  {list.some((o) => !o.in_stock) && <Badge tone="danger">{list.filter((o) => !o.in_stock).length} نافد</Badge>}
                </summary>
                <DataTable rows={list} columns={columns} rowKey={(o) => `${o.supplier}:${o.ref}`} />
              </details>
            ))}
          </div>
        ) : (
          <DataTable rows={rows} columns={columns} rowKey={(o) => `${o.supplier}:${o.ref}`} loading={offers.isLoading} empty={<Empty icon={<Truck />} title="لا عروض" />} />
        )
      )}
    </Card>
  );
}

type Compared = {
  supply: Supply;
  /** Who it is bought from now (the first candidate). */
  winner?: string;
  winnerCost?: number;
  /** Who prices it lowest, in stock or not; "" when the prices are equal. */
  cheapest?: string;
  /** The dearer price less the cheaper one, and that as a share of the cheaper. */
  gap?: number;
  gapPct?: number;
  unitPrice?: number;
  margin?: number;
};

type CompareFilter = "" | "tie" | "dearer" | `cheaper:${string}`;
type CompareSort = "" | "gap" | "gap-pct";

/** Two prices this close are the same price. */
const TIE = 0.005;

function compare(s: Supply, unitPrice: number | undefined): Compared {
  const ranked = [...(s.suppliers ?? [])].filter((o) => o.candidate && o.cost_lyd).sort((a, b) => a.rank - b.rank);
  const winner = ranked[0];
  const winnerCost = winner?.cost_lyd ? Number(winner.cost_lyd) : undefined;
  const priced = (s.suppliers ?? []).filter((o) => o.cost_lyd).sort((a, b) => Number(a.cost_lyd) - Number(b.cost_lyd));
  let cheapest: string | undefined;
  let gap: number | undefined;
  let gapPct: number | undefined;
  if (priced.length >= 2) {
    const low = Number(priced[0].cost_lyd);
    gap = Number(priced[1].cost_lyd) - low;
    gapPct = low > 0 ? (gap / low) * 100 : undefined;
    cheapest = gap < TIE ? "" : priced[0].supplier;
  }
  return {
    supply: s,
    winner: winner?.supplier,
    winnerCost,
    cheapest,
    gap,
    gapPct,
    unitPrice,
    margin: winnerCost !== undefined && unitPrice !== undefined ? unitPrice - winnerCost : undefined,
  };
}

function CompareTab() {
  const catalog = useCatalog();
  const [query, setQuery] = useState("");
  const [filter, setFilter] = useSearchParam("cheaper");
  const [sort, setSort] = useState<CompareSort>("gap");
  const rows = useMemo<Compared[]>(() => {
    const prices = new Map<string, string>();
    for (const b of catalog.data?.view?.brands ?? []) for (const i of b.items) prices.set(i.key, i.unit_price);
    return (catalog.data?.supply ?? [])
      .filter((s) => (s.suppliers?.length ?? 0) >= 2)
      .map((s) => compare(s, prices.has(s.item) ? Number(prices.get(s.item)) : undefined));
  }, [catalog.data]);
  const suppliers = useMemo(() => [...new Set(rows.flatMap((r) => (r.supply.suppliers ?? []).map((o) => o.supplier)))].sort(), [rows]);
  // Who prices lowest, how many items, and how much cheaper in all.
  const board = suppliers.map((key) => {
    const won = rows.filter((r) => r.cheapest === key);
    return { key, items: won.length, saving: won.reduce((sum, r) => sum + (r.gap ?? 0), 0), bought: rows.filter((r) => r.winner === key).length };
  });
  const leader = [...board].sort((a, b) => b.items - a.items)[0];
  const ties = rows.filter((r) => r.cheapest === "").length;
  const dearer = rows.filter(boughtDearer).length;
  const belowCost = rows.filter((r) => r.margin !== undefined && r.margin < 0).length;
  const wanted = (filter || "") as CompareFilter;
  const shown = useMemo(() => {
    const filtered = rows.filter(
      (r) =>
        matches(query, r.supply.name, r.supply.item) &&
        (wanted === "" ||
          (wanted === "tie" && r.cheapest === "") ||
          (wanted === "dearer" && boughtDearer(r)) ||
          (wanted.startsWith("cheaper:") && r.cheapest === wanted.slice("cheaper:".length))),
    );
    if (sort === "gap") return [...filtered].sort((a, b) => (b.gap ?? -1) - (a.gap ?? -1));
    if (sort === "gap-pct") return [...filtered].sort((a, b) => (b.gapPct ?? -1) - (a.gapPct ?? -1));
    return filtered;
  }, [rows, query, wanted, sort]);
  const columns: Column<Compared>[] = [
    { key: "item", header: "الصنف", mobile: "title", cell: (r) => <Stacked title={r.supply.name} sub={r.supply.item} mono /> },
    {
      key: "cheapest",
      header: "الأرخص",
      mobile: "trailing",
      cell: (r) =>
        r.cheapest === undefined ? (
          <span className="faint">—</span>
        ) : r.cheapest === "" ? (
          <Badge tone="neutral">متساويان</Badge>
        ) : (
          <Badge tone="success">{label(supplierLabels, r.cheapest)}</Badge>
        ),
    },
    {
      key: "costs",
      header: "التكلفة لدى كل مورّد",
      mobile: "subtitle",
      cell: (r) => (
        <div className="pill-list">
          {(r.supply.suppliers ?? []).map((o) => (
            <Badge key={o.supplier} tone={o.supplier === r.cheapest ? "success" : o.candidate ? "outline" : "neutral"}>
              {label(supplierLabels, o.supplier)}: {o.cost_lyd ? money(Number(o.cost_lyd).toFixed(3)) : reasonText(o.reason) || "—"}
              {o.cost_lyd && !o.candidate ? " · لا يُشترى منه الآن" : ""}
            </Badge>
          ))}
        </div>
      ),
    },
    {
      key: "gap",
      header: "الفرق",
      align: "end",
      cell: (r) =>
        r.gap !== undefined ? (
          <span className="price-cell">
            <Money value={r.gap.toFixed(3)} />
            {r.gapPct !== undefined && <span className="faint num" style={{ fontSize: 12 }}>{r.gapPct.toFixed(1)}%</span>}
          </span>
        ) : (
          <span className="faint">—</span>
        ),
    },
    {
      key: "winner",
      header: "يُشترى من",
      cell: (r) =>
        r.winner ? (
          <Badge tone={boughtDearer(r) ? "warning" : "outline"}>
            {label(supplierLabels, r.winner)}
            {boughtDearer(r) ? " · ليس الأرخص" : ""}
          </Badge>
        ) : (
          <Badge tone="danger">لا أحد</Badge>
        ),
    },
    {
      key: "margin",
      header: "ربحنا",
      align: "end",
      wideOnly: true,
      cell: (r) => <ProfitCell value={r.margin} of={r.winnerCost} />,
    },
  ];
  return (
    <div className="stack">
      {leader && leader.items > 0 && (
        <Notice tone="money" icon={<Trophy />}>
          {board.filter((b) => b.items === leader.items).length > 1 ? (
            <>الموردون متعادلون: </>
          ) : (
            <>
              الأرخص في الغالب: <strong>{label(supplierLabels, leader.key)}</strong> —{" "}
            </>
          )}
          {board.map((b) => `${label(supplierLabels, b.key)} أرخص في ${count(b.items)}`).join(" · ")} من {count(rows.length)} صنفاً
          {ties ? ` · متساويان في ${count(ties)}` : ""}.
        </Notice>
      )}
      <div className="grid kpis">
        {board.map((b) => (
          <button
            type="button"
            key={b.key}
            className={`card kpi clickable ${wanted === `cheaper:${b.key}` ? "selected" : ""}`}
            onClick={() => setFilter(wanted === `cheaper:${b.key}` ? "" : `cheaper:${b.key}`)}
          >
            <div className="kpi-label">أرخص لدى {label(supplierLabels, b.key)}</div>
            <div className="kpi-value">{count(b.items)}</div>
            <div className="kpi-foot">
              أرخص بـ {money(b.saving.toFixed(2))} في مجموعها · يُشترى منه {count(b.bought)}
            </div>
          </button>
        ))}
        <button
          type="button"
          className={`card kpi clickable ${dearer ? "attention" : ""} ${wanted === "dearer" ? "selected" : ""}`}
          onClick={() => setFilter(wanted === "dearer" ? "" : "dearer")}
        >
          <div className="kpi-label">يُشترى من غير الأرخص</div>
          <div className="kpi-value">{count(dearer)}</div>
          <div className="kpi-foot">{dearer ? "الأرخص نافد أو رصيدنا لديه لا يكفي" : "لا شيء"}</div>
        </button>
        <div className={`card kpi ${belowCost ? "attention" : ""}`}>
          <div className="kpi-label">يُباع بأقل من التكلفة</div>
          <div className="kpi-value">{count(belowCost)}</div>
          <div className="kpi-foot">{belowCost ? "راجع أسعارها في الكتالوج" : "لا شيء"}</div>
        </div>
      </div>
      <Card tight title={`${count(shown.length)} من ${count(rows.length)} صنفاً لها أكثر من مورّد`}>
        <div className="toolbar stacks">
          <div className="search-input">
            <Search />
            <input className="input" placeholder="صنف" value={query} onChange={(e) => setQuery(e.target.value)} />
          </div>
          <Segmented<CompareFilter>
            value={wanted}
            onChange={setFilter}
            options={[
              { id: "", label: "الكل" },
              ...suppliers.map((key) => ({ id: `cheaper:${key}` as CompareFilter, label: `أرخص لدى ${label(supplierLabels, key)}` })),
              { id: "tie", label: "متساوية" },
              { id: "dearer", label: "ليس من الأرخص" },
            ]}
          />
          <Segmented<CompareSort>
            value={sort}
            onChange={setSort}
            options={[
              { id: "gap", label: "الفرق الأكبر" },
              { id: "gap-pct", label: "النسبة الأكبر" },
              { id: "", label: "ترتيب الكتالوج" },
            ]}
          />
        </div>
        <DataTable rows={shown} columns={columns} rowKey={(r) => r.supply.item} loading={catalog.isLoading} empty={<Empty icon={<ArrowLeftRight />} title={rows.length ? "لا أصناف بهذه الشروط" : "لا صنف له أكثر من مورّد"} />} />
      </Card>
    </div>
  );
}

/** Bought from a supplier that is not the cheapest: the cheaper one is out of stock, short of our money, or refused. */
function boughtDearer(r: Compared): boolean {
  return !!r.winner && !!r.cheapest && r.winner !== r.cheapest;
}

function BalancesTab() {
  const reloadly = useQuery({ queryKey: ["vouchers", "reloadly"], queryFn: () => api.get<{ reloadly: Record<string, unknown>; sandbox: boolean }>("/v1/vouchers/admin/reloadly/balance"), retry: false });
  const services = useQuery({ queryKey: ["services", "balance"], queryFn: () => api.get<{ balances: Record<string, unknown>[] }>("/v1/services/admin/balance"), retry: false });
  const bnplus = useQuery({ queryKey: ["vouchers", "bnplus", "wallets"], queryFn: () => api.get<{ bnplus: unknown }>("/v1/vouchers/admin/bnplus/wallets"), retry: false });
  const block = (q: { isLoading: boolean; isError: boolean; error: unknown }, body: () => JSX.Element) =>
    q.isLoading ? <Skeleton height={60} /> : q.isError ? <Empty title="غير متاح" >{String((q.error as Error)?.message ?? "")}</Empty> : body();
  return (
    <div className="grid two">
      <Card title="BN Plus" hint="محافظ الشركة">
        {block(bnplus, () => <AutoView data={bnplus.data?.bnplus} />)}
      </Card>
      <Card title="Reloadly — بطاقات الهدايا" actions={reloadly.data?.sandbox ? <Badge tone="warning">تجريبي</Badge> : undefined}>
        {block(reloadly, () => <ConfigList data={reloadly.data?.reloadly} fields={{ balance: { label: "الرصيد" }, currency: { label: "العملة" } }} />)}
      </Card>
      <Card title="Reloadly — الشحن والفواتير">
        {block(services, () => (
          <DataTable
            rows={services.data?.balances ?? []}
            columns={[
              { key: "product", header: "المنتج", mobile: "title", cell: (b) => String(b.product ?? "") },
              { key: "balance", header: "الرصيد", align: "end", mobile: "trailing", cell: (b) => <span className="num">{String(b.balance ?? "—")} {String(b.currency ?? "")}</span> },
              { key: "frozen", header: "محجوز", align: "end", cell: (b) => <span className="num">{String(b.frozen ?? "—")}</span> },
              { key: "error", header: "خطأ", mobile: "subtitle", cell: (b) => (b.error ? <span className="faint">{String(b.error)}</span> : null) },
            ]}
            rowKey={(b) => String(b.product)}
          />
        ))}
      </Card>
    </div>
  );
}

type BNPlusWhat = "wallets" | "groups" | "companies" | "cards" | "orders" | "order";

function BNPlusTab() {
  const [what, setWhat] = useState<BNPlusWhat>("groups");
  const [param, setParam] = useState("");
  const [groupType, setGroupType] = useState("");
  const [asked, setAsked] = useState<{ what: BNPlusWhat; params: Record<string, string> } | null>(null);
  const needs: Partial<Record<BNPlusWhat, { key: string; label: string }>> = {
    companies: { key: "group_id", label: "رقم المجموعة" },
    cards: { key: "branch_id", label: "رقم الفرع" },
    order: { key: "order_id", label: "رقم الطلب" },
  };
  const need = needs[what];
  const result = useQuery({
    queryKey: ["vouchers", "bnplus", asked],
    enabled: !!asked,
    queryFn: () => api.get<{ bnplus: unknown }>(`/v1/vouchers/admin/bnplus/${asked!.what}` + qs(asked!.params)).then((r) => r.bnplus),
    retry: false,
  });
  return (
    <Card tight title="قراءة مباشرة من BN Plus بحساب الشركة" hint="قراءة فقط">
      <div className="toolbar stacks">
        <Segmented<BNPlusWhat>
          value={what}
          onChange={(v) => {
            setWhat(v);
            setParam("");
          }}
          options={[
            { id: "groups", label: "المجموعات" },
            { id: "companies", label: "الشركات" },
            { id: "cards", label: "البطاقات" },
            { id: "wallets", label: "المحافظ" },
            { id: "orders", label: "الطلبات" },
            { id: "order", label: "طلب" },
          ]}
        />
        <div className="filters">
          {what === "groups" && (
            <Segmented
              value={groupType}
              onChange={setGroupType}
              options={[
                { id: "", label: "الكل" },
                { id: "local", label: "محلية" },
                { id: "international", label: "دولية" },
              ]}
            />
          )}
          {need && <input className="input num" inputMode="numeric" placeholder={need.label} value={param} onChange={(e) => setParam(e.target.value.replace(/\D/g, ""))} />}
          <Button
            variant="primary"
            size="sm"
            icon={<Telescope />}
            disabled={!!need && !param}
            loading={result.isFetching}
            onClick={() => setAsked({ what, params: need ? { [need.key]: param } : what === "groups" && groupType ? { type: groupType } : {} })}
          >
            اقرأ
          </Button>
        </div>
      </div>
      <div className="card-body tight">
        {!asked ? (
          <Empty icon={<Telescope />} title="اختر ما تريد قراءته" />
        ) : result.isLoading ? (
          <div className="card-body">
            <Skeleton height={120} />
          </div>
        ) : result.isError ? (
          <Empty title="لم يُجب BN Plus">{String((result.error as Error)?.message ?? "")}</Empty>
        ) : (
          <AutoView data={result.data} />
        )}
      </div>
    </Card>
  );
}

function ConfigTab() {
  const config = useQuery({ queryKey: ["vouchers", "config"], queryFn: () => api.get<Record<string, unknown>>("/v1/vouchers/admin/config"), retry: false });
  return (
    <Card title="إعداد متجر البطاقات" hint="لا تظهر هنا بيانات دخول الموردين">
      {config.isLoading ? (
        <Skeleton height={100} />
      ) : (
        <ConfigList
          data={config.data}
          fields={{
            configured: { label: "مضبوط", render: yesNo },
            test_mode: { label: "الوضع", render: testOrLive },
            sandbox: { label: "بيئة تجريبية", render: yesNo },
            suppliers: { label: "الموردون" },
            bnplus: { label: "BN Plus", render: yesNo },
            reloadly: { label: "Reloadly", render: yesNo },
            reloadly_sandbox: { label: "Reloadly تجريبي", render: yesNo },
            sync_interval: { label: "قراءة العروض كل" },
            offers_max_age: { label: "أقصى عمر للعرض" },
            rate_limit: { label: "حد الشراء لكل متجر" },
            request_timeout: { label: "مهلة الطلب" },
            currency: { label: "العملة" },
            max_quantity: { label: "أكبر كمية" },
          }}
        />
      )}
    </Card>
  );
}

/** A supplier's price as it reads on an invoice: no float noise, at most four places. */
function supplierPrice(raw: string | number): string {
  const n = Number(raw);
  if (!Number.isFinite(n)) return String(raw);
  return new Intl.NumberFormat("en-US", { maximumFractionDigits: 4, minimumFractionDigits: 2 }).format(n);
}

/** A price that moved in the last week is worth a look. */
function recentlyMoved(o: SupplierOffer): boolean {
  return (
    !!o.previous_price &&
    Number(o.previous_price) !== Number(o.price) &&
    !!o.price_changed_at &&
    Date.now() - new Date(o.price_changed_at).getTime() < 7 * 86_400_000
  );
}
