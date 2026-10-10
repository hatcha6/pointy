import { useEffect, useMemo, useRef, useState } from "react";
import { ArrowDownLeft, ArrowUpRight, CalendarDays, CalendarCheck, ChevronDown, Info, Plus, Repeat } from "lucide-react";
import { Dialog } from "../dialog";
import { Button, Field, Segmented, Switch } from "../ui";
import { AttachmentPicker } from "./Attachments";
import { useAction } from "../guarded";
import { useToast } from "../toast";
import { idempotencyKey } from "../../lib/stepup";
import { money, parseAmount } from "../../lib/format";
import { useInstallations } from "../../lib/queries";
import {
  categoryOf,
  expenseCategories,
  financeKeys,
  incomeCategories,
  libyaDay,
  monthLabel,
  periodRange,
  shortDay,
  useFinanceSummary,
  yesterday,
  type Direction,
  type Attachment,
  type FinanceEntry,
  type Recurring,
} from "../../lib/finance";

/** How many categories show before «المزيد». */
const VISIBLE_CATEGORIES = 6;

const currencies = [
  { id: "LYD", label: "دينار" },
  { id: "USD", label: "دولار" },
  { id: "EUR", label: "يورو" },
];

export type EntryDraft = Partial<
  Pick<
    FinanceEntry,
    "direction" | "category" | "original_amount" | "currency" | "rate" | "occurred_on" | "counterparty" | "note" | "installation_id" | "reference" | "recurring_id" | "recurring_month"
  >
>;

/**
 * Writes one line in the company's books. What most lines need (direction,
 * amount, category, day) is up front; currency, who, which shop and the
 * paper trail wait behind «تفاصيل إضافية».
 */
export function EntryDialog({ open, onClose, draft }: { open: boolean; onClose: () => void; draft?: EntryDraft }) {
  const toast = useToast();
  const installations = useInstallations();
  const month = periodRange("month");
  const summary = useFinanceSummary(month.from, month.to);
  const action = useAction<FinanceEntry>({ invalidate: [financeKeys.all] });

  const [direction, setDirection] = useState<Direction>("expense");
  const [amount, setAmount] = useState("");
  const [category, setCategory] = useState("");
  const [day, setDay] = useState(libyaDay());
  const [pickingDay, setPickingDay] = useState(false);
  const [note, setNote] = useState("");
  const [moreCategories, setMoreCategories] = useState(false);
  const [details, setDetails] = useState(false);
  const [currency, setCurrency] = useState("LYD");
  const [rate, setRate] = useState("");
  const [counterparty, setCounterparty] = useState("");
  const [shop, setShop] = useState("");
  const [reference, setReference] = useState("");
  const [key, setKey] = useState(idempotencyKey);
  const [attachments, setAttachments] = useState<Attachment[]>([]);
  const [uploading, setUploading] = useState(false);
  // «يتكرر كل شهر»: the line also becomes a monthly one from its month on.
  const [repeat, setRepeat] = useState(false);
  const [repeatAuto, setRepeatAuto] = useState(true);
  const confirming = !!draft?.recurring_id;
  // A monthly line made by a save whose entry then failed: a retry reuses it.
  const madeRecurring = useRef<string>("");

  function reset(next?: EntryDraft, keepDirection?: Direction) {
    const d = next ?? {};
    setDirection(keepDirection ?? d.direction ?? "expense");
    setAmount(d.original_amount ? String(Number(d.original_amount)) : "");
    setCategory(d.category ?? "");
    setDay(d.occurred_on ?? libyaDay());
    setPickingDay(!!d.occurred_on && d.occurred_on !== libyaDay() && d.occurred_on !== yesterday());
    setNote(d.note ?? "");
    setCurrency(d.currency ?? "LYD");
    setRate(d.rate && d.currency && d.currency !== "LYD" ? String(Number(d.rate)) : "");
    setCounterparty(d.counterparty ?? "");
    setShop(d.installation_id ?? "");
    setReference(d.reference ?? "");
    const hasDetails = !!(d.counterparty || d.installation_id || d.reference || (d.currency && d.currency !== "LYD"));
    setDetails(hasDetails);
    setMoreCategories(!!d.category && (d.direction === "income" ? incomeCategories : expenseCategories).findIndex((c) => c.id === d.category) >= VISIBLE_CATEGORIES);
    setKey(idempotencyKey());
    setAttachments([]);
    setRepeat(false);
    setRepeatAuto(true);
    madeRecurring.current = "";
    action.setError(null);
  }

  useEffect(() => {
    if (open) reset(draft);
  }, [open, draft]);

  // A dollar line starts at the rate the shops are priced at today.
  useEffect(() => {
    if (currency === "USD" && !rate && summary.data?.usd_rate.rate) setRate(String(Number(summary.data.usd_rate.rate)));
    if (currency === "LYD") setRate("");
  }, [currency]);

  const categories = direction === "income" ? incomeCategories : expenseCategories;
  const visible = moreCategories ? categories : categories.slice(0, VISIBLE_CATEGORIES);
  const chosenHidden = !moreCategories && category && !visible.some((c) => c.id === category);
  const parsed = parseAmount(amount);
  const parsedRate = currency === "LYD" ? "1" : rate.trim() && Number(rate) > 0 ? rate.trim() : null;
  const dinars = parsed && parsedRate ? Number(parsed) * Number(parsedRate) : null;
  const valid = !!parsed && !!category && !!day && !!parsedRate && !uploading;
  const dayOfMonth = Math.min(Number(day.slice(8, 10)) || 1, 28);

  const shops = useMemo(
    () => [...(installations.data ?? [])].sort((a, b) => (a.shop_name || a.id).localeCompare(b.shop_name || b.id, "ar")),
    [installations.data],
  );

  async function submit(again: boolean) {
    if (!valid || !parsed) return;
    let recurringId = draft?.recurring_id ?? "";
    let recurringMonth = draft?.recurring_month ?? "";
    if (repeat && !confirming && madeRecurring.current) {
      recurringId = madeRecurring.current;
      recurringMonth = day.slice(0, 7);
    } else if (repeat && !confirming) {
      const created = await action.run("POST", "/v1/finance/recurring", {
        direction,
        category,
        amount: parsed,
        currency,
        rate: currency === "LYD" ? "" : parsedRate,
        day_of_month: dayOfMonth,
        mode: repeatAuto ? "auto" : "confirm",
        counterparty: counterparty.trim(),
        note: note.trim(),
        installation_id: shop,
        start_month: day.slice(0, 7),
      });
      if (!created) return;
      recurringId = (created as unknown as Recurring).id;
      madeRecurring.current = recurringId;
      recurringMonth = day.slice(0, 7);
    }
    const saved = await action.run("POST", "/v1/finance/entries", {
      direction,
      category,
      amount: parsed,
      currency,
      rate: currency === "LYD" ? "" : parsedRate,
      occurred_on: day,
      note: note.trim(),
      counterparty: counterparty.trim(),
      installation_id: shop,
      reference: reference.trim(),
      idempotency_key: key,
      attachments: attachments.map((a) => ({ sha256: a.sha256, name: a.name })),
      recurring_id: recurringId,
      recurring_month: recurringMonth,
    });
    if (!saved) return;
    toast.success(
      `${direction === "income" ? "سُجّل دخل" : "سُجّل مصروف"} ${money(saved.amount)}`,
      `${categoryOf(direction, category).label} · ${shortDay(saved.occurred_on)}${repeat ? " · يتكرر كل شهر" : ""}`,
    );
    if (again) reset(undefined, direction);
    else onClose();
  }

  const income = direction === "income";
  return (
    <Dialog
      open={open}
      onClose={onClose}
      busy={action.busy}
      dirty={!!(amount.trim() && amount !== (draft?.original_amount ? String(Number(draft.original_amount)) : "")) || !!note.trim() && note !== (draft?.note ?? "") || attachments.length > 0}
      title={confirming ? `${categoryOf(direction, category).label} — ${monthLabel(draft?.recurring_month ?? "", true)}` : income ? "تسجيل دخل" : "تسجيل مصروف"}
      subtitle={confirming ? "أكّد مبلغ هذا الشهر كما في الفاتورة" : "في دفتر حسابات الشركة"}
      icon={confirming ? <CalendarCheck /> : income ? <ArrowDownLeft /> : <ArrowUpRight />}
      iconTone={income ? "money" : "danger"}
      footer={
        <>
          <Button variant="primary" size="lg" loading={action.busy} disabled={!valid} onClick={() => submit(false)}>
            {dinars ? `حفظ ${money(dinars)}` : "حفظ"}
          </Button>
          {!confirming && (
            <Button size="lg" icon={<Plus />} disabled={!valid || action.busy} onClick={() => submit(true)} title="يحفظ ويبقي النافذة مفتوحة لسطر جديد">
              حفظ وإضافة آخر
            </Button>
          )}
        </>
      }
    >
      <form
        className="form"
        onSubmit={(event) => {
          event.preventDefault();
          void submit(false);
        }}
      >
        <div className={`direction-toggle ${direction}`} hidden={confirming}>
          <Segmented
            value={direction}
            onChange={(next) => {
              setDirection(next);
              setCategory("");
              setMoreCategories(false);
            }}
            options={[
              { id: "expense", label: "مصروف" },
              { id: "income", label: "دخل" },
            ]}
          />
        </div>

        <Field label="المبلغ" htmlFor="fin-amount" error={amount && !parsed ? "اكتب مبلغاً موجباً بخانتين عشريتين على الأكثر." : null}>
          <div className="input-affix">
            <input
              id="fin-amount"
              className="input amount"
              inputMode="decimal"
              autoComplete="off"
              autoFocus
              placeholder="0.00"
              value={amount}
              onChange={(e) => setAmount(e.target.value)}
            />
            <span className="affix">{currency === "LYD" ? "د.ل" : currency}</span>
          </div>
        </Field>

        <div className="field" hidden={confirming}>
          <span className="field-label">{income ? "مصدر الدخل" : "نوع المصروف"}</span>
          <div className="chips category-chips">
            {visible.map((c) => {
              const Icon = c.icon;
              return (
                <button type="button" key={c.id} className={`chip ${category === c.id ? "on" : ""}`} onClick={() => setCategory(c.id)} title={c.hint}>
                  <Icon width={15} />
                  {c.label}
                </button>
              );
            })}
            {chosenHidden && (
              <button type="button" className="chip on">
                {categoryOf(direction, category).label}
              </button>
            )}
            {categories.length > VISIBLE_CATEGORIES && (
              <button type="button" className="chip ghost-chip" onClick={() => setMoreCategories((v) => !v)}>
                {moreCategories ? "أقل" : `المزيد (${categories.length - VISIBLE_CATEGORIES})`}
                <ChevronDown width={14} className={moreCategories ? "flip" : ""} />
              </button>
            )}
          </div>
          {category && categoryOf(direction, category).hint && <span className="help">{categoryOf(direction, category).hint}</span>}
        </div>

        <div className="field">
          <span className="field-label">التاريخ</span>
          <div className="chips">
            <button type="button" className={`chip ${!pickingDay && day === libyaDay() ? "on" : ""}`} onClick={() => (setDay(libyaDay()), setPickingDay(false))}>
              اليوم
            </button>
            <button type="button" className={`chip ${!pickingDay && day === yesterday() ? "on" : ""}`} onClick={() => (setDay(yesterday()), setPickingDay(false))}>
              أمس
            </button>
            <button type="button" className={`chip ${pickingDay ? "on" : ""}`} onClick={() => setPickingDay(true)}>
              <CalendarDays width={15} />
              {pickingDay ? shortDay(day) : "تاريخ آخر…"}
            </button>
          </div>
          {pickingDay && (
            <input type="date" className="input" value={day} max={libyaDay()} min="2020-01-01" onChange={(e) => e.target.value && setDay(e.target.value)} />
          )}
        </div>

        {!confirming && (
          <div className={`repeat-box ${repeat ? "on" : ""}`}>
            <div className="switch-row">
              <Repeat width={17} className="muted" />
              <div className="text">
                يتكرر كل شهر
                <span>{repeat ? `يوم ${dayOfMonth} من كل شهر، بدءاً من ${monthLabel(day.slice(0, 7))}.` : "الإيجار، الخادم، الرواتب: سجّله مرة واحدة."}</span>
              </div>
              <Switch on={repeat} onChange={setRepeat} label="يتكرر كل شهر" />
            </div>
            {repeat && (
              <Segmented
                value={repeatAuto ? "auto" : "confirm"}
                onChange={(v) => setRepeatAuto(v === "auto")}
                options={[
                  { id: "auto", label: "يُسجّل وحده بنفس المبلغ" },
                  { id: "confirm", label: "يذكّرني لأؤكد المبلغ" },
                ]}
              />
            )}
          </div>
        )}

        <Field label="وصف قصير" help="اختياري — يظهر في الدفتر بجانب المبلغ.">
          <input
            className="input"
            value={note}
            maxLength={200}
            placeholder={income ? "مثلاً: اشتراك سنة — محل النسيم" : "مثلاً: فاتورة الخادم لشهر أكتوبر"}
            onChange={(e) => setNote(e.target.value)}
          />
        </Field>

        <AttachmentPicker value={attachments} onChange={setAttachments} onBusy={setUploading} />

        <button type="button" className="disclosure" aria-expanded={details} onClick={() => setDetails((v) => !v)}>
          <ChevronDown width={16} className={details ? "flip" : ""} />
          تفاصيل إضافية
          <span className="muted">العملة، الجهة، المتجر، رقم المرجع</span>
        </button>

        {details && (
          <div className="form disclosure-body">
            <div className="field">
              <span className="field-label">عملة الدفع</span>
              <Segmented value={currency} onChange={setCurrency} options={currencies} />
            </div>
            {currency !== "LYD" && (
              <Field
                label={`سعر ${currency === "USD" ? "الدولار" : "اليورو"} بالدينار`}
                help={
                  dinars
                    ? `يُسجّل في الدفتر ${money(dinars)}`
                    : currency === "USD" && summary.data?.usd_rate.rate
                      ? "مُعبّأ بسعر التسعير الحالي؛ عدّله إلى السعر الذي دفعت به."
                      : "السعر الذي دفعت به فعلاً."
                }
              >
                <input className="input" inputMode="decimal" dir="ltr" value={rate} onChange={(e) => setRate(e.target.value)} placeholder="7.25" />
              </Field>
            )}
            <div className="form-row">
              <Field label={income ? "من دفع" : "لمن دُفع"}>
                <input className="input" value={counterparty} maxLength={200} onChange={(e) => setCounterparty(e.target.value)} placeholder={income ? "اسم الزبون" : "Azure، المؤجّر…"} />
              </Field>
              <Field label="رقم المرجع">
                <input className="input" value={reference} maxLength={200} onChange={(e) => setReference(e.target.value)} placeholder="فاتورة أو حوالة" />
              </Field>
            </div>
            <Field label="متجر مرتبط" help="اختياري — يظهر السطر في صفحة المتجر.">
              <select className="select" value={shop} onChange={(e) => setShop(e.target.value)}>
                <option value="">بلا متجر</option>
                {shops.map((s) => (
                  <option key={s.id} value={s.id}>
                    {s.shop_name || s.id}
                  </option>
                ))}
              </select>
            </Field>
          </div>
        )}

        {!income && !confirming && (
          <p className="inline-hint">
            <Info width={15} />
            تكلفة الرسائل والبطاقات تُحسب تلقائياً عند كل عملية؛ لا تسجّل شحن رصيد رسالة أو الموردين هنا حتى لا تُحسب مرتين.
          </p>
        )}
        {action.error && <p className="error-text">{action.error}</p>}
        <button type="submit" hidden />
      </form>
    </Dialog>
  );
}
