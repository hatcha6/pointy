import type { ReactNode } from "react";
import { useQuery } from "@tanstack/react-query";
import { AlertTriangle, BellOff, CalendarClock, CircleDollarSign, CreditCard, Landmark, Rocket, Wallet as WalletIcon, WifiOff } from "lucide-react";
import { api } from "../lib/api";
import { useFleet, useInstallations, usePurchases, useTopUps } from "../lib/queries";
import { categoryOf, dueItems, monthLabel, useRecurring, type Recurring } from "../lib/finance";
import { agentQuiet, updateStatus } from "../lib/updates";
import { daysUntil, date } from "../lib/format";
import { isExpiring } from "../pages/Shops";
import { Link } from "../lib/router";
import { Badge, Money, TimeAgo } from "./ui";

// Everything that needs a person, from every corner of the console, in one
// list ordered by how much it costs to leave it: money stuck or at risk
// first, then what keeps shops running, then reminders. Home shows it; the
// rail shows how many are urgent.

export type InboxLevel = "urgent" | "money" | "soon" | "setup";

export type InboxItem = {
  id: string;
  level: InboxLevel;
  icon: ReactNode;
  title: ReactNode;
  meta?: ReactNode;
  cta?: string;
  to?: string;
  /** For items that open a dialog in place (a monthly bill). */
  recurring?: { recurring: Recurring; month: string };
};

type ActiveAlerts = { watching: boolean; alerts: { kind: string; source: string; since: string }[] };

const balanceNames: Record<string, string> = {
  reloadly: "Reloadly",
  bnplus_lyd: "BN Plus",
  openrouter: "OpenRouter (المساعد الذكي)",
  serper: "Serper (بحث الصور)",
};

const levelOrder: Record<InboxLevel, number> = { urgent: 0, money: 1, soon: 2, setup: 3 };

export function useInbox() {
  const installations = useInstallations();
  const pending = useTopUps({ status: "pending" });
  const review = useTopUps({ status: "review" });
  const held = usePurchases({ held: "1" });
  const fleet = useFleet();
  const recurring = useRecurring();
  const active = useQuery({ queryKey: ["alerts", "active"], queryFn: () => api.get<ActiveAlerts>("/v1/alerts/active"), refetchInterval: 120_000, retry: false });
  const voucherConfig = useQuery({ queryKey: ["vouchers", "config"], queryFn: () => api.get<{ reloadly: boolean }>("/v1/vouchers/admin/config"), staleTime: 300_000, retry: false });
  const pricing = useQuery({ queryKey: ["vouchers", "settings"], queryFn: () => api.get<{ priced: boolean }>("/v1/vouchers/admin/settings"), staleTime: 120_000, retry: false });

  const items: InboxItem[] = [];

  // Urgent: something is failing now.
  const fleetRows = fleet.data?.installations ?? [];
  const failed = fleetRows.filter((f) => ["failed", "rolled_back"].includes(updateStatus(f).state));
  if (failed.length) {
    items.push({
      id: "updates-failed",
      level: "urgent",
      icon: <Rocket />,
      title: failed.length === 1 ? `فشل التحديث في ${failed[0].shop_name || "متجر"}` : `فشل التحديث في ${failed.length} متاجر`,
      meta: "يعيد الوكيل المحاولة كل 30 دقيقة؛ أوقف النشر إن تكرر.",
      cta: "انظر",
      to: "/fleet?show=failed",
    });
  }
  for (const alert of active.data?.alerts ?? []) {
    const name = balanceNames[alert.source] ?? alert.source;
    items.push({
      id: `alert-${alert.kind}-${alert.source}`,
      level: alert.kind === "balance_low" ? "urgent" : "soon",
      icon: <CircleDollarSign />,
      title: alert.kind === "balance_low" ? `رصيد ${name} منخفض` : `تعذّرت قراءة رصيد ${name}`,
      meta: (
        <>
          {alert.kind === "balance_low" ? "اشحنه قبل أن تفشل المبيعات" : "تحقّق من حساب المورّد"} · منذ <TimeAgo value={alert.since} />
        </>
      ),
      cta: "الأرصدة",
      to: "/suppliers?tab=balances",
    });
  }
  if (voucherConfig.data?.reloadly && pricing.data && !pricing.data.priced) {
    items.push({
      id: "no-dollar-rate",
      level: "urgent",
      icon: <AlertTriangle />,
      title: "لا سعر دولار: Reloadly لا يبيع شيئاً",
      meta: "اضبط مصدر السعر أو سعراً يدوياً في التسعير.",
      cta: "التسعير",
      to: "/pricing",
    });
  }

  // Money waiting on a person.
  for (const t of [...(review.data ?? [])].reverse().slice(0, 8)) {
    items.push({
      id: `transfer-${t.id}`,
      level: "money",
      icon: <Landmark />,
      title: (
        <>
          تحويل مصرفي <Money value={t.amount} /> بانتظار التحقق
        </>
      ),
      meta: (
        <>
          {t.shop_name} · <TimeAgo value={t.created_at} />
        </>
      ),
      cta: "تحقّق",
      to: `/topups/${encodeURIComponent(t.id)}`,
    });
  }
  for (const p of (held.data ?? []).slice(0, 5)) {
    items.push({
      id: `held-${p.id}`,
      level: "money",
      icon: <CreditCard />,
      title: (
        <>
          {p.name} · <Money value={p.amount} /> معلّقة
        </>
      ),
      meta: (
        <>
          {p.shop_name} · منذ <TimeAgo value={p.held_since ?? p.created_at} />
        </>
      ),
      cta: "تسوية",
      to: "/purchases?held=1",
    });
  }
  const stale = (pending.data ?? []).filter((t) => Date.now() - new Date(t.created_at).getTime() > 15 * 60_000);
  for (const t of stale.slice(0, 5)) {
    items.push({
      id: `stale-${t.id}`,
      level: "money",
      icon: <WalletIcon />,
      title: (
        <>
          شحن <Money value={t.amount} /> لم يكتمل
        </>
      ),
      meta: (
        <>
          {t.shop_name} · بدأ <TimeAgo value={t.created_at} />
        </>
      ),
      cta: "راجع",
      to: "/topups?status=pending",
    });
  }

  // Soon: keeps shops running, or the books right.
  const quiet = fleetRows.filter((f) => agentQuiet(f));
  if (quiet.length) {
    items.push({
      id: "agents-quiet",
      level: "soon",
      icon: <WifiOff />,
      title: quiet.length === 1 ? `وكيل تحديث ${quiet[0].shop_name || "متجر"} لا يتصل` : `${quiet.length} وكلاء تحديث لا يتصلون`,
      meta: "الجهاز مطفأ أو بلا إنترنت، أو توقف الوكيل.",
      cta: "انظر",
      to: "/fleet?show=quiet",
    });
  }
  for (const due of dueItems(recurring.data?.recurring).slice(0, 4)) {
    items.push({
      id: `bill-${due.recurring.id}-${due.month}`,
      level: "soon",
      icon: <CalendarClock />,
      title: `${categoryOf(due.recurring.direction, due.recurring.category).label} — ${monthLabel(due.month)}`,
      meta: "مصروف شهري ينتظر تأكيد مبلغه",
      cta: "تأكيد",
      recurring: due,
    });
  }
  const expiring = (installations.data ?? []).filter(isExpiring).sort((a, b) => (daysUntil(a.subscription_ends_at) ?? 0) - (daysUntil(b.subscription_ends_at) ?? 0));
  for (const s of expiring.slice(0, 6)) {
    items.push({
      id: `expiring-${s.id}`,
      level: "soon",
      icon: <CalendarClock />,
      title: s.shop_name || "متجر",
      meta: `الاشتراك ${(daysUntil(s.subscription_ends_at) ?? 0) < 0 ? "انتهى" : "ينتهي"} ${date(s.subscription_ends_at)}`,
      cta: "تمديد",
      to: `/shops/${encodeURIComponent(s.id)}?do=extend`,
    });
  }

  // Setup: nothing is wrong, but something would go unseen.
  if (active.data && !active.data.watching) {
    items.push({
      id: "alerts-off",
      level: "setup",
      icon: <BellOff />,
      title: "قناة التنبيهات غير مضبوطة",
      meta: "لن تصلك تنبيهات الأرصدة المنخفضة على هاتفك، ولن تظهر هنا.",
      cta: "اضبطها",
      to: "/settings?section=alerts",
    });
  }

  items.sort((a, b) => levelOrder[a.level] - levelOrder[b.level]);
  const urgent = items.filter((i) => i.level === "urgent" || i.level === "money").length;
  return { items, urgent, loading: installations.isLoading || review.isLoading };
}

const levelBadge: Record<InboxLevel, { tone: "danger" | "money" | "warning" | "neutral"; label: string }> = {
  urgent: { tone: "danger", label: "عاجل" },
  money: { tone: "money", label: "مال" },
  soon: { tone: "warning", label: "قريباً" },
  setup: { tone: "neutral", label: "إعداد" },
};

/** One row of the inbox: a link, or a button for what opens in place. */
export function InboxRow({ item, onOpen }: { item: InboxItem; onOpen?: (item: InboxItem) => void }) {
  const body = (
    <>
      <div className={`t-icon level-${item.level}`}>{item.icon}</div>
      <div className="t-body">
        <strong>{item.title}</strong>
        {item.meta && <div className="t-meta">{item.meta}</div>}
      </div>
      {item.cta && <Badge tone={levelBadge[item.level].tone}>{item.cta}</Badge>}
    </>
  );
  if (item.to) {
    return (
      <Link to={item.to} className={`timeline-item inbox-row level-${item.level}`}>
        {body}
      </Link>
    );
  }
  return (
    <button type="button" className={`timeline-item inbox-row as-button level-${item.level}`} onClick={() => onOpen?.(item)}>
      {body}
    </button>
  );
}

export const inboxLevels = levelBadge;
