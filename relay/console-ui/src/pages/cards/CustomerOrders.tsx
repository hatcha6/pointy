import { useState } from "react";
import { ReceiptText, Search } from "lucide-react";
import { Link, useSearchParam } from "../../lib/router";
import { cardChannel, cardOrderStatus, useCardOrders, type CardOrder } from "../../lib/cards";
import { count, dateTime } from "../../lib/format";
import { label, method as methodLabels } from "../../lib/labels";
import { Badge, Card, CopyText, Empty, Money, Segmented, TimeAgo } from "../../components/ui";
import { DataTable, Stacked, type Column } from "../../components/DataTable";
import { Dialog } from "../../components/dialog";
import { Unavailable } from "../../components/Unavailable";
import { Phone } from "../../components/cards/Phone";

function StatusBadge({ order }: { order: CardOrder }) {
  const status = cardOrderStatus[order.status] ?? { label: order.status, tone: "neutral" as const };
  return <Badge tone={status.tone}>{status.label}</Badge>;
}

function paidWith(order: CardOrder): string {
  if (!order.method) return "من الرصيد";
  const name = label(methodLabels, order.method);
  return Number(order.credit_used) > 0 ? `${name} + الرصيد` : name;
}

/** Orders, newest first; a row opens its whole story. */
export function CardOrdersTable({ orders, loading, showCustomer = true }: { orders: CardOrder[]; loading?: boolean; showCustomer?: boolean }) {
  const [open, setOpen] = useState<CardOrder | null>(null);
  const columns: Column<CardOrder>[] = [
    {
      key: "what",
      header: "الطلب",
      mobile: "title",
      cell: (o) => (
        <Stacked
          title={
            <>
              {o.name || o.item} {o.quantity > 1 ? `× ${count(o.quantity)}` : ""}{" "}
              {o.review ? <Badge>مراجعة المتجر</Badge> : o.test_mode ? <Badge tone="warning">تجريبي</Badge> : null}
            </>
          }
          sub={<>{label(cardChannel, o.channel)} · {paidWith(o)}</>}
        />
      ),
    },
    ...(showCustomer
      ? [{
          key: "who",
          header: "الزبون",
          mobile: "subtitle" as const,
          cell: (o: CardOrder) => (
            <Link to={`/cards/customers/${o.customer_id}`} onClick={(e) => e.stopPropagation()}>
              <Phone value={o.customer_phone} />
            </Link>
          ),
        }]
      : []),
    { key: "status", header: "الحالة", cell: (o) => <StatusBadge order={o} /> },
    { key: "total", header: "المبلغ", align: "end", mobile: "trailing", cell: (o) => <Money value={o.total} /> },
    { key: "when", header: "الوقت", cell: (o) => <TimeAgo value={o.created_at} /> },
  ];
  return (
    <>
      <DataTable
        rows={orders}
        columns={columns}
        rowKey={(o) => o.id}
        loading={loading}
        onRowClick={setOpen}
        empty={<Empty icon={<ReceiptText />} title="لا طلبات" />}
      />
      {open && <OrderDialog order={open} onClose={() => setOpen(null)} />}
    </>
  );
}

function OrderDialog({ order, onClose }: { order: CardOrder; onClose: () => void }) {
  const facts: [string, React.ReactNode][] = [
    ["الحالة", <StatusBadge order={order} />],
    ["الزبون", <Link to={`/cards/customers/${order.customer_id}`} onClick={onClose}><Phone value={order.customer_phone} /></Link>],
    ["الصنف", <>{order.name || order.item} <span className="muted mono">{order.item}</span></>],
    ["الكمية", count(order.quantity)],
    ["سعر الكرت", <Money value={order.unit_price} />],
    ["المجموع", <Money value={order.total} />],
    ["من الرصيد", Number(order.credit_used) ? <Money value={order.credit_used} /> : "—"],
    ["عبر البوابة", Number(order.amount_due) ? <Money value={order.amount_due} /> : "—"],
    ["رسوم البوابة", Number(order.fee) ? <Money value={order.fee} /> : "—"],
    ["طريقة الدفع", paidWith(order)],
    ["الدافع", order.payer_hint ? <bdi dir="ltr">{order.payer_hint}</bdi> : "—"],
    ["التطبيق", label(cardChannel, order.channel)],
    ["أُنشئ", dateTime(order.created_at)],
    ["دُفع", order.paid_at ? dateTime(order.paid_at) : "—"],
    ["اكتمل", order.completed_at ? dateTime(order.completed_at) : "—"],
  ];
  return (
    <Dialog open onClose={onClose} title={order.name || order.item} subtitle={<CopyText value={order.id} />} icon={<ReceiptText />} wide>
      <dl className="facts">
        {facts.map(([name, value]) => (
          <div className="fact" key={name}>
            <dt>{name}</dt>
            <dd>{value}</dd>
          </div>
        ))}
        {order.payment_id && (
          <div className="fact">
            <dt>رقم الدفعة (دفع)</dt>
            <dd><CopyText value={order.payment_id} /></dd>
          </div>
        )}
        {order.purchase_id && (
          <div className="fact">
            <dt>عملية الشراء من المورّد</dt>
            <dd><CopyText value={order.purchase_id} /></dd>
          </div>
        )}
      </dl>
      {(order.error_code || order.error_detail || order.late_paid) && (
        <div className="notice warning" style={{ marginTop: 16 }}>
          {order.late_paid && <p>وصلت دفعته بعد إغلاق الطلب، فأُضيفت لرصيد الزبون.</p>}
          {order.error_code && <p className="mono">{order.error_code}</p>}
          {order.error_detail && <p>{order.error_detail}</p>}
        </div>
      )}
    </Dialog>
  );
}

/** Every order placed in «دفتر كروت», by any customer. */
export function CustomerOrders() {
  const [status, setStatus] = useSearchParam("status");
  const [channel, setChannel] = useSearchParam("channel");
  const [query, setQuery] = useSearchParam("q");
  const orders = useCardOrders({ status, channel, q: query.trim() });
  return (
    <>
      <div className="page-head">
        <div className="titles">
          <h1>طلبات دفتر كروت</h1>
          <p>كل ما اشتراه الزبائن من التطبيق. اضغط طلباً لترى مبلغه وطريقة دفعه وعملية الشراء التي سلّمته.</p>
        </div>
      </div>
      <Card tight>
        <div className="toolbar stacks">
          <div className="search-input">
            <Search />
            <input className="input" placeholder="رقم الطلب، الصنف، العلامة، رقم الدفعة…" value={query} onChange={(e) => setQuery(e.target.value)} />
          </div>
          <Segmented
            value={status}
            onChange={setStatus}
            options={[
              { id: "", label: "الكل" },
              { id: "open", label: "مفتوحة" },
              { id: "delivered", label: "مُسلَّمة" },
              { id: "refunded", label: "أُعيدت للرصيد" },
              { id: "failed", label: "فشلت" },
            ]}
          />
          <Segmented
            value={channel}
            onChange={setChannel}
            options={[
              { id: "", label: "كل التطبيقات" },
              { id: "ios", label: "آيفون" },
              { id: "play", label: "بلاي" },
              { id: "apk", label: "أندرويد" },
              { id: "web", label: "الويب" },
            ]}
          />
        </div>
        {orders.isError ? (
          <Unavailable feature="customers" error={orders.error} onRetry={() => void orders.refetch()} />
        ) : (
          <CardOrdersTable orders={orders.data?.orders ?? []} loading={orders.isLoading} />
        )}
      </Card>
    </>
  );
}
