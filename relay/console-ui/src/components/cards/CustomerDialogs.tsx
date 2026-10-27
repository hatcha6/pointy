import { useEffect, useState } from "react";
import { Ban, BellRing, CircleMinus, PlusCircle, ShieldCheck, Trash2 } from "lucide-react";
import { Dialog } from "../dialog";
import { Button, Field, Money, Segmented } from "../ui";
import { PasskeyHint, useAction } from "../guarded";
import { idempotencyKey } from "../../lib/stepup";
import { parseAmount } from "../../lib/format";
import { cardKeys, type CardCustomer } from "../../lib/cards";
import { Phone } from "./Phone";
import { NotificationForm, emptyNotification, type NotificationDraft } from "./NotificationForm";

const invalidate = [cardKeys.all];

/** Gives a customer credit (compensation, a goodwill gift) or takes it back. */
export function CustomerCreditDialog({ customer, balance, open, onClose }: {
  customer: CardCustomer;
  balance: string;
  open: boolean;
  onClose: () => void;
}) {
  const [mode, setMode] = useState<"grant" | "charge">("grant");
  const [amount, setAmount] = useState("");
  const [note, setNote] = useState("");
  const [key, setKey] = useState(idempotencyKey);
  const action = useAction<{ balance: string }>({ passkey: true, invalidate, success: "تم تعديل الرصيد" });

  useEffect(() => {
    if (!open) return;
    setMode("grant");
    setAmount("");
    setNote("");
    setKey(idempotencyKey());
    action.setError(null);
  }, [open]);

  const parsed = parseAmount(amount);
  const after = parsed ? Number(balance) + (mode === "charge" ? -1 : 1) * Number(parsed) : null;
  const overdraws = after !== null && after < 0;
  const valid = !!parsed && note.trim().length > 0 && !overdraws;

  async function submit() {
    if (!valid || !parsed) return;
    const result = await action.run("POST", `/v1/customers/admin/customers/${encodeURIComponent(customer.id)}/credit`, {
      amount: mode === "charge" ? `-${parsed}` : parsed,
      note: note.trim(),
      key,
    });
    if (result) onClose();
  }

  return (
    <Dialog
      open={open}
      onClose={onClose}
      busy={action.busy}
      dirty={!!amount || !!note}
      icon={mode === "grant" ? <PlusCircle /> : <CircleMinus />}
      iconTone="money"
      title="رصيد الزبون"
      subtitle={<Phone value={customer.phone} />}
      footer={
        <>
          <Button variant="money" size="lg" onClick={() => void submit()} disabled={!valid} loading={action.busy}>
            {mode === "grant" ? "إضافة للرصيد" : "خصم من الرصيد"}
          </Button>
          <Button size="lg" onClick={onClose} disabled={action.busy}>
            إلغاء
          </Button>
        </>
      }
    >
      <form
        className="form"
        onSubmit={(event) => {
          event.preventDefault();
          void submit();
        }}
      >
        <Segmented
          value={mode}
          onChange={setMode}
          options={[
            { id: "grant", label: "إضافة" },
            { id: "charge", label: "خصم" },
          ]}
        />
        <Field
          label="المبلغ"
          htmlFor="credit-amount"
          error={amount && !parsed ? "مبلغ موجب بخانتين عشريتين على الأكثر" : overdraws ? "الرصيد لا ينزل تحت الصفر" : null}
          help={after !== null && !overdraws ? <>الرصيد بعدها <Money value={after} /></> : <>الرصيد الآن <Money value={balance} /></>}
        >
          <div className="input-affix">
            <input
              id="credit-amount"
              className={`input amount ${amount && (!parsed || overdraws) ? "invalid" : ""}`}
              inputMode="decimal"
              autoComplete="off"
              value={amount}
              onChange={(e) => setAmount(e.target.value)}
              placeholder="0.00"
              autoFocus
            />
            <span className="affix">د.ل</span>
          </div>
        </Field>
        <Field label="السبب" htmlFor="credit-note" help="يظهر في سجل رصيد الزبون مع اسمك.">
          <input
            id="credit-note"
            className="input"
            value={note}
            maxLength={300}
            onChange={(e) => setNote(e.target.value)}
            placeholder={mode === "grant" ? "تعويض عن كرت لم يعمل" : "تصحيح إضافة سابقة"}
          />
        </Field>
        {action.error && <p className="error-text">{action.error}</p>}
        <PasskeyHint />
      </form>
    </Dialog>
  );
}

/** Stops an account (it is signed out and cannot sign in) or restarts it. */
export function CustomerBlockDialog({ customer, open, onClose }: { customer: CardCustomer; open: boolean; onClose: () => void }) {
  const blocking = !customer.blocked_at;
  const [reason, setReason] = useState("");
  const action = useAction({ passkey: true, invalidate, success: blocking ? "أُوقف الحساب" : "أُعيد تفعيل الحساب" });
  useEffect(() => {
    if (open) {
      setReason("");
      action.setError(null);
    }
  }, [open]);

  async function submit() {
    if (blocking && !reason.trim()) return;
    const result = await action.run("POST", `/v1/customers/admin/customers/${encodeURIComponent(customer.id)}/block`, {
      blocked: blocking,
      reason: reason.trim(),
    });
    if (result !== undefined) onClose();
  }

  return (
    <Dialog
      open={open}
      onClose={onClose}
      busy={action.busy}
      icon={blocking ? <Ban /> : <ShieldCheck />}
      iconTone={blocking ? "danger" : undefined}
      title={blocking ? "إيقاف الحساب" : "إعادة تفعيل الحساب"}
      subtitle={<Phone value={customer.phone} />}
      footer={
        <>
          <Button variant={blocking ? "danger" : "primary"} size="lg" onClick={() => void submit()} disabled={blocking && !reason.trim()} loading={action.busy}>
            {blocking ? "إيقاف" : "إعادة التفعيل"}
          </Button>
          <Button size="lg" onClick={onClose} disabled={action.busy}>
            إلغاء
          </Button>
        </>
      }
    >
      <div className="form">
        {blocking ? (
          <>
            <p>يُسجَّل خروجه من كل أجهزته، ولا يستطيع الدخول برقمه حتى تعيد تفعيله. طلباته ورصيده يبقيان كما هما.</p>
            <Field label="السبب" htmlFor="block-reason" help="لا يراه الزبون؛ يبقى في ملفه هنا.">
              <input id="block-reason" className="input" value={reason} maxLength={300} onChange={(e) => setReason(e.target.value)} autoFocus />
            </Field>
          </>
        ) : (
          <p>يستطيع الدخول برقمه من جديد.{customer.blocked_reason ? ` سبب الإيقاف: ${customer.blocked_reason}` : ""}</p>
        )}
        {action.error && <p className="error-text">{action.error}</p>}
        <PasskeyHint />
      </div>
    </Dialog>
  );
}

/** Erases an account, as the customer can from the app: the phone goes, the orders stay. */
export function CustomerDeleteDialog({ customer, open, onClose, onDeleted }: {
  customer: CardCustomer;
  open: boolean;
  onClose: () => void;
  onDeleted: () => void;
}) {
  const action = useAction({ passkey: true, invalidate, success: "حُذف الحساب" });
  async function submit() {
    const result = await action.run("DELETE", `/v1/customers/admin/customers/${encodeURIComponent(customer.id)}`);
    if (result !== undefined) {
      onClose();
      onDeleted();
    }
  }
  return (
    <Dialog
      open={open}
      onClose={onClose}
      busy={action.busy}
      icon={<Trash2 />}
      iconTone="danger"
      title="حذف الحساب"
      subtitle={<Phone value={customer.phone} />}
      footer={
        <>
          <Button variant="danger" size="lg" onClick={() => void submit()} loading={action.busy}>
            حذف نهائياً
          </Button>
          <Button size="lg" onClick={onClose} disabled={action.busy}>
            إلغاء
          </Button>
        </>
      }
    >
      <div className="form">
        <p>يُمحى رقم الهاتف ويُسجَّل خروجه من كل أجهزته، كما لو حذف حسابه بنفسه. تبقى طلباته في السجلات بلا رقم. لا يمكن التراجع.</p>
        {action.error && <p className="error-text">{action.error}</p>}
        <PasskeyHint />
      </div>
    </Dialog>
  );
}

/** A notification to one customer's phones. */
export function CustomerNotifyDialog({ customer, open, onClose }: { customer: CardCustomer; open: boolean; onClose: () => void }) {
  const [draft, setDraft] = useState<NotificationDraft>(emptyNotification);
  const action = useAction<{ notification: { sent: number; devices: number } }>({ invalidate, success: "أُرسل الإشعار" });
  useEffect(() => {
    if (open) {
      setDraft(emptyNotification);
      action.setError(null);
    }
  }, [open]);

  async function submit() {
    const result = await action.run("POST", "/v1/customers/admin/notifications", {
      ...draft,
      audience: "customer",
      customer_id: customer.id,
    });
    if (result) onClose();
  }

  return (
    <Dialog
      open={open}
      onClose={onClose}
      busy={action.busy}
      dirty={!!draft.title || !!draft.body}
      wide
      icon={<BellRing />}
      title="إشعار لهذا الزبون"
      subtitle={
        <>
          <Phone value={customer.phone} /> · {customer.push_devices} جهاز يستقبل الإشعارات
        </>
      }
      footer={
        <>
          <Button variant="primary" size="lg" onClick={() => void submit()} disabled={!draft.title.trim() || !draft.body.trim()} loading={action.busy}>
            إرسال
          </Button>
          <Button size="lg" onClick={onClose} disabled={action.busy}>
            إلغاء
          </Button>
        </>
      }
    >
      <NotificationForm draft={draft} onChange={setDraft} />
      {action.error && <p className="error-text">{action.error}</p>}
    </Dialog>
  );
}
