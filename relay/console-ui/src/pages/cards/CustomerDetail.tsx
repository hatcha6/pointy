import { useState } from "react";
import { Ban, BellRing, UserRound, ChevronLeft, CreditCard, History, LogOut, MonitorSmartphone, ReceiptText, ShieldCheck, Trash2, Wallet as WalletIcon } from "lucide-react";
import { Link, useRouter, useSearchParam } from "../../lib/router";
import { cardAudience, cardCreditKind, cardPlatform, useCardCustomer, type CardCreditEntry, type CardDevice, type CardNotification } from "../../lib/cards";
import { count, date } from "../../lib/format";
import { label } from "../../lib/labels";
import { Badge, Button, Card, CopyText, Empty, Money, Skeleton, Tabs, TimeAgo } from "../../components/ui";
import { DataTable, Stacked, type Column } from "../../components/DataTable";
import { useAction } from "../../components/guarded";
import { CustomerBlockDialog, CustomerCreditDialog, CustomerDeleteDialog, CustomerNotifyDialog } from "../../components/cards/CustomerDialogs";
import { CardOrdersTable } from "./CustomerOrders";
import { customerBadge } from "./Customers";
import { Phone } from "../../components/cards/Phone";
import { cardKeys } from "../../lib/cards";

type Tab = "orders" | "credit" | "devices" | "notifications";
type Open = "credit" | "block" | "delete" | "notify" | null;

export function CustomerDetail({ id }: { id: string }) {
  const { navigate } = useRouter();
  const detail = useCardCustomer(id);
  const [tab, setTab] = useSearchParam("tab");
  const [open, setOpen] = useState<Open>(null);
  const current = (tab || "orders") as Tab;
  const signOut = useAction<{ signed_out: number }>({ invalidate: [cardKeys.all], success: "سُجِّل الخروج" });

  if (detail.isLoading) {
    return (
      <div className="stack">
        <Skeleton height={60} width={360} />
        <Skeleton height={120} />
        <Skeleton height={300} />
      </div>
    );
  }
  if (detail.isError || !detail.data) {
    return (
      <Card>
        <Empty title="لم نجد هذا الزبون">
          <Link to="/cards/customers">العودة إلى الزبائن</Link>
        </Empty>
      </Card>
    );
  }
  const { customer, sessions, credit, orders, notifications } = detail.data;
  const live = !customer.deleted_at;

  return (
    <>
      <div className="crumbs">
        <Link to="/cards/customers">زبائن دفتر كروت</Link>
        <ChevronLeft />
        <span>{live ? <Phone value={customer.phone} /> : "حساب محذوف"}</span>
      </div>
      <div className="page-head">
        <div className="shop-hero titles">
          <div className="shop-mark">
            <UserRound />
          </div>
          <div>
            <h1 className="row" style={{ gap: 8 }}>
              {live ? <Phone value={customer.phone} /> : "حساب محذوف"}
              {customerBadge(customer)}
            </h1>
            <div className="row" style={{ marginTop: 4 }}>
              <span className="muted">انضم {date(customer.created_at)}</span>
              <CopyText value={customer.id} />
            </div>
          </div>
        </div>
        {live && (
          <div className="actions">
            <Button variant="money" icon={<WalletIcon />} onClick={() => setOpen("credit")}>
              الرصيد
            </Button>
            <Button variant="primary" icon={<BellRing />} onClick={() => setOpen("notify")} disabled={customer.push_devices === 0}
              title={customer.push_devices === 0 ? "لا جهاز له يستقبل الإشعارات" : undefined}>
              إشعار
            </Button>
            <Button icon={customer.blocked_at ? <ShieldCheck /> : <Ban />} onClick={() => setOpen("block")}>
              {customer.blocked_at ? "إعادة التفعيل" : "إيقاف"}
            </Button>
            <Button icon={<Trash2 />} onClick={() => setOpen("delete")} title="حذف الحساب">
              حذف
            </Button>
          </div>
        )}
      </div>

      {customer.blocked_at && (
        <div className="notice danger" style={{ marginBottom: 16 }}>
          أُوقف <TimeAgo value={customer.blocked_at} />{customer.blocked_reason ? ` — ${customer.blocked_reason}` : ""}. لا يستطيع الدخول برقمه.
        </div>
      )}

      <div className="grid kpis">
        <div className="card kpi money">
          <div className="kpi-label">اشترى بـ</div>
          <div className="kpi-value"><Money value={customer.spent} /></div>
          <div className="kpi-foot">{count(customer.delivered)} طلب مُسلَّم من {count(customer.orders)}</div>
        </div>
        <div className="card kpi">
          <div className="kpi-label">الرصيد</div>
          <div className="kpi-value"><Money value={credit.balance} /></div>
          <div className="kpi-foot">يدفع به طلباته القادمة</div>
        </div>
        <div className="card kpi">
          <div className="kpi-label">الأجهزة</div>
          <div className="kpi-value">{count(customer.devices)}</div>
          <div className="kpi-foot">{customer.push_devices ? `${count(customer.push_devices)} يستقبل الإشعارات` : "لا إشعارات"}</div>
        </div>
        <div className="card kpi">
          <div className="kpi-label">آخر ظهور</div>
          <div className="kpi-value small"><TimeAgo value={customer.last_seen_at ?? customer.last_sign_in_at} /></div>
          <div className="kpi-foot">{customer.last_order_at ? <>آخر طلب <TimeAgo value={customer.last_order_at} /></> : "لم يطلب بعد"}</div>
        </div>
      </div>

      <Tabs<Tab>
        value={current}
        onChange={(next) => setTab(next === "orders" ? "" : next)}
        tabs={[
          { id: "orders", label: `الطلبات (${count(orders.length)})`, icon: <ReceiptText width={16} /> },
          { id: "credit", label: "حركات الرصيد", icon: <CreditCard width={16} /> },
          { id: "devices", label: `الأجهزة (${count(sessions.length)})`, icon: <MonitorSmartphone width={16} /> },
          { id: "notifications", label: "الإشعارات", icon: <History width={16} /> },
        ]}
      />

      {current === "orders" && (
        <Card tight>
          <CardOrdersTable orders={orders} showCustomer={false} />
        </Card>
      )}
      {current === "credit" && (
        <Card tight>
          <CreditTable entries={credit.entries} />
        </Card>
      )}
      {current === "devices" && (
        <Card
          tight
          actions={
            sessions.length > 0 && (
              <Button size="sm" icon={<LogOut />} loading={signOut.busy}
                onClick={() => void signOut.run("POST", `/v1/customers/admin/customers/${encodeURIComponent(id)}/sign-out`)}>
                خروج من كل الأجهزة
              </Button>
            )
          }
          title="الأجهزة المسجّل دخولها"
        >
          <DevicesTable
            devices={sessions}
            busy={signOut.busy}
            onSignOut={(device) => void signOut.run("DELETE", `/v1/customers/admin/customers/${encodeURIComponent(id)}/sessions/${encodeURIComponent(device.id)}`)}
          />
        </Card>
      )}
      {current === "notifications" && (
        <Card tight>
          <NotificationsTable notifications={notifications} />
        </Card>
      )}

      <CustomerCreditDialog customer={customer} balance={credit.balance} open={open === "credit"} onClose={() => setOpen(null)} />
      <CustomerBlockDialog customer={customer} open={open === "block"} onClose={() => setOpen(null)} />
      <CustomerNotifyDialog customer={customer} open={open === "notify"} onClose={() => setOpen(null)} />
      <CustomerDeleteDialog customer={customer} open={open === "delete"} onClose={() => setOpen(null)} onDeleted={() => navigate("/cards/customers")} />
    </>
  );
}

function CreditTable({ entries }: { entries: CardCreditEntry[] }) {
  const columns: Column<CardCreditEntry>[] = [
    {
      key: "what",
      header: "الحركة",
      mobile: "title",
      cell: (e) => <Stacked title={<>{label(cardCreditKind, e.kind)} {e.test_mode && <Badge tone="warning">تجريبي</Badge>}</>} sub={e.note || (e.order_id ? `طلب ${e.order_id.slice(0, 8)}` : undefined)} />,
    },
    { key: "amount", header: "المبلغ", align: "end", mobile: "trailing", cell: (e) => <Money value={e.amount} signed /> },
    { key: "when", header: "الوقت", cell: (e) => <TimeAgo value={e.created_at} /> },
    { key: "actor", header: "بواسطة", wideOnly: true, cell: (e) => <span className="muted">{e.actor || (e.kind === "adjustment" ? "—" : "تلقائي")}</span> },
  ];
  return <DataTable rows={entries} columns={columns} rowKey={(e) => e.id} empty={<Empty icon={<CreditCard />} title="لا حركات على رصيده" />} />;
}

function DevicesTable({ devices, onSignOut, busy }: { devices: CardDevice[]; onSignOut: (device: CardDevice) => void; busy: boolean }) {
  const columns: Column<CardDevice>[] = [
    {
      key: "device",
      header: "الجهاز",
      mobile: "title",
      cell: (d) => (
        <Stacked
          title={<>{d.device_name || label(cardPlatform, d.platform)} {d.push ? <Badge tone="success">يستقبل الإشعارات</Badge> : null}</>}
          sub={label(cardPlatform, d.platform)}
        />
      ),
    },
    { key: "seen", header: "آخر ظهور", mobile: "subtitle", cell: (d) => <TimeAgo value={d.last_seen_at} /> },
    { key: "since", header: "دخل", wideOnly: true, cell: (d) => date(d.created_at) },
    {
      key: "out",
      header: "",
      align: "end",
      mobile: "actions",
      cell: (d) => (
        <Button size="sm" icon={<LogOut />} disabled={busy} onClick={() => onSignOut(d)}>
          خروج
        </Button>
      ),
    },
  ];
  return <DataTable rows={devices} columns={columns} rowKey={(d) => d.id} empty={<Empty icon={<MonitorSmartphone />} title="ليس مسجّلاً على أي جهاز" />} />;
}

export function NotificationsTable({ notifications, showAudience }: { notifications: CardNotification[]; showAudience?: boolean }) {
  const columns: Column<CardNotification>[] = [
    { key: "what", header: "الإشعار", mobile: "title", cell: (n) => <Stacked title={n.title} sub={n.body} /> },
    ...(showAudience
      ? [{
          key: "to",
          header: "إلى",
          mobile: "subtitle" as const,
          cell: (n: CardNotification) =>
            n.audience === "customer" && n.customer_id ? (
              <Link to={`/cards/customers/${n.customer_id}`}>زبون</Link>
            ) : (
              label(cardAudience, n.audience)
            ),
        }]
      : []),
    {
      key: "result",
      header: "النتيجة",
      cell: (n) =>
        n.failed && !n.sent ? (
          <span title={n.error}><Badge tone="danger">لم يُرسل</Badge></span>
        ) : n.audience === "customer" ? (
          <Badge tone={n.failed ? "warning" : "success"}>{`وصل ${count(n.sent)} من ${count(n.devices)}`}</Badge>
        ) : (
          <Badge tone="success">أُرسل</Badge>
        ),
    },
    { key: "when", header: "الوقت", mobile: "trailing", cell: (n) => <TimeAgo value={n.created_at} /> },
    { key: "by", header: "بواسطة", wideOnly: true, cell: (n) => <span className="muted">{n.sent_by || "—"}</span> },
  ];
  return <DataTable rows={notifications} columns={columns} rowKey={(n) => n.id} empty={<Empty icon={<BellRing />} title="لم يُرسل إشعار بعد" />} />;
}
