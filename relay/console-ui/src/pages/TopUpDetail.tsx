import { useEffect, useState } from "react";
import type { ReactNode } from "react";
import { AlertTriangle, BadgeCheck, Ban, ChevronLeft, Landmark, Receipt, Store, XCircle } from "lucide-react";
import { useTopUp, useTopUps, keys } from "../lib/queries";
import { Link, useRouter } from "../lib/router";
import { bankName, label, method as methodLabels, topUpStatus, transferChannel } from "../lib/labels";
import { dateTime, money, parseAmount } from "../lib/format";
import type { BankAccount, TopUp } from "../lib/types";
import { Badge, Button, Card, CopyText, Empty, Field, Money, Notice, Skeleton, TimeAgo } from "../components/ui";
import { Dialog } from "../components/dialog";
import { PasskeyHint, useAction } from "../components/guarded";
import { useToast } from "../components/toast";
import { ReceiptViewer } from "../components/ReceiptViewer";
import { ConfirmTopUpDialog } from "../components/money-dialogs";

/** An IBAN in the groups of four people read it in. */
export function groupedIBAN(iban: string): string {
  return iban.replace(/(.{4})/g, "$1 ").trim();
}

/**
 * One top-up. A bank transfer waits here for an operator: the receipt beside
 * the shop's account, our account it went to, and the two decisions — credit
 * what arrived, or reject with a reason the shop reads. Deciding one moves on
 * to the next transfer waiting.
 */
export function TopUpDetail({ id }: { id: string }) {
  const detail = useTopUp(id);
  const queue = useTopUps({ status: "review" });
  const { navigate } = useRouter();
  const [deciding, setDeciding] = useState<"confirm" | "reject" | "confirm-gateway" | null>(null);

  const next = (queue.data ?? []).filter((t) => t.id !== id).at(-1);
  function decided() {
    setDeciding(null);
    if (next) navigate(`/topups/${encodeURIComponent(next.id)}`);
  }

  if (detail.isLoading) {
    return (
      <div className="stack">
        <Skeleton height={60} width={360} />
        <Skeleton height={420} />
      </div>
    );
  }
  if (detail.isError || !detail.data) {
    return (
      <Card>
        <Empty title="لم نجد عملية الشحن هذه">
          <Link to="/topups">العودة إلى عمليات الشحن</Link>
        </Empty>
      </Card>
    );
  }
  const { top_up: topUp, account, duplicates } = detail.data;
  const transfer = topUp.transfer;
  const status = topUpStatus[topUp.status] ?? { label: topUp.status, tone: "neutral" as const };
  const inReview = topUp.status === "review";
  const shop = topUp.shop_name || topUp.installation_id;
  const declared = transfer?.declared_amount;
  const creditedDiffers = topUp.status === "paid" && declared && Number(declared) !== Number(topUp.amount);

  return (
    <>
      <div className="crumbs">
        <Link to={inReview ? "/topups?status=review" : "/topups"}>عمليات الشحن</Link>
        <ChevronLeft />
        <span className="mono">{topUp.invoice_no || topUp.id.slice(0, 8)}</span>
      </div>
      <div className="page-head">
        <div className="titles">
          <h1 className="row" style={{ gap: 10 }}>
            <Money value={topUp.amount} />
            <Badge tone={status.tone} dot>
              {status.label}
            </Badge>
            {topUp.test_mode && <Badge tone="warning">تجريبي</Badge>}
          </h1>
          <p className="row" style={{ gap: 6 }}>
            {transfer ? `تحويل مصرفي عبر ${label(transferChannel, transfer.channel)}` : label(methodLabels, topUp.method)}
            <span className="faint">·</span>
            <Link to={`/shops/${encodeURIComponent(topUp.installation_id)}`}>{shop}</Link>
            <span className="faint">·</span>
            <TimeAgo value={topUp.created_at} />
          </p>
        </div>
        <div className={`actions ${inReview && transfer ? "decision-bar" : ""}`}>
          {inReview && transfer && (
            <>
              <Button variant="money" size="lg" icon={<BadgeCheck />} onClick={() => setDeciding("confirm")}>
                وصل المبلغ — أضفه
              </Button>
              <Button variant="danger" size="lg" icon={<Ban />} onClick={() => setDeciding("reject")}>
                رفض
              </Button>
            </>
          )}
          {topUp.status === "rejected" && transfer && (
            <Button variant="money" icon={<BadgeCheck />} onClick={() => setDeciding("confirm")} title="وصل المبلغ بعد الرفض">
              وصل بعد كل شيء — أضفه
            </Button>
          )}
          {!transfer && (topUp.status === "pending" || topUp.status === "failed" || topUp.status === "expired") && (
            <Button variant="money" icon={<BadgeCheck />} onClick={() => setDeciding("confirm-gateway")}>
              تأكيد يدوي
            </Button>
          )}
        </div>
      </div>

      <div className="stack">
        {duplicates.length > 0 && (
          <Notice tone="danger" icon={<AlertTriangle />}>
            <strong>هذا الإيصال نفسه أُرسل مع {duplicates.length === 1 ? "عملية أخرى" : `${duplicates.length} عمليات أخرى`}:</strong>{" "}
            {duplicates.map((d, i) => (
              <span key={d.id}>
                {i > 0 && "، "}
                <Link to={`/topups/${encodeURIComponent(d.id)}`}>
                  {d.shop_name || d.installation_id} — {money(d.amount)} ({topUpStatus[d.status]?.label ?? d.status})
                </Link>
              </span>
            ))}
          </Notice>
        )}
        {topUp.status === "rejected" && (
          <Notice tone="danger" icon={<XCircle />}>
            <strong>رُفض{transfer?.rejected_by ? ` بواسطة ${transfer.rejected_by}` : ""}:</strong> {topUp.error_detail || "—"}
          </Notice>
        )}
        {creditedDiffers && (
          <Notice tone="warning" icon={<AlertTriangle />}>
            أُضيف {money(topUp.amount)} بدل {money(declared)} الذي ذكره المتجر.
          </Notice>
        )}
        {topUp.status === "paid" && (
          <Notice tone="money" icon={<BadgeCheck />}>
            أُضيف إلى المحفظة {topUp.paid_at ? dateTime(topUp.paid_at) : ""}
            {topUp.confirmed_by ? ` — ${topUp.confirmed_by.replace(/^operator:/, "")}` : ""}.
          </Notice>
        )}

        <div className="review-grid">
          {transfer ? (
            <Card tight title="الإيصال" className="review-receipt">
              <ReceiptViewer topUpId={topUp.id} name={transfer.receipt.name} contentType={transfer.receipt.content_type} size={transfer.receipt.size} />
            </Card>
          ) : null}
          <div className="stack">
            {transfer && (
              <Card title="من حساب المتجر" hint={label(transferChannel, transfer.channel)}>
                <AccountFacts bank={transfer.payer_bank} account={transfer.payer_account} iban={transfer.payer_iban} />
              </Card>
            )}
            {transfer && (
              <Card title="إلى حسابنا" hint={account ? undefined : "حساب لم يعد في الإعدادات"}>
                {account ? <OurAccount account={account} /> : <span className="faint">{transfer.to_account || "—"}</span>}
              </Card>
            )}
            <Card title="العملية">
              <dl className="facts">
                <Fact label="الرقم">
                  {topUp.invoice_no ? <CopyText value={topUp.invoice_no} /> : "—"}
                </Fact>
                <Fact label="المتجر">
                  <Link to={`/shops/${encodeURIComponent(topUp.installation_id)}`} className="row" style={{ gap: 4 }}>
                    <Store width={14} />
                    {shop}
                  </Link>
                </Fact>
                <Fact label="طلبها">{topUp.requested_by || "—"}</Fact>
                <Fact label="الوقت">{dateTime(topUp.created_at)}</Fact>
                {declared && <Fact label="المبلغ المذكور">{money(declared)}</Fact>}
                {!transfer && topUp.payer_hint && <Fact label="الدافع">{topUp.payer_hint}</Fact>}
                {topUp.provider_transaction_id && (
                  <Fact label={transfer ? "مرجع الكشف" : "رقم الدفعة"}>
                    <CopyText value={topUp.provider_transaction_id} />
                  </Fact>
                )}
              </dl>
            </Card>
          </div>
        </div>
      </div>

      {transfer && (
        <>
          <ConfirmTransferDialog topUp={topUp} open={deciding === "confirm"} onClose={() => setDeciding(null)} onDone={decided} />
          <RejectTransferDialog topUp={topUp} open={deciding === "reject"} onClose={() => setDeciding(null)} onDone={decided} />
        </>
      )}
      <ConfirmTopUpDialog topUp={deciding === "confirm-gateway" ? topUp : null} onClose={() => setDeciding(null)} />
    </>
  );
}

function Fact({ label: title, children }: { label: string; children: ReactNode }) {
  return (
    <div className="fact">
      <dt>{title}</dt>
      <dd>{children}</dd>
    </div>
  );
}

function AccountFacts({ bank, account, iban }: { bank: string; account: string; iban: string }) {
  return (
    <dl className="facts">
      <Fact label="المصرف">
        <span className="row" style={{ gap: 6 }}>
          <Landmark width={15} />
          {bankName(bank)}
        </span>
      </Fact>
      <Fact label="رقم الحساب">
        <CopyText value={account} />
      </Fact>
      <div className="fact" style={{ gridColumn: "1 / -1" }}>
        <dt>IBAN</dt>
        <dd>
          <CopyText value={iban} display={<span className="mono iban">{groupedIBAN(iban)}</span>} />
        </dd>
      </div>
    </dl>
  );
}

function OurAccount({ account }: { account: BankAccount }) {
  return (
    <>
      <div className="faint" style={{ marginBottom: 8 }}>
        {account.holder}
      </div>
      <AccountFacts bank={account.bank} account={account.account_number} iban={account.iban} />
    </>
  );
}

/** Credit what arrived: the declared amount, or what the statement shows. */
function ConfirmTransferDialog({ topUp, open, onClose, onDone }: { topUp: TopUp; open: boolean; onClose: () => void; onDone: () => void }) {
  const declared = topUp.transfer?.declared_amount || topUp.amount;
  const [amount, setAmount] = useState(String(Number(declared)));
  const [reference, setReference] = useState("");
  const toast = useToast();
  const action = useAction<{ top_up: TopUp; applied: boolean }>({ passkey: true, invalidate: [["wallet"], keys.topUp(topUp.id)] });

  useEffect(() => {
    if (open) {
      setAmount(String(Number(declared)));
      setReference("");
      action.setError(null);
    }
  }, [open, declared]);

  const parsed = parseAmount(amount);
  const differs = parsed !== null && Number(parsed) !== Number(declared);
  async function submit() {
    if (!parsed) return;
    const body: Record<string, unknown> = { provider_transaction_id: reference.trim(), reason: "" };
    if (differs) body.amount = parsed;
    const result = await action.run("POST", `/v1/wallet/admin/topups/${encodeURIComponent(topUp.id)}/confirm`, body);
    if (!result) return;
    toast.success(result.applied ? `أُضيف ${money(parsed)} — ${topUp.shop_name || ""}` : "أُضيفت من قبل؛ لم تتكرر.");
    onDone();
  }

  return (
    <Dialog
      open={open}
      onClose={onClose}
      busy={action.busy}
      title="وصل المبلغ — إضافته للمحفظة"
      subtitle={topUp.shop_name}
      icon={<BadgeCheck />}
      iconTone="money"
      footer={
        <>
          <Button variant="money" size="lg" icon={<BadgeCheck />} loading={action.busy} disabled={!parsed} onClick={submit}>
            {parsed ? `أضف ${money(parsed)}` : "أضف"}
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
        <Notice tone="money" icon={<Receipt />}>
          أضفه فقط بعد أن تراه في كشف حسابنا. الإيصال وحده ليس دليلاً.
        </Notice>
        <Field
          label="المبلغ الذي وصل"
          htmlFor="ct-amount"
          help={differs ? `المتجر ذكر ${money(declared)}؛ سيُضاف ما كتبته هنا وتُذكر الحالة في سجله.` : `كما ذكره المتجر.`}
        >
          <input id="ct-amount" className="input num" inputMode="decimal" value={amount} onChange={(e) => setAmount(e.target.value)} autoFocus />
        </Field>
        <Field label="مرجع العملية في الكشف (اختياري)" htmlFor="ct-ref" help="يساعد من يراجع لاحقاً.">
          <input id="ct-ref" className="input mono" value={reference} onChange={(e) => setReference(e.target.value)} />
        </Field>
        <PasskeyHint />
      </form>
    </Dialog>
  );
}

const rejectReasons = [
  "لم يصل المبلغ إلى حسابنا.",
  "المبلغ الذي وصل يختلف عمّا ذكرته.",
  "الإيصال غير واضح. أرسل صورة أوضح.",
  "هذا الإيصال أُرسل من قبل.",
  "بيانات الحساب المحوِّل لا تطابق التحويل.",
];

/** Turn it down with a reason the shop reads in its app. */
function RejectTransferDialog({ topUp, open, onClose, onDone }: { topUp: TopUp; open: boolean; onClose: () => void; onDone: () => void }) {
  const [reason, setReason] = useState("");
  const toast = useToast();
  const action = useAction<{ top_up: TopUp }>({ passkey: true, invalidate: [["wallet"], keys.topUp(topUp.id)] });

  useEffect(() => {
    if (open) {
      setReason("");
      action.setError(null);
    }
  }, [open]);

  const valid = reason.trim().length >= 3;
  async function submit() {
    if (!valid) return;
    const result = await action.run("POST", `/v1/wallet/admin/topups/${encodeURIComponent(topUp.id)}/reject`, { reason: reason.trim() });
    if (!result) return;
    toast.success("رُفض التحويل وأُبلغ المتجر بالسبب.");
    onDone();
  }

  return (
    <Dialog
      open={open}
      onClose={onClose}
      busy={action.busy}
      title="رفض التحويل"
      subtitle={`${topUp.shop_name || ""} — ${money(topUp.amount)}`}
      icon={<Ban />}
      iconTone="danger"
      footer={
        <>
          <Button variant="danger" size="lg" icon={<Ban />} loading={action.busy} disabled={!valid} onClick={submit}>
            رفض
          </Button>
          <Button size="lg" onClick={onClose} disabled={action.busy}>
            إلغاء
          </Button>
        </>
      }
    >
      <div className="form">
        <div className="chips">
          {rejectReasons.map((r) => (
            <button key={r} type="button" className={`chip ${reason === r ? "on" : ""}`} onClick={() => setReason(r)}>
              {r}
            </button>
          ))}
        </div>
        <Field label="السبب كما سيراه المتجر" htmlFor="rj-reason">
          <textarea id="rj-reason" className="textarea" rows={3} value={reason} onChange={(e) => setReason(e.target.value)} />
        </Field>
        <PasskeyHint />
      </div>
    </Dialog>
  );
}
