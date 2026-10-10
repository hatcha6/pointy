import { useMemo, useState, type ReactNode } from "react";
import { Activity, ArrowDownLeft, CalendarCheck2, CreditCard, Landmark, NotebookPen, RotateCcw, Wallet as WalletIcon } from "lucide-react";
import { useConsoleAudit, useEntries, useInstallationAudit, usePurchases, useTopUps } from "../../lib/queries";
import { auditLabel, entryKind, label, purchaseStatus, service as serviceLabels, topUpStatus } from "../../lib/labels";
import { dateTime } from "../../lib/format";
import { categoryOf, useFinanceEntries } from "../../lib/finance";
import { Link } from "../../lib/router";
import { Badge, Card, Empty, Money, Segmented, Skeleton } from "../../components/ui";

// Everything that happened to one shop, newest first, in one list: money in
// and out of its wallet, its top-ups and purchases, subscription changes, what
// operators did to it, and what it paid us in cash. Each source is read once;
// what two sources both record (a paid top-up and its wallet credit, a card
// sale and its charge) is shown once.

type Kind = "money" | "subscription" | "cards" | "books" | "console";

type Event = {
  id: string;
  at: string;
  kind: Kind;
  icon: ReactNode;
  tone?: "money" | "danger";
  title: ReactNode;
  meta: ReactNode;
  amount?: { value: string | number; signed?: boolean };
  to?: string;
};

const PAGE = 40;

const dayFormat = new Intl.DateTimeFormat("ar-LY-u-nu-latn", { weekday: "long", day: "numeric", month: "long", year: "numeric" });

function dayOf(at: string): string {
  const d = new Date(at);
  return Number.isNaN(d.getTime()) ? "" : dayFormat.format(d);
}

export function ShopTimeline({ id }: { id: string }) {
  const [kind, setKind] = useState<"" | Kind>("");
  const [limit, setLimit] = useState(PAGE);
  const audit = useInstallationAudit(id);
  const fromConsole = useConsoleAudit({ q: id });
  const entries = useEntries(id);
  const topUps = useTopUps({ installation_id: id });
  const purchases = usePurchases({ installation_id: id });
  const books = useFinanceEntries({ installation_id: id, include_voided: "" });
  const loading = audit.isLoading || entries.isLoading || topUps.isLoading;

  const events = useMemo(() => {
    const out: Event[] = [];
    for (const e of entries.data ?? []) {
      // A paid top-up and a card sale have their own rows below.
      if (e.kind === "topup" || (e.kind === "charge" && e.service === "vouchers")) continue;
      const credit = Number(e.amount) > 0;
      out.push({
        id: "entry:" + e.id,
        at: e.created_at,
        kind: "money",
        icon: e.kind === "refund" ? <RotateCcw /> : <WalletIcon />,
        tone: "money",
        title: `${label(entryKind, e.kind)}${e.service ? ` · ${label(serviceLabels, e.service)}` : ""}`,
        meta: [e.description, e.actor].filter(Boolean).join(" · ") || "—",
        amount: { value: e.amount, signed: true },
        to: `/shops/${encodeURIComponent(id)}?tab=wallet`,
      });
      void credit;
    }
    for (const t of topUps.data ?? []) {
      const s = topUpStatus[t.status] ?? { label: t.status, tone: "neutral" as const };
      out.push({
        id: "topup:" + t.id,
        at: t.paid_at ?? t.created_at,
        kind: "money",
        icon: t.transfer ? <Landmark /> : <ArrowDownLeft />,
        tone: "money",
        title: (
          <>
            {t.transfer ? "تحويل مصرفي" : "شحن المحفظة"} <Badge tone={s.tone}>{s.label}</Badge>
          </>
        ),
        meta: t.invoice_no || t.id.slice(0, 8),
        amount: { value: t.amount },
        to: `/topups/${encodeURIComponent(t.id)}`,
      });
    }
    for (const p of purchases.data ?? []) {
      const s = purchaseStatus[p.status] ?? { label: p.status, tone: "neutral" as const };
      out.push({
        id: "purchase:" + p.id,
        at: p.created_at,
        kind: "cards",
        icon: <CreditCard />,
        title: (
          <>
            {p.name} <Badge tone={s.tone}>{s.label}</Badge>
          </>
        ),
        meta: p.target || p.supplier,
        amount: { value: p.amount },
        to: `/shops/${encodeURIComponent(id)}?tab=purchases`,
      });
    }
    for (const a of audit.data ?? []) {
      out.push({
        id: "audit:" + a.id,
        at: a.created_at,
        kind: "subscription",
        icon: <CalendarCheck2 />,
        title: a.reason || a.action,
        meta: a.actor || "—",
      });
    }
    for (const b of books.data ?? []) {
      out.push({
        id: "book:" + b.id,
        at: b.occurred_on + "T12:00:00Z",
        kind: "books",
        icon: <NotebookPen />,
        title: `${categoryOf(b.direction, b.category).label}${b.voided_at ? " (ملغى)" : ""}`,
        meta: [b.note, b.actor].filter(Boolean).join(" · ") || "دفتر الشركة",
        amount: { value: b.direction === "income" ? b.amount : -Number(b.amount), signed: true },
      });
    }
    for (const c of fromConsole.data ?? []) {
      // Money the console moved is already above, from its own record.
      if (/^\/v1\/(wallet|finance)\//.test(c.path) && c.method !== "GET") continue;
      out.push({
        id: "console:" + c.id,
        at: c.at,
        kind: "console",
        icon: <Activity />,
        tone: c.status >= 400 ? "danger" : undefined,
        title: auditLabel(c.action, c.method, c.path),
        meta: `${c.operator_name}${c.status >= 400 ? ` · رُفضت (${c.status})` : ""}`,
      });
    }
    return out.sort((a, b) => b.at.localeCompare(a.at));
  }, [entries.data, topUps.data, purchases.data, audit.data, books.data, fromConsole.data, id]);

  const shown = events.filter((e) => !kind || e.kind === kind);
  let lastDay = "";
  return (
    <Card tight>
      <div className="toolbar stacks">
        <Segmented
          value={kind}
          onChange={(k) => {
            setKind(k);
            setLimit(PAGE);
          }}
          options={[
            { id: "", label: "كل ما حدث" },
            { id: "money", label: "المال" },
            { id: "cards", label: "البطاقات" },
            { id: "subscription", label: "الاشتراك" },
            { id: "books", label: "الدفتر" },
            { id: "console", label: "من اللوحة" },
          ]}
        />
      </div>
      <div className="timeline shop-timeline">
        {loading && (
          <div className="card-body">
            <Skeleton height={160} />
          </div>
        )}
        {shown.slice(0, limit).map((e) => {
          const day = dayOf(e.at);
          const header = day !== lastDay ? <div className="timeline-day">{day}</div> : null;
          lastDay = day;
          const body = (
            <>
              <div className={`t-icon ${e.tone ?? ""}`}>{e.icon}</div>
              <div className="t-body">
                <strong>{e.title}</strong>
                <div className="t-meta">
                  {e.meta} · <time dateTime={e.at}>{dateTime(e.at)}</time>
                </div>
              </div>
              {e.amount && <Money value={e.amount.value} signed={e.amount.signed} />}
            </>
          );
          return (
            <div key={e.id} style={{ display: "contents" }}>
              {header}
              {e.to ? (
                <Link to={e.to} className="timeline-item inbox-row">
                  {body}
                </Link>
              ) : (
                <div className="timeline-item">{body}</div>
              )}
            </div>
          );
        })}
        {!loading && shown.length === 0 && <Empty title="لا شيء هنا بعد" />}
        {shown.length > limit && (
          <button type="button" className="inbox-more" onClick={() => setLimit(limit + PAGE)}>
            أقدم ({shown.length - limit})
          </button>
        )}
      </div>
    </Card>
  );
}
