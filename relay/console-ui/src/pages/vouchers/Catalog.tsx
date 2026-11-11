import { memo, useMemo, useState } from "react";
import { Unavailable } from "../../components/Unavailable";
import { useQuery } from "@tanstack/react-query";
import { BookOpen, ChevronLeft, Download, FilePenLine, History, Search, Upload } from "lucide-react";
import { api } from "../../lib/api";
import { useRouter, useSearchParam, useSearchText } from "../../lib/router";
import { folded, matcher } from "../../lib/search";
import { count, dateTime, money } from "../../lib/format";
import { saveText, useVoucherImage } from "../../lib/files";
import { accountKind, label, supplier as supplierLabels } from "../../lib/labels";
import { ProfitCell } from "../../components/profit";
import { reasonText, splitOf, type CatalogAnswer, type CatalogRecord, type ShopBrand, type ShopItem, type Supply } from "../../lib/vouchers";
import { Badge, Button, Card, CopyText, Empty, Money, Segmented, Skeleton, TimeAgo } from "../../components/ui";
import { DataTable, Pager, Stacked, usePage, type Column } from "../../components/DataTable";
import { PageHeader } from "../../components/PageHeader";
import { PublishCatalogDialog } from "./PublishCatalog";

export function useCatalog() {
  return useQuery({ queryKey: ["vouchers", "catalog"], queryFn: () => api.get<CatalogAnswer>("/v1/vouchers/admin/catalog"), retry: false, staleTime: 60_000 });
}

/** What the company pays for an item: the cost at the supplier it is bought from now. */
export function winnerCost(s: Supply | undefined): number | undefined {
  const winner = s?.suppliers?.find((o) => o.supplier === s.winner);
  return winner?.cost_lyd ? Number(winner.cost_lyd) : undefined;
}

export function BrandLogo({ refId, name }: { refId?: string; name: string }) {
  const url = useVoucherImage(refId);
  return <div className="logo-tile">{url ? <img src={url} alt="" decoding="async" /> : name.trim()[0] ?? "؟"}</div>;
}

/** Brands on a page: each is one folded row, so a page is light whatever the catalog's size. */
const BRANDS_PER_PAGE = 25;
/** A search that leaves this few brands opens them: the answer is what was asked for. */
const OPEN_WHEN_FEW = 4;

/** A brand with the text its rows are searched by, folded once when the catalog loads. */
type IndexedBrand = { brand: ShopBrand; text: string; items: { item: ShopItem; text: string }[] };

export function Catalog() {
  const { navigate } = useRouter();
  const catalog = useCatalog();
  const history = useQuery({
    queryKey: ["vouchers", "catalogs"],
    queryFn: () => api.get<{ catalogs: CatalogRecord[] }>("/v1/vouchers/admin/catalogs?limit=20").then((r) => r.catalogs ?? []),
    retry: false,
  });
  const { text, setText, query } = useSearchText();
  const [category, setCategory] = useSearchParam("category");
  const [onlyOff, setOnlyOff] = useState(false);
  const [publishing, setPublishing] = useState(false);
  const [opened, setOpened] = useState<ReadonlySet<string>>(new Set());
  const view = catalog.data?.view;
  const record = catalog.data?.catalog;

  const supplyOf = useMemo(() => new Map((catalog.data?.supply ?? []).map((s) => [s.item, s])), [catalog.data]);
  const index = useMemo<IndexedBrand[]>(
    () =>
      (view?.brands ?? []).map((brand) => ({
        brand,
        text: folded(brand.name, brand.key),
        items: brand.items.map((item) => ({ item, text: folded(item.label, item.key) })),
      })),
    [view],
  );
  const totals = useMemo(() => {
    let items = 0;
    let off = 0;
    for (const b of view?.brands ?? []) {
      items += b.items.length;
      for (const i of b.items) if (!i.available) off++;
    }
    return { items, off };
  }, [view]);

  const brands = useMemo(() => {
    const hit = matcher(query);
    const out: ShopBrand[] = [];
    for (const entry of index) {
      if (category && entry.brand.category !== category) continue;
      const whole = hit(entry.text);
      const items = entry.items.filter((i) => (!onlyOff || !i.item.available) && (whole || hit(i.text))).map((i) => i.item);
      if (items.length === 0) continue;
      // The brand itself when nothing was filtered out of it, so its row need not draw again.
      out.push(items.length === entry.brand.items.length ? entry.brand : { ...entry.brand, items });
    }
    return out;
  }, [index, query, category, onlyOff]);

  const paging = usePage(brands.length, BRANDS_PER_PAGE, `${query}|${category}|${onlyOff}`);
  const shown = brands.slice(paging.start, paging.end);
  const few = (query !== "" || onlyOff) && brands.length <= OPEN_WHEN_FEW;
  const allOpen = shown.length > 0 && shown.every((b) => few || opened.has(b.key));

  const toggle = (key: string) =>
    setOpened((current) => {
      const next = new Set(current);
      if (!next.delete(key)) next.add(key);
      return next;
    });
  const toggleAll = () =>
    setOpened((current) => {
      const next = new Set(current);
      for (const b of shown) {
        if (allOpen) next.delete(b.key);
        else next.add(b.key);
      }
      return next;
    });

  return (
    <>
      <PageHeader
        title="الكتالوج"
        description="ما تراه المتاجر في متجر البطاقات الآن: الأسعار والعروض والتوفّر، ومن يُشترى منه كل صنف. اضغط علامة لترى أصنافها."
        actions={
          <>
            <Button variant="primary" icon={<FilePenLine />} onClick={() => navigate("/catalog/edit")}>
              تعديل الكتالوج
            </Button>
            <Button icon={<Upload />} onClick={() => setPublishing(true)}>
              نشر من ملف
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
              <div className="kpi-value">{count(totals.items)}</div>
              <div className="kpi-foot">{count(view?.brands.length ?? 0)} علامة</div>
            </div>
            <div className={`card kpi ${totals.off ? "attention" : ""}`}>
              <div className="kpi-label">غير متاحة الآن</div>
              <div className="kpi-value">{count(totals.off)}</div>
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
                <input className="input" placeholder="علامة أو صنف" value={text} onChange={(e) => setText(e.target.value)} />
              </div>
              <Segmented
                value={category}
                onChange={setCategory}
                options={[{ id: "", label: "كل الفئات" }, ...(view?.categories ?? []).map((c) => ({ id: c.key, label: c.name }))]}
              />
              <button type="button" className={`chip ${onlyOff ? "on" : ""}`} onClick={() => setOnlyOff(!onlyOff)}>
                غير المتاحة فقط
              </button>
              {shown.length > 0 && !few && (
                <Button size="sm" variant="ghost" onClick={toggleAll}>
                  {allOpen ? "طيّ الكل" : "فتح الكل"}
                </Button>
              )}
            </div>
            {catalog.isLoading && (
              <div className="card-body">
                <Skeleton height={160} />
              </div>
            )}
            {!catalog.isLoading && brands.length === 0 && <Empty icon={<BookOpen />} title={view ? "لا أصناف بهذه الشروط" : "لا كتالوج منشور بعد"} />}
            {shown.map((brand) => (
              <BrandRow key={brand.key} brand={brand} supplyOf={supplyOf} open={few || opened.has(brand.key)} onToggle={toggle} />
            ))}
            <Pager {...paging} total={brands.length} unit="علامة" onPage={(page) => {
              paging.setPage(page);
              window.scrollTo({ top: 0 });
            }} />
          </Card>
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

/** One brand: a line that says what it holds, and its items once opened. */
const BrandRow = memo(function BrandRow({ brand, supplyOf, open, onToggle }: {
  brand: ShopBrand;
  supplyOf: Map<string, Supply>;
  open: boolean;
  onToggle: (key: string) => void;
}) {
  const off = brand.items.reduce((n, i) => n + (i.available ? 0 : 1), 0);
  const prices = brand.items.map((i) => Number(i.unit_price)).filter(Number.isFinite);
  const low = Math.min(...prices);
  const high = Math.max(...prices);
  return (
    <div className={`brand-row ${open ? "open" : ""}`}>
      <button type="button" className="brand-toggle" aria-expanded={open} onClick={() => onToggle(brand.key)}>
        <ChevronLeft />
        <BrandLogo refId={brand.logo} name={brand.name} />
        <span className="brand-name">
          {brand.name}
          {brand.featured && <Badge tone="info">مميّزة</Badge>}
          {brand.badge && <Badge tone="money">{brand.badge}</Badge>}
          {brand.target && <Badge tone="outline">يُشحن إلى {label(accountKind, brand.target.kind)}</Badge>}
          {brand.platform === "steam" && <Badge tone="outline">ستيم</Badge>}
        </span>
        <span className="brand-facts">
          {off > 0 && <Badge tone="danger" dot>{count(off)} غير متاح</Badge>}
          {prices.length > 0 && <span className="brand-range">{low === high ? money(low) : `${money(low)} – ${money(high)}`}</span>}
          <span>{count(brand.items.length)} صنف</span>
        </span>
      </button>
      {open && (
        <div className="brand-items">
          {brand.target && (
            <p className="brand-target">
              يُطلب: {brand.target.fields.map((f) => f.label).join(" و")}
              {brand.target.check ? " · يُتحقق من الحساب قبل البيع" : ""}
            </p>
          )}
          <BrandItems items={brand.items} supplyOf={supplyOf} />
        </div>
      )}
    </div>
  );
});

function BrandItems({ items, supplyOf }: { items: ShopItem[]; supplyOf: Map<string, Supply> }) {
  const columns = useMemo<Column<ShopItem>[]>(() => {
    const costOf = (i: ShopItem) => winnerCost(supplyOf.get(i.key));
    return [
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
      { key: "cost", header: "تكلفتنا", align: "end", cell: (i) => (costOf(i) !== undefined ? <Money value={costOf(i)!.toFixed(2)} /> : <span className="faint">—</span>) },
      { key: "ours", header: "ربحنا", align: "end", cell: (i) => <ProfitCell value={splitOf(costOf(i), i.unit_price, i.retail_price).company} of={costOf(i)} /> },
      { key: "price", header: "يدفع المتجر", align: "end", mobile: "trailing", cell: (i) => <Money value={i.unit_price} /> },
      { key: "theirs", header: "ربح المتجر", align: "end", cell: (i) => <ProfitCell value={splitOf(costOf(i), i.unit_price, i.retail_price).shop} of={Number(i.unit_price)} /> },
      { key: "retail", header: "للزبون", align: "end", cell: (i) => <Money value={i.retail_price} /> },
      {
        key: "regular",
        header: "قبل العرض",
        align: "end",
        wideOnly: true,
        cell: (i) => (i.promo && i.regular_unit_price ? <span className="faint">{i.regular_unit_price}</span> : null),
      },
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
    ];
  }, [supplyOf]);
  return <DataTable rows={items} columns={columns} rowKey={(i) => i.key} />;
}
