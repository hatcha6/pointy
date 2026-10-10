import { useMemo, useState } from "react";
import { ArrowDownLeft, ArrowUpRight, Ban, Copy, Download, NotebookPen, Paperclip, Repeat, Search } from "lucide-react";
import { Button, Card, Empty, Field, Money, Segmented, Switch, Tabs } from "../components/ui";
import { AttachmentStrip } from "../components/finance/Attachments";
import { DueStrip, RecurringList } from "../components/finance/Recurring";
import { describeError } from "../lib/errors";
import { useToast } from "../components/toast";
import { DataTable, Stacked, type Column } from "../components/DataTable";
import { Dialog } from "../components/dialog";
import { PasskeyHint, useAction } from "../components/guarded";
import { Link, useSearchParam, useSetSearch } from "../lib/router";
import { dateTime, money } from "../lib/format";
import { matches } from "../lib/search";
import {
  categoryOf,
  expenseCategories,
  financeKeys,
  incomeCategories,
  monthLabel,
  shortDay,
  uploadAttachment,
  useFinanceEntries,
  useRecurring,
  type FinanceEntry,
} from "../lib/finance";
import { PeriodPicker, useEntryDialog, usePeriod } from "./Finance";

function signed(entry: FinanceEntry) {
  return entry.direction === "income" ? Number(entry.amount) : -Number(entry.amount);
}

/** What the next line copied from this one starts with: everything but the day. */
function draftFrom(entry: FinanceEntry) {
  const { direction, category, original_amount, currency, rate, counterparty, note, installation_id, reference } = entry;
  return { direction, category, original_amount, currency, rate, counterparty, note, installation_id, reference };
}

function exportCsv(entries: FinanceEntry[], from: string, to: string) {
  const header = ["التاريخ", "النوع", "الفئة", "المبلغ (د.ل)", "العملة", "المبلغ الأصلي", "السعر", "الوصف", "الجهة", "المتجر", "المرجع", "سجّله", "ملغى", "سبب الإلغاء"];
  const rows = entries.map((e) => [
    e.occurred_on,
    e.direction === "income" ? "دخل" : "مصروف",
    categoryOf(e.direction, e.category).label,
    e.amount,
    e.currency,
    e.original_amount,
    e.rate,
    e.note ?? "",
    e.counterparty ?? "",
    e.shop_name || e.installation_id || "",
    e.reference ?? "",
    e.actor ?? "",
    e.voided_at ? "نعم" : "",
    e.void_reason ?? "",
  ]);
  const cell = (v: string) => (/[",\n]/.test(v) ? `"${v.replace(/"/g, '""')}"` : v);
  const text = "﻿" + [header, ...rows].map((r) => r.map((v) => cell(String(v))).join(",")).join("\n");
  const url = URL.createObjectURL(new Blob([text], { type: "text/csv;charset=utf-8" }));
  const a = document.createElement("a");
  a.href = url;
  a.download = `daftar-books-${from}-${to}.csv`;
  a.click();
  URL.revokeObjectURL(url);
}

export function Ledger() {
  const period = usePeriod();
  const { from, to } = period.range;
  const [direction] = useSearchParam("direction");
  const [category, setCategory] = useSearchParam("category");
  const [shop, setShop] = useSearchParam("shop");
  const setSearch = useSetSearch();
  const [query, setQuery] = useState("");
  const [showVoided, setShowVoided] = useState(false);
  const [open, setOpen] = useState<FinanceEntry | null>(null);
  const [voiding, setVoiding] = useState<FinanceEntry | null>(null);
  const entry = useEntryDialog();
  const [tab, setTab] = useSearchParam("tab");
  const recurring = useRecurring();
  const monthlyCount = recurring.data?.recurring.filter((r) => r.active).length ?? 0;

  const entries = useFinanceEntries({ from, to, direction, category, installation_id: shop, include_voided: showVoided ? "1" : "" });
  const rows = useMemo(
    () =>
      (entries.data ?? []).filter((e) =>
        matches(query, e.note, e.counterparty, e.shop_name, e.reference, e.actor, categoryOf(e.direction, e.category).label, e.amount),
      ),
    [entries.data, query],
  );
  const live = rows.filter((e) => !e.voided_at);
  const income = live.filter((e) => e.direction === "income").reduce((s, e) => s + Number(e.amount), 0);
  const expense = live.filter((e) => e.direction === "expense").reduce((s, e) => s + Number(e.amount), 0);
  const categories = direction === "income" ? incomeCategories : direction === "expense" ? expenseCategories : [...expenseCategories, ...incomeCategories];

  const columns: Column<FinanceEntry>[] = [
    {
      key: "day",
      header: "التاريخ",
      mobile: "subtitle",
      cell: (e) => <span className="num">{shortDay(e.occurred_on)}</span>,
    },
    {
      key: "what",
      header: "البند",
      mobile: "title",
      cell: (e) => {
        const c = categoryOf(e.direction, e.category);
        const Icon = c.icon;
        return (
          <div className={`ledger-what ${e.voided_at ? "voided" : ""}`}>
            <span className={`l-icon ${e.direction}`}>
              <Icon />
            </span>
            <Stacked
              title={
                <span className="inline-icons">
                  {c.label}
                  {e.recurring_id && <Repeat width={13} className="faint" aria-label="شهري" />}
                  {!!e.attachments?.length && <Paperclip width={13} className="faint" aria-label="عليه إيصال" />}
                </span>
              }
              sub={e.note || (e.recurring_month ? `شهر ${monthLabel(e.recurring_month)}` : undefined)}
            />
          </div>
        );
      },
    },
    {
      key: "party",
      header: "الجهة",
      cell: (e) =>
        e.installation_id ? (
          <Link to={`/shops/${encodeURIComponent(e.installation_id)}`} onClick={(ev) => ev.stopPropagation()}>
            {e.shop_name || e.installation_id}
          </Link>
        ) : (
          e.counterparty || <span className="faint">—</span>
        ),
    },
    {
      key: "amount",
      header: "المبلغ",
      align: "end",
      mobile: "trailing",
      cell: (e) => (
        <div className={`ledger-amount ${e.voided_at ? "voided" : ""}`}>
          <Money value={signed(e)} signed />
          {e.currency !== "LYD" && <span className="faint">{money(e.original_amount, e.currency)}</span>}
          {e.voided_at && <span className="badge neutral">ملغى</span>}
        </div>
      ),
    },
    { key: "actor", header: "سجّله", wideOnly: true, cell: (e) => <span className="muted">{e.actor || "—"}</span> },
    {
      key: "actions",
      header: "",
      mobile: "actions",
      align: "end",
      cell: (e) => (
        <div className="row-actions">
          <Button size="sm" variant="ghost" icon={<Copy />} title="سطر جديد مثله" aria-label="سطر جديد مثله" onClick={() => entry.open(draftFrom(e))} />
          {!e.voided_at && (
            <Button size="sm" variant="ghost" className="danger" icon={<Ban />} title="إلغاء القيد" aria-label="إلغاء القيد" onClick={() => setVoiding(e)} />
          )}
        </div>
      ),
    },
  ];

  return (
    <div className="fin">
      <div className="page-head">
        <div className="titles">
          <h1>دفتر الحسابات</h1>
          <p>ما سجّلته بيدك من دخل ومصروف. لا يُحذف قيد: الخطأ يُلغى بسببه ويُسجَّل من جديد.</p>
        </div>
        <div className="actions">
          <Button icon={<Download />} disabled={!rows.length} onClick={() => exportCsv(rows, from, to)}>
            تصدير
          </Button>
          <Button icon={<ArrowDownLeft />} onClick={() => entry.open({ direction: "income" })}>
            دخل
          </Button>
          <Button variant="primary" icon={<ArrowUpRight />} onClick={() => entry.open({ direction: "expense" })}>
            مصروف
          </Button>
        </div>
      </div>

      <Tabs
        value={tab === "monthly" ? "monthly" : "entries"}
        onChange={(next) => setTab(next === "entries" ? "" : next)}
        tabs={[
          { id: "entries", label: "القيود", icon: <NotebookPen width={16} /> },
          { id: "monthly", label: "الشهرية", icon: <Repeat width={16} />, badge: monthlyCount ? <span className="badge">{monthlyCount}</span> : undefined },
        ]}
      />

      <DueStrip onConfirm={entry.open} />

      {tab === "monthly" ? (
        <RecurringList onConfirm={entry.open} onNew={() => entry.open({ direction: "expense" })} />
      ) : (
      <>
      <PeriodPicker period={period} />

      <Card tight>
        <div className="toolbar stacks">
          <Segmented
            value={direction}
            onChange={(next) => setSearch({ direction: next, category: "" })}
            options={[
              { id: "", label: "الكل" },
              { id: "expense", label: "المصروف" },
              { id: "income", label: "الدخل" },
            ]}
          />
          <select className="select toolbar-select" value={category} onChange={(e) => setCategory(e.target.value)} aria-label="الفئة">
            <option value="">كل الفئات</option>
            {categories.map((c) => (
              <option key={c.id} value={c.id}>
                {c.label}
              </option>
            ))}
          </select>
          <div className="search-input">
            <Search />
            <input className="input" placeholder="ابحث في الوصف أو الجهة…" value={query} onChange={(e) => setQuery(e.target.value)} />
          </div>
          {shop && (
            <button type="button" className="chip on" onClick={() => setShop("")} title="إزالة التصفية">
              {(entries.data ?? []).find((e) => e.installation_id === shop)?.shop_name || "متجر واحد"} ✕
            </button>
          )}
          <span className="spacer" />
          <label className="row muted" style={{ fontSize: 13 }}>
            <Switch on={showVoided} onChange={setShowVoided} label="إظهار الملغاة" />
            الملغاة
          </label>
        </div>
        {live.length > 0 && (
          <div className="ledger-totals">
            <span>
              الدخل <Money value={income} />
            </span>
            <span>
              المصروف <Money value={expense} />
            </span>
            <span>
              الصافي <Money value={income - expense} signed />
            </span>
            <span className="muted">{live.length} قيد</span>
          </div>
        )}
        <DataTable
          rows={rows}
          columns={columns}
          rowKey={(e) => e.id}
          loading={entries.isLoading}
          onRowClick={setOpen}
          empty={
            <Empty title={query || category || direction || shop ? "لا قيود تطابق البحث" : "لا قيود في هذه الفترة"}>
              <div className="row" style={{ justifyContent: "center" }}>
                <Button size="sm" variant="primary" icon={<ArrowUpRight />} onClick={() => entry.open({ direction: "expense" })}>
                  سجّل مصروفاً
                </Button>
                <Button size="sm" icon={<ArrowDownLeft />} onClick={() => entry.open({ direction: "income" })}>
                  سجّل دخلاً
                </Button>
              </div>
            </Empty>
          }
        />
      </Card>
      </>
      )}

      <EntryDetail
        entry={open}
        onClose={() => setOpen(null)}
        onCopy={(e) => {
          setOpen(null);
          entry.open(draftFrom(e));
        }}
        onVoid={(e) => {
          setOpen(null);
          setVoiding(e);
        }}
        onChanged={setOpen}
      />
      <VoidDialog entry={voiding} onClose={() => setVoiding(null)} />
      {entry.dialog}
    </div>
  );
}

function EntryDetail({ entry, onClose, onCopy, onVoid, onChanged }: {
  entry: FinanceEntry | null;
  onClose: () => void;
  onCopy: (e: FinanceEntry) => void;
  onVoid: (e: FinanceEntry) => void;
  onChanged: (e: FinanceEntry) => void;
}) {
  const attach = useAction<FinanceEntry>({ invalidate: [financeKeys.all], success: "أُرفق الإيصال." });
  const toast = useToast();
  const [uploading, setUploading] = useState(false);
  if (!entry) return null;
  async function addReceipt(file: File) {
    if (!entry) return;
    setUploading(true);
    try {
      const ref = await uploadAttachment(file);
      const updated = await attach.run("POST", `/v1/finance/entries/${encodeURIComponent(entry.id)}/attachments`, { sha256: ref.sha256, name: ref.name });
      if (updated) onChanged(updated);
    } catch (e) {
      toast.error(describeError(e).title);
    } finally {
      setUploading(false);
    }
  }
  const c = categoryOf(entry.direction, entry.category);
  const Icon = c.icon;
  const facts: [string, React.ReactNode][] = [
    ["التاريخ", shortDay(entry.occurred_on)],
    ["المبلغ", <Money key="m" value={entry.amount} />],
    ...(entry.currency !== "LYD"
      ? ([["دُفع", `${money(entry.original_amount, entry.currency)} × ${Number(entry.rate)}`]] as [string, React.ReactNode][])
      : []),
    ...(entry.counterparty ? ([[entry.direction === "income" ? "من دفع" : "لمن دُفع", entry.counterparty]] as [string, React.ReactNode][]) : []),
    ...(entry.installation_id
      ? ([["المتجر", <Link key="s" to={`/shops/${encodeURIComponent(entry.installation_id)}`}>{entry.shop_name || entry.installation_id}</Link>]] as [string, React.ReactNode][])
      : []),
    ...(entry.recurring_month ? ([["مصروف شهري", `عن ${monthLabel(entry.recurring_month, true)}`]] as [string, React.ReactNode][]) : []),
    ...(entry.reference ? ([["المرجع", <span key="r" className="mono">{entry.reference}</span>]] as [string, React.ReactNode][]) : []),
    ["سجّله", `${entry.actor || "—"} · ${dateTime(entry.created_at)}`],
  ];
  return (
    <Dialog
      open
      onClose={onClose}
      title={c.label}
      subtitle={entry.direction === "income" ? "دخل" : "مصروف"}
      icon={<Icon />}
      iconTone={entry.direction === "income" ? "money" : undefined}
      footer={
        <>
          <Button icon={<Copy />} onClick={() => onCopy(entry)}>
            سطر جديد مثله
          </Button>
          {!entry.voided_at && (
            <Button variant="ghost" className="danger" icon={<Ban />} onClick={() => onVoid(entry)}>
              إلغاء القيد
            </Button>
          )}
        </>
      }
    >
      {entry.voided_at && (
        <div className="notice warning" style={{ marginBottom: 14 }}>
          <Ban />
          <div>
            أُلغي {dateTime(entry.voided_at)} بيد {entry.voided_by || "—"}: {entry.void_reason}
          </div>
        </div>
      )}
      {entry.note && <p style={{ marginBottom: 14 }}>{entry.note}</p>}
      <dl className="facts">
        {facts.map(([k, v]) => (
          <div className="fact" key={k}>
            <dt>{k}</dt>
            <dd>{v}</dd>
          </div>
        ))}
      </dl>
      <div className="field" style={{ marginTop: 18 }}>
        <span className="field-label">الإيصالات</span>
        <AttachmentStrip attachments={entry.attachments ?? []} onAdd={addReceipt} adding={uploading || attach.busy} />
      </div>
    </Dialog>
  );
}

function VoidDialog({ entry, onClose }: { entry: FinanceEntry | null; onClose: () => void }) {
  const [reason, setReason] = useState("");
  const action = useAction({ passkey: true, invalidate: [financeKeys.all], success: "أُلغي القيد." });
  if (!entry) return null;
  async function submit() {
    if (!entry || !reason.trim()) return;
    const done = await action.run("POST", `/v1/finance/entries/${encodeURIComponent(entry.id)}/void`, { reason: reason.trim() });
    if (done !== undefined) {
      setReason("");
      onClose();
    }
  }
  return (
    <Dialog
      open
      onClose={onClose}
      busy={action.busy}
      dirty={!!reason.trim()}
      title="إلغاء قيد"
      subtitle={`${categoryOf(entry.direction, entry.category).label} · ${money(entry.amount)} · ${shortDay(entry.occurred_on)}`}
      icon={<Ban />}
      iconTone="danger"
      footer={
        <>
          <Button variant="danger" className="solid" size="lg" loading={action.busy} disabled={!reason.trim()} onClick={submit}>
            إلغاء القيد
          </Button>
          <Button size="lg" onClick={onClose} disabled={action.busy}>
            رجوع
          </Button>
        </>
      }
    >
      <div className="form">
        <p className="muted">يخرج القيد من الحساب ويبقى في الدفتر باسمك وسببك. إن كان المبلغ أو التاريخ خطأً، سجّله من جديد بعد الإلغاء.</p>
        <Field label="السبب">
          <input className="input" autoFocus value={reason} maxLength={300} onChange={(e) => setReason(e.target.value)} placeholder="مثلاً: سُجّل مرتين" onKeyDown={(e) => e.key === "Enter" && submit()} />
        </Field>
        <PasskeyHint />
        {action.error && <p className="error-text">{action.error}</p>}
      </div>
    </Dialog>
  );
}
