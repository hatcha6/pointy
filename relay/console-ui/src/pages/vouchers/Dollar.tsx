import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { Ban, CircleDollarSign, Plus, ShieldCheck, TrendingUp, TriangleAlert, Wallet } from "lucide-react";
import { api } from "../../lib/api";
import { dateTime, money } from "../../lib/format";
import { label, supplier as supplierLabels } from "../../lib/labels";
import { fxKey, methodLabel, pct, rate, seriesName, type FXBook, type FXQuote, type FXState, type SupplierFunding } from "../../lib/fx";
import { Badge, Button, Card, Empty, Field, Fold, Notice, Skeleton, TimeAgo } from "../../components/ui";
import { DataTable } from "../../components/DataTable";
import { Dialog } from "../../components/dialog";
import { useAction } from "../../components/guarded";
import { FundingDialog } from "./FundingDialog";

export function useFX() {
  return useQuery({ queryKey: fxKey, queryFn: () => api.get<FXState>("/v1/vouchers/admin/fx"), refetchInterval: 60_000, retry: false });
}

/**
 * «الدولار والتمويل»: the dollar rate every dollar card is priced at, how it is
 * reached, the capital each supplier holds for us, and the top-up ledger that
 * teaches it what our dollars really cost.
 */
export function DollarTab() {
  const fx = useFX();
  const [recording, setRecording] = useState(false);
  if (fx.isLoading) return <Skeleton height={240} />;
  if (fx.isError || !fx.data) return <Empty title="غير متاح">{String((fx.error as Error)?.message ?? "")}</Empty>;
  const state = fx.data;
  const quote = state.quote;
  const uncovered = (quote?.books ?? []).filter((b) => Number(b.uncovered_usd) >= 1);
  return (
    <div className="stack">
      {state.problem === "off" && (
        <Notice tone="warning" icon={<TriangleAlert />}>
          التسعير بتكلفة التمويل متوقف (fx.enabled = off): تُسعَّر البطاقات بسعر المصرف وهامش الإعداد فقط.
        </Notice>
      )}
      {state.problem === "manual" && (
        <Notice tone="warning" icon={<TriangleAlert />}>
          مصدر سعر الدولار «يدوي» في الإعداد: تُسعَّر البطاقات بالسعر اليدوي، لا بما في هذه الصفحة.
        </Notice>
      )}
      {state.problem === "manual_fallback" && (
        <Notice tone="warning" icon={<TriangleAlert />}>
          لا سعر حديث من fulus.ly ({state.rate_problem}): تُسعَّر البطاقات بالسعر اليدوي الاحتياطي المضبوط في الإعداد.
        </Notice>
      )}
      {state.problem && !["off", "manual", "manual_fallback"].includes(state.problem) && (
        <Notice tone="danger" icon={<TriangleAlert />}>
          لا سعر دولار صالح الآن: {state.problem}
        </Notice>
      )}
      {quote?.fallback && (
        <Notice tone="danger" icon={<TriangleAlert />}>
          لا سعر حديث من fulus.ly ({state.rate_problem}). البطاقات تُباع بآخر سعر معروف وآخر شحنة مع الوسادة كاملة حتى يعود السعر. إن طال الانقطاع
          راجع الاشتراك في fulus.ly.
        </Notice>
      )}
      {quote?.premium_high && (
        <Notice tone="warning" icon={<TriangleAlert />}>
          علاوة إعادة الشحن {pct(quote.premium_percent)} فوق المصرف عالية جداً: راجع آخر الشحنات في السجل، فقد تكون إحداها مكتوبة خطأ.
        </Notice>
      )}
      {quote?.shocked && (
        <Notice tone="danger" icon={<TrendingUp />}>
          تحرّك الدولار {pct(quote.shock_percent)} خلال يوم واحد. رُفعت الأسعار تلقائياً مع أول قراءة؛ تأكّد من سعر شرائك القادم قبل أن تشحن.
        </Notice>
      )}
      {uncovered.map((b) => (
        <Notice key={b.supplier} tone="warning" icon={<Wallet />}>
          لدى {label(supplierLabels, b.supplier)} <bdi className="num">{rate(b.uncovered_usd)}$</bdi> لا تشرحها أي شحنة مسجّلة: تُسعَّر بسعر السوق.
          سجّل الشحنة التي جاءت منها ليُحمى رأس مالها.
        </Notice>
      ))}

      <div className="grid two">
        {quote ? <RateCard state={state} quote={quote} /> : <Card title="سعر الدولار في التسعير"><Empty title="لا سعر" /></Card>}
        <Card
          title="رأس المال لدى الموردين"
          hint="الدولارات التي يحملها كل مورد لنا، وما كلّفتنا"
          actions={
            <Button variant="money" icon={<Plus />} onClick={() => setRecording(true)}>
              سجّل شحنة رصيد
            </Button>
          }
        >
          {(quote?.books ?? []).length === 0 ? (
            <Empty title="لا رصيد دولاري مقروء">يظهر هنا رصيد FazerCards وReloadly بعد أول قراءة.</Empty>
          ) : (
            <div className="stack">
              {quote!.books.map((b) => (
                <BookRow key={b.supplier} book={b} market={quote!.market} />
              ))}
            </div>
          )}
        </Card>
      </div>

      <FundingsCard fundings={state.fundings ?? []} onRecord={() => setRecording(true)} />
      <HowItWorks state={state} />
      {recording && <FundingDialog state={state} onClose={() => setRecording(false)} />}
    </div>
  );
}

function RateCard({ state, quote }: { state: FXState; quote: FXQuote }) {
  const bank = seriesName(state.series);
  const p = state.policy;
  return (
    <Card title="سعر الدولار في التسعير" hint="كل بطاقة بالدولار تُسعَّر به، لكل المحلات وتطبيق الكروت">
      <div className="fx-hero">
        <bdi className="num fx-hero-rate">{rate(quote.market)}</bdi>
        <span className="faint">د.ل لكل دولار</span>
      </div>
      <ol className="fx-steps">
        <li>
          <span>سعر {bank} الآن</span>
          <bdi className="num">{rate(quote.live)}</bdi>
          <span className="faint">
            <TimeAgo value={quote.live_at} />
          </span>
        </li>
        <li>
          <span>+ علاوة إعادة الشحن</span>
          <bdi className="num">{pct(quote.premium_percent)}</bdi>
          <span className="faint">
            {quote.premium_source === "learned"
              ? quote.premium_from.length > 1
                ? `الوسيط لآخر ${quote.premium_from.length} شحنات مسجّلة`
                : "من آخر شحنة مسجّلة"
              : "من الإعداد: لم تُسجَّل شحنة حديثة بعد"}
          </span>
        </li>
        <li className="fx-sub">
          <span>= تكلفة شراء الدولار من جديد</span>
          <bdi className="num">{rate(quote.replacement)}</bdi>
        </li>
        {quote.binding === "peak" && (
          <li>
            <span>↑ أعلى سعر في آخر {p.peak_days} أيام</span>
            <bdi className="num">{rate(quote.peak)}</bdi>
            <span className="faint">
              كان {rate(quote.peak_raw)} ويهبط {pct(p.fall_percent_per_day, 0)} يومياً، ويُترك كلياً إن ثبت السعر الأدنى {p.release_hours} ساعة: الصعود
              يُطبَّق فوراً والهبوط بعد التأكد منه، ولا يرفع بطاقة فوق سعر منافسها
            </span>
          </li>
        )}
        <li>
          <span>+ وسادة صعود الدولار{quote.fallback ? " (كاملة: لا سعر حديث)" : ""}</span>
          <bdi className="num">{pct(quote.cushion_percent)}</bdi>
          <span className="faint">
            {Number(quote.cushion_percent) > 0
              ? `صعد ${pct(quote.momentum_percent)} في ${p.momentum_days} أيام؛ نضيف ${pct(p.momentum_share_percent, 0)} منه (بحدّ ${pct(p.cushion_cap_percent, 0)})`
              : `لم يصعد في آخر ${p.momentum_days} أيام (${pct(quote.momentum_percent)})`}
          </span>
        </li>
        <li className="fx-total">
          <span>= سعر التسعير</span>
          <bdi className="num">{rate(quote.market)}</bdi>
        </li>
      </ol>
      {state.history && state.history.length > 1 && <Sparkline points={state.history} label={bank} />}
    </Card>
  );
}

function BookRow({ book, market }: { book: FXBook; market: string }) {
  const gain = Number(book.gain_lyd ?? 0);
  const hundred = book.examples.find((e) => e.usd === 100);
  return (
    <div className="fx-book">
      <div className="fx-between">
        <strong>{label(supplierLabels, book.supplier)}</strong>
        {book.binding === "book" ? (
          <Badge tone="warning" dot>
            يُسعَّر بتكلفة رصيده
          </Badge>
        ) : (
          <Badge tone="success" dot>
            بسعر السوق
          </Badge>
        )}
      </div>
      <dl className="facts">
        <div className="fact">
          <dt>الرصيد</dt>
          <dd>
            <bdi className="num">{book.held_usd ? `${rate(book.held_usd)}$` : "—"}</bdi>
            {book.read_at && (
              <span className="faint">
                {" "}
                · <TimeAgo value={book.read_at} />
              </span>
            )}
          </dd>
        </div>
        <div className="fact">
          <dt>كلّفتنا</dt>
          <dd>{Number(book.covered_usd) > 0 ? money(book.cost_lyd) : "—"}</dd>
        </div>
        <div className="fact">
          <dt>متوسط تكلفة الدولار</dt>
          <dd>
            <bdi className="num">{rate(book.average)}</bdi>
          </dd>
        </div>
        <div className="fact">
          <dt>يُسعَّر الدولار بـ</dt>
          <dd>
            <bdi className="num">{rate(book.rate)}</bdi>
          </dd>
        </div>
        <div className="fact">
          <dt>ربح/خسارة الصرف</dt>
          <dd className={gain < 0 ? "fx-loss" : gain > 0 ? "fx-gain" : ""}>{book.gain_lyd ? money(book.gain_lyd) : "—"}</dd>
        </div>
        {hundred && (
          <div className="fact">
            <dt>بطاقة 100$ للزبون</dt>
            <dd>
              {money(hundred.retail)} <span className="faint">· هامش {pct(hundred.margin_percent)}</span>
            </dd>
          </div>
        )}
      </dl>
      {book.binding === "market" && gain < 0 && Number(book.covered_usd) > 0 && (
        <p className="faint">
          <TrendingUp width={14} /> هبط الدولار تحت تكلفة هذا الرصيد ({rate(book.average)}): يُباع بسعر السوق لتبقى أسعارك منافسة، والفرق خسارة صرف تظهر هنا. يحدّها
          أن يبقى رصيد كل مورد بقدر أسبوع من المبيعات.
        </p>
      )}
      {book.binding === "book" && (
        <p className="faint">
          <ShieldCheck width={14} /> دولارات هذا الرصيد كلّفتنا {rate(book.average)} وهو أعلى من سعر السوق {rate(market)}: تبقى مُسعَّرة بتكلفتها حتى تُباع، فلا يُباع
          رأس المال بخسارة.
        </p>
      )}
    </div>
  );
}

function FundingsCard({ fundings, onRecord }: { fundings: SupplierFunding[]; onRecord: () => void }) {
  const [voiding, setVoiding] = useState<SupplierFunding | null>(null);
  return (
    <Card title="سجل شحن الموردين" hint="كل دينار دُفع لشراء دولار عند مورد" tight>
      {fundings.length === 0 ? (
        <Empty icon={<CircleDollarSign />} title="لم تُسجَّل شحنة بعد">
          سجّل كل شحنة لرصيد FazerCards أو Reloadly: ما دفعته بالدينار وما وصل بالدولار. منها يعرف الخادم تكلفة دولارك الحقيقية.
          <div style={{ marginTop: 12 }}>
            <Button variant="money" icon={<Plus />} onClick={onRecord}>
              سجّل شحنة رصيد
            </Button>
          </div>
        </Empty>
      ) : (
        <DataTable
          rows={fundings}
          rowKey={(f) => f.id}
          columns={[
            { key: "when", header: "التاريخ", mobile: "subtitle", cell: (f) => dateTime(f.funded_at) },
            { key: "supplier", header: "المورد", mobile: "title", cell: (f) => label(supplierLabels, f.supplier) },
            { key: "method", header: "الطريقة", cell: (f) => methodLabel(f.method) },
            { key: "usd", header: "وصل", align: "end", cell: (f) => <bdi className="num">{rate(f.usd)}$</bdi> },
            { key: "lyd", header: "دُفع", align: "end", mobile: "trailing", cell: (f) => money(f.lyd) },
            { key: "rate", header: "سعر دولارنا", align: "end", cell: (f) => <bdi className="num">{rate(Number(f.lyd) / Number(f.usd))}</bdi> },
            {
              key: "premium",
              header: "فوق المصرف",
              align: "end",
              cell: (f) => (f.market_rate ? pct((Number(f.lyd) / Number(f.usd) / Number(f.market_rate) - 1) * 100) : "—"),
            },
            {
              key: "status",
              header: "",
              cell: (f) =>
                f.voided_at ? (
                  <Badge tone="neutral">ملغاة: {f.void_reason}</Badge>
                ) : (
                  <Button size="sm" variant="ghost" icon={<Ban />} onClick={() => setVoiding(f)}>
                    إلغاء
                  </Button>
                ),
            },
          ]}
        />
      )}
      {voiding && <VoidDialog funding={voiding} onClose={() => setVoiding(null)} />}
    </Card>
  );
}

function VoidDialog({ funding, onClose }: { funding: SupplierFunding; onClose: () => void }) {
  const [reason, setReason] = useState("");
  const action = useAction({ passkey: true, invalidate: [fxKey, ["vouchers"]], success: "أُلغيت الشحنة" });
  return (
    <Dialog
      open
      onClose={onClose}
      busy={action.busy}
      dirty={!!reason}
      title="إلغاء شحنة"
      subtitle={`${label(supplierLabels, funding.supplier)} · ${rate(funding.usd)}$ بـ ${rate(funding.lyd)} د.ل`}
      icon={<Ban />}
      iconTone="danger"
      footer={
        <>
          <Button
            variant="danger"
            size="lg"
            loading={action.busy}
            disabled={!reason.trim()}
            onClick={async () => {
              const done = await action.run("POST", `/v1/vouchers/admin/fx/fundings/${funding.id}/void`, { reason: reason.trim() });
              if (done) onClose();
            }}
          >
            ألغِ الشحنة
          </Button>
          <Button size="lg" onClick={onClose} disabled={action.busy}>
            رجوع
          </Button>
        </>
      }
    >
      <div className="form">
        <p className="faint">تبقى في السجل ملغاة، ويُعاد حساب تكلفة الرصيد وسعر التسعير بدونها. للتصحيح: ألغِها ثم سجّلها من جديد.</p>
        <Field label="السبب" htmlFor="funding-void-reason">
          <input id="funding-void-reason" className="input" value={reason} onChange={(e) => setReason(e.target.value)} autoFocus />
        </Field>
      </div>
    </Dialog>
  );
}

function HowItWorks({ state }: { state: FXState }) {
  const p = state.policy;
  return (
    <Fold summary="كيف يُحسب سعر التسعير؟">
      <div className="stack faint">
        <p>
          سعر التسعير هو الأعلى من: <b>تكلفة شراء الدولار من جديد</b> (سعر {seriesName(state.series)} + علاوة آخر شحنة)، و<b>أعلى سعر في آخر {p.peak_days} أيام</b>{" "}
          يهبط {pct(p.fall_percent_per_day, 0)} يومياً، ثم تُضاف <b>وسادة</b> قدرها {pct(p.momentum_share_percent, 0)} من صعود الدولار في آخر {p.momentum_days} أيام بحدّ{" "}
          {pct(p.cushion_cap_percent, 0)}.
        </p>
        <p>
          الذروة والوسادة لا تجعلان بطاقة لها سعر منافس معروف أغلى منه: إن تجاوزته تُسعَّر البطاقة بتكلفة إعادة الشحن وحدها، ما دام المورد الذي يُشترى منه هو
          نفسه.
        </p>
        <p>
          العلاوة هي الوسيط لآخر {p.premium_top_ups} شحنات، فلا تغيّر شحنةٌ واحدة شاذة كل الأسعار. وإن انقطع سعر fulus.ly تُسعَّر البطاقات بآخر سعر معروف
          وآخر شحنة مع الوسادة كاملة.
        </p>
        <p>
          ما كلّفتنا دولارات كل مورد يُحسب من الأحدث فالأقدم ويظهر ربحاً أو خسارة صرف.{" "}
          {p.book_floor === "on"
            ? "وتسعير الرصيد بتكلفته مفعّل (fx.book_floor = on): إن هبط الدولار تبقى بطاقات المورد بتكلفتها حتى تُباع، وقد تصير أغلى من المنافسين."
            : "ولا يرفع السعر (fx.book_floor = off): إن هبط الدولار فقد وقعت الخسارة على الرصيد سواء بعنا أم لا، وإبقاء السعر القديم يضيف إليها خسارة الزبائن. نحمي رأس المال بحجم الرصيد لا بالسعر."}
        </p>
        <p>
          تحرّك أكثر من {pct(p.shock_percent, 0)} في يوم يُعدّ صدمة وتنبّه هذه الصفحة. تُغيَّر هذه الأرقام من «التسعير» ← الإعداد (fx.*).
        </p>
      </div>
    </Fold>
  );
}

/** The series priced by over its window, as a line. */
function Sparkline({ points, label: name }: { points: { at: string; rate: string }[]; label: string }) {
  const values = points.map((p) => Number(p.rate)).filter(Number.isFinite);
  const min = Math.min(...values);
  const max = Math.max(...values);
  const span = max - min || 1;
  const w = 320;
  const h = 56;
  const line = values.map((v, i) => `${((i / Math.max(values.length - 1, 1)) * w).toFixed(1)},${(h - ((v - min) / span) * (h - 6) - 3).toFixed(1)}`).join(" ");
  return (
    <figure className="fx-spark">
      <svg viewBox={`0 0 ${w} ${h}`} preserveAspectRatio="none" role="img" aria-label={`سعر ${name} في آخر 30 يوماً`}>
        <polyline points={line} fill="none" stroke="currentColor" strokeWidth="2" vectorEffect="non-scaling-stroke" />
      </svg>
      <figcaption className="row between faint">
        <span>
          {name} · آخر 30 يوماً
        </span>
        <span>
          <bdi className="num">{rate(min)}</bdi> – <bdi className="num">{rate(max)}</bdi>
        </span>
      </figcaption>
    </figure>
  );
}
