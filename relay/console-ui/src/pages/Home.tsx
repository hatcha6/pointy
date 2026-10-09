import { AlertTriangle, ArrowLeft, CalendarClock, CreditCard, Landmark, Store, Wallet as WalletIcon } from "lucide-react";
import { useConsoleAudit, useInstallations, useMe, usePurchases, useTopUps, useWallets } from "../lib/queries";
import { Link } from "../lib/router";
import { auditLabel } from "../lib/labels";
import { count, daysUntil, date } from "../lib/format";
import { Badge, Card, Empty, Money, Skeleton, TimeAgo } from "../components/ui";
import { isExpiring } from "./Shops";

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

  const shops = installations.data ?? [];
  const active = shops.filter((s) => s.subscription_active).length;
  const expiring = shops.filter(isExpiring).sort((a, b) => (daysUntil(a.subscription_ends_at) ?? 0) - (daysUntil(b.subscription_ends_at) ?? 0));
  const mainTotal = (wallets.data?.wallets ?? []).filter((w) => w.account === "main").reduce((sum, w) => sum + Number(w.balance || 0), 0);
  const stalePending = (pending.data ?? []).filter((t) => Date.now() - new Date(t.created_at).getTime() > 15 * 60_000);
  const transfers = [...(review.data ?? [])].reverse();
  const attention = transfers.length + stalePending.length + (held.data?.length ?? 0) + expiring.length;

  return (
    <>
      <div className="page-head">
        <div className="titles">
          <h1>
            {greeting()}، {me.data?.operator.name.split(" ")[0]}
          </h1>
          <p>{attention > 0 ? `${count(attention)} أمور تحتاج انتباهك.` : "كل شيء على ما يرام."}</p>
        </div>
      </div>

      <div className="grid kpis" style={{ marginBottom: 16 }}>
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

      <div className="grid two">
        <Card tight title="يحتاج انتباهك" hint={attention ? count(attention) : undefined}>
          <div className="timeline">
            {transfers.slice(0, 8).map((t) => (
              <Link key={t.id} to={`/topups/${encodeURIComponent(t.id)}`} className="timeline-item" style={{ color: "inherit", textDecoration: "none" }}>
                <div className="t-icon money">
                  <Landmark />
                </div>
                <div className="t-body">
                  <strong>
                    تحويل مصرفي <Money value={t.amount} /> بانتظار التحقق
                  </strong>
                  <div className="t-meta">
                    {t.shop_name} · <TimeAgo value={t.created_at} />
                  </div>
                </div>
                <Badge tone="info">تحقّق</Badge>
              </Link>
            ))}
            {(held.data ?? []).slice(0, 5).map((p) => (
              <Link key={p.id} to="/purchases?held=1" className="timeline-item" style={{ color: "inherit", textDecoration: "none" }}>
                <div className="t-icon money">
                  <CreditCard />
                </div>
                <div className="t-body">
                  <strong>
                    {p.name} · <Money value={p.amount} />
                  </strong>
                  <div className="t-meta">
                    {p.shop_name} · معلّقة <TimeAgo value={p.held_since ?? p.created_at} />
                  </div>
                </div>
                <ArrowLeft width={16} className="faint" />
              </Link>
            ))}
            {stalePending.slice(0, 5).map((t) => (
              <Link key={t.id} to="/topups?status=pending" className="timeline-item" style={{ color: "inherit", textDecoration: "none" }}>
                <div className="t-icon money">
                  <WalletIcon />
                </div>
                <div className="t-body">
                  <strong>
                    شحن <Money value={t.amount} /> لم يكتمل
                  </strong>
                  <div className="t-meta">
                    {t.shop_name} · بدأ <TimeAgo value={t.created_at} />
                  </div>
                </div>
                <ArrowLeft width={16} className="faint" />
              </Link>
            ))}
            {expiring.slice(0, 6).map((s) => (
              <Link key={s.id} to={`/shops/${encodeURIComponent(s.id)}?do=extend`} className="timeline-item" style={{ color: "inherit", textDecoration: "none" }}>
                <div className="t-icon">
                  <CalendarClock />
                </div>
                <div className="t-body">
                  <strong>{s.shop_name}</strong>
                  <div className="t-meta">
                    الاشتراك {(daysUntil(s.subscription_ends_at) ?? 0) < 0 ? "انتهى" : "ينتهي"} {date(s.subscription_ends_at)}
                  </div>
                </div>
                <Badge tone="warning">تمديد</Badge>
              </Link>
            ))}
            {attention === 0 && <Empty icon={<AlertTriangle />} title="لا شيء ينتظرك" />}
          </div>
        </Card>

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
    </>
  );
}
