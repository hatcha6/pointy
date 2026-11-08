import { useEffect, useState } from "react";
import { Flag } from "lucide-react";
import { Link, useSearchParam } from "../../lib/router";
import { cardKeys, cardReportReason, useCardReports, type CardReportView } from "../../lib/cards";
import { dateTime } from "../../lib/format";
import { label } from "../../lib/labels";
import { Badge, Button, Card, CopyText, Empty, Field, Money, Segmented, TimeAgo } from "../../components/ui";
import { DataTable, Stacked, type Column } from "../../components/DataTable";
import { Dialog } from "../../components/dialog";
import { useAction } from "../../components/guarded";
import { Unavailable } from "../../components/Unavailable";
import { Phone } from "../../components/cards/Phone";
import { OrderDialog, StatusBadge } from "./CustomerOrders";

/** "player_id: 5123…, zone: 2001" → one line, as the customer typed it. */
function accountLine(account?: Record<string, string>): string {
  return Object.values(account ?? {}).filter(Boolean).join(" · ");
}

/**
 * Problems customers reported with their orders, open ones first. Answering
 * one marks it handled and sends the reply to the customer's phone; they see
 * it on the order too.
 */
export function Reports() {
  const [status, setStatus] = useSearchParam("status");
  const [opened, setOpened] = useSearchParam("report");
  const reports = useCardReports({ status: status || "open" });
  const rows = reports.data?.reports ?? [];
  const [open, setOpen] = useState<CardReportView | null>(null);

  // An alert's link names one report: open it once the list has it.
  useEffect(() => {
    if (!opened) return;
    const found = rows.find((row) => row.report.id === opened);
    if (found) setOpen(found);
  }, [opened, rows]);

  const columns: Column<CardReportView>[] = [
    {
      key: "what",
      header: "البلاغ",
      mobile: "title",
      cell: ({ report, order }) => (
        <Stacked
          title={
            <>
              <Badge tone={report.status === "open" ? "warning" : "success"}>{label(cardReportReason, report.reason)}</Badge>{" "}
              {order?.name || order?.item || report.order_id}
            </>
          }
          sub={report.note ? `«${report.note}»` : accountLine(order?.account) || undefined}
        />
      ),
    },
    {
      key: "who",
      header: "الزبون",
      mobile: "subtitle",
      cell: ({ report, order }) => (
        <Link to={`/cards/customers/${report.customer_id}`} onClick={(e) => e.stopPropagation()}>
          <Phone value={order?.customer_phone} />
        </Link>
      ),
    },
    { key: "order", header: "حالة الطلب", cell: ({ order }) => (order ? <StatusBadge order={order} /> : "—") },
    { key: "total", header: "المبلغ", align: "end", mobile: "trailing", cell: ({ order }) => (order ? <Money value={order.total} /> : "—") },
    { key: "when", header: "الوقت", cell: ({ report }) => <TimeAgo value={report.created_at} /> },
  ];

  return (
    <>
      <div className="page-head">
        <div className="titles">
          <h1>بلاغات الزبائن</h1>
          <p>ما أبلغ عنه الزبائن في طلباتهم من التطبيق. اضغط بلاغاً لترى الطلب كاملاً وتردّ عليه: يصل ردّك إلى هاتف الزبون ويظهر له في الطلب.</p>
        </div>
      </div>
      <Card tight>
        <div className="toolbar stacks">
          <Segmented
            value={status}
            onChange={setStatus}
            options={[
              { id: "", label: "مفتوحة" },
              { id: "resolved", label: "عولجت" },
            ]}
          />
        </div>
        {reports.isError ? (
          <Unavailable feature="customers" error={reports.error} onRetry={() => void reports.refetch()} />
        ) : (
          <DataTable
            rows={rows}
            columns={columns}
            rowKey={(row) => row.report.id}
            loading={reports.isLoading}
            onRowClick={setOpen}
            empty={<Empty icon={<Flag />} title={status === "resolved" ? "لا بلاغات معالجة" : "لا بلاغات مفتوحة"} />}
          />
        )}
      </Card>
      {open && (
        <ReportDialog
          view={open}
          onClose={() => {
            setOpen(null);
            if (opened) setOpened("");
          }}
        />
      )}
    </>
  );
}

function ReportDialog({ view, onClose }: { view: CardReportView; onClose: () => void }) {
  const { report, order } = view;
  const [reply, setReply] = useState("");
  const [showOrder, setShowOrder] = useState(false);
  const resolve = useAction({ invalidate: [cardKeys.all], success: "أُرسل الرد إلى الزبون" });
  const isOpen = report.status === "open";

  async function submit() {
    const done = await resolve.run("POST", `/v1/customers/admin/reports/${encodeURIComponent(report.id)}/resolve`, {
      reply: reply.trim(),
    });
    if (done) onClose();
  }

  const facts: [string, React.ReactNode][] = [
    ["المشكلة", label(cardReportReason, report.reason)],
    ["قال الزبون", report.note ? `«${report.note}»` : "—"],
    ["أُبلغ", dateTime(report.created_at)],
    ["الطلب", order ? <>{order.name || order.item} <StatusBadge order={order} /></> : <CopyText value={report.order_id} />],
    ["الحساب", accountLine(order?.account) ? <bdi dir="ltr">{accountLine(order?.account)}</bdi> : "—"],
    ["المبلغ", order ? <Money value={order.total} /> : "—"],
  ];
  if (!isOpen) {
    facts.push(
      ["ردّنا", report.reply || "—"],
      ["عالجه", report.resolved_by || "—"],
      ["عولج", report.resolved_at ? dateTime(report.resolved_at) : "—"],
    );
  }

  return (
    <>
      <Dialog
        open
        onClose={onClose}
        title={isOpen ? "بلاغ مفتوح" : "بلاغ عولج"}
        subtitle={<CopyText value={report.id} />}
        icon={<Flag />}
        wide
        footer={
          <>
            {order && (
              <Button variant="ghost" onClick={() => setShowOrder(true)}>
                تفاصيل الطلب
              </Button>
            )}
            {isOpen && (
              <Button variant="primary" loading={resolve.busy} onClick={() => void submit()}>
                تمت المعالجة
              </Button>
            )}
          </>
        }
      >
        <dl className="facts">
          {facts.map(([name, value]) => (
            <div className="fact" key={name}>
              <dt>{name}</dt>
              <dd>{value}</dd>
            </div>
          ))}
        </dl>
        {isOpen && (
          <div className="stack" style={{ marginTop: 16 }}>
            <Field
              label="الرد على الزبون"
              htmlFor="report-reply"
              help="اختياري. يصله في إشعار ويظهر له في الطلب، مثل: «أعدنا الشحن، تحقق الآن»."
            >
              <textarea
                id="report-reply"
                className="input"
                rows={3}
                maxLength={500}
                value={reply}
                onChange={(e) => setReply(e.target.value)}
              />
            </Field>
            {resolve.error && <p className="error-text">{resolve.error}</p>}
          </div>
        )}
      </Dialog>
      {showOrder && order && <OrderDialog order={order} onClose={() => setShowOrder(false)} />}
    </>
  );
}
