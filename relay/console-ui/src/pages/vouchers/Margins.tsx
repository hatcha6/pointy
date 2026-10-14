import { useMemo, useState } from "react";
import { Coins, Search, TriangleAlert } from "lucide-react";
import { useSearchParam } from "../../lib/router";
import { matches } from "../../lib/search";
import { count, money } from "../../lib/format";
import { label, supplier as supplierLabels } from "../../lib/labels";
import { splitOf, type Split } from "../../lib/vouchers";
import { Badge, Button, Card, Empty, Money, Notice, Segmented } from "../../components/ui";
import { DataTable, Stacked, type Column } from "../../components/DataTable";
import { PageHeader } from "../../components/PageHeader";
import { ProfitCell } from "../../components/profit";
import { Unavailable } from "../../components/Unavailable";
import { useCatalog, winnerCost } from "./Catalog";
import { useDirectory } from "./Services";

// Every thing a shop can sell — cards, airtime, bills — on one line each: what
// it costs us, what we keep, what the shop pays and keeps, what its customer
// pays. Read from the catalog and the services directory the relay already
// serves; nothing here is worked out twice.

type Kind = "card" | "airtime" | "bill";
type Sort = "" | "ours-desc" | "ours-asc" | "ours-pct" | "shop-pct";

type Line = Split & {
  key: string;
  kind: Kind;
  name: string;
  sub: string;
  /** Who it is bought from (cards only). */
  supplier?: string;
  available: boolean;
  search: string[];
};

const PAGE = 150;

export function Margins() {
  const catalog = useCatalog();
  const directory = useDirectory();
  const [kind, setKind] = useSearchParam("kind");
  const current = (kind || "card") as Kind;
  const [query, setQuery] = useSearchParam("q");
  const [sort, setSort] = useState<Sort>("");
  const [onlyLoss, setOnlyLoss] = useState(false);
  const [shown, setShown] = useState(PAGE);

  const cards = useMemo<Line[]>(() => {
    const supplyOf = new Map((catalog.data?.supply ?? []).map((s) => [s.item, s]));
    return (catalog.data?.view?.brands ?? []).flatMap((b) =>
      b.items.map((i) => {
        const s = supplyOf.get(i.key);
        const name = i.label || `${i.face_value} ${i.face_currency}`;
        return {
          ...splitOf(winnerCost(s), i.unit_price, i.retail_price),
          key: i.key,
          kind: "card" as const,
          name: `${b.name} · ${name}`,
          sub: i.key,
          supplier: s?.winner,
          available: i.available,
          search: [b.name, b.key, name, i.key, i.country],
        };
      }),
    );
  }, [catalog.data]);

  const services = useMemo<{ airtime: Line[]; bill: Line[] }>(() => {
    const airtime: Line[] = [];
    const bill: Line[] = [];
    for (const c of directory.data?.directory.countries ?? []) {
      for (const op of c.airtime ?? []) {
        for (const a of op.amounts) {
          if (!a.unit_price || !a.retail_price) continue;
          airtime.push({
            ...splitOf(a.cost_lyd, a.unit_price, a.retail_price),
            key: `air:${op.id}:${a.amount}`,
            kind: "airtime",
            name: `${op.name} · ${a.amount} ${op.amount_currency}`,
            sub: `${c.name} · يستلم ${a.receive} ${a.receive_currency}${op.approximate ? " (تقريبي)" : ""}`,
            available: true,
            search: [c.name, c.name_en, c.code, op.name, op.name_en],
          });
        }
      }
      for (const b of c.bills ?? []) {
        const entries = b.plans?.length
          ? b.plans.map((p) => ({ id: `p${p.id}`, amount: p.amount, label: p.description || p.description_en, cost_lyd: p.cost_lyd, unit_price: p.unit_price, retail_price: p.retail_price }))
          : (b.suggested ?? []).map((g) => ({ id: g.amount, amount: g.amount, label: "", cost_lyd: g.cost_lyd, unit_price: g.unit_price, retail_price: g.retail_price }));
        for (const e of entries) {
          if (!e.unit_price || !e.retail_price) continue;
          bill.push({
            ...splitOf(e.cost_lyd, e.unit_price, e.retail_price),
            key: `bill:${b.id}:${e.id}`,
            kind: "bill",
            name: `${b.name} · ${e.amount} ${b.amount_currency}`,
            sub: `${c.name}${e.label ? " · " + e.label : ""}`,
            available: true,
            search: [c.name, c.name_en, c.code, b.name, b.name_en, e.label],
          });
        }
      }
    }
    return { airtime, bill };
  }, [directory.data]);

  const all = current === "card" ? cards : services[current];
  const loading = current === "card" ? catalog.isLoading : directory.isLoading;
  const failed = current === "card" ? catalog : directory;
  const rows = useMemo(() => {
    const filtered = all.filter((l) => matches(query, ...l.search) && (!onlyLoss || (l.company !== undefined && l.company <= 0)));
    const by: Record<Exclude<Sort, "">, (l: Line) => number> = {
      "ours-desc": (l) => -(l.company ?? -Infinity),
      "ours-asc": (l) => l.company ?? Infinity,
      "ours-pct": (l) => -(l.company !== undefined && l.cost ? l.company / l.cost : -Infinity),
      "shop-pct": (l) => -(l.unit ? l.shop / l.unit : -Infinity),
    };
    return sort ? [...filtered].sort((a, b) => by[sort](a) - by[sort](b)) : filtered;
  }, [all, query, onlyLoss, sort]);

  const totals = useMemo(() => summary(rows), [rows]);

  const columns: Column<Line>[] = [
    {
      key: "name",
      header: "الصنف",
      mobile: "title",
      cell: (l) => (
        <Stacked
          title={
            <>
              {l.name} {!l.available && <Badge tone="danger">غير متاح</Badge>}
            </>
          }
          sub={l.supplier ? `${l.sub} · ${label(supplierLabels, l.supplier)}` : l.sub}
        />
      ),
    },
    { key: "cost", header: "تكلفتنا", align: "end", cell: (l) => (l.cost !== undefined ? <Money value={l.cost.toFixed(2)} /> : <span className="faint">—</span>) },
    { key: "ours", header: "ربحنا", align: "end", cell: (l) => <ProfitCell value={l.company} of={l.cost} /> },
    { key: "unit", header: "يدفع المتجر", align: "end", mobile: "trailing", cell: (l) => <Money value={l.unit.toFixed(2)} /> },
    { key: "shop", header: "ربح المتجر", align: "end", cell: (l) => <ProfitCell value={l.shop} of={l.unit} /> },
    { key: "retail", header: "سعر الزبون", align: "end", cell: (l) => <Money value={l.retail.toFixed(2)} /> },
  ];

  return (
    <>
      <PageHeader
        title="الأسعار والأرباح"
        description="لكل بطاقة وشحن وفاتورة: تكلفتنا وربحنا، وما يدفعه المتجر وربحه، والسعر المقترح للزبون. النسبة تحت ربحنا من التكلفة، وتحت ربح المتجر من سعره."
      />
      <div className="stack">
        <Segmented<Kind>
          value={current}
          onChange={(k) => {
            setKind(k === "card" ? "" : k);
            setShown(PAGE);
          }}
          options={[
            { id: "card", label: `البطاقات ${cards.length ? count(cards.length) : ""}`.trim() },
            { id: "airtime", label: `الشحن المباشر ${services.airtime.length ? count(services.airtime.length) : ""}`.trim() },
            { id: "bill", label: `الفواتير ${services.bill.length ? count(services.bill.length) : ""}`.trim() },
          ]}
        />
        {current !== "card" && directory.data && !directory.data.directory.priced && (
          <Notice tone="warning" icon={<TriangleAlert />}>
            الأسعار غير محسوبة: سعر الدولار غير مضبوط في التسعير.
          </Notice>
        )}
        <div className="grid kpis">
          <div className="card kpi">
            <div className="kpi-label">الأصناف</div>
            <div className="kpi-value">{count(rows.length)}</div>
            <div className="kpi-foot">{query || onlyLoss ? `من ${count(all.length)}` : "كلها"}</div>
          </div>
          <div className="card kpi money">
            <div className="kpi-label">ربحنا الوسيط</div>
            <div className="kpi-value">{totals.ours !== undefined ? money(totals.ours.toFixed(2)) : "—"}</div>
            <div className="kpi-foot">{totals.oursPct !== undefined ? `${totals.oursPct.toFixed(1)}% من التكلفة` : "—"}</div>
          </div>
          <div className="card kpi">
            <div className="kpi-label">ربح المتجر الوسيط</div>
            <div className="kpi-value">{totals.shop !== undefined ? money(totals.shop.toFixed(2)) : "—"}</div>
            <div className="kpi-foot">{totals.shopPct !== undefined ? `${totals.shopPct.toFixed(1)}% من سعره` : "—"}</div>
          </div>
          <div className={`card kpi ${totals.loss ? "attention" : ""}`}>
            <div className="kpi-label">بلا ربح لنا</div>
            <div className="kpi-value">{count(totals.loss)}</div>
            <div className="kpi-foot">{totals.loss ? "يُباع بالتكلفة أو أقل" : "لا شيء"}</div>
          </div>
        </div>
        <Card tight>
          <div className="toolbar stacks">
            <div className="search-input">
              <Search />
              <input
                className="input"
                placeholder={current === "card" ? "علامة أو صنف أو دولة" : "دولة أو مشغّل أو مفوتر"}
                value={query}
                onChange={(e) => {
                  setQuery(e.target.value);
                  setShown(PAGE);
                }}
              />
            </div>
            <Segmented<Sort>
              value={sort}
              onChange={setSort}
              options={[
                { id: "", label: "الترتيب الأصلي" },
                { id: "ours-desc", label: "ربحنا الأعلى" },
                { id: "ours-asc", label: "ربحنا الأقل" },
                { id: "ours-pct", label: "نسبة ربحنا" },
                { id: "shop-pct", label: "نسبة ربح المتجر" },
              ]}
            />
            <button type="button" className={`chip ${onlyLoss ? "on" : ""}`} onClick={() => setOnlyLoss(!onlyLoss)}>
              بلا ربح لنا فقط
            </button>
          </div>
          {failed.isError ? (
            <Unavailable feature={current === "card" ? "vouchers" : "services"} error={failed.error} onRetry={() => void failed.refetch()} />
          ) : (
            <DataTable
              rows={rows.slice(0, shown)}
              columns={columns}
              rowKey={(l) => l.key}
              loading={loading}
              empty={<Empty icon={<Coins />} title={all.length ? "لا أصناف بهذه الشروط" : "لا أصناف مسعّرة"} />}
            />
          )}
          {rows.length > shown && (
            <div className="card-body" style={{ textAlign: "center" }}>
              <Button size="sm" onClick={() => setShown(shown + PAGE * 2)}>
                عرض المزيد ({count(rows.length - shown)} متبقية)
              </Button>
            </div>
          )}
        </Card>
      </div>
    </>
  );
}

/** The middle of the list, which a few odd items do not drag the way an average would. */
function median(values: number[]): number | undefined {
  if (!values.length) return undefined;
  const sorted = [...values].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
}

function summary(rows: Line[]) {
  const known = rows.filter((l) => l.company !== undefined && l.cost);
  return {
    ours: median(known.map((l) => l.company!)),
    oursPct: median(known.map((l) => (l.company! / l.cost!) * 100)),
    shop: median(rows.map((l) => l.shop)),
    shopPct: median(rows.filter((l) => l.unit > 0).map((l) => (l.shop / l.unit) * 100)),
    loss: known.filter((l) => l.company! <= 0).length,
  };
}
