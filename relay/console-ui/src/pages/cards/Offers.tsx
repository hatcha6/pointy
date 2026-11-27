import { useMemo, useState } from "react";
import { CalendarPlus, Copy, TicketPercent } from "lucide-react";
import { count, date, money } from "../../lib/format";
import { Badge, Button, Card, Empty, Money, Notice } from "../../components/ui";
import { DataTable, Stacked, type Column } from "../../components/DataTable";
import { Unavailable } from "../../components/Unavailable";
import { useAction } from "../../components/guarded";
import { Dialog } from "../../components/dialog";
import { draftOf, openOfferBuilder } from "./OfferBuilder";
import { badgeText, offerKindInfo, scopeIsEverything } from "../../lib/offers";
import { useRouter } from "../../lib/router";
import { pct, segmentKeys, segmentLabel, useOffers, useSegments, type CustomerOffer, type OfferResult, type OfferUse } from "../../lib/segments";

type Row = { offer: CustomerOffer; result: OfferResult; use?: OfferUse };

/** What an offer gives and on what, in a line. */
function offerTerms(o: CustomerOffer): string {
  const kind = offerKindInfo[o.kind]?.label ?? o.kind;
  const cap = Number(o.max_discount) > 0 && o.kind !== "amount" ? ` · حتى ${money(o.max_discount)}` : "";
  const min = Number(o.min_order) > 0 && o.kind !== "tiered" ? ` · من ${money(o.min_order)}` : "";
  return `${kind}${cap}${min} · ${scopeText(o)}`;
}

/** What an offer covers, in words. */
function scopeText(o: CustomerOffer): string {
  const s = o.scope ?? {};
  if (scopeIsEverything(s)) return "كل ما يُباع";
  const parts = [
    s.categories?.length ? `${count(s.categories.length)} فئة` : "",
    s.brands?.length ? `${count(s.brands.length)} علامة` : "",
    s.items?.length ? `${count(s.items.length)} كرت` : "",
  ].filter(Boolean);
  return parts.join(" و");
}

function running(o: CustomerOffer): boolean {
  return o.active && (!o.ends_at || new Date(o.ends_at).getTime() > Date.now());
}

function scheduled(o: CustomerOffer): boolean {
  return running(o) && new Date(o.starts_at).getTime() > Date.now();
}

/** Its budget, when it has one, and whether it is spent. */
function budgetOf(o: CustomerOffer, use?: OfferUse): { budget: number; spent: number; over: boolean } | null {
  const budget = Number(o.budget);
  if (!(budget > 0)) return null;
  const spent = Number(use?.spent ?? 0);
  return { budget, spent, over: spent >= budget };
}

/** What its notifications did, in a line: «أُرسل · تذكير قبل الانتهاء». */
function noticeText(o: CustomerOffer): string {
  const n = o.notice;
  if (!n) return "";
  const parts = [
    n.title ? (n.sent_at ? `أُرسل الإشعار ${date(n.sent_at)}` : "الإشعار ينتظر بدء العرض") : "",
    n.remind ? (n.reminded_at ? "أُرسل التذكير" : "تذكير قبل الانتهاء") : "",
  ].filter(Boolean);
  return parts.join(" · ");
}

/**
 * The offers made for segments and what each did: who used it, what it gave
 * away, what it earned, and against its holdout whether it brought orders
 * that would not have come anyway.
 */
export function Offers() {
  const answer = useOffers();
  const segments = useSegments();
  const { navigate } = useRouter();
  const [stopping, setStopping] = useState<CustomerOffer | null>(null);
  const stop = useAction({ invalidate: [segmentKeys.all], success: "أُوقف العرض", passkey: true });
  const extend = useAction({ invalidate: [segmentKeys.all], success: "مُدّد العرض أسبوعاً", passkey: true });
  const rows = answer.data?.offers ?? [];

  // A week more from its end: those it reminded are not reminded again.
  async function extendWeek(offer: CustomerOffer) {
    const ends = new Date(new Date(offer.ends_at ?? Date.now()).getTime() + 7 * 86_400_000);
    await extend.run("PATCH", `/v1/customers/admin/offers/${encodeURIComponent(offer.id)}`, { ends_at: ends.toISOString() });
  }

  const columns = useMemo<Column<Row>[]>(
    () => [
      {
        key: "offer",
        header: "العرض",
        mobile: "title",
        cell: ({ offer }) => (
          <Stacked
            title={offer.name}
            sub={`${offerTerms(offer)} · ${offer.audience === "everyone" ? "للجميع" : offer.segments.map(segmentLabel).join("، ")}`}
          />
        ),
      },
      {
        key: "badge",
        header: "الحالة",
        mobile: "subtitle",
        cell: ({ offer, use }) => {
          const budget = budgetOf(offer, use);
          const notice = noticeText(offer);
          return (
            <div>
              <span className="row" style={{ gap: 6, flexWrap: "nowrap" }}>
                <span className="sale-pill">{badgeText(offer)}</span>
                {!running(offer) ? (
                  <Badge>انتهى</Badge>
                ) : scheduled(offer) ? (
                  <Badge tone="info" dot>يبدأ {date(offer.starts_at)}</Badge>
                ) : budget?.over ? (
                  <Badge tone="warning" dot>بلغ ميزانيته</Badge>
                ) : (
                  <Badge tone="success" dot>يعمل</Badge>
                )}
              </span>
              <div className="faint" style={{ fontSize: 12, marginTop: 4 }}>
                {offer.ends_at ? `حتى ${date(offer.ends_at)}` : "بلا نهاية"}
                {budget && ` · الميزانية ${money(budget.spent)} من ${money(budget.budget)}`}
              </div>
              {budget && (
                <div className="budget-bar" aria-hidden>
                  <span style={{ width: `${Math.min(100, (budget.spent / budget.budget) * 100)}%` }} />
                </div>
              )}
              {notice && <div className="faint" style={{ fontSize: 12, marginTop: 2 }}>{notice}</div>}
            </div>
          );
        },
      },
      {
        key: "used",
        header: "استخدموه",
        align: "end",
        mobile: "trailing",
        cell: ({ offer, result }) => (
          <Stacked
            title={offer.audience === "everyone" ? count(result.redeemers) : `${count(result.redeemers)} من ${count(offer.recipients)}`}
            sub={
              offer.audience === "everyone"
                ? "للجميع"
                : `${offer.recipients ? pct(result.redeemers / offer.recipients) : "—"}${offer.holdouts ? ` · مقارنة ${count(offer.holdouts)}` : ""}`
            }
          />
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
                <span style={{ display: "inline-flex" }}>
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
        key: "actions",
        header: "",
        mobile: "actions",
        cell: ({ offer }) => (
          <span className="row" style={{ gap: 4, flexWrap: "wrap", justifyContent: "flex-end", maxWidth: 104 }}>
            <Button size="sm" variant="ghost" icon={<Copy />} title="نسخ: عرض جديد بنفس الشروط" aria-label="نسخ العرض" onClick={(e) => { e.stopPropagation(); openOfferBuilder(navigate, draftOf(offer)); }} />
            {running(offer) && offer.ends_at && (
              <Button size="sm" variant="ghost" icon={<CalendarPlus />} title="تمديد أسبوعاً" aria-label="تمديد العرض أسبوعاً" loading={extend.busy} onClick={(e) => { e.stopPropagation(); void extendWeek(offer); }} />
            )}
            {running(offer) && (
              <Button size="sm" variant="ghost" onClick={(e) => { e.stopPropagation(); setStopping(offer); }}>
                إيقاف
              </Button>
            )}
          </span>
        ),
      },
    ],
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [extend.busy],
  );

  return (
    <>
      <div className="page-head">
        <div className="titles">
          <h1>عروض الشرائح</h1>
          <p>خصومات لشرائح الزبائن، وما فعله كل عرض: من استخدمه، وما كلّفه، وهل جلب طلبات ما كانت لتأتي بدونه.</p>
        </div>
        <div className="actions">
          <Button variant="primary" icon={<TicketPercent />} onClick={() => openOfferBuilder(navigate)} disabled={!segments.data}>
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
