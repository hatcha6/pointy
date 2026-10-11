import { useState, type ReactNode } from "react";
import { AlertTriangle, ChevronDown, Info, PiggyBank } from "lucide-react";
import { Button, Money, Notice, Skeleton } from "../ui";
import { Link } from "../../lib/router";
import { count, money } from "../../lib/format";
import { libyaDay, serviceCategory, trackedLinks, useFinancePosition, type FinancePosition } from "../../lib/finance";

/** The ledger since the first day, for one kind of line. */
const allTime = (direction: string) => `/ledger?direction=${direction}&period=custom&from=2020-01-01&to=${libyaDay()}`;

/**
 * The money that is the owners' to take now: everything the company earned,
 * less what it never actually received and what was already taken. The number
 * is up front; how it was reached (sales, cost and profit by service, then
 * every subtraction) waits behind a disclosure.
 */
export function AvailableCard({ onWithdraw }: { onWithdraw: () => void }) {
  const position = useFinancePosition();
  const [open, setOpen] = useState(false);
  const data = position.data;
  const available = Number(data?.available ?? 0);
  const short = data && available < 0;

  if (position.isError) {
    return (
      <Notice tone="danger" icon={<AlertTriangle />}>
        تعذّر حساب المال المتاح لك. حدّث الصفحة بعد قليل.
      </Notice>
    );
  }

  return (
    <section className={`available ${short ? "short" : ""}`}>
      <div className="available-head">
        <span className="available-icon">
          <PiggyBank />
        </span>
        <div className="available-main">
          <span className="pnl-label">مالك المتاح للسحب الآن</span>
          <div className="available-value">{data ? <Money value={Math.max(available, 0)} /> : <Skeleton height={40} width={200} />}</div>
          <p className="available-sentence">
            {!data ? (
              <Skeleton height={16} width={280} />
            ) : short && Number(data.net_profit) <= 0 ? (
              <>
                لا ربح بعد: منذ البداية زادت المصروفات على الدخل بـ <Money value={-Number(data.net_profit)} />.
              </>
            ) : short ? (
              <>
                لا شيء متاح للسحب: ما سحبته وما لم يُحصّل بعد يزيدان على الربح بـ <Money value={-available} />.
              </>
            ) : (
              <>
                ربح تحقّق ودخل فعلاً، بعد طرح ما على المتاجر من ديون وما لم يكتمل وما سحبته من قبل
                {Number(data.withdrawn) > 0 && (
                  <>
                    {" "}
                    (<Money value={data.withdrawn} />)
                  </>
                )}
                .
              </>
            )}
          </p>
        </div>
        <div className="available-actions">
          <Button variant="primary" icon={<PiggyBank />} disabled={!data} onClick={onWithdraw}>
            سجّل سحباً
          </Button>
        </div>
      </div>

      {data && <ServiceTable data={data} />}

      <button type="button" className="disclosure" aria-expanded={open} onClick={() => setOpen((v) => !v)}>
        <ChevronDown width={16} className={open ? "flip" : ""} />
        كيف وصلنا إلى هذا الرقم؟
      </button>
      {open && data && <Steps data={data} />}
    </section>
  );
}

/** Sales, cost and profit of every service, since the first sale. */
function ServiceTable({ data }: { data: FinancePosition }) {
  if (!data.services.length) {
    return <p className="muted">لم تُبع أي خدمة بعد.</p>;
  }
  return (
    <div className="profit-table-wrap">
      <table className="profit-table">
        <thead>
          <tr>
            <th>الخدمة · منذ البداية</th>
            <th>المبيعات</th>
            <th>التكلفة</th>
            <th>الربح</th>
            <th className="col-margin">الهامش</th>
          </tr>
        </thead>
        <tbody>
          {data.services.map((line) => {
            const c = serviceCategory(line.key);
            const Icon = c.icon;
            const to = trackedLinks[line.key];
            return (
              <tr key={line.key}>
                <td>
                  <span className="inline-icons">
                    <Icon width={15} className="muted" />
                    {to ? <Link to={to}>{c.label}</Link> : c.label}
                  </span>
                </td>
                <td data-label="المبيعات">
                  <Money value={line.sales} />
                </td>
                <td data-label="التكلفة">{Number(line.cost) > 0 ? <Money value={line.cost} /> : <span className="faint" title="تكلفتها في المصروفات المسجّلة">—</span>}</td>
                <td data-label="الربح">
                  <Money value={line.profit} signed />
                </td>
                <td className="col-margin">{line.margin_percent ? <span className="num">{line.margin_percent}%</span> : "—"}</td>
              </tr>
            );
          })}
        </tbody>
        <tfoot>
          <tr>
            <th>المجموع</th>
            <th data-label="المبيعات">
              <Money value={data.gross.sales} />
            </th>
            <th data-label="التكلفة">
              <Money value={data.gross.cost} />
            </th>
            <th data-label="الربح">
              <Money value={data.gross.profit} signed />
            </th>
            <th className="col-margin">{data.gross.margin_percent ? <span className="num">{data.gross.margin_percent}%</span> : "—"}</th>
          </tr>
        </tfoot>
      </table>
    </div>
  );
}

/** Every step from the services' profit down to what is left to take. */
function Steps({ data }: { data: FinancePosition }) {
  const steps: { label: ReactNode; value: string | number; sign: "+" | "−" | "="; hint?: ReactNode }[] = [
    { label: "ربح الخدمات (المبيعات ناقص تكلفتها)", value: data.gross.profit, sign: "=" },
    { label: <Link to={allTime("income")}>دخل سجّلته في الدفتر</Link>, value: data.manual_income, sign: "+" },
    {
      label: <Link to={allTime("expense")}>مصروفات سجّلتها في الدفتر</Link>,
      value: data.manual_expense,
      sign: "−",
      hint: "الخوادم والرواتب واشتراك الذكاء الاصطناعي وغيرها — تكلفة الاشتراكات تأتي من هنا.",
    },
    {
      label: <Link to="/company">مشتريات الشركة لنفسها</Link>,
      value: data.company_purchases ?? "0",
      sign: "−",
      hint: "بطاقات وشحن وفواتير اشتريناها من الموردين لاستخدامنا أو للبيع نقداً.",
    },
    { label: "صافي الربح منذ البداية", value: data.net_profit, sign: "=" },
    {
      label: <Link to="/wallets">ديون على المتاجر</Link>,
      value: data.shops_owe,
      sign: "−",
      hint: data.owing_shops ? `${count(data.owing_shops)} ${data.owing_shops === 1 ? "متجر صرف" : "متاجر صرفت"} أكثر مما دفع — ربح لم يصل بعد.` : undefined,
    },
    {
      label: <Link to="/purchases?held=1">عمليات لم تكتمل</Link>,
      value: data.in_flight,
      sign: "−",
      hint: "بطاقات قيد الشراء ورسائل تنتظر تأكيد شركة الرسائل: قد تعود للمتجر.",
    },
    { label: "رصيد مجاني منحته (تعويضات)", value: data.goodwill, sign: "−", hint: "صُرف كأنه مال، ولم يدخل مقابله شيء." },
    { label: <Link to={allTime("withdrawal")}>ما سحبته من قبل</Link>, value: data.withdrawn, sign: "−" },
    { label: "المتاح لك الآن", value: data.available, sign: "=" },
  ];
  const unpriced = Object.entries(data.unpriced ?? {});
  return (
    <div className="available-steps">
      <ol>
        {steps
          .filter((s) => s.sign === "=" || Number(s.value) !== 0)
          .map((s, i) => (
            <li key={i} className={s.sign === "=" ? "total" : ""}>
              <span className="sign">{s.sign}</span>
              <span className="what">
                {s.label}
                {s.hint && <small>{s.hint}</small>}
              </span>
              <Money value={s.value} signed={s.sign === "="} />
            </li>
          ))}
      </ol>
      {unpriced.length > 0 && (
        <Notice tone="warning" icon={<AlertTriangle />}>
          تكاليف موردين بعملة بلا سعر صرف لم تُطرح: {unpriced.map(([currency, amount]) => money(amount, currency)).join("، ")}. الرقم أعلى من الحقيقة بقيمتها — اضبط
          سعر الصرف في <Link to="/pricing">التسعير</Link>.
        </Notice>
      )}
      <ul className="available-notes">
        <li>
          <Info width={14} />
          <span>
            أموال المتاجر غير المصروفة (<Money value={data.shops_hold} />) ليست لك ولم تدخل هذا الحساب.
          </span>
        </li>
        {Number(data.stock_cost) > 0 && (
          <li>
            <Info width={14} />
            <span>
              جزء من مالك مدفوع في <Link to="/stock">بطاقات لم تُبع بعد</Link> (<Money value={data.stock_cost} />) أو في أرصدة الموردين المدفوعة مسبقاً؛ تأكّد من رصيد المصرف
              قبل السحب.
            </span>
          </li>
        )}
        {data.usd_rate.rate && (
          <li>
            <Info width={14} />
            <span>تكاليف الدولار محوّلة بسعر اليوم ({money(Number(data.usd_rate.rate).toFixed(3))}) — تقدير.</span>
          </li>
        )}
      </ul>
    </div>
  );
}
