import { useMemo } from "react";
import { BellRing, ChartPie, Lightbulb, TicketPercent, Users } from "lucide-react";
import { useRouter } from "../../lib/router";
import { count, money } from "../../lib/format";
import { Badge, Button, Card, Empty, Money, Skeleton } from "../../components/ui";
import { DataTable, Stacked, type Column } from "../../components/DataTable";
import { Unavailable } from "../../components/Unavailable";
import { openOfferBuilder } from "./OfferBuilder";
import {
  dayCount,
  insightText,
  offerFromInsight,
  pct,
  round2,
  segmentInfo,
  useSegments,
  type Insight,
  type OfferDraft,
  type SegmentStats,
} from "../../lib/segments";

/**
 * «دفتر كروت»'s customers by how they buy: each segment's size, money and
 * habit, what to do about it, and the means to do it (an offer, a
 * notification) for one segment or several.
 */
export function Segments() {
  const { navigate } = useRouter();
  const answer = useSegments();
  const data = answer.data;
  const stats = data?.segments ?? [];
  const o = data?.overview;

  const notify = (keys: string[]) => navigate(`/cards/notifications?segments=${keys.join(",")}`);
  const customersOf = (keys: string[]) => navigate(`/cards/customers?rfm=${keys.join(",")}`);

  const columns = useMemo<Column<SegmentStats>[]>(
    () => [
      {
        key: "segment",
        header: "الشريحة",
        mobile: "title",
        cell: (s) => (
          <span title={segmentInfo[s.key].about}>
            <Badge tone={segmentInfo[s.key].tone}>{segmentInfo[s.key].label}</Badge>
          </span>
        ),
      },
      { key: "customers", header: "الزبائن", align: "end", mobile: "trailing", cell: (s) => <Stacked title={count(s.customers)} sub={pct(s.share)} /> },
      { key: "reach", header: "يصلهم إشعار", align: "end", wideOnly: true, cell: (s) => count(s.reachable) },
      { key: "revenue", header: "المبيعات", align: "end", cell: (s) => <Stacked title={<Money value={s.revenue} />} sub={pct(s.revenue_share)} /> },
      {
        key: "profit",
        header: "الربح",
        align: "end",
        cell: (s) => <Stacked title={<Money value={s.profit} />} sub={Number(s.revenue) > 0 ? `هامش ${pct(s.margin)}` : "—"} />,
      },
      { key: "aov", header: "متوسط الطلب", align: "end", wideOnly: true, cell: (s) => (s.orders ? <Money value={s.average_order} /> : <span className="faint">—</span>) },
      {
        key: "habit",
        header: "الإيقاع",
        wideOnly: true,
        cell: (s) =>
          s.buyers ? (
            <Stacked title={s.repeat_buyers ? `كل ${dayCount(s.cycle_days)}` : "مرة واحدة"} sub={`آخر طلب قبل ${dayCount(s.days_since_last)}`} />
          ) : (
            <span className="faint">لم يشتروا</span>
          ),
      },
      {
        key: "actions",
        header: "",
        mobile: "actions",
        cell: (s) => (
          <span className="row" style={{ gap: 6, flexWrap: "nowrap" }}>
            <Button size="sm" icon={<TicketPercent />} disabled={!s.customers} onClick={(e) => { e.stopPropagation(); openOfferBuilder(navigate, { segments: [s.key] }); }}>
              عرض
            </Button>
            <Button size="sm" variant="ghost" icon={<BellRing />} disabled={!s.reachable} onClick={(e) => { e.stopPropagation(); notify([s.key]); }}>
              إشعار
            </Button>
          </span>
        ),
      },
    ],
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [],
  );

  return (
    <>
      <div className="page-head">
        <div className="titles">
          <h1>شرائح الزبائن</h1>
          <p>زبائن دفتر كروت حسب طريقة شرائهم: كم يجلب كل صنف، وما الذي يستحق أن تفعله معه.</p>
        </div>
        <div className="actions">
          <Button variant="primary" icon={<TicketPercent />} onClick={() => openOfferBuilder(navigate)} disabled={!data}>
            عرض جديد
          </Button>
          <Button icon={<TicketPercent />} onClick={() => navigate("/cards/offers")}>
            العروض ونتائجها
          </Button>
        </div>
      </div>

      {answer.isError ? (
        <Card>
          <Unavailable feature="customers" error={answer.error} onRetry={() => void answer.refetch()} />
        </Card>
      ) : (
        <div className="stack">
          <div className="grid kpis">
            <Kpi label="المشترون" value={o ? count(o.buyers) : null} foot={o ? `من ${count(o.customers)} حساب · ${count(o.active_buyers)} اشتروا خلال ٣٠ يوماً` : ""} />
            <Kpi label="عادوا لطلب ثانٍ" value={o ? pct(o.repeat_rate) : null} foot={o ? `${pct(o.second_within_30)} خلال ٣٠ يوماً من أول طلب` : ""} />
            <Kpi label="المبيعات (٩٠ يوماً)" value={o ? <Money value={o.recent_revenue} /> : null} foot={o ? `الربح ${money(o.recent_profit)} · الهامش ${pct(o.margin)}` : ""} />
            <Kpi label="الخصومات الممنوحة" value={o ? <Money value={o.discounts} /> : null} foot="من عروض الشرائح، منذ البداية" />
          </div>

          <Card title="ما يستحق أن تفعله" hint={<Lightbulb width={14} />}>
            {answer.isLoading ? (
              <Skeleton height={120} />
            ) : (data?.insights ?? []).length === 0 ? (
              <Empty icon={<Lightbulb />} title="لا توصيات الآن">
                تظهر التوصيات حين يكبر عدد الزبائن في الشرائح.
              </Empty>
            ) : (
              <div className="insights">
                {(data?.insights ?? []).map((insight, i) => (
                  <InsightRow
                    key={`${insight.code}-${i}`}
                    insight={insight}
                    onOffer={(draft) => openOfferBuilder(navigate, draft)}
                    onNotify={() => notify(insight.segments)}
                    onCustomers={() => customersOf(insight.segments)}
                  />
                ))}
              </div>
            )}
          </Card>

          <Card tight title="الشرائح" hint={<ChartPie width={14} />}>
            <DataTable
              rows={stats}
              columns={columns}
              rowKey={(s) => s.key}
              onRowClick={(s) => customersOf([s.key])}
              loading={answer.isLoading}
              pageSize={0}
              empty={<Empty icon={<Users />} title="لا زبائن بعد" />}
            />
          </Card>

          {data && (
            <Card title="كيف تُحسب الشرائح">
              <ul className="plain-list muted">
                <li>
                  لكل زبون اشترى مرتين أو أكثر «إيقاع» خاص به: متوسط الأيام بين أيام شرائه. يُقاس تأخره بإيقاعه هو، لا بعدد أيام واحد للجميع: عشرة
                  أيام بلا طلب لا تعني شيئاً لمن يشتري كل شهر، وتعني الكثير لمن يشتري كل أسبوع.
                </li>
                <li>
                  على إيقاعه: حتى {data.rules.on_rhythm.toLocaleString("ar-LY")} من فتراته المعتادة. بعدها «مهدد»، وبعد{" "}
                  {data.rules.slipping_to.toLocaleString("ar-LY")} «خامل». بلا طلب منذ {count(data.rules.lost_days)} يوماً: «فقدناهم».
                </li>
                <li>
                  الأبطال: {count(data.rules.champion_orders)} طلبات أو أكثر خلال {count(data.rules.window_days)} يوماً، ومن أعلى{" "}
                  {pct(data.rules.high_value_share)} إنفاقاً. الأوفياء: {count(data.rules.loyal_orders)} طلبات أو أكثر.
                </li>
                <li>
                  «اشتروا مرة» خلال {count(data.rules.first_purchase_days)} يوماً من طلبهم، و«جدد» خلال {count(data.rules.new_days)} يوماً من
                  دخولهم. الربح بتكلفة كل طلب وسعر الدولار يوم شرائه. الحسابات الموقوفة والمحذوفة خارج الشرائح.
                </li>
              </ul>
            </Card>
          )}
        </div>
      )}

    </>
  );
}

function Kpi({ label, value, foot }: { label: string; value: React.ReactNode | null; foot: string }) {
  return (
    <div className="card kpi">
      <div className="kpi-label">{label}</div>
      <div className="kpi-value">{value ?? <Skeleton height={30} width={100} />}</div>
      <div className="kpi-foot">{foot}</div>
    </div>
  );
}

function InsightRow({
  insight,
  onOffer,
  onNotify,
  onCustomers,
}: {
  insight: Insight;
  onOffer: (draft: Partial<OfferDraft>) => void;
  onNotify: () => void;
  onCustomers: () => void;
}) {
  const text = insightText(insight);
  const offer = offerFromInsight(insight);
  return (
    <div className="insight">
      <div className="insight-body">
        <strong>{text.title}</strong>
        <p>{text.body}</p>
        <p className="insight-action">
          <Lightbulb width={14} /> {text.action}
        </p>
        {Number(insight.impact) > 0 && <p className="faint">في الميزان نحو {money(round2(insight.impact))} شهرياً.</p>}
      </div>
      <div className="insight-buttons">
        {offer && (
          <Button size="sm" variant="primary" icon={<TicketPercent />} onClick={() => onOffer({ ...offer, segments: insight.segments, name: text.title })}>
            أنشئ العرض
          </Button>
        )}
        <Button size="sm" icon={<BellRing />} onClick={onNotify}>
          إشعار
        </Button>
        <Button size="sm" variant="ghost" icon={<Users />} onClick={onCustomers}>
          الزبائن
        </Button>
      </div>
    </div>
  );
}
