import { useState } from "react";
import { BadgeCheck, CreditCard, Landmark, RefreshCw, Receipt, Wallet as WalletIcon } from "lucide-react";
import { useRouter } from "../lib/router";
import { dateTime } from "../lib/format";
import {
  account as accountLabels,
  bankName,
  entryKind,
  label,
  method as methodLabels,
  purchaseKind,
  purchaseStatus,
  service as serviceLabels,
  supplier as supplierLabels,
  topUpStatus,
  transferChannel,
} from "../lib/labels";
import type { Purchase, TopUp, WalletEntry } from "../lib/types";
import { Badge, Button, Empty, Money, TimeAgo } from "./ui";
import { DataTable, Stacked, type Column } from "./DataTable";
import { useAction } from "./guarded";
import { useToast } from "./toast";
import { ConfirmTopUpDialog, ResolvePurchaseDialog } from "./money-dialogs";

function TestBadge({ on }: { on?: boolean }) {
  return on ? <Badge tone="warning">تجريبي</Badge> : null;
}

export function EntriesTable({ entries, loading }: { entries: WalletEntry[]; loading?: boolean }) {
  const columns: Column<WalletEntry>[] = [
    {
      key: "what",
      header: "الحركة",
      mobile: "title",
      cell: (e) => (
        <Stacked
          title={
            <>
              {label(entryKind, e.kind)}
              {e.service ? ` · ${label(serviceLabels, e.service)}` : ""} <TestBadge on={e.test_mode} />
            </>
          }
          sub={e.description}
        />
      ),
    },
    { key: "amount", header: "المبلغ", align: "end", mobile: "trailing", cell: (e) => <Money value={e.amount} signed /> },
    { key: "when", header: "الوقت", cell: (e) => <TimeAgo value={e.created_at} /> },
    { key: "account", header: "الحساب", cell: (e) => label(accountLabels, e.account) },
    { key: "after", header: "الرصيد بعدها", align: "end", cell: (e) => <Money value={e.balance_after} /> },
    { key: "actor", header: "بواسطة", wideOnly: true, cell: (e) => <span className="muted">{e.actor || "—"}</span> },
  ];
  return (
    <DataTable rows={entries} columns={columns} rowKey={(e) => e.id} loading={loading} empty={<Empty icon={<Receipt />} title="لا حركات بعد" />} />
  );
}

export function TopUpsTable({ topUps, loading, showShop = true }: { topUps: TopUp[]; loading?: boolean; showShop?: boolean }) {
  const { navigate } = useRouter();
  const toast = useToast();
  const [confirming, setConfirming] = useState<TopUp | null>(null);
  const [checking, setChecking] = useState<string | null>(null);
  const check = useAction<{ top_up: TopUp; applied?: boolean; dafa?: { is_paid?: boolean } }>({ invalidate: [["wallet"]] });

  async function runCheck(topUp: TopUp) {
    setChecking(topUp.id);
    const result = await check.run("POST", `/v1/wallet/admin/topups/${encodeURIComponent(topUp.id)}/check`);
    setChecking(null);
    if (!result) return;
    if (result.applied) toast.success("دفع تؤكد أنها مدفوعة، وأُضيفت للمحفظة.");
    else if (result.dafa?.is_paid) toast.success("مدفوعة ومضافة من قبل.");
    else toast.error("دفع لا تُظهرها مدفوعة بعد.", "إن رأيتها مدفوعة في لوحة دفع فاستخدم «تأكيد».");
  }

  const columns: Column<TopUp>[] = [
    ...(showShop
      ? [
          {
            key: "shop",
            header: "المتجر",
            mobile: "title",
            cell: (t: TopUp) => <Stacked title={t.shop_name || t.installation_id} sub={t.requested_by} />,
          } as Column<TopUp>,
        ]
      : []),
    {
      key: "amount",
      header: "المبلغ",
      align: "end",
      mobile: showShop ? "trailing" : "title",
      cell: (t) => <Money value={t.amount} />,
    },
    {
      key: "status",
      header: "الحالة",
      mobile: showShop ? "subtitle" : "trailing",
      cell: (t) => {
        const status = topUpStatus[t.status] ?? { label: t.status, tone: "neutral" as const };
        return (
          <div className="row" style={{ gap: 6 }}>
            <Badge tone={status.tone} dot>
              {status.label}
            </Badge>
            <TestBadge on={t.test_mode} />
          </div>
        );
      },
    },
    { key: "when", header: "الوقت", cell: (t) => <TimeAgo value={t.created_at} /> },
    {
      key: "method",
      header: "الطريقة",
      cell: (t) =>
        t.transfer ? (
          <Stacked title={`تحويل · ${label(transferChannel, t.transfer.channel)}`} sub={`${bankName(t.transfer.payer_bank)} ${t.transfer.payer_account}`} mono />
        ) : (
          <Stacked title={label(methodLabels, t.method)} sub={t.payer_hint} mono />
        ),
    },
    {
      key: "number",
      header: "الرقم",
      wideOnly: true,
      mobile: "meta",
      cell: (t) => (
        <span className="mono" title={dateTime(t.created_at)}>
          {t.invoice_no || t.id.slice(0, 8)}
        </span>
      ),
    },
    {
      key: "detail",
      header: "ملاحظة",
      mobile: "subtitle",
      wideOnly: true,
      cell: (t) =>
        t.error_detail ? (
          <span className="faint">{t.error_detail}</span>
        ) : t.confirmed_by ? (
          <span className="faint">أكّده {t.confirmed_by.replace(/^operator:/, "")}</span>
        ) : null,
    },
    {
      key: "actions",
      header: "",
      mobile: "actions",
      cell: (t) =>
        t.status === "review" ? (
          <Button size="sm" variant="money" icon={<Landmark />} onClick={() => navigate(`/topups/${encodeURIComponent(t.id)}`)}>
            تحقّق
          </Button>
        ) : !t.transfer && (t.status === "pending" || t.status === "failed" || t.status === "expired") ? (
          <div className="row">
            <Button size="sm" icon={<RefreshCw />} loading={check.busy && checking === t.id} title="اسأل دفع عنها الآن" onClick={() => void runCheck(t)}>
              مراجعة
            </Button>
            <Button size="sm" variant="money" icon={<BadgeCheck />} onClick={() => setConfirming(t)}>
              تأكيد
            </Button>
          </div>
        ) : null,
    },
  ];
  return (
    <>
      <DataTable
        rows={topUps}
        columns={columns}
        rowKey={(t) => t.id}
        loading={loading}
        onRowClick={(t) => navigate(`/topups/${encodeURIComponent(t.id)}`)}
        empty={<Empty icon={<WalletIcon />} title="لا عمليات شحن هنا" />}
      />
      <ConfirmTopUpDialog topUp={confirming} onClose={() => setConfirming(null)} />
    </>
  );
}

export function PurchasesTable({ purchases, loading, showShop = true }: { purchases: Purchase[]; loading?: boolean; showShop?: boolean }) {
  const { navigate } = useRouter();
  const toast = useToast();
  const [resolving, setResolving] = useState<Purchase | null>(null);
  const [checking, setChecking] = useState<string | null>(null);
  const check = useAction<{ purchase: Purchase; verdict?: string; error?: string }>({ invalidate: [["vouchers"], ["wallet"]] });

  async function runCheck(p: Purchase) {
    setChecking(p.id);
    const result = await check.run("POST", `/v1/vouchers/admin/purchases/${encodeURIComponent(p.id)}/check`);
    setChecking(null);
    if (!result) return;
    if (result.error) toast.error("لم يُجب المورّد.", result.error);
    else toast.success(`حالتها الآن: ${purchaseStatus[result.purchase?.status]?.label ?? result.purchase?.status}`, result.verdict);
  }

  const columns: Column<Purchase>[] = [
    {
      key: "item",
      header: "الصنف",
      mobile: "title",
      cell: (p) => (
        <Stacked
          title={`${p.name}${p.quantity > 1 ? ` × ${p.quantity}` : ""}`}
          sub={`${label(purchaseKind, p.kind)}${p.target ? ` · ${p.target}` : ""}`}
        />
      ),
    },
    { key: "amount", header: "المبلغ", align: "end", mobile: "trailing", cell: (p) => <Money value={p.amount} /> },
    {
      key: "status",
      header: "الحالة",
      mobile: "subtitle",
      cell: (p) => {
        const status = purchaseStatus[p.status] ?? { label: p.status, tone: "neutral" as const };
        return (
          <div className="row" style={{ gap: 6 }}>
            <Badge tone={p.held_since ? "warning" : status.tone} dot>
              {p.held_since ? "معلّقة" : status.label}
            </Badge>
            <TestBadge on={p.test_mode} />
          </div>
        );
      },
    },
    ...(showShop
      ? [{ key: "shop", header: "المتجر", cell: (p: Purchase) => <Stacked title={p.shop_name || p.installation_id} sub={p.requested_by} /> } as Column<Purchase>]
      : []),
    { key: "when", header: "الوقت", cell: (p) => <TimeAgo value={p.created_at} /> },
    {
      key: "supplier",
      header: "المورّد",
      cell: (p) => <Stacked title={label(supplierLabels, p.supplier)} sub={p.supplier_order_id} mono />,
    },
    {
      key: "detail",
      header: "ملاحظة",
      wideOnly: true,
      mobile: "subtitle",
      cell: (p) => (p.error_detail ? <span className="faint">{p.error_detail}</span> : null),
    },
    {
      key: "actions",
      header: "",
      mobile: "actions",
      cell: (p) =>
        p.status === "pending" ? (
          <div className="row">
            <Button size="sm" icon={<RefreshCw />} loading={check.busy && checking === p.id} title="اسأل المورّد الآن" onClick={() => void runCheck(p)}>
              مراجعة
            </Button>
            <Button size="sm" variant="money" onClick={() => setResolving(p)}>
              تسوية
            </Button>
          </div>
        ) : null,
    },
  ];
  return (
    <>
      <DataTable
        rows={purchases}
        columns={columns}
        rowKey={(p) => p.id}
        loading={loading}
        onRowClick={showShop ? (p) => navigate(`/shops/${encodeURIComponent(p.installation_id)}?tab=purchases`) : undefined}
        empty={<Empty icon={<CreditCard />} title="لا عمليات هنا" />}
      />
      <ResolvePurchaseDialog purchase={resolving} onClose={() => setResolving(null)} />
    </>
  );
}
