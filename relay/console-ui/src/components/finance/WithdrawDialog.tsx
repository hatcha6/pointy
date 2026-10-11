import { useEffect, useState } from "react";
import { AlertTriangle, PiggyBank } from "lucide-react";
import { Dialog } from "../dialog";
import { Button, Field, Money, Notice, Switch } from "../ui";
import { AttachmentPicker } from "./Attachments";
import { useAction } from "../guarded";
import { useToast } from "../toast";
import { idempotencyKey } from "../../lib/stepup";
import { money, parseAmount } from "../../lib/format";
import { useMe } from "../../lib/queries";
import { financeKeys, libyaDay, useFinancePosition, shortDay, type Attachment, type FinanceEntry } from "../../lib/finance";

/**
 * Books money the owners took out of the company's earnings. It moves nothing
 * by itself: it records what was taken, so what is still theirs to take goes
 * down by it. Taking more than is theirs is allowed only after saying so — the
 * rest is shops' money.
 */
export function WithdrawDialog({ open, onClose }: { open: boolean; onClose: () => void }) {
  const toast = useToast();
  const position = useFinancePosition();
  const available = position.data ? Number(position.data.available) : null;
  const me = useMe();
  const action = useAction<FinanceEntry>({ invalidate: [financeKeys.all] });
  const [amount, setAmount] = useState("");
  const [day, setDay] = useState(libyaDay());
  const [who, setWho] = useState("");
  const [note, setNote] = useState("");
  const [attachments, setAttachments] = useState<Attachment[]>([]);
  const [uploading, setUploading] = useState(false);
  const [beyond, setBeyond] = useState(false);
  const [key, setKey] = useState(idempotencyKey);

  useEffect(() => {
    if (!open) return;
    setAmount("");
    setDay(libyaDay());
    setWho(me.data?.operator.name ?? "");
    setNote("");
    setAttachments([]);
    setBeyond(false);
    setKey(idempotencyKey());
    action.setError(null);
  }, [open]);

  const parsed = parseAmount(amount);
  const over = parsed !== null && available !== null && Number(parsed) > Math.max(available, 0);
  const valid = !!parsed && !!day && !uploading && (!over || beyond);

  async function submit() {
    if (!valid || !parsed) return;
    const saved = await action.run("POST", "/v1/finance/entries", {
      direction: "withdrawal",
      category: "owner_draw",
      amount: parsed,
      currency: "LYD",
      occurred_on: day,
      counterparty: who.trim(),
      note: note.trim(),
      idempotency_key: key,
      attachments: attachments.map((a) => ({ sha256: a.sha256, name: a.name })),
    });
    if (!saved) return;
    toast.success(`سُجّل سحب ${money(saved.amount)}`, `${who.trim() || "سحب أرباح"} · ${shortDay(saved.occurred_on)}`);
    onClose();
  }

  return (
    <Dialog
      open={open}
      onClose={onClose}
      busy={action.busy}
      dirty={!!amount.trim() || !!note.trim() || attachments.length > 0}
      title="تسجيل سحب لك"
      subtitle={available !== null ? <>المتاح الآن <Money value={Math.max(available, 0)} /></> : "من أرباح الشركة"}
      icon={<PiggyBank />}
      iconTone="money"
      footer={
        <Button variant="primary" size="lg" loading={action.busy} disabled={!valid} onClick={submit}>
          {parsed ? `حفظ سحب ${money(parsed)}` : "حفظ"}
        </Button>
      }
    >
      <form
        className="form"
        onSubmit={(event) => {
          event.preventDefault();
          void submit();
        }}
      >
        <Field label="المبلغ الذي أخذته" htmlFor="draw-amount" error={amount && !parsed ? "اكتب مبلغاً موجباً بخانتين عشريتين على الأكثر." : null}>
          <div className="input-affix">
            <input
              id="draw-amount"
              className="input amount"
              inputMode="decimal"
              autoComplete="off"
              autoFocus
              placeholder="0.00"
              value={amount}
              onChange={(e) => setAmount(e.target.value)}
            />
            <span className="affix">د.ل</span>
          </div>
        </Field>
        {available !== null && available > 0 && (
          <div className="chips">
            <button type="button" className="chip" onClick={() => setAmount(available.toFixed(2))}>
              كل المتاح ({money(available)})
            </button>
          </div>
        )}

        {over && (
          <Notice tone="danger" icon={<AlertTriangle />}>
            <div>
              هذا أكثر مما صار لك. الفرق <Money value={Number(parsed) - Math.max(available ?? 0, 0)} /> من أموال المتاجر أو من مال لم يُحصّل بعد.
              <label className="row" style={{ marginTop: 8 }}>
                <Switch on={beyond} onChange={setBeyond} label="أعلم ذلك" />
                أعلم ذلك وأريد تسجيله
              </label>
            </div>
          </Notice>
        )}

        <div className="form-row">
          <Field label="التاريخ">
            <input type="date" className="input" value={day} max={libyaDay()} min="2020-01-01" onChange={(e) => e.target.value && setDay(e.target.value)} />
          </Field>
          <Field label="من سحب">
            <input className="input" value={who} maxLength={200} onChange={(e) => setWho(e.target.value)} />
          </Field>
        </div>

        <Field label="وصف قصير" help="اختياري — مثلاً: حوالة إلى حسابي الشخصي.">
          <input className="input" value={note} maxLength={200} onChange={(e) => setNote(e.target.value)} />
        </Field>

        <AttachmentPicker value={attachments} onChange={setAttachments} onBusy={setUploading} />

        {action.error && <p className="error-text">{action.error}</p>}
        <button type="submit" hidden />
      </form>
    </Dialog>
  );
}
