import { Search, Smartphone, Users, BellRing } from "lucide-react";
import { useRouter, useSearchParam } from "../../lib/router";
import { cardPlatform, useCardCustomers, useCardSummary, type CardCustomer } from "../../lib/cards";
import { count } from "../../lib/format";
import { label } from "../../lib/labels";
import { Badge, Button, Card, Empty, Money, Segmented, Skeleton, TimeAgo } from "../../components/ui";
import { DataTable, Stacked, type Column } from "../../components/DataTable";
import { Unavailable } from "../../components/Unavailable";
import { Phone } from "../../components/cards/Phone";

const PAGE = 50;

export function customerBadge(c: CardCustomer) {
  if (c.deleted_at) return <Badge>حذف حسابه</Badge>;
  if (c.blocked_at) return <Badge tone="danger">موقوف</Badge>;
  return null;
}

/** «دفتر كروت»'s customers: who signed in, who buys, who can be notified. */
export function Customers() {
  const { navigate } = useRouter();
  const [query, setQuery] = useSearchParam("q");
  const [segment, setSegment] = useSearchParam("segment");
  const [pageParam, setPage] = useSearchParam("page");
  const page = Math.max(0, Number(pageParam) || 0);
  const summary = useCardSummary();
  const customers = useCardCustomers({ q: query.trim(), segment, limit: String(PAGE), offset: String(page * PAGE) });
  const stats = summary.data?.stats;
  const total = customers.data?.total ?? 0;

  const columns: Column<CardCustomer>[] = [
    {
      key: "who",
      header: "الزبون",
      mobile: "title",
      cell: (c) => (
        <Stacked
          title={
            <span className="row" style={{ gap: 6 }}>
              {c.deleted_at ? <span className="muted">رقم محذوف</span> : <Phone value={c.phone} />} {customerBadge(c)}
            </span>
          }
          sub={<>انضم <TimeAgo value={c.created_at} /></>}
        />
      ),
    },
    {
      key: "orders",
      header: "الطلبات",
      mobile: "subtitle",
      cell: (c) => (c.orders ? `${count(c.delivered)} مُسلَّم من ${count(c.orders)}` : <span className="muted">لم يطلب بعد</span>),
    },
    { key: "spent", header: "اشترى بـ", align: "end", mobile: "trailing", cell: (c) => <Money value={c.spent} /> },
    { key: "credit", header: "الرصيد", align: "end", cell: (c) => (Number(c.credit) ? <Money value={c.credit} /> : <span className="muted">—</span>) },
    {
      key: "devices",
      header: "الأجهزة",
      cell: (c) =>
        c.devices ? (
          <span className="row" style={{ gap: 6 }}>
            {(c.platforms ?? "").split(",").filter(Boolean).map((p) => label(cardPlatform, p)).join("، ") || count(c.devices)}
            {c.push_devices > 0 && <BellRing width={14} aria-label="تصله الإشعارات" />}
          </span>
        ) : (
          <span className="muted">لا جهاز</span>
        ),
    },
    { key: "seen", header: "آخر ظهور", wideOnly: true, cell: (c) => <TimeAgo value={c.last_seen_at ?? c.last_sign_in_at} /> },
  ];

  return (
    <>
      <div className="page-head">
        <div className="titles">
          <h1>زبائن دفتر كروت</h1>
          <p>كل من دخل التطبيق برقم هاتفه: ما اشتراه ورصيده وأجهزته. افتح زبوناً لتعديل رصيده أو إيقافه أو مراسلته.</p>
        </div>
        <div className="actions">
          <Button icon={<BellRing />} onClick={() => navigate("/cards/notifications")}>
            إرسال إشعار
          </Button>
        </div>
      </div>

      {summary.isError ? (
        <Unavailable feature="customers" error={summary.error} onRetry={() => void summary.refetch()} />
      ) : (
        <div className="grid kpis">
          <Kpi label="الزبائن" value={stats ? count(stats.customers) : null} foot={stats ? `${count(stats.new_7d)} جديد هذا الأسبوع` : ""} />
          <Kpi label="نشطون (30 يوماً)" value={stats ? count(stats.active_30d) : null} foot={stats ? `${count(stats.orders_30d)} طلباً في 30 يوماً · ${count(stats.open_orders)} مفتوح` : ""} />
          <Kpi label="اشتروا" value={stats ? count(stats.buyers) : null} foot={stats ? <>بمجموع <Money value={stats.spent} /></> : ""} money />
          <Kpi
            label="أرصدة الزبائن"
            value={stats ? <Money value={stats.credit_owed} /> : null}
            foot={stats ? `${count(stats.with_push)} تصلهم الإشعارات · ${count(stats.blocked)} موقوف` : ""}
          />
        </div>
      )}

      <Card tight>
        <div className="toolbar stacks">
          <div className="search-input">
            <Search />
            <input
              className="input"
              placeholder="رقم الهاتف (091…) أو معرّف الزبون"
              value={query}
              onChange={(e) => {
                setQuery(e.target.value);
                setPage("");
              }}
            />
          </div>
          <Segmented
            value={segment}
            onChange={(v) => {
              setSegment(v);
              setPage("");
            }}
            options={[
              { id: "", label: "الحسابات" },
              { id: "buyers", label: "اشتروا" },
              { id: "blocked", label: "موقوفون" },
              { id: "deleted", label: "حذفوا حساباتهم" },
            ]}
          />
        </div>
        {customers.isError ? (
          <Unavailable feature="customers" error={customers.error} onRetry={() => void customers.refetch()} />
        ) : (
          <DataTable
            rows={customers.data?.customers ?? []}
            columns={columns}
            rowKey={(c) => c.id}
            loading={customers.isLoading}
            onRowClick={(c) => navigate(`/cards/customers/${c.id}`)}
            empty={<Empty icon={<Users />} title={query ? "لا زبون بهذا الرقم" : "لا زبائن بعد"} />}
          />
        )}
        {total > PAGE && (
          <div className="row" style={{ justifyContent: "space-between", padding: "12px 16px" }}>
            <span className="muted">
              {count(page * PAGE + 1)}–{count(Math.min(total, (page + 1) * PAGE))} من {count(total)}
            </span>
            <div className="row">
              <Button size="sm" disabled={page === 0} onClick={() => setPage(page > 1 ? String(page - 1) : "")}>
                السابق
              </Button>
              <Button size="sm" disabled={(page + 1) * PAGE >= total} onClick={() => setPage(String(page + 1))}>
                التالي
              </Button>
            </div>
          </div>
        )}
      </Card>
      {!summary.isLoading && summary.data && !summary.data.push_configured && (
        <p className="muted" style={{ marginTop: 12 }}>
          <Smartphone width={14} /> الإشعارات غير مفعّلة على الخادم بعد: تحتاج مفتاح حساب الخدمة من Firebase.
        </p>
      )}
    </>
  );
}

export function Kpi({ label: name, value, foot, money }: { label: string; value: React.ReactNode | null; foot?: React.ReactNode; money?: boolean }) {
  return (
    <div className={`card kpi ${money ? "money" : ""}`}>
      <div className="kpi-label">{name}</div>
      <div className="kpi-value">{value ?? <Skeleton height={28} width={70} />}</div>
      {foot ? <div className="kpi-foot">{foot}</div> : null}
    </div>
  );
}
