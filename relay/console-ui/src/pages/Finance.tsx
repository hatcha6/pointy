import { useEffect, useMemo, useState } from "react";
import { AlertTriangle, ArrowDownLeft, ArrowUpRight, BookOpenText, ChevronDown, Info, PiggyBank, Wallet } from "lucide-react";
import { Button, Card, Empty, Money, Notice, Segmented, Skeleton } from "../components/ui";
import { Breakdown, Delta, MonthlyChart } from "../components/finance/charts";
import { EntryDialog, type EntryDraft } from "../components/finance/EntryDialog";
import { DueStrip } from "../components/finance/Recurring";
import { useWallets } from "../lib/queries";
import { Link, useSearchParam, useSetSearch } from "../lib/router";
import { money } from "../lib/format";
import { label, method as methodLabels } from "../lib/labels";
import { change, periodPhrase, periodRange, periods, shortDay, useFinanceSummary, type Direction, type PeriodId } from "../lib/finance";

/** The period a finance page reads, kept in the address so a link shares it. */
export function usePeriod() {
  const [period] = useSearchParam("period");
  const [from] = useSearchParam("from");
  const [to] = useSearchParam("to");
  const setSearch = useSetSearch();
  const id = (period || "month") as PeriodId;
  const range = periodRange(id, { from, to });
  return {
    id,
    range,
    // A preset needs no days in the address; a custom period keeps both.
    setPeriod: (next: string) =>
      setSearch(next === "custom" ? { period: next, from: range.from, to: range.to } : { period: next, from: "", to: "" }),
    setFrom: (day: string) => setSearch({ from: day }),
    setTo: (day: string) => setSearch({ to: day }),
  };
}

export function PeriodPicker({ period }: { period: ReturnType<typeof usePeriod> }) {
  const custom = period.id === "custom";
  return (
    <div className="period-picker">
      <Segmented
        value={custom ? ("custom" as PeriodId) : period.id}
        onChange={(next) => period.setPeriod(next === "month" ? "" : next)}
        options={[...periods, { id: "custom" as PeriodId, label: "مخصّصة" }]}
      />
      {custom && (
        <div className="period-custom">
          <input type="date" className="input" value={period.range.from} max={period.range.to} onChange={(e) => e.target.value && period.setFrom(e.target.value)} aria-label="من" />
          <span className="muted">إلى</span>
          <input type="date" className="input" value={period.range.to} min={period.range.from} onChange={(e) => e.target.value && period.setTo(e.target.value)} aria-label="إلى" />
        </div>
      )}
    </div>
  );
}

/** Opens the entry dialog from `?do=income|expense` (the palette's way in). */
export function useEntryDialog() {
  const [doParam, setDo] = useSearchParam("do");
  const [draft, setDraft] = useState<EntryDraft | null>(null);
  useEffect(() => {
    if (doParam === "income" || doParam === "expense") {
      setDraft({ direction: doParam });
      setDo("");
    }
  }, [doParam]);
  return {
    draft,
    open: (next: EntryDraft) => setDraft(next),
    dialog: <EntryDialog open={draft !== null} draft={draft ?? undefined} onClose={() => setDraft(null)} />,
  };
}

export function Finance() {
  const period = usePeriod();
  const { from, to } = period.range;
  const summary = useFinanceSummary(from, to);
  const wallets = useWallets();
  const entry = useEntryDialog();
  const [explain, setExplain] = useState(false);
  const data = summary.data;
  const phrase = periodPhrase(period.id, period.range);
  const ledgerQuery = useMemo(() => `&from=${from}&to=${to}`, [from, to]);

  const net = Number(data?.totals.net ?? 0);
  const held = (wallets.data?.wallets ?? []).reduce((sum, w) => sum + Number(w.balance || 0), 0);
  const nothingYet = data && Number(data.totals.income) === 0 && Number(data.totals.expense) === 0 && data.manual_count === 0;
  const unpriced = Object.entries(data?.unpriced ?? {});

  const add = (direction: Direction) => () => entry.open({ direction });

  return (
    <div className="fin">
      <div className="page-head">
        <div className="titles">
          <h1>الأرباح والخسائر</h1>
          <p>ما تكسبه الشركة وما تنفقه: ما يسجّله النظام بنفسه، وما تضيفه أنت في الدفتر.</p>
        </div>
        <div className="actions">
          <Button icon={<ArrowDownLeft />} onClick={add("income")}>
            دخل
          </Button>
          <Button variant="primary" icon={<ArrowUpRight />} onClick={add("expense")}>
            مصروف
          </Button>
        </div>
      </div>

      <PeriodPicker period={period} />

      <DueStrip onConfirm={entry.open} limit={3} />

      {summary.isError && (
        <Notice tone="danger" icon={<AlertTriangle />}>
          تعذّر حساب الأرباح. حدّث الصفحة بعد قليل.
        </Notice>
      )}

      <section className={`pnl-hero ${!data ? "" : net > 0 ? "up" : net < 0 ? "down" : ""}`}>
        <div className="pnl-main">
          <span className="pnl-label">
            {net < 0 ? "صافي الخسارة" : "صافي الربح"} · {phrase}
          </span>
          <div className="pnl-value">{data ? <Money value={Math.abs(net)} /> : <Skeleton height={44} width={220} />}</div>
          <div className="pnl-sentence">
            {data ? (
              <>
                {Number(data.totals.income) > 0 ? (
                  <>
                    من دخل <Money value={data.totals.income} /> بعد مصروفات <Money value={data.totals.expense} />.
                  </>
                ) : Number(data.totals.expense) > 0 ? (
                  <>
                    مصروفات <Money value={data.totals.expense} /> ولا دخل بعد في هذه الفترة.
                  </>
                ) : (
                  "لا حركة في هذه الفترة بعد."
                )}{" "}
                <Delta value={change(data.totals.net, data.previous.totals.net)} />
              </>
            ) : (
              <Skeleton height={16} width={260} />
            )}
          </div>
        </div>
        <dl className="pnl-stats">
          <div>
            <dt>الدخل</dt>
            <dd>{data ? <Money value={data.totals.income} /> : <Skeleton height={20} width={90} />}</dd>
            {data && <Delta value={change(data.totals.income, data.previous.totals.income)} suffix="" />}
          </div>
          <div>
            <dt>المصروف</dt>
            <dd>{data ? <Money value={data.totals.expense} /> : <Skeleton height={20} width={90} />}</dd>
            {data && <Delta value={change(data.totals.expense, data.previous.totals.expense)} good="down" suffix="" />}
          </div>
          <div>
            <dt>هامش الربح</dt>
            <dd className="num">{data ? (data.totals.margin_percent ? `${data.totals.margin_percent}%` : "—") : <Skeleton height={20} width={60} />}</dd>
            {data && (
              <span className="delta flat">
                الفترة السابقة {shortDay(data.previous.from)} – {shortDay(data.previous.to)}
              </span>
            )}
          </div>
        </dl>
      </section>

      {nothingYet && (
        <Card>
          <Empty icon={<BookOpenText />} title="ابدأ دفتر الشركة">
            <p className="muted" style={{ maxWidth: 460, margin: "6px auto 14px" }}>
              ما تدفعه المتاجر من محافظها يظهر هنا وحده. سجّل ما لا يراه النظام: فاتورة الخادم، الرواتب، اشتراك دُفع نقداً في المكتب.
            </p>
            <div className="row" style={{ justifyContent: "center" }}>
              <Button variant="primary" icon={<ArrowUpRight />} onClick={add("expense")}>
                سجّل أول مصروف
              </Button>
              <Button icon={<ArrowDownLeft />} onClick={add("income")}>
                سجّل دخلاً
              </Button>
            </div>
          </Empty>
        </Card>
      )}

      {data && data.months.length > 1 && (
        <Card title="شهراً بشهر" hint={phrase}>
          <MonthlyChart months={data.months} />
        </Card>
      )}

      {data && !nothingYet && (
        <div className="grid two">
          <Card tight title="من أين جاء الدخل" actions={<Link to={`/ledger?direction=income${ledgerQuery}`}>القيود</Link>}>
            {data.income.length ? (
              <Breakdown direction="income" lines={data.income} total={data.totals.income} ledgerQuery={ledgerQuery} />
            ) : (
              <Empty title="لا دخل في هذه الفترة">
                <Button size="sm" icon={<ArrowDownLeft />} onClick={add("income")}>
                  سجّل دخلاً
                </Button>
              </Empty>
            )}
          </Card>
          <Card tight title="أين ذهب المال" actions={<Link to={`/ledger?direction=expense${ledgerQuery}`}>القيود</Link>}>
            {data.expense.length ? (
              <Breakdown direction="expense" lines={data.expense} total={data.totals.expense} ledgerQuery={ledgerQuery} />
            ) : (
              <Empty title="لا مصروفات مسجّلة في هذه الفترة">
                <Button size="sm" icon={<ArrowUpRight />} onClick={add("expense")}>
                  سجّل مصروفاً
                </Button>
              </Empty>
            )}
          </Card>
        </div>
      )}

      {unpriced.length > 0 && (
        <Notice tone="warning" icon={<AlertTriangle />}>
          تكاليف موردين بعملة بلا سعر صرف لم تدخل الحساب:{" "}
          {unpriced.map(([currency, amount]) => money(amount, currency)).join("، ")}. اضبط سعر الصرف في <Link to="/pricing">التسعير</Link>.
        </Notice>
      )}

      <Card
        title={
          <span className="row">
            <PiggyBank width={18} /> أموال المتاجر لدينا
          </span>
        }
        hint="ليست ربحاً"
      >
        <div className="held">
          <div>
            <span className="muted">دخلت المحافظ {phrase}</span>
            <strong>{data ? <Money value={data.topups.total} /> : <Skeleton height={22} width={100} />}</strong>
          </div>
          <div>
            <span className="muted">في كل المحافظ الآن</span>
            <strong>{wallets.isLoading ? <Skeleton height={22} width={100} /> : <Money value={held} />}</strong>
          </div>
          <Link to="/wallets" className="btn sm">
            <Wallet /> المحافظ
          </Link>
        </div>
        <p className="muted held-note">
          ما يشحنه المتجر يبقى ماله حتى يصرفه على خدمة. عندها فقط يصبح دخلاً ويظهر أعلاه.
        </p>
        {data && Object.keys(data.topups.by_method).length > 0 && (
          <ul className="held-methods">
            {Object.entries(data.topups.by_method)
              .sort((a, b) => Number(b[1]) - Number(a[1]))
              .map(([m, amount]) => (
                <li key={m}>
                  <span>{label(methodLabels, m)}</span>
                  <Money value={amount} />
                </li>
              ))}
          </ul>
        )}
      </Card>

      <button type="button" className="disclosure explain-toggle" aria-expanded={explain} onClick={() => setExplain((v) => !v)}>
        <ChevronDown width={16} className={explain ? "flip" : ""} />
        <Info width={16} />
        كيف تُحسب هذه الأرقام؟
      </button>
      {explain && (
        <Card className="explain">
          <ul>
            <li>
              <strong>تلقائي:</strong> ما دفعته المتاجر من محافظها لكل خدمة (بعد طرح الاسترداد)، وما دفعناه لموردي البطاقات والشحن، وما خصمته شركة
              الرسائل عن كل رسالة خرجت. العمليات التجريبية لا تُحسب.
            </li>
            <li>
              <strong>يدوي:</strong> كل قيد في <Link to="/ledger">دفتر الحسابات</Link>. القيد الملغى لا يُحسب لكنه يبقى في الدفتر.
            </li>
            <li>
              <strong>الدولار:</strong>{" "}
              {data?.usd_rate.rate
                ? `تكاليف الموردين بالدولار محوّلة بسعر ${money(Number(data.usd_rate.rate).toFixed(3))} (${data.usd_rate.source === "manual" ? "السعر اليدوي" : "سعر السوق من fulus.ly"}) — تقدير بسعر اليوم.`
                : "لا يوجد سعر دولار في التسعير؛ تكاليف الدولار تظهر منفصلة ولا تدخل الحساب."}
            </li>
            <li>
              <strong>الأشهر</strong> بتوقيت ليبيا. المقارنة مع فترة سابقة بنفس الطول.
            </li>
            <li>
              شحن رصيد شركة الرسائل أو الموردين ليس مصروفاً جديداً: تكلفته تُحسب عند كل استعمال، فلا تسجّله في الدفتر حتى لا يُحسب مرتين.
            </li>
          </ul>
        </Card>
      )}

      {entry.dialog}
    </div>
  );
}
