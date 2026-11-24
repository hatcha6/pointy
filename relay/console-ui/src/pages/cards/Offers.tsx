import { useMemo, useState } from "react";
import { TicketPercent } from "lucide-react";
import { count, dateTime, money } from "../../lib/format";
import { Badge, Button, Card, Empty, Money, Notice } from "../../components/ui";
import { DataTable, Stacked, type Column } from "../../components/DataTable";
import { Unavailable } from "../../components/Unavailable";
import { useAction } from "../../components/guarded";
import { Dialog } from "../../components/dialog";
import { OfferDialog } from "../../components/cards/OfferDialog";
import { pct, segmentKeys, segmentLabel, useOffers, useSegments, type CustomerOffer, type OfferResult } from "../../lib/segments";

type Row = { offer: CustomerOffer; result: OfferResult };

function offerTerms(o: CustomerOffer): string {
  const off = o.kind === "percent" ? `${Number(o.value).toLocaleString("ar-LY")}٪` : money(o.value);
  const cap = o.kind === "percent" && Number(o.max_discount) > 0 ? ` حتى ${money(o.max_discount)}` : "";
  const min = Number(o.min_order) > 0 ? ` على طلب من ${money(o.min_order)}` : "";
  return `${off}${cap}${min}`;
}

function running(o: CustomerOffer): boolean {
  return o.active && (!o.ends_at || new Date(o.ends_at).getTime() > Date.now());
}

/**
 * The offers made for segments and what each did: who used it, what it gave
 * away, what it earned, and against its holdout whether it brought orders
 * that would not have come anyway.
 */
export function Offers() {
  const answer = useOffers();
  const segments = useSegments();
  const [making, setMaking] = useState(false);
  const [stopping, setStopping] = useState<CustomerOffer | null>(null);
  const stop = useAction({ invalidate: [segmentKeys.all], success: "أُوقف العرض", passkey: true });
  const rows = answer.data?.offers ?? [];

  const columns = useMemo<Column<Row>[]>(
    () => [
      {
        key: "offer",
        header: "العرض",
        mobile: "title",
        cell: ({ offer }) => (
          <Stacked title={offer.name} sub={`${offerTerms(offer)} · ${offer.segments.map(segmentLabel).join("، ")}`} />
        ),
      },
      {
        key: "status",
        header: "الحالة",
        mobile: "subtitle",
        cell: ({ offer }) => (
          <span>{running(offer) ? <Badge tone="success" dot>يعمل</Badge> : <Badge>انتهى</Badge>}</span>
        ),
      },
      {
        key: "who",
        header: "حصلوا عليه",
        align: "end",
        cell: ({ offer }) => (
          <Stacked title={count(offer.recipients)} sub={offer.holdouts ? `مقارنة ${count(offer.holdouts)}` : "بلا مقارنة"} />
        ),
      },
      {
        key: "used",
        header: "استخدموه",
        align: "end",
        mobile: "trailing",
        cell: ({ offer, result }) => (
          <Stacked title={count(result.redeemers)} sub={offer.recipients ? pct(result.redeemers / offer.recipients) : "—"} />
        ),
      },
      {
        key: "money",
        header: "المبيعات بالعرض",
        align: "end",
        cell: ({ result }) => <Stacked title={<Money value={result.revenue} />} sub={`خصم ${money(result.discounts)} · ربح ${money(result.profit)}`} />,
      },
      {
        key: "lift",
        header: "الأثر",
        cell: ({ offer, result }) =>
          offer.holdouts ? (
            <Stacked
              title={
                <span>
                  <Badge tone={result.lift > 0.02 ? "success" : result.lift < -0.02 ? "danger" : "neutral"}>
                    <bdi>{result.lift >= 0 ? "+" : ""}{pct(result.lift)}</bdi>
                  </Badge>
                </span>
              }
              sub={`اشترى ${pct(result.recipient_rate)} مقابل ${pct(result.holdout_rate)} بدونه`}
            />
          ) : (
            <span className="faint">لا يُقاس</span>
          ),
      },
      {
        key: "when",
        header: "المدة",
        wideOnly: true,
        cell: ({ offer }) => <Stacked title={dateTime(offer.starts_at)} sub={offer.ends_at ? `حتى ${dateTime(offer.ends_at)}` : "بلا نهاية"} />,
      },
      {
        key: "actions",
        header: "",
        mobile: "actions",
        cell: ({ offer }) =>
          running(offer) ? (
            <Button size="sm" variant="ghost" onClick={(e) => { e.stopPropagation(); setStopping(offer); }}>
              إيقاف
            </Button>
          ) : null,
      },
    ],
    [],
  );

  return (
    <>
      <div className="page-head">
        <div className="titles">
          <h1>عروض الشرائح</h1>
          <p>خصومات لشرائح الزبائن، وما فعله كل عرض: من استخدمه، وما كلّفه، وهل جلب طلبات ما كانت لتأتي بدونه.</p>
        </div>
        <div className="actions">
          <Button variant="primary" icon={<TicketPercent />} onClick={() => setMaking(true)} disabled={!segments.data}>
            عرض جديد
          </Button>
        </div>
      </div>
      <div className="stack">
        <Notice tone="info" icon={<TicketPercent />}>
          «الأثر» هو الفرق بين من اشترى ممن حصل على العرض ومن اشترى من مجموعة المقارنة خلال مدته. أثر قريب من الصفر يعني أن العرض أعطى خصماً لمن
          كان سيشتري على أي حال: خسارة في الهامش.
        </Notice>
        <Card tight>
          {answer.isError ? (
            <Unavailable feature="customers" error={answer.error} onRetry={() => void answer.refetch()} />
          ) : (
            <DataTable
              rows={rows}
              columns={columns}
              rowKey={(r) => r.offer.id}
              loading={answer.isLoading}
              empty={<Empty icon={<TicketPercent />} title="لا عروض بعد">أنشئ عرضاً من صفحة الشرائح أو من هنا.</Empty>}
            />
          )}
        </Card>
      </div>

      <OfferDialog
        open={making}
        onClose={() => setMaking(false)}
        stats={segments.data?.segments ?? []}
        pushConfigured={!!segments.data?.push_configured}
      />
      <Dialog
        open={stopping !== null}
        onClose={() => setStopping(null)}
        busy={stop.busy}
        icon={<TicketPercent />}
        title={`إيقاف «${stopping?.name ?? ""}»؟`}
        footer={
          <>
            <Button
              variant="primary"
              size="lg"
              loading={stop.busy}
              onClick={async () => {
                if (!stopping) return;
                const done = await stop.run("PATCH", `/v1/customers/admin/offers/${encodeURIComponent(stopping.id)}`, { active: false });
                if (done) setStopping(null);
              }}
            >
              إيقاف الآن
            </Button>
            <Button size="lg" onClick={() => setStopping(null)} disabled={stop.busy}>
              تراجع
            </Button>
          </>
        }
      >
        <p>لن يظهر للزبائن بعد الآن. الطلبات التي استخدمته تبقى كما هي، وتبقى نتائجه هنا.</p>
        {stop.error && <p className="error-text">{stop.error}</p>}
      </Dialog>
    </>
  );
}
