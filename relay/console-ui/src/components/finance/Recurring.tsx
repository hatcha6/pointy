import { useEffect, useState } from "react";
import { BellRing, CalendarClock, Pause, Pencil, Play, Plus, Repeat, SkipForward } from "lucide-react";
import { Badge, Button, Card, Empty, Field, Money, Segmented, Skeleton } from "../ui";
import { Dialog } from "../dialog";
import { useAction } from "../guarded";
import { money, parseAmount } from "../../lib/format";
import {
  categoryOf,
  dueDay,
  dueItems,
  financeKeys,
  libyaDay,
  monthLabel,
  shortDay,
  useRecurring,
  type Recurring,
} from "../../lib/finance";
import type { EntryDraft } from "./EntryDialog";

/** What confirming a due month starts the entry dialog with. */
export function draftForMonth(r: Recurring, month: string): EntryDraft {
  const day = dueDay(r, month);
  const today = libyaDay();
  return {
    direction: r.direction,
    category: r.category,
    original_amount: r.amount,
    currency: r.currency,
    rate: r.rate,
    occurred_on: day < today ? day : today,
    counterparty: r.counterparty,
    note: r.note,
    installation_id: r.installation_id,
    recurring_id: r.id,
    recurring_month: month,
  };
}

function useRecurringAction(success?: string) {
  return useAction({ invalidate: [financeKeys.all], success });
}

/**
 * Monthly lines waiting for their amount. Shown wherever the books are read,
 * so a bill never waits unseen; each one is a tap to confirm or skip.
 */
export function DueStrip({ onConfirm, limit = 4 }: { onConfirm: (draft: EntryDraft) => void; limit?: number }) {
  const recurring = useRecurring();
  const skip = useRecurringAction("تُخطّي الشهر.");
  const items = dueItems(recurring.data?.recurring);
  if (!items.length) return null;
  return (
    <div className="due-strip" role="region" aria-label="مستحقات شهرية">
      <div className="due-head">
        <BellRing width={17} />
        <strong>{items.length === 1 ? "مصروف شهري ينتظر مبلغه" : `${items.length} مصروفات شهرية تنتظر مبالغها`}</strong>
      </div>
      <ul>
        {items.slice(0, limit).map(({ recurring: r, month }) => {
          const c = categoryOf(r.direction, r.category);
          const Icon = c.icon;
          return (
            <li key={r.id + month}>
              <span className={`l-icon ${r.direction}`}>
                <Icon />
              </span>
              <div className="due-text">
                <strong>
                  {c.label} — {monthLabel(month)}
                </strong>
                <span className="muted">
                  {r.note || "المعتاد"} <Money value={r.amount} currency={r.currency === "LYD" ? undefined : r.currency} /> · استحق {shortDay(dueDay(r, month))}
                </span>
              </div>
              <Button size="sm" variant="primary" onClick={() => onConfirm(draftForMonth(r, month))}>
                تأكيد المبلغ
              </Button>
              <Button
                size="sm"
                variant="ghost"
                icon={<SkipForward />}
                loading={skip.busy}
                title="لم يكن هناك هذا الشهر"
                onClick={() => skip.run("PATCH", `/v1/finance/recurring/${encodeURIComponent(r.id)}`, { skip: month })}
              >
                تخطّي
              </Button>
            </li>
          );
        })}
      </ul>
      {items.length > limit && <div className="due-more muted">و{items.length - limit} غيرها في تبويب «الشهرية».</div>}
    </div>
  );
}

/** Every monthly line: what it writes, when, and what it wrote last. */
export function RecurringList({ onConfirm, onNew }: { onConfirm: (draft: EntryDraft) => void; onNew: () => void }) {
  const recurring = useRecurring();
  const toggle = useRecurringAction();
  const [editing, setEditing] = useState<Recurring | null>(null);
  const list = recurring.data?.recurring ?? [];
  const active = list.filter((r) => r.active);
  const monthly = active.filter((r) => r.direction === "expense").reduce((sum, r) => sum + Number(r.amount) * (r.currency === "LYD" ? 1 : Number(r.rate) || 0), 0);

  if (recurring.isLoading) return <Skeleton height={160} />;
  if (!list.length) {
    return (
      <Card>
        <Empty icon={<Repeat />} title="لا مصروفات شهرية بعد">
          <p className="muted" style={{ maxWidth: 440, margin: "6px auto 12px" }}>
            الإيجار، الخادم، الرواتب: سجّل أيّاً منها مرة واحدة وفعّل «يتكرر كل شهر»، فيُكتب كل شهر وحده أو يذكّرك لتؤكد مبلغه.
          </p>
          <Button variant="primary" icon={<Plus />} onClick={onNew}>
            مصروف شهري جديد
          </Button>
        </Empty>
      </Card>
    );
  }
  return (
    <>
      <div className="recurring-sum muted">
        {active.length} شهرية تعمل · المصروف الثابت شهرياً نحو <Money value={monthly} />
      </div>
      <div className="recurring-grid">
        {list.map((r) => {
          const c = categoryOf(r.direction, r.category);
          const Icon = c.icon;
          return (
            <Card key={r.id} className={`recurring-card ${r.active ? "" : "stopped"}`}>
              <div className="rc-top">
                <span className={`l-icon ${r.direction}`}>
                  <Icon />
                </span>
                <div className="rc-title">
                  <strong>{c.label}</strong>
                  {r.note && <span className="muted">{r.note}</span>}
                </div>
                <div className="rc-amount">
                  <Money value={r.amount} currency={r.currency === "LYD" ? undefined : r.currency} />
                  <span className="faint">شهرياً</span>
                </div>
              </div>
              <div className="rc-meta">
                <span>
                  <CalendarClock width={14} /> يوم {r.day_of_month}
                </span>
                {r.mode === "auto" ? <Badge tone="info">يُسجّل وحده</Badge> : <Badge tone="warning">بتأكيد المبلغ</Badge>}
                {!r.active && <Badge>متوقف</Badge>}
                {r.due.length > 0 && <Badge tone="money">{r.due.length} مستحق</Badge>}
              </div>
              <div className="rc-foot muted">
                {r.active && r.next_day ? `القادم ${shortDay(r.next_day)}` : r.active ? "انتهت مدته" : "لا يُكتب شيء حتى تستأنفه"}
                {r.last_month && ` · آخر شهر ${monthLabel(r.last_month)}`}
              </div>
              <div className="rc-actions">
                {r.due.map((m) => (
                  <Button key={m} size="sm" variant="primary" onClick={() => onConfirm(draftForMonth(r, m))}>
                    تأكيد {monthLabel(m)}
                  </Button>
                ))}
                <span className="spacer" />
                <Button size="sm" variant="ghost" icon={<Pencil />} onClick={() => setEditing(r)}>
                  تعديل
                </Button>
                <Button
                  size="sm"
                  variant="ghost"
                  icon={r.active ? <Pause /> : <Play />}
                  loading={toggle.busy}
                  onClick={() => toggle.run("PATCH", `/v1/finance/recurring/${encodeURIComponent(r.id)}`, { active: !r.active })}
                >
                  {r.active ? "إيقاف" : "استئناف"}
                </Button>
              </div>
            </Card>
          );
        })}
      </div>
      <RecurringEditDialog recurring={editing} onClose={() => setEditing(null)} />
    </>
  );
}

/** Changes a monthly line from now on; lines already written stay as they are. */
function RecurringEditDialog({ recurring, onClose }: { recurring: Recurring | null; onClose: () => void }) {
  const [amount, setAmount] = useState("");
  const [rate, setRate] = useState("");
  const [day, setDay] = useState(1);
  const [mode, setMode] = useState<"auto" | "confirm">("auto");
  const [note, setNote] = useState("");
  const action = useRecurringAction("حُفظ التعديل.");
  useEffect(() => {
    if (!recurring) return;
    setAmount(String(Number(recurring.amount)));
    setRate(recurring.rate ? String(Number(recurring.rate)) : "");
    setDay(recurring.day_of_month);
    setMode(recurring.mode);
    setNote(recurring.note ?? "");
    action.setError(null);
  }, [recurring]);
  if (!recurring) return null;
  const parsed = parseAmount(amount);
  const foreign = recurring.currency !== "LYD";
  const valid = !!parsed && day >= 1 && day <= 28 && (!foreign || Number(rate) > 0);
  async function save() {
    if (!recurring || !valid) return;
    const done = await action.run("PATCH", `/v1/finance/recurring/${encodeURIComponent(recurring.id)}`, {
      amount: parsed,
      ...(foreign ? { rate } : {}),
      day_of_month: day,
      mode,
      note: note.trim(),
    });
    if (done) onClose();
  }
  return (
    <Dialog
      open
      onClose={onClose}
      busy={action.busy}
      title="تعديل مصروف شهري"
      subtitle={categoryOf(recurring.direction, recurring.category).label}
      icon={<Repeat />}
      footer={
        <>
          <Button variant="primary" size="lg" loading={action.busy} disabled={!valid} onClick={save}>
            حفظ
          </Button>
          <Button size="lg" onClick={onClose}>
            إلغاء
          </Button>
        </>
      }
    >
      <div className="form">
        <div className="form-row">
          <Field label={`المبلغ الشهري (${foreign ? recurring.currency : "د.ل"})`} error={amount && !parsed ? "مبلغ غير صحيح." : null}>
            <input className="input" inputMode="decimal" dir="ltr" value={amount} onChange={(e) => setAmount(e.target.value)} />
          </Field>
          <Field label="يوم الاستحقاق" help="من 1 إلى 28 حتى يوجد في كل شهر.">
            <input className="input" type="number" min={1} max={28} value={day} onChange={(e) => setDay(Number(e.target.value))} />
          </Field>
        </div>
        {foreign && (
          <Field label="السعر بالدينار" help={parsed && Number(rate) > 0 ? `يُسجّل ${money(Number(parsed) * Number(rate))} شهرياً.` : undefined}>
            <input className="input" inputMode="decimal" dir="ltr" value={rate} onChange={(e) => setRate(e.target.value)} />
          </Field>
        )}
        <div className="field">
          <span className="field-label">طريقة التسجيل</span>
          <Segmented
            value={mode}
            onChange={setMode}
            options={[
              { id: "auto", label: "وحده بنفس المبلغ" },
              { id: "confirm", label: "يذكّرني لأؤكد" },
            ]}
          />
        </div>
        <Field label="الوصف">
          <input className="input" value={note} maxLength={200} onChange={(e) => setNote(e.target.value)} />
        </Field>
        <p className="inline-hint">التعديل يسري على الأشهر القادمة؛ ما سُجّل من قبل يبقى كما هو.</p>
        {action.error && <p className="error-text">{action.error}</p>}
      </div>
    </Dialog>
  );
}
