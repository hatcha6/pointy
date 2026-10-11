import { useEffect, useState } from "react";
import { PackageCheck, RotateCcw, TriangleAlert } from "lucide-react";
import { Dialog } from "./dialog";
import { Button, Field, Money, Notice, Switch } from "./ui";
import { PasskeyHint, useAction } from "./guarded";
import { money } from "../lib/format";
import type { Purchase } from "../lib/types";

export type StockReturn = { restock: boolean; verifiedUnused: boolean };

/** True when a stock return may go ahead: putting codes back needs the operator's check. */
export function stockReturnReady(choice: StockReturn): boolean {
  return !choice.restock || choice.verifiedUnused;
}

/**
 * Where a refunded stock sale's codes go: back on the shelf, or void. Back on
 * the shelf needs the operator to say they checked the card was never redeemed
 * — no supplier lets the relay ask, and a redeemed code sold again is a
 * customer holding a dead card.
 */
export function StockReturnChoice({ value, onChange, quantity }: { value: StockReturn; onChange: (next: StockReturn) => void; quantity: number }) {
  const what = quantity > 1 ? "الأكواد" : "الكود";
  return (
    <div className="stock-return">
      <div className="switch-row">
        <div className="text">
          أعِد {what} إلى المخزون
          <span>{value.restock ? `يُباع ${what} من جديد لمتجر آخر.` : `يُلغى ${what} ولا يُباع أبداً، ويبقى في السجل.`}</span>
        </div>
        <Switch on={value.restock} onChange={(restock) => onChange({ restock, verifiedUnused: false })} label={`أعِد ${what} إلى المخزون`} />
      </div>
      {value.restock && (
        <>
          <Notice tone="warning" icon={<TriangleAlert />}>
            لا يستطيع النظام معرفة إن شُحن الكرت أم لا. تأكّد بنفسك من الجهة المُصدِرة (أو من المتجر) أنه لم يُستعمل قبل إعادته.
          </Notice>
          <label className="check-row">
            <input type="checkbox" checked={value.verifiedUnused} onChange={(e) => onChange({ ...value, verifiedUnused: e.target.checked })} />
            <span>تأكّدتُ أن {what} لم {quantity > 1 ? "تُستعمل" : "يُستعمل"}، ويُسجَّل ذلك باسمي.</span>
          </label>
        </>
      )}
    </div>
  );
}

/** Refunds a completed sale from our own stock: the shop's money back, its codes to the shelf or void. */
export function StockRefundDialog({ purchase, onClose }: { purchase: Purchase | null; onClose: () => void }) {
  const [reason, setReason] = useState("");
  const [choice, setChoice] = useState<StockReturn>({ restock: false, verifiedUnused: false });
  const action = useAction({ passkey: true, invalidate: [["vouchers"], ["wallet"]], success: "أُعيد المبلغ للمتجر." });
  useEffect(() => {
    setReason("");
    setChoice({ restock: false, verifiedUnused: false });
  }, [purchase]);
  if (!purchase) return null;
  const valid = reason.trim() !== "" && stockReturnReady(choice);
  return (
    <Dialog
      open
      onClose={onClose}
      busy={action.busy}
      title="استرداد بيع من مخزوننا"
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
            icon={choice.restock ? <PackageCheck /> : undefined}
            onClick={async () => {
              const result = await action.run("POST", `/v1/vouchers/admin/purchases/${encodeURIComponent(purchase.id)}/refund`, {
                restock: choice.restock,
                verified_unused: choice.verifiedUnused,
                reason: reason.trim(),
              });
              if (result) onClose();
            }}
          >
            أعِد {money(purchase.amount)} للمتجر
          </Button>
          <Button size="lg" onClick={onClose} disabled={action.busy}>
            إلغاء
          </Button>
        </>
      }
    >
      <div className="form">
        <p className="muted">
          يعود <Money value={purchase.amount} /> إلى رصيد بطاقات المتجر مرة واحدة. العملية تبقى «تمّت» لأن المتجر استلم الكود، وتُسجَّل الاسترداد في ملاحظتها.
        </p>
        <StockReturnChoice value={choice} onChange={setChoice} quantity={purchase.quantity} />
        <Field label="السبب" htmlFor="stock-refund-why">
          <input id="stock-refund-why" className="input" value={reason} onChange={(e) => setReason(e.target.value)} maxLength={200} />
        </Field>
        <PasskeyHint />
      </div>
    </Dialog>
  );
}

/** A completed stock sale the operator has not given back yet. */
export function refundableStockSale(p: Purchase): boolean {
  return p.supplier === "stock" && p.status === "succeeded" && !(p.error_detail ?? "").includes("refunded by operator");
}
