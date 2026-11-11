import { memo, useCallback, useMemo, useState } from "react";
import { ChevronLeft, CloudOff, FilePenLine, Layers, LayoutList, Pencil, Plus, Search, TriangleAlert, Upload } from "lucide-react";
import { useRouter, useSearchText } from "../../lib/router";
import { folded, matcher } from "../../lib/search";
import { count, money } from "../../lib/format";
import {
  allKeys,
  editBrand,
  editItem,
  freeKey,
  isActive,
  isAuto,
  itemProblems,
  promoState,
  useCatalogDraft,
  type Doc,
  type DocBrand,
  type DocItem,
} from "../../lib/catalogDraft";
import { diffCatalog } from "../../lib/catalogDiff";
import { Badge, Button, Card, Empty, Notice, Skeleton } from "../../components/ui";
import { Pager, usePage } from "../../components/DataTable";
import { PageHeader } from "../../components/PageHeader";
import { Unavailable } from "../../components/Unavailable";
import { useToast } from "../../components/toast";
import { BrandLogo, useCatalog, winnerCost } from "./Catalog";
import { ItemSheet } from "./editor/ItemSheet";
import { BrandSheet } from "./editor/BrandSheet";
import { BulkSheet } from "./editor/BulkSheet";
import { CategoriesSheet } from "./editor/CategoriesSheet";
import { PublishDraft } from "./editor/PublishDraft";

// The catalog edited by hand, a field at a time, from a phone: tap a card to
// change its prices or put it on promotion, tap a brand for its name and
// logo, or change many cards at once. Edits collect in a draft kept in this
// browser; one publish (and its passkey tap) sends them to the shops as a new
// version, exactly as publishing a file does. The file way stays, for bulk
// work, on the catalog page.

const EMPTY: Doc = { categories: [], brands: [] };
const BRANDS_PER_PAGE = 20;
const ITEMS_PER_PAGE = 40;

type Filter = "" | "promo" | "hidden" | "auto" | "problem";
type Sheet =
  | { kind: "item"; brand: string; item: DocItem; isNew: boolean }
  | { kind: "brand"; brand: DocBrand; isNew: boolean }
  | { kind: "bulk"; brand?: string }
  | { kind: "categories" }
  | { kind: "publish" }
  | null;

const filters: { id: Filter; label: string }[] = [
  { id: "", label: "الكل" },
  { id: "promo", label: "عليها عرض" },
  { id: "hidden", label: "مخفية" },
  { id: "auto", label: "سعرها تلقائي" },
  { id: "problem", label: "فيها خطأ" },
];

export function CatalogEditor() {
  const { navigate } = useRouter();
  const toast = useToast();
  const catalog = useCatalog();
  const published = catalog.data ? ((catalog.data.catalog?.document as Doc | undefined) ?? EMPTY) : undefined;
  const base = catalog.data ? catalog.data.catalog?.id ?? "" : undefined;
  const draft = useCatalogDraft(published, base);
  const doc = draft.doc;
  const { text, setText, query } = useSearchText();
  const [category, setCategory] = useState("");
  const [filter, setFilter] = useState<Filter>("");
  const [opened, setOpened] = useState<ReadonlySet<string>>(new Set());
  const [sheet, setSheet] = useState<Sheet>(null);

  // What each card costs now and what shops pay for it now, from the published catalog.
  const costOf = useMemo(() => new Map((catalog.data?.supply ?? []).map((s) => [s.item, winnerCost(s)])), [catalog.data]);
  const liveOf = useMemo(() => new Map((catalog.data?.view?.brands ?? []).flatMap((b) => b.items.map((i) => [i.key, i.unit_price] as const))), [catalog.data]);

  const index = useMemo(
    () => (doc?.brands ?? []).map((brand) => ({ brand, text: folded(brand.name, brand.key, ...(brand.aliases ?? [])), items: brand.items.map((item) => ({ item, text: folded(item.label, item.key) })) })),
    [doc],
  );
  const shown = useMemo(() => {
    if (!doc) return [];
    const hit = matcher(query);
    const keep = (brand: DocBrand, item: DocItem) =>
      filter === "" ||
      (filter === "promo" && !!item.promo) ||
      (filter === "hidden" && (!isActive(item.active) || !isActive(brand.active))) ||
      (filter === "auto" && isAuto(doc, item)) ||
      (filter === "problem" && itemProblems(item).length > 0);
    const out: { brand: DocBrand; items: DocItem[] }[] = [];
    for (const entry of index) {
      if (category && entry.brand.category !== category) continue;
      const whole = hit(entry.text);
      const items = entry.items.filter((i) => (whole || hit(i.text)) && keep(entry.brand, i.item)).map((i) => i.item);
      // A brand with no items still shows while nothing narrows the list: it is how its first item is added.
      if (items.length === 0 && !(whole && filter === "" && entry.brand.items.length === 0)) continue;
      out.push({ brand: entry.brand, items });
    }
    return out;
  }, [doc, index, query, category, filter]);

  const narrowed = query !== "" || category !== "" || filter !== "";
  const paging = usePage(shown.length, BRANDS_PER_PAGE, `${query}|${category}|${filter}`);
  const page = shown.slice(paging.start, paging.end);
  const few = narrowed && shown.length <= 3;
  const shownItems = useMemo(() => shown.reduce((n, b) => n + b.items.length, 0), [shown]);

  const diff = useMemo(() => (draft.editing && published && doc ? diffCatalog(published, doc) : null), [draft.editing, published, doc]);
  const changes = diff ? diff.changed.length + diff.itemsAdded.length + diff.itemsRemoved.length + diff.brandsAdded.length + diff.brandsRemoved.length : 0;
  const taken = useMemo(() => (doc ? allKeys(doc) : new Set<string>()), [doc]);

  const toggle = useCallback(
    (key: string) =>
      setOpened((current) => {
        const next = new Set(current);
        if (!next.delete(key)) next.add(key);
        return next;
      }),
    [],
  );
  const openItem = useCallback((brand: string, item: DocItem) => setSheet({ kind: "item", brand, item, isNew: false }), []);
  const openBrand = useCallback((brand: DocBrand) => setSheet({ kind: "brand", brand, isNew: false }), []);
  const openBulk = useCallback((brand: string) => setSheet({ kind: "bulk", brand }), []);
  const newItem = useCallback(
    (brand: DocBrand) => setSheet({ kind: "item", brand: brand.key, isNew: true, item: { key: "", price: "", retail_price: "", supplier: {} } }),
    [],
  );

  if (catalog.isError) {
    return (
      <Card>
        <Unavailable feature="vouchers" error={catalog.error} onRetry={() => void catalog.refetch()} />
      </Card>
    );
  }

  const sheetBrand = sheet && (sheet.kind === "item" || sheet.kind === "bulk") && sheet.brand ? doc?.brands.find((b) => b.key === sheet.brand) : undefined;
  const bulkTargets =
    sheet?.kind === "bulk"
      ? sheetBrand
        ? sheetBrand.items.map((item) => ({ brand: sheetBrand, item }))
        : shown.flatMap((b) => b.items.map((item) => ({ brand: b.brand, item })))
      : [];

  return (
    <>
      <PageHeader
        crumbs={[{ to: "/catalog", label: "الكتالوج" }]}
        title="تعديل الكتالوج"
        description="اضغط صنفاً لتغيّر سعره أو تضع عليه عرضاً، أو علامةً لاسمها وصورتها. التعديلات تُجمع في مسودة على هذا الجهاز، ولا تصل المتاجر إلا عند النشر."
        actions={
          <>
            <Button icon={<LayoutList />} disabled={!doc} onClick={() => setSheet({ kind: "categories" })}>
              الفئات
            </Button>
            <Button
              icon={<Plus />}
              disabled={!doc}
              onClick={() => setSheet({ kind: "brand", isNew: true, brand: { key: "", name: "", category: category || doc?.categories[0]?.key || "", logo: {}, items: [] } })}
            >
              علامة جديدة
            </Button>
          </>
        }
      />
      <div className="stack">
        {draft.stale && (
          <Notice tone="warning" icon={<TriangleAlert />}>
            نُشرت نسخة أخرى من الكتالوج بعد أن بدأت هذه المسودة. نشر المسودة يستبدل تلك النسخة كلها: راجع التغييرات قبل النشر، أو تجاهل المسودة وابدأ من المنشور.
          </Notice>
        )}
        {draft.unsaved && (
          <Notice tone="warning" icon={<CloudOff />}>
            تعذّر حفظ المسودة على هذا الجهاز (المتصفح لا يسمح أو الكتالوج أكبر مما يحفظه): تبقى ما دامت هذه الصفحة مفتوحة، فانشرها قبل إغلاقها.
          </Notice>
        )}
        <Card tight>
          <div className="toolbar stacks">
            <div className="search-input">
              <Search />
              <input className="input" placeholder="علامة أو صنف" value={text} onChange={(e) => setText(e.target.value)} />
            </div>
            <select className="input edit-category-pick" aria-label="الفئة" value={category} onChange={(e) => setCategory(e.target.value)}>
              <option value="">كل الفئات</option>
              {(doc?.categories ?? []).map((c) => (
                <option key={c.key} value={c.key}>
                  {c.name}
                </option>
              ))}
            </select>
            <div className="chips">
              {filters.map((f) => (
                <button type="button" key={f.id} className={`chip ${filter === f.id ? "on" : ""}`} onClick={() => setFilter(f.id)}>
                  {f.label}
                </button>
              ))}
            </div>
            <Button size="sm" icon={<Layers />} disabled={shownItems === 0} onClick={() => setSheet({ kind: "bulk" })}>
              تعديل جماعي لـ {count(shownItems)} صنفاً
            </Button>
          </div>
          {catalog.isLoading && (
            <div className="card-body">
              <Skeleton height={160} />
            </div>
          )}
          {!catalog.isLoading && shown.length === 0 && <Empty icon={<FilePenLine />} title={narrowed ? "لا أصناف بهذه الشروط" : "الكتالوج فارغ: أضف فئة ثم علامة"} />}
          {doc &&
            page.map(({ brand, items }) => (
              <EditBrandRow
                key={brand.key}
                doc={doc}
                brand={brand}
                items={items}
                open={few || opened.has(brand.key)}
                costOf={costOf}
                liveOf={liveOf}
                onToggle={toggle}
                onItem={openItem}
                onBrand={openBrand}
                onBulk={openBulk}
                onNewItem={newItem}
              />
            ))}
          <Pager
            {...paging}
            total={shown.length}
            unit="علامة"
            onPage={(next) => {
              paging.setPage(next);
              window.scrollTo({ top: 0 });
            }}
          />
        </Card>
      </div>

      {draft.editing && (
        <div className="draft-bar" role="status">
          <span className="draft-count">{changes ? `${count(changes)} تغييراً في المسودة` : "المسودة مطابقة للمنشور"}</span>
          <Button
            variant="ghost"
            onClick={() => {
              if (!changes || window.confirm("تجاهل كل تغييرات المسودة؟")) draft.discard();
            }}
          >
            تجاهل
          </Button>
          <Button variant="primary" icon={<Upload />} disabled={!changes} onClick={() => setSheet({ kind: "publish" })}>
            راجع وانشر
          </Button>
        </div>
      )}

      {doc && sheet?.kind === "item" && sheetBrand && (
        <ItemSheet
          key={sheet.item.key || "new"}
          doc={doc}
          brand={sheetBrand}
          item={sheet.item}
          isNew={sheet.isNew}
          cost={costOf.get(sheet.item.key)}
          livePrice={liveOf.get(sheet.item.key)}
          takenKeys={taken}
          onClose={() => setSheet(null)}
          onSave={(next) => {
            const { brand, item, isNew } = sheet;
            draft.update((d) => (isNew ? editBrand(d, brand, (b) => ({ ...b, items: [...b.items, next] })) : editItem(d, brand, item.key, () => next)));
            setOpened((current) => new Set(current).add(brand));
            setSheet(null);
          }}
          onDelete={() => {
            draft.update((d) => editItem(d, sheet.brand, sheet.item.key, () => null));
            setSheet(null);
          }}
          onDuplicate={() => {
            const { promo: _promo, ...copy } = sheet.item;
            setSheet({ kind: "item", brand: sheet.brand, isNew: true, item: { ...copy, key: freeKey(sheet.item.key, taken) } as DocItem });
          }}
        />
      )}
      {doc && sheet?.kind === "brand" && (
        <BrandSheet
          key={sheet.brand.key || "new"}
          doc={doc}
          brand={sheet.brand}
          isNew={sheet.isNew}
          takenKeys={taken}
          onClose={() => setSheet(null)}
          onSave={(next) => {
            const { brand, isNew } = sheet;
            // The sheet edits the brand's own fields; its items are whatever the draft holds now.
            draft.update((d) => (isNew ? { ...d, brands: [...d.brands, next] } : editBrand(d, brand.key, (b) => ({ ...next, items: b.items }))));
            if (isNew) setOpened((current) => new Set(current).add(next.key));
            setSheet(null);
          }}
          onDelete={() => {
            draft.update((d) => editBrand(d, sheet.brand.key, () => null));
            setSheet(null);
          }}
        />
      )}
      {doc && sheet?.kind === "bulk" && (
        <BulkSheet
          doc={doc}
          targets={bulkTargets}
          scope={sheetBrand ? `علامة ${sheetBrand.name}` : narrowed ? "ما يعرضه البحث والتصفية" : "الكتالوج كله"}
          onClose={() => setSheet(null)}
          onApply={(change, done) => {
            draft.update(change);
            toast.success(done);
            setSheet(null);
          }}
        />
      )}
      {doc && sheet?.kind === "categories" && (
        <CategoriesSheet
          doc={doc}
          onClose={() => setSheet(null)}
          onSave={(categories) => {
            draft.update((d) => ({ ...d, categories }));
            setSheet(null);
          }}
        />
      )}
      {doc && published && sheet?.kind === "publish" && (
        <PublishDraft
          published={published}
          draft={doc}
          onClose={() => setSheet(null)}
          onPublished={() => {
            draft.discard();
            setSheet(null);
            navigate("/catalog");
          }}
        />
      )}
    </>
  );
}

const EditBrandRow = memo(function EditBrandRow({ doc, brand, items, open, costOf, liveOf, onToggle, onItem, onBrand, onBulk, onNewItem }: {
  doc: Doc;
  brand: DocBrand;
  /** The brand's items the search and filters leave. */
  items: DocItem[];
  open: boolean;
  costOf: Map<string, number | undefined>;
  liveOf: Map<string, string>;
  onToggle: (key: string) => void;
  onItem: (brand: string, item: DocItem) => void;
  onBrand: (brand: DocBrand) => void;
  onBulk: (brand: string) => void;
  onNewItem: (brand: DocBrand) => void;
}) {
  const paging = usePage(items.length, ITEMS_PER_PAGE);
  const promos = brand.items.reduce((n, i) => n + (promoState(i.promo) === "running" || promoState(i.promo) === "scheduled" ? 1 : 0), 0);
  return (
    <div className={`brand-row ${open ? "open" : ""}`}>
      <button type="button" className="brand-toggle" aria-expanded={open} onClick={() => onToggle(brand.key)}>
        <ChevronLeft />
        <BrandLogo refId={brand.logo?.display} name={brand.name} />
        <span className="brand-name">
          {brand.name}
          {!isActive(brand.active) && <Badge tone="warning">مخفية</Badge>}
          {brand.featured && <Badge tone="info">مميّزة</Badge>}
          {brand.badge && <Badge tone="money">{brand.badge}</Badge>}
        </span>
        <span className="brand-facts">
          {promos > 0 && <Badge tone="money">{count(promos)} عرض</Badge>}
          <span>
            {items.length === brand.items.length ? count(items.length) : `${count(items.length)} من ${count(brand.items.length)}`} صنف
          </span>
        </span>
      </button>
      {open && (
        <div className="brand-items">
          <div className="edit-brand-actions">
            <Button size="sm" icon={<Pencil />} onClick={() => onBrand(brand)}>
              العلامة
            </Button>
            <Button size="sm" icon={<Plus />} onClick={() => onNewItem(brand)}>
              صنف
            </Button>
            <Button size="sm" icon={<Layers />} disabled={brand.items.length === 0} onClick={() => onBulk(brand.key)}>
              تعديل جماعي
            </Button>
          </div>
          {items.slice(paging.start, paging.end).map((item) => {
            const state = promoState(item.promo);
            const auto = isAuto(doc, item);
            const live = auto ? liveOf.get(item.key) : undefined;
            const cost = costOf.get(item.key);
            const shop = Number(live ?? item.price);
            const bad = itemProblems(item).length > 0;
            return (
              <button type="button" key={item.key} className="edit-item" onClick={() => onItem(brand.key, item)}>
                <span className="edit-item-name">
                  <strong>{item.label || `${item.face_value ?? ""} ${item.face_currency ?? ""}`.trim() || item.key}</strong>
                  <span className="mono">{item.key}</span>
                  <span className="edit-item-badges">
                    {bad && <Badge tone="danger">خطأ</Badge>}
                    {!isActive(item.active) && <Badge tone="warning">مخفي</Badge>}
                    {auto && <Badge tone="outline">تلقائي</Badge>}
                    {state === "running" && <Badge tone="money">{item.promo!.badge || "عرض"}</Badge>}
                    {state === "scheduled" && <Badge tone="info">عرض مجدول</Badge>}
                    {state === "ended" && <Badge>عرض انتهى</Badge>}
                  </span>
                </span>
                <span className="edit-item-prices">
                  <strong>{money(live ?? item.price)}</strong>
                  <span>للزبون {money(item.promo?.retail_price && state === "running" ? item.promo.retail_price : item.retail_price)}</span>
                  {cost !== undefined && Number.isFinite(shop) && <span className={shop - cost < 0 ? "negative" : "positive"}>ربحنا {money((shop - cost).toFixed(2))}</span>}
                </span>
              </button>
            );
          })}
          {items.length === 0 && <p className="brand-target">لا أصناف بعد. أضف أول صنف.</p>}
          <Pager {...paging} total={items.length} unit="صنف" onPage={paging.setPage} />
        </div>
      )}
    </div>
  );
});
