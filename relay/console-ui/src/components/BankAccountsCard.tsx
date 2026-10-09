import { useEffect, useState } from "react";
import { Landmark, Plus, Save, Trash2 } from "lucide-react";
import { keys, useBankAccounts } from "../lib/queries";
import { banks } from "../lib/labels";
import { dateTime } from "../lib/format";
import type { BankAccount } from "../lib/types";
import { Button, Card, Empty, Field, Notice, Skeleton, Switch } from "./ui";
import { PasskeyHint, useAction } from "./guarded";

/** ISO 13616 check digits, as the relay checks them. */
export function validLibyanIBAN(raw: string): boolean {
  const iban = raw.replace(/\s+/g, "").toUpperCase();
  if (!/^LY\d{23}$/.test(iban)) return false;
  const digits = (iban.slice(4) + iban.slice(0, 4)).replace(/[A-Z]/g, (c) => String(c.charCodeAt(0) - 55));
  let remainder = 0;
  for (const d of digits) remainder = (remainder * 10 + Number(d)) % 97;
  return remainder === 1;
}

const blank = (): BankAccount => ({ id: "", bank: "", bank_name: "", holder: "", account_number: "", iban: "", enabled: true });

/**
 * The company's accounts shops transfer to with LYPay (the IBAN) or OnePay
 * (the bank and account number). Kept on the relay, never in the code; every
 * change takes a passkey tap, since it decides where shops send money.
 */
export function BankAccountsCard() {
  const settings = useBankAccounts();
  const [accounts, setAccounts] = useState<BankAccount[]>([]);
  const [dirty, setDirty] = useState(false);
  const save = useAction({ passkey: true, invalidate: [keys.bankAccounts], success: "حُفظت حسابات الاستلام." });

  useEffect(() => {
    if (settings.data && !dirty) setAccounts(settings.data.accounts ?? []);
  }, [settings.data, dirty]);

  function change(index: number, patch: Partial<BankAccount>) {
    setDirty(true);
    setAccounts((list) => list.map((a, i) => (i === index ? { ...a, ...patch } : a)));
  }

  const problems = accounts.map((a) => {
    if (!a.bank) return "اختر المصرف.";
    if (!a.holder.trim()) return "اكتب اسم صاحب الحساب كما يظهر للمحوِّل.";
    if (!/^\d{6,20}$/.test(a.account_number.replace(/[\s-]/g, ""))) return "رقم الحساب أرقام فقط.";
    if (!validLibyanIBAN(a.iban)) return "رقم IBAN غير صحيح.";
    return null;
  });
  const valid = problems.every((p) => p === null);

  async function submit() {
    const body = {
      accounts: accounts.map((a) => ({ ...a, bank_name: banks[a.bank] ?? a.bank_name, iban: a.iban.replace(/\s+/g, "").toUpperCase() })),
    };
    if (await save.run("PUT", "/v1/wallet/admin/bank-accounts", body)) setDirty(false);
  }

  return (
    <Card
      title="حسابات استلام التحويلات"
      hint={settings.data?.updated_at ? `آخر تعديل ${dateTime(settings.data.updated_at)} — ${settings.data.updated_by || ""}` : "تظهر للمتاجر في صفحة الشحن"}
      actions={
        <Button
          size="sm"
          icon={<Plus />}
          onClick={() => {
            setDirty(true);
            setAccounts((list) => [...list, blank()]);
          }}
        >
          حساب
        </Button>
      }
      tight
    >
      {settings.isLoading ? (
        <div className="card-body">
          <Skeleton height={80} />
        </div>
      ) : accounts.length === 0 ? (
        <Empty icon={<Landmark />} title="لا حساب بعد">
          أضف حساباً ليظهر خيار التحويل المصرفي للمتاجر.
        </Empty>
      ) : (
        accounts.map((a, i) => (
          <div key={a.id || `new-${i}`} className="bank-account-row">
            <Field label="المصرف" htmlFor={`ba-bank-${i}`}>
              <select id={`ba-bank-${i}`} className="select" value={a.bank} onChange={(e) => change(i, { bank: e.target.value, bank_name: banks[e.target.value] ?? "" })}>
                <option value="">—</option>
                {Object.entries(banks).map(([slug, name]) => (
                  <option key={slug} value={slug}>
                    {name}
                  </option>
                ))}
              </select>
            </Field>
            <Field label="اسم صاحب الحساب" htmlFor={`ba-holder-${i}`}>
              <input id={`ba-holder-${i}`} className="input" value={a.holder} onChange={(e) => change(i, { holder: e.target.value })} />
            </Field>
            <Field label="IBAN" htmlFor={`ba-iban-${i}`} error={a.iban && !validLibyanIBAN(a.iban) ? "رقم غير صحيح" : null}>
              <input
                id={`ba-iban-${i}`}
                className="input mono"
                dir="ltr"
                value={a.iban}
                placeholder="LY.."
                onChange={(e) => {
                  const iban = e.target.value.toUpperCase();
                  const compact = iban.replace(/\s+/g, "");
                  // The account number is the IBAN's last fifteen digits.
                  const patch: Partial<BankAccount> = { iban };
                  if (validLibyanIBAN(compact) && !a.account_number) patch.account_number = compact.slice(-15);
                  change(i, patch);
                }}
              />
            </Field>
            <Field label="رقم الحساب" htmlFor={`ba-number-${i}`}>
              <input id={`ba-number-${i}`} className="input mono" dir="ltr" inputMode="numeric" value={a.account_number} onChange={(e) => change(i, { account_number: e.target.value })} />
            </Field>
            <div className="row" style={{ alignSelf: "end", justifyContent: "space-between", gap: 8 }}>
              <span className="row" style={{ gap: 8 }}>
                <Switch on={a.enabled} onChange={(on) => change(i, { enabled: on })} label="يظهر للمتاجر" />
                <span className="faint">{a.enabled ? "يظهر للمتاجر" : "مخفي"}</span>
              </span>
              <Button
                size="sm"
                variant="ghost"
                icon={<Trash2 />}
                title="حذف"
                onClick={() => {
                  setDirty(true);
                  setAccounts((list) => list.filter((_, j) => j !== i));
                }}
              />
            </div>
            {problems[i] && dirty && <span className="error-text" style={{ gridColumn: "1 / -1" }}>{problems[i]}</span>}
          </div>
        ))
      )}
      {dirty && (
        <div className="card-body stack" style={{ gap: 10 }}>
          <Notice tone="warning" icon={<Landmark />}>
            هذه الحسابات هي ما تحوّل إليه المتاجر أموالها. راجعها حرفاً حرفاً قبل الحفظ.
          </Notice>
          <div className="row" style={{ justifyContent: "space-between" }}>
            <PasskeyHint />
            <div className="row">
              <Button
                onClick={() => {
                  setDirty(false);
                  setAccounts(settings.data?.accounts ?? []);
                }}
              >
                تراجع
              </Button>
              <Button variant="primary" icon={<Save />} loading={save.busy} disabled={!valid} onClick={submit}>
                حفظ
              </Button>
            </div>
          </div>
        </div>
      )}
    </Card>
  );
}
