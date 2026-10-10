import { useState } from "react";
import { ArrowDownLeft, ArrowLeft, ArrowUpRight, CalendarClock, CheckCircle2, CreditCard, Landmark, PlusCircle, Store, TrendingUp, Wallet as WalletIcon } from "lucide-react";
import { InboxRow, useInbox } from "../components/Inbox";
import { useConsoleAudit, useInstallations, useMe, usePurchases, useTopUps, useWallets } from "../lib/queries";
import { Link } from "../lib/router";
import { auditLabel } from "../lib/labels";
import { count } from "../lib/format";
import { Button, Card, Empty, Money, Skeleton, TimeAgo } from "../components/ui";
import { Delta } from "../components/finance/charts";
import { change, periodRange, useFinanceSummary } from "../lib/finance";
import { draftForMonth } from "../components/finance/Recurring";
import { useEntryDialog } from "./Finance";
import { openPalette } from "../components/CommandPalette";

function greeting(): string {
  const hour = new Date().getHours();
  if (hour < 12) return "صباح الخير";
  if (hour < 18) return "مساء الخير";
  return "مساء النور";
}

export function Home() {
  const me = useMe();
  const installations = useInstallations();
  const wallets = useWallets();
  const pending = useTopUps({ status: "pending" });
  const review = useTopUps({ status: "review" });
  const recentPaid = useTopUps({ status: "paid" });
  const held = usePurchases({ held: "1" });
  const audit = useConsoleAudit({});
  const month = periodRange("month");
  const finance = useFinanceSummary(month.from, month.to);
  const entry = useEntryDialog();
  const net = Number(finance.data?.totals.net ?? 0);

  const shops = installations.data ?? [];
  const active = shops.filter((s) => s.subscription_active).length;
  const mainTotal = (wallets.data?.wallets ?? []).filter((w) => w.account === "main").reduce((sum, w) => sum + Number(w.balance || 0), 0);
  const stalePending = (pending.data ?? []).filter((t) => Date.now() - new Date(t.created_at).getTime() > 15 * 60_000);
  const transfers = [...(review.data ?? [])].reverse();
  const inbox = useInbox();
  const [showAll, setShowAll] = useState(false);
  const urgentCount = inbox.items.filter((i) => i.level === "urgent").length;

  return (
    <>
      <div className="page-head">
        <div className="titles">
          <h1>
            {greeting()}، {me.data?.operator.name.split(" ")[0]}
          </h1>
          <p>
            {inbox.items.length === 0
              ? "كل شيء على ما يرام."
              : urgentCount
                ? `${count(urgentCount)} ${urgentCount === 1 ? "أمر عاجل" : "أمور عاجلة"} و${count(inbox.items.length - urgentCount)} غيرها تنتظرك.`
                : `${count(inbox.items.length)} ${inbox.items.length === 1 ? "أمر ينتظرك" : "أمور تنتظرك"}.`}
          </p>
        </div>
      </div>

      <div className="quick-actions" style={{ marginBottom: 16 }}>
        <Button variant="primary" icon={<ArrowUpRight />} onClick={() => entry.open({ direction: "expense" })}>
          سجّل مصروفاً
        </Button>
        <Button icon={<ArrowDownLeft />} onClick={() => entry.open({ direction: "income" })}>
          سجّل دخلاً
        </Button>
        <Button icon={<PlusCircle />} onClick={() => openPalette("credit")}>
          رصيد لمتجر
        </Button>
        <Button icon={<CalendarClock />} onClick={() => openPalette("extend")}>
          تمديد اشتراك
        </Button>
      </div>

      <div className="grid kpis" style={{ marginBottom: 16 }}>
        <Link to="/finance" className="card kpi kpi-link">
          <div className="kpi-label">
            <TrendingUp /> {net < 0 ? "خسارة هذا الشهر" : "ربح هذا الشهر"}
          </div>
          <div className={`kpi-value ${net > 0 ? "positive" : net < 0 ? "negative" : ""}`}>
            {finance.isLoading ? <Skeleton height={30} width={120} /> : finance.data ? <Money value={Math.abs(net)} /> : "—"}
          </div>
          <div className="kpi-foot">
            {finance.data ? <Delta value={change(finance.data.totals.net, finance.data.previous.totals.net)} suffix="عن الشهر الماضي" /> : "الدخل ناقص المصروف"}
          </div>
        </Link>
        <Link to="/shops" className="card kpi kpi-link">
          <div className="kpi-label">
            <Store /> المتاجر الفعّالة
          </div>
          <div className="kpi-value">{installations.isLoading ? <Skeleton height={30} width={80} /> : count(active)}</div>
          <div className="kpi-foot">من أصل {count(shops.length)}</div>
        </Link>
        <div className="card kpi money">
          <div className="kpi-label">
            <WalletIcon /> أرصدة المحافظ
          </div>
          <div className="kpi-value">{wallets.isLoading ? <Skeleton height={30} width={120} /> : <Money value={mainTotal} />}</div>
          <div className="kpi-foot">مجموع المحافظ الرئيسية</div>
        </div>
        <Link
          to={transfers.length ? "/topups?status=review" : "/topups?status=pending"}
          className={`card kpi kpi-link ${transfers.length || stalePending.length ? "attention" : ""}`}
        >
          <div className="kpi-label">
            <Landmark /> تحويلات للتحقق
          </div>
          <div className="kpi-value">{count(transfers.length)}</div>
          <div className="kpi-foot">
            {count(pending.data?.length ?? 0)} شحن قيد الدفع
            {stalePending.length ? ` · ${count(stalePending.length)} أقدم من 15 دقيقة` : ""}
          </div>
        </Link>
        <Link to="/purchases?held=1" className={`card kpi kpi-link ${held.data?.length ? "attention" : ""}`}>
          <div className="kpi-label">
            <CreditCard /> عمليات معلّقة
          </div>
          <div className="kpi-value">{count(held.data?.length ?? 0)}</div>
          <div className="kpi-foot">بطاقات وشحن وفواتير تنتظر تسوية</div>
        </Link>
      </div>

      <div className="grid two columns">
        <Card tight title="يحتاج انتباهك" hint={inbox.items.length ? count(inbox.items.length) : undefined} className="inbox-card">
          <div className="timeline">
            {inbox.items.slice(0, showAll ? undefined : 9).map((item) => (
              <InboxRow key={item.id} item={item} onOpen={(i) => i.recurring && entry.open(draftForMonth(i.recurring.recurring, i.recurring.month))} />
            ))}
            {inbox.items.length > 9 && (
              <button type="button" className="inbox-more" onClick={() => setShowAll(!showAll)}>
                {showAll ? "أقل" : `${inbox.items.length - 9} غيرها`}
              </button>
            )}
            {!inbox.loading && inbox.items.length === 0 && (
              <Empty icon={<CheckCircle2 />} title="لا شيء ينتظرك">
                التحويلات والتحديثات والأرصدة والفواتير كلها على ما يرام.
              </Empty>
            )}
          </div>
        </Card>

        <div className="stack">
          <Card tight title="آخر الشحنات المدفوعة" actions={<Link to="/topups">الكل</Link>}>
            <div className="timeline">
              {(recentPaid.data ?? []).slice(0, 7).map((t) => (
                <Link key={t.id} to={`/shops/${encodeURIComponent(t.installation_id)}?tab=topups`} className="timeline-item" style={{ color: "inherit", textDecoration: "none" }}>
                  <div className="t-icon money">
                    <WalletIcon />
                  </div>
                  <div className="t-body">
                    <strong>{t.shop_name || t.installation_id}</strong>
                    <div className="t-meta">
                      <TimeAgo value={t.paid_at ?? t.updated_at} />
                    </div>
                  </div>
                  <Money value={t.amount} />
                </Link>
              ))}
              {!recentPaid.isLoading && (recentPaid.data ?? []).length === 0 && <Empty title="لا شحنات بعد" />}
            </div>
          </Card>

          <Card tight title="آخر العمليات من اللوحة" actions={<Link to="/activity">السجل</Link>}>
            <div className="timeline">
              {(audit.data ?? []).slice(0, 8).map((e) => (
                <div key={e.id} className="timeline-item">
                  <div className={`t-icon ${e.stepped_up ? "money" : ""}`}>
                    <ArrowLeft />
                  </div>
                  <div className="t-body">
                    <strong>{auditLabel(e.action, e.method, e.path)}</strong>
                    <div className="t-meta">
                      {e.operator_name} · <TimeAgo value={e.at} />
                    </div>
                  </div>
                </div>
              ))}
              {!audit.isLoading && (audit.data ?? []).length === 0 && <Empty title="لا عمليات بعد" />}
            </div>
          </Card>
        </div>
      </div>
      {entry.dialog}
    </>
  );
}
