import { useMemo, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { Ban, FileSpreadsheet, FlaskConical, KeyRound, Layers, PackageOpen, PackagePlus, Search, Undo2, X } from "lucide-react";
import { api, qs } from "../../lib/api";
import { useSearchParam } from "../../lib/router";
import { matches } from "../../lib/search";
import { count, date, daysUntil } from "../../lib/format";
import { statusLabels, type StockAnswer, type StockBatch, type StockCode, type StockLevel } from "../../lib/stock";
import { useAction, PasskeyHint } from "../../components/guarded";
import { Dialog } from "../../components/dialog";
import { Unavailable } from "../../components/Unavailable";
import { DataTable, Stacked, type Column } from "../../components/DataTable";
import { PageHeader } from "../../components/PageHeader";
import { Badge, Button, Card, Empty, Field, Money, Notice, Segmented, Skeleton, TimeAgo } from "../../components/ui";
import { AddStockDialog } from "./AddStock";

/** Codes that expire within this many days are flagged. */
const soonDays = 14;

export function Stock() {
  const stock = useQuery({ queryKey: ["vouchers", "stock"], queryFn: () => api.get<StockAnswer>("/v1/vouchers/admin/stock"), retry: false });
  const [query, setQuery] = useSearchParam("q");
  const [item, setItem] = useSearchParam("item");
  const [batch, setBatch] = useSearchParam("batch");
  const [status, setStatus] = useState<"" | StockCode["status"]>("available");
  const [adding, setAdding] = useState<null | "manual" | "csv">(null);
  const [voiding, setVoiding] = useState<StockCode | null>(null);

  const codes = useQuery({
    queryKey: ["vouchers", "stock", "codes", item, batch, status],
    queryFn: () =>
      api.get<{ codes: StockCode[] }>("/v1/vouchers/admin/stock/codes" + qs({ item, batch, status, limit: 300 })).then((r) => r.codes ?? []),
    retry: false,
  });

  const levels = stock.data?.items ?? [];
  const nameOf = useMemo(() => new Map(levels.map((l) => [l.item, l.name || l.item])), [levels]);
  const shown = levels.filter((l) => matches(query, l.name, l.item, l.brand));
  const totals = useMemo(() => {
    let available = 0;
    let value = 0;
    let stocked = 0;
    let soon = 0;
    for (const l of levels) {
      available += l.available;
      value += Number(l.available_cost) || 0;
      if (l.available > 0) stocked++;
      const left = daysUntil(l.next_expiry);
      if (l.available > 0 && left !== null && left <= soonDays) soon++;
    }
    return { available, value, stocked, soon };
  }, [levels]);
  const notSellable = levels.filter((l) => l.available > 0 && !l.in_catalog);

  const levelColumns: Column<StockLevel>[] = [
    {
      key: "item",
      header: "البطاقة",
      mobile: "title",
      cell: (l) => <Stacked title={<>{l.name || l.item} {!l.in_catalog && <Badge tone="danger">ليست في الكتالوج</Badge>}</>} sub={l.item} mono />,
    },
    {
      key: "available",
      header: "متاح للبيع",
      align: "end",
      mobile: "trailing",
      cell: (l) => (l.available > 0 ? <Badge tone="success">{count(l.available)}</Badge> : <Badge tone="neutral">نفد</Badge>),
    },
    { key: "value", header: "قيمته بالتكلفة", align: "end", cell: (l) => <Money value={l.available_cost} /> },
    {
      key: "expiry",
      header: "أقرب انتهاء",
      cell: (l) => {
        const left = daysUntil(l.next_expiry);
        if (!l.next_expiry) return <span className="faint">—</span>;
        return left !== null && left <= soonDays ? <Badge tone="warning">{date(l.next_expiry)}</Badge> : date(l.next_expiry);
      },
    },
    { key: "sold", header: "مُباع", align: "end", cell: (l) => count(l.sold) },
    {
      key: "off",
      header: "منتهٍ / ملغى",
      align: "end",
      wideOnly: true,
      cell: (l) => (l.expired + l.voided > 0 ? `${count(l.expired)} / ${count(l.voided)}` : <span className="faint">—</span>),
    },
    { key: "added", header: "آخر إضافة", wideOnly: true, cell: (l) => <TimeAgo value={l.last_added_at} /> },
  ];

  const codeColumns: Column<StockCode>[] = [
    { key: "code", header: "الكود", mobile: "title", cell: (c) => <Stacked title={<span className="mono" dir="ltr">{c.code}</span>} sub={c.serial} mono /> },
    { key: "item", header: "البطاقة", mobile: "subtitle", cell: (c) => <Stacked title={nameOf.get(c.item) ?? c.item} sub={c.item} mono /> },
    { key: "cost", header: "التكلفة", align: "end", cell: (c) => <Money value={c.cost} /> },
    {
      key: "status",
      header: "الحالة",
      mobile: "trailing",
      cell: (c) => {
        // Compared as dates: a code still sells on its last day.
        const expired = c.status === "available" && !!c.expires_on && c.expires_on < new Date().toLocaleDateString("en-CA");
        if (expired) return <Badge tone="warning">منتهٍ</Badge>;
        const tone = c.status === "available" ? "success" : c.status === "sold" ? "info" : "neutral";
        return (
          <span className="row" style={{ gap: 4 }} title={c.return_reason || c.void_reason || undefined}>
            <Badge tone={tone}>{statusLabels[c.status]}</Badge>
            {c.returned_from && (
              <Badge tone="warning">
                <Undo2 width={11} /> أُعيد
              </Badge>
            )}
          </span>
        );
      },
    },
    { key: "expiry", header: "الانتهاء", cell: (c) => (c.expires_on ? date(c.expires_on) : <span className="faint">—</span>) },
    { key: "source", header: "المصدر", wideOnly: true, cell: (c) => c.source || <span className="faint">—</span> },
    { key: "when", header: "أُضيف", wideOnly: true, cell: (c) => <TimeAgo value={c.created_at} /> },
    {
      key: "actions",
      header: "",
      mobile: "actions",
      cell: (c) =>
        c.status === "available" ? (
          <Button size="sm" variant="ghost" icon={<Ban />} onClick={() => setVoiding(c)}>
            إلغاء الكود
          </Button>
        ) : c.status === "void" ? (
          <span className="faint" style={{ fontSize: 12.5 }}>
            {c.voided_by ? `${c.voided_by}: ` : ""}
            {c.void_reason}
          </span>
        ) : null,
    },
  ];

  const batchColumns: Column<StockBatch>[] = [
    { key: "when", header: "الإضافة", mobile: "title", cell: (b) => <Stacked title={<TimeAgo value={b.created_at} />} sub={b.note} /> },
    { key: "source", header: "المصدر", mobile: "subtitle", cell: (b) => b.source || <span className="faint">—</span> },
    { key: "codes", header: "الأكواد", align: "end", cell: (b) => count(b.codes) },
    { key: "items", header: "البطاقات", wideOnly: true, cell: (b) => b.items.map((i) => nameOf.get(i) ?? i).join("، ") },
    { key: "cost", header: "التكلفة", align: "end", mobile: "trailing", cell: (b) => <Money value={b.cost} /> },
    { key: "actor", header: "بواسطة", wideOnly: true, cell: (b) => b.actor || "—" },
  ];

  return (
    <>
      <PageHeader
        title="مخزون البطاقات"
        description="أكواد اشتريناها بأنفسنا من خارج الموردين. تُباع للمتاجر قبل أي مورّد، وحين ينفد مخزون بطاقة يعود بيعها إلى الموردين تلقائياً."
        actions={
          <>
            <Button variant="primary" icon={<PackagePlus />} disabled={stock.data?.key_set === false} onClick={() => setAdding("manual")}>
              إضافة أكواد
            </Button>
            <Button icon={<FileSpreadsheet />} disabled={stock.data?.key_set === false} onClick={() => setAdding("csv")}>
              رفع ملف CSV
            </Button>
          </>
        }
      />
      {stock.isError ? (
        <Card>
          <Unavailable feature="vouchers" error={stock.error} onRetry={() => void stock.refetch()} />
        </Card>
      ) : (
        <div className="stack">
          {stock.data?.key_set === false && (
            <Notice tone="danger" icon={<KeyRound />}>
              لم يُضبط مفتاح المخزون على الخادم (POINTY_RELAY_VOUCHER_STOCK_KEY)، فلا يمكن إضافة أكواد ولا يُباع شيء من المخزون. أنشئ مفتاحاً بالأمر
              <span className="mono"> pointy-relay gen-stock-key </span>
              واحفظه مع أسرار الخادم ونسخة احتياطية منفصلة: بدونه لا تُفتح الأكواد المخزّنة.
            </Notice>
          )}
          {stock.data?.test_mode && (
            <Notice tone="warning" icon={<FlaskConical />}>
              الخادم في الوضع التجريبي: لا يُباع شيء من المخزون، فكل عملية تأخذ كوداً تجريبياً.
            </Notice>
          )}
          {notSellable.length > 0 && (
            <Notice tone="danger" icon={<Ban />}>
              {count(notSellable.length)} بطاقة في المخزون لم تعد في الكتالوج المنشور، فلا تُباع: {notSellable.map((l) => l.item).join("، ")}.
            </Notice>
          )}
          <div className="grid kpis">
            <div className="card kpi">
              <div className="kpi-label">أكواد متاحة للبيع</div>
              <div className="kpi-value">{stock.isLoading ? <Skeleton height={24} width={60} /> : count(totals.available)}</div>
              <div className="kpi-foot">في {count(totals.stocked)} بطاقة</div>
            </div>
            <div className="card kpi">
              <div className="kpi-label">قيمتها بالتكلفة</div>
              <div className="kpi-value">
                <Money value={totals.value.toFixed(3)} />
              </div>
              <div className="kpi-foot">ما دفعناه فيها</div>
            </div>
            <div className={`card kpi ${totals.soon ? "attention" : ""}`}>
              <div className="kpi-label">تنتهي قريباً</div>
              <div className="kpi-value">{count(totals.soon)}</div>
              <div className="kpi-foot">بطاقة فيها كود ينتهي خلال {count(soonDays)} يوماً</div>
            </div>
          </div>

          <Card tight title="المخزون حسب البطاقة" hint={<Layers width={14} />}>
            <div className="toolbar stacks">
              <div className="search-input">
                <Search />
                <input className="input" placeholder="بطاقة أو علامة" value={query} onChange={(e) => setQuery(e.target.value)} />
              </div>
            </div>
            <DataTable
              rows={shown}
              columns={levelColumns}
              rowKey={(l) => l.item}
              onRowClick={(l) => {
                setItem(l.item);
                setBatch("");
                document.getElementById("stock-codes")?.scrollIntoView({ behavior: "smooth" });
              }}
              loading={stock.isLoading}
              empty={
                <Empty icon={<PackageOpen />} title={levels.length ? "لا بطاقة بهذا الاسم" : "المخزون فارغ"}>
                  {!levels.length && "أضف أكواداً اشتريتها بنفسك، واحداً واحداً أو من ملف CSV."}
                </Empty>
              }
            />
          </Card>

          <div id="stock-codes">
            <Card tight title="الأكواد" hint="تظهر آخر 4 خانات فقط من كل كود">
              <div className="toolbar stacks">
                <Segmented
                  value={status}
                  onChange={setStatus}
                  options={[
                    { id: "available", label: "متاحة" },
                    { id: "sold", label: "مُباعة" },
                    { id: "void", label: "ملغاة" },
                    { id: "", label: "الكل" },
                  ]}
                />
                {item && (
                  <button type="button" className="chip on" onClick={() => setItem("")}>
                    {nameOf.get(item) ?? item} <X width={12} />
                  </button>
                )}
                {batch && (
                  <button type="button" className="chip on" onClick={() => setBatch("")}>
                    إضافة واحدة <X width={12} />
                  </button>
                )}
              </div>
              <DataTable rows={codes.data ?? []} columns={codeColumns} rowKey={(c) => c.id} loading={codes.isLoading} empty={<Empty title="لا أكواد بهذه الشروط" />} />
            </Card>
          </div>

          <Card tight title="الإضافات الأخيرة">
            <DataTable
              rows={stock.data?.batches ?? []}
              columns={batchColumns}
              rowKey={(b) => b.id}
              onRowClick={(b) => {
                setBatch(b.id);
                setItem("");
                setStatus("");
                document.getElementById("stock-codes")?.scrollIntoView({ behavior: "smooth" });
              }}
              loading={stock.isLoading}
              skeletonRows={3}
              empty={<Empty title="لم يُضف شيء بعد" />}
            />
          </Card>
        </div>
      )}
      <AddStockDialog open={adding !== null} initialMode={adding ?? "manual"} initialItem={item} onClose={() => setAdding(null)} />
      <VoidDialog code={voiding} name={voiding ? nameOf.get(voiding.item) ?? voiding.item : ""} onClose={() => setVoiding(null)} />
    </>
  );
}

function VoidDialog({ code, name, onClose }: { code: StockCode | null; name: string; onClose: () => void }) {
  const [reason, setReason] = useState("");
  const action = useAction({ passkey: true, invalidate: [["vouchers", "stock"], ["vouchers", "catalog"]], success: "أُلغي الكود ولن يُباع" });
  const close = () => {
    setReason("");
    action.setError(null);
    onClose();
  };
  return (
    <Dialog
      open={code !== null}
      onClose={close}
      busy={action.busy}
      title="إلغاء كود من المخزون"
      subtitle={code ? `${name} · ${code.code}` : undefined}
      icon={<Ban />}
      iconTone="danger"
      footer={
        <>
          <Button
            variant="danger"
            size="lg"
            loading={action.busy}
            disabled={!reason.trim()}
            onClick={async () => {
              if (!code) return;
              const done = await action.run("POST", `/v1/vouchers/admin/stock/${code.id}/void`, { reason: reason.trim() });
              if (done) close();
            }}
          >
            ألغِ الكود
          </Button>
          <Button size="lg" onClick={close} disabled={action.busy}>
            تراجع
          </Button>
        </>
      }
    >
      <div className="form">
        <p className="muted">الكود الملغى لا يُباع أبداً ويبقى في السجل. استعمله لكود أُدخل خطأً أو لا يعمل عند الشحن.</p>
        <Field label="السبب" htmlFor="void-reason">
          <input id="void-reason" className="input" value={reason} onChange={(e) => setReason(e.target.value)} maxLength={300} autoFocus />
        </Field>
        <PasskeyHint />
      </div>
    </Dialog>
  );
}
