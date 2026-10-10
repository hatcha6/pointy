import { useMemo, useState } from "react";
import { Unavailable } from "../../components/Unavailable";
import { useQuery } from "@tanstack/react-query";
import { BookOpen, Download, History, Search, Upload } from "lucide-react";
import { api } from "../../lib/api";
import { useSearchParam } from "../../lib/router";
import { matches } from "../../lib/search";
import { count, dateTime } from "../../lib/format";
import { saveText, useVoucherImage } from "../../lib/files";
import { label, supplier as supplierLabels } from "../../lib/labels";
import { reasonText, type CatalogAnswer, type CatalogRecord, type ShopBrand, type ShopItem, type Supply } from "../../lib/vouchers";
import { Badge, Button, Card, CopyText, Empty, Money, Segmented, Skeleton, TimeAgo } from "../../components/ui";
import { DataTable, Stacked, type Column } from "../../components/DataTable";
import { PageHeader } from "../../components/PageHeader";
import { PublishCatalogDialog } from "./PublishCatalog";

export function useCatalog() {
  return useQuery({ queryKey: ["vouchers", "catalog"], queryFn: () => api.get<CatalogAnswer>("/v1/vouchers/admin/catalog"), retry: false, staleTime: 60_000 });
}

export function BrandLogo({ refId, name }: { refId?: string; name: string }) {
  const url = useVoucherImage(refId);
  return <div className="logo-tile">{url ? <img src={url} alt="" /> : name.trim()[0] ?? "؟"}</div>;
}

export function Catalog() {
  const catalog = useCatalog();
  const history = useQuery({
    queryKey: ["vouchers", "catalogs"],
    queryFn: () => api.get<{ catalogs: CatalogRecord[] }>("/v1/vouchers/admin/catalogs?limit=20").then((r) => r.catalogs ?? []),
    retry: false,
  });
  const [query, setQuery] = useSearchParam("q");
  const [category, setCategory] = useSearchParam("category");
  const [onlyOff, setOnlyOff] = useState(false);
  const [publishing, setPublishing] = useState(false);
  const view = catalog.data?.view;
  const record = catalog.data?.catalog;

  const supplyOf = useMemo(() => new Map((catalog.data?.supply ?? []).map((s) => [s.item, s])), [catalog.data]);
  const brands = (view?.brands ?? [])
    .filter((b) => !category || b.category === category)
    .map((b) => ({
      ...b,
      items: b.items.filter((i) => (!onlyOff || !i.available) && (matches(query, b.name, b.key) || matches(query, i.label, i.key))),
    }))
    .filter((b) => b.items.length > 0);
  const items = view?.brands.flatMap((b) => b.items) ?? [];
  const off = items.filter((i) => !i.available).length;

  return (
    <>
      <PageHeader
        title="الكتالوج"
        description="ما تراه المتاجر في متجر البطاقات الآن: الأسعار والعروض والتوفّر، ومن يُشترى منه كل صنف."
        actions={
          <>
            <Button variant="primary" icon={<Upload />} onClick={() => setPublishing(true)}>
              نشر نسخة جديدة
            </Button>
            {record?.document != null && (
              <Button icon={<Download />} onClick={() => saveText(JSON.stringify(record.document, null, 2) + "\n", `catalog-${record.id.slice(0, 8)}.json`, "application/json")}>
                تنزيل الحالية
              </Button>
            )}
          </>
        }
      />
      {catalog.isError ? (
        <Card>
          <Unavailable feature="vouchers" error={catalog.error} onRetry={() => void catalog.refetch()} />
        </Card>
      ) : (
        <div className="stack">
          <div className="grid kpis">
            <div className="card kpi">
              <div className="kpi-label">النسخة المنشورة</div>
              <div className="kpi-value mono" style={{ fontSize: 20 }}>{record ? record.id.slice(0, 8) : catalog.isLoading ? <Skeleton height={24} width={90} /> : "—"}</div>
              <div className="kpi-foot">{record ? <>{record.actor || "—"} · <TimeAgo value={record.created_at} /></> : "لا كتالوج منشور"}</div>
            </div>
            <div className="card kpi">
              <div className="kpi-label">الأصناف</div>
              <div className="kpi-value">{count(items.length)}</div>
              <div className="kpi-foot">{count(view?.brands.length ?? 0)} علامة</div>
            </div>
            <div className={`card kpi ${off ? "attention" : ""}`}>
              <div className="kpi-label">غير متاحة الآن</div>
              <div className="kpi-value">{count(off)}</div>
              <div className="kpi-foot">{view?.test_mode ? "الوضع تجريبي" : "لا تُعرض للشراء"}</div>
            </div>
          </div>
          {record?.note && (
            <p className="muted">
              ملاحظة النسخة: «{record.note}»
            </p>
          )}
          <Card tight>
            <div className="toolbar stacks">
              <div className="search-input">
                <Search />
                <input className="input" placeholder="علامة أو صنف" value={query} onChange={(e) => setQuery(e.target.value)} />
              </div>
              <Segmented
                value={category}
                onChange={setCategory}
                options={[{ id: "", label: "كل الفئات" }, ...(view?.categories ?? []).map((c) => ({ id: c.key, label: c.name }))]}
              />
              <button type="button" className={`chip ${onlyOff ? "on" : ""}`} onClick={() => setOnlyOff(!onlyOff)}>
                غير المتاحة فقط
              </button>
            </div>
            {catalog.isLoading && (
              <div className="card-body">
                <Skeleton height={160} />
              </div>
            )}
            {!catalog.isLoading && brands.length === 0 && <Empty icon={<BookOpen />} title={view ? "لا أصناف بهذه الشروط" : "لا كتالوج منشور بعد"} />}
          </Card>
          {brands.map((brand) => (
            <BrandCard key={brand.key} brand={brand} supplyOf={supplyOf} />
          ))}
          <Card tight title="النسخ السابقة" hint={<History width={14} />}>
            <DataTable
              rows={history.data ?? []}
              columns={[
                { key: "id", header: "النسخة", mobile: "title", cell: (c) => <Stacked title={<span className="mono">{c.id.slice(0, 8)}</span>} sub={c.note} /> },
                { key: "when", header: "نُشرت", mobile: "trailing", cell: (c) => <TimeAgo value={c.created_at} /> },
                { key: "actor", header: "بواسطة", cell: (c) => c.actor || "—" },
                { key: "sha", header: "SHA-256", wideOnly: true, cell: (c) => <CopyText value={c.sha256} display={<span className="mono">{c.sha256.slice(0, 12)}…</span>} /> },
                { key: "at", header: "الوقت", wideOnly: true, cell: (c) => dateTime(c.created_at) },
              ]}
              rowKey={(c) => c.id}
              loading={history.isLoading}
              skeletonRows={3}
            />
          </Card>
        </div>
      )}
      <PublishCatalogDialog open={publishing} onClose={() => setPublishing(false)} />
    </>
  );
}

function BrandCard({ brand, supplyOf }: { brand: ShopBrand; supplyOf: Map<string, Supply> }) {
  const columns: Column<ShopItem>[] = [
    {
      key: "item",
      header: "الصنف",
      mobile: "title",
      cell: (i) => (
        <Stacked
          title={
            <>
              {i.label || `${i.face_value} ${i.face_currency}`} {i.promo && <Badge tone="money">{i.promo.badge || "عرض"}</Badge>}
            </>
          }
          sub={i.key}
          mono
        />
      ),
    },
    { key: "price", header: "سعر المتجر", align: "end", mobile: "trailing", cell: (i) => <Money value={i.unit_price} /> },
    {
      key: "available",
      header: "التوفّر",
      mobile: "subtitle",
      cell: (i) => {
        const s = supplyOf.get(i.key);
        return i.available ? (
          <Badge tone="success" dot>
            متاح{s?.winner ? ` · ${label(supplierLabels, s.winner)}` : ""}
          </Badge>
        ) : (
          <span className="row" style={{ gap: 6 }}>
            <Badge tone="danger" dot>
              غير متاح
            </Badge>
            <span className="faint" style={{ fontSize: 12.5 }}>{reasonText(s?.reason)}</span>
          </span>
        );
      },
    },
    { key: "retail", header: "للزبون", align: "end", cell: (i) => <Money value={i.retail_price} /> },
    {
      key: "regular",
      header: "قبل العرض",
      align: "end",
      wideOnly: true,
      cell: (i) => (i.promo && i.regular_unit_price ? <span className="faint">{i.regular_unit_price}</span> : null),
    },
    {
      key: "cost",
      header: "التكلفة",
      align: "end",
      cell: (i) => {
        const s = supplyOf.get(i.key);
        const winner = s?.suppliers?.find((o) => o.supplier === s.winner);
        return winner?.cost_lyd ? <Money value={Number(winner.cost_lyd).toFixed(2)} /> : <span className="faint">—</span>;
      },
    },
  ];
  return (
    <Card
      tight
      title={
        <span className="brand-head">
          <BrandLogo refId={brand.logo} name={brand.name} />
          <span>
            {brand.name} {brand.featured && <Badge tone="info">مميّزة</Badge>} {brand.badge && <Badge tone="money">{brand.badge}</Badge>}
          </span>
        </span>
      }
      hint={`${brand.items.length} صنف`}
    >
      <DataTable rows={brand.items} columns={columns} rowKey={(i) => i.key} />
    </Card>
  );
}
