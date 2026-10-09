import { useEffect, useMemo, useState } from "react";
import { BadgeCheck, Banknote, Building2, CircleMinus, Gift, Landmark, PenLine, PlusCircle, RotateCcw, TriangleAlert } from "lucide-react";
import { Dialog } from "./dialog";
import { Button, Field, Money, Notice, Segmented } from "./ui";
import { PasskeyHint, useAction } from "./guarded";
import { useToast } from "./toast";
import { idempotencyKey } from "../lib/stepup";
import { money, parseAmount } from "../lib/format";
import { account as accountLabels, label, method as methodLabels, service as serviceLabels, supplier as supplierLabels } from "../lib/labels";
import { keys } from "../lib/queries";
import type { Purchase, TopUp } from "../lib/types";

export type EntryMode = "credit" | "debit" | "refund";

const sources = [
  { id: "cash", label: "نقداً في المكتب", icon: <Banknote width={16} />, statement: "إيداع نقدي" },
  { id: "bank", label: "حوالة مصرفية", icon: <Landmark width={16} />, statement: "حوالة مصرفية" },
  { id: "goodwill", label: "تعويض", icon: <Gift width={16} />, statement: "تعويض من دفتر" },
  { id: "other", label: "أخرى", icon: <PenLine width={16} />, statement: "" },
] as const;

const services = ["subscription", "remote_access", "ai", "sms", "vouchers"];
const quickAmounts = [50, 100, 200, 500, 1000];

/** A hand-made wallet movement: a credit (cash or transfer we received), a debit, or a refund. */
export function WalletEntryDialog({ open, onClose, installationId, shopName, mode: initialMode, balances }: {
  open: boolean;
  onClose: () => void;
  installationId: string;
  shopName: string;
  mode: EntryMode;
  balances?: Record<string, string>;
}) {
  const [mode, setMode] = useState<EntryMode>(initialMode);
  const [account, setAccount] = useState("main");
  const [amount, setAmount] = useState("");
  const [source, setSource] = useState<(typeof sources)[number]["id"]>("cash");
  const [reference, setReference] = useState("");
  const [note, setNote] = useState("");
  const [service, setService] = useState("");
  const [allowOverdraft, setAllowOverdraft] = useState(false);
  const [key, setKey] = useState(idempotencyKey);
  const toast = useToast();
  const action = useAction<{ entry: { balance_after: string }; created: boolean }>({
    passkey: true,
    invalidate: [["wallet"], keys.installationAudit(installationId)],
  });

  useEffect(() => {
    if (open) {
      setMode(initialMode);
      setAccount("main");
      setAmount("");
      setSource("cash");
      setReference("");
      setNote("");
      setService("");
      setAllowOverdraft(false);
      setKey(idempotencyKey());
      action.setError(null);
    }
  }, [open, initialMode]);

  const parsed = parseAmount(amount);
  const sourceInfo = sources.find((s) => s.id === source)!;
  const description = useMemo(() => {
    if (mode === "credit") {
      const parts = [sourceInfo.statement, reference.trim() && `إيصال ${reference.trim()}`, note.trim()].filter(Boolean);
      return parts.join(" — ");
    }
    return note.trim();
  }, [mode, sourceInfo, reference, note]);

  const current = balances?.[account];
  const after = parsed && current !== undefined ? Number(current) + (mode === "debit" ? -1 : 1) * Number(parsed) : null;
  const overdraws = mode === "debit" && after !== null && after < 0;
  const valid = !!parsed && !!description && (mode !== "refund" || !!service) && (!overdraws || allowOverdraft);

  async function submit() {
    if (!valid || !parsed) return;
    const kind = mode === "refund" ? "refund" : mode === "debit" && service ? "charge" : "adjustment";
    const result = await action.run("POST", "/v1/wallet/admin/entries", {
      installation_id: installationId,
      account,
      kind,
      service: mode === "credit" ? "" : service,
      amount: mode === "debit" ? "-" + parsed : parsed,
      reference: reference.trim(),
      description,
      idempotency_key: key,
      allow_overdraft: mode === "debit" && allowOverdraft,
    });
    if (!result) return;
    const verb = mode === "debit" ? "خُصم" : mode === "refund" ? "استُرد" : "أُضيف";
    toast.success(
      result.created ? `${verb} ${money(parsed)} — ${shopName}` : "سُجّلت هذه العملية من قبل؛ لم تتكرر.",
      `الرصيد الآن ${money(result.entry.balance_after)}`,
    );
    onClose();
  }

  const titles: Record<EntryMode, string> = { credit: "إضافة رصيد", debit: "خصم من الرصيد", refund: "استرداد خدمة" };
  const icons: Record<EntryMode, JSX.Element> = { credit: <PlusCircle />, debit: <CircleMinus />, refund: <RotateCcw /> };

  return (
    <Dialog
      open={open}
      onClose={onClose}
      busy={action.busy}
      title={titles[mode]}
      subtitle={shopName}
      icon={icons[mode]}
      iconTone="money"
      footer={
        <>
          <Button variant="money" size="lg" icon={<BadgeCheck />} loading={action.busy} disabled={!valid} onClick={submit}>
            {parsed ? `تأكيد ${money(parsed)}` : "تأكيد"}
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
            { id: "credit", label: "إضافة" },
            { id: "debit", label: "خصم" },
            { id: "refund", label: "استرداد" },
          ]}
        />
        <Field label="المبلغ" htmlFor="amount" error={amount && !parsed ? "مبلغ موجب بخانتين عشريتين على الأكثر" : null}>
          <div className="input-affix">
            <input id="amount" className={`input amount ${amount && !parsed ? "invalid" : ""}`} inputMode="decimal" autoComplete="off" value={amount} onChange={(e) => setAmount(e.target.value)} placeholder="0.00" autoFocus />
            <span className="affix">د.ل</span>
          </div>
          <div className="quick-amounts">
            {quickAmounts.map((value) => (
              <button type="button" key={value} className="chip" onClick={() => setAmount(String(value))}>
                {value}
              </button>
            ))}
          </div>
        </Field>
        <Field label="الحساب">
          <div className="chips">
            {(["main", "sms", "vouchers"] as const).map((id) => (
              <button type="button" key={id} className={`chip ${account === id ? "on" : ""}`} onClick={() => setAccount(id)}>
                {accountLabels[id]}
                {balances?.[id] !== undefined && <span className="faint num">{money(balances[id])}</span>}
              </button>
            ))}
          </div>
        </Field>
        {mode === "credit" && (
          <>
            <Field label="مصدر المبلغ">
              <div className="chips">
                {sources.map((s) => (
                  <button type="button" key={s.id} className={`chip ${source === s.id ? "on" : ""}`} onClick={() => setSource(s.id)}>
                    {s.icon}
                    {s.label}
                  </button>
                ))}
              </div>
            </Field>
          </>
        )}
        <div className="form-row">
          {mode === "credit" && (source === "cash" || source === "bank") && (
            <Field label={source === "cash" ? "رقم الإيصال" : "رقم الحوالة"} help="اختياري" htmlFor="reference">
              <input id="reference" className="input" value={reference} onChange={(e) => setReference(e.target.value)} maxLength={60} />
            </Field>
          )}
        {mode !== "credit" && (
          <Field label={mode === "refund" ? "الخدمة المستردّة" : "الخدمة (اختياري)"} help={mode === "debit" ? "بدون خدمة يُسجَّل الخصم تسويةً يدوية." : undefined}>
            <div className="chips">
              {services.map((id) => (
                <button type="button" key={id} className={`chip ${service === id ? "on" : ""}`} onClick={() => setService(service === id ? "" : id)}>
                  {serviceLabels[id]}
                </button>
              ))}
            </div>
          </Field>
        )}
          <Field label={mode === "credit" ? "ملاحظة (اختياري)" : "السبب"} help="يظهر في كشف حساب المتجر." htmlFor="note">
            <input id="note" className="input" value={note} onChange={(e) => setNote(e.target.value)} maxLength={200} required={mode !== "credit"} />
          </Field>
        </div>
        {overdraws && (
          <Notice tone="warning" icon={<TriangleAlert />}>
            الرصيد لا يغطي هذا الخصم ({money(current)}).
            <label className="row" style={{ marginTop: 6 }}>
              <input type="checkbox" checked={allowOverdraft} onChange={(e) => setAllowOverdraft(e.target.checked)} />
              اسمح بأن يصبح الرصيد سالباً
            </label>
          </Notice>
        )}
        {parsed && description && (
          <dl className="summary">
            <div>
              <dt>{mode === "debit" ? "يُخصم من" : "يُضاف إلى"}</dt>
              <dd>
                {label(accountLabels, account)} · {shopName}
              </dd>
            </div>
            <div>
              <dt>المبلغ</dt>
              <dd>
                <Money value={mode === "debit" ? "-" + parsed : parsed} signed />
              </dd>
            </div>
            {after !== null && (
              <div>
                <dt>الرصيد بعدها</dt>
                <dd>
                  <Money value={after} />
                </dd>
              </div>
            )}
            <div>
              <dt>في الكشف</dt>
              <dd>{description}</dd>
            </div>
          </dl>
        )}
        <PasskeyHint />
        <button type="submit" hidden />
      </form>
    </Dialog>
  );
}

/** Credits by hand a top-up Dafa will not show as paid, after checking Dafa's dashboard. */
export function ConfirmTopUpDialog({ topUp, onClose }: { topUp: TopUp | null; onClose: () => void }) {
  const [transactionId, setTransactionId] = useState("");
  const [reason, setReason] = useState("");
  const action = useAction<{ applied: boolean }>({ passkey: true, invalidate: [["wallet"]], success: "أُضيف الشحن إلى المحفظة." });
  useEffect(() => {
    setTransactionId(topUp?.provider_transaction_id ?? "");
    setReason("");
  }, [topUp]);
  if (!topUp) return null;
  const valid = transactionId.trim() && reason.trim();
  return (
    <Dialog
      open
      onClose={onClose}
      busy={action.busy}
      title="تأكيد الشحن يدوياً"
      subtitle={topUp.shop_name || topUp.installation_id}
      icon={<BadgeCheck />}
      iconTone="money"
      footer={
        <>
          <Button
            variant="money"
            size="lg"
            icon={<BadgeCheck />}
            loading={action.busy}
            disabled={!valid}
            onClick={async () => {
              const result = await action.run("POST", `/v1/wallet/admin/topups/${encodeURIComponent(topUp.id)}/confirm`, {
                provider_transaction_id: transactionId.trim(),
                reason: reason.trim(),
              });
              if (result) onClose();
            }}
          >
            {`أضف ${money(topUp.amount)} للمحفظة`}
          </Button>
          <Button size="lg" onClick={onClose} disabled={action.busy}>
            إلغاء
          </Button>
        </>
      }
    >
      <div className="form">
        <Notice tone="money" icon={<Building2 />}>
          استخدم هذا فقط بعد أن ترى الدفعة مدفوعة في لوحة دفع أو في كشف الحساب. لا تؤكّد من صورة إيصال أو رسالة.
        </Notice>
        <dl className="summary">
          <div>
            <dt>المبلغ</dt>
            <dd>
              <Money value={topUp.amount} />
            </dd>
          </div>
          <div>
            <dt>الطريقة</dt>
            <dd>{label(methodLabels, topUp.method)}</dd>
          </div>
          <div>
            <dt>رقم العملية</dt>
            <dd className="mono">{topUp.invoice_no || topUp.id}</dd>
          </div>
          {topUp.payer_hint && (
            <div>
              <dt>الدافع</dt>
              <dd className="mono">{topUp.payer_hint}</dd>
            </div>
          )}
        </dl>
        <Field label="رقم المعاملة لدى دفع" htmlFor="tx">
          <input id="tx" className="input mono" value={transactionId} onChange={(e) => setTransactionId(e.target.value)} autoFocus />
        </Field>
        <Field label="السبب" htmlFor="reason" help="مثال: ظاهرة مدفوعة في لوحة دفع ولم يصل الإشعار.">
          <input id="reason" className="input" value={reason} onChange={(e) => setReason(e.target.value)} maxLength={200} />
        </Field>
        <PasskeyHint />
      </div>
    </Dialog>
  );
}

/** Settles a card/top-up/bill purchase the reconciler could not: refund the shop, or record the supplier order found. */
export function ResolvePurchaseDialog({ purchase, onClose }: { purchase: Purchase | null; onClose: () => void }) {
  const [outcome, setOutcome] = useState<"refund" | "found">("refund");
  const [orderId, setOrderId] = useState("");
  const [reason, setReason] = useState("");
  const action = useAction({ passkey: true, invalidate: [["vouchers"], ["wallet"]], success: "سُوّيت العملية." });
  useEffect(() => {
    setOutcome("refund");
    setOrderId("");
    setReason("");
  }, [purchase]);
  if (!purchase) return null;
  const valid = reason.trim() && (outcome === "refund" || orderId.trim());
  return (
    <Dialog
      open
      onClose={onClose}
      busy={action.busy}
      title="تسوية عملية معلّقة"
      subtitle={`${purchase.name} · ${purchase.shop_name || purchase.installation_id}`}
      icon={<RotateCcw />}
      iconTone="money"
      footer={
        <>
          <Button
            variant="money"
            size="lg"
            loading={action.busy}
            disabled={!valid}
            onClick={async () => {
              const result = await action.run("POST", `/v1/vouchers/admin/purchases/${encodeURIComponent(purchase.id)}/resolve`, {
                outcome,
                supplier_order_id: outcome === "found" ? orderId.trim() : "",
                reason: reason.trim(),
              });
              if (result) onClose();
            }}
          >
            {outcome === "refund" ? `أعِد ${money(purchase.amount)} للمتجر` : "سجّل أنها تمّت"}
          </Button>
          <Button size="lg" onClick={onClose} disabled={action.busy}>
            إلغاء
          </Button>
        </>
      }
    >
      <div className="form">
        <Notice tone="info" icon={<Building2 />}>
          تحقّق أولاً من لوحة المورّد ({label(supplierLabels, purchase.supplier)}). إن لم يُنفَّذ الطلب فأعد المبلغ، وإن نُفّذ فسجّل رقم طلبه.
        </Notice>
        <Segmented
          value={outcome}
          onChange={setOutcome}
          options={[
            { id: "refund", label: "لم تتم — أعد المبلغ" },
            { id: "found", label: "تمّت لدى المورّد" },
          ]}
        />
        {outcome === "found" && (
          <Field label="رقم الطلب لدى المورّد" htmlFor="order">
            <input id="order" className="input mono" value={orderId} onChange={(e) => setOrderId(e.target.value)} autoFocus />
          </Field>
        )}
        <Field label="السبب" htmlFor="why">
          <input id="why" className="input" value={reason} onChange={(e) => setReason(e.target.value)} maxLength={200} />
        </Field>
        <PasskeyHint />
      </div>
    </Dialog>
  );
}
