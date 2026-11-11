import { useMemo, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { Banknote, CreditCard, Eye, FlaskConical, Info, Search, ShoppingBag, Smartphone, TriangleAlert, UserCheck, UserSearch } from "lucide-react";
import { api, qs } from "../../lib/api";
import { idempotencyKey } from "../../lib/stepup";
import { useSearchText } from "../../lib/router";
import { matches } from "../../lib/search";
import { count, money } from "../../lib/format";
import { purchasePurpose } from "../../lib/labels";
import { financeKeys, libyaDay, type FinanceEntry } from "../../lib/finance";
import type { Purchase } from "../../lib/types";
import { reasonText } from "../../lib/vouchers";
import { useAction, PasskeyHint } from "../../components/guarded";
import { Dialog } from "../../components/dialog";
import { Combobox, type ComboOption } from "../../components/Combobox";
import { Stacked, type Column } from "../../components/DataTable";
import { PageHeader } from "../../components/PageHeader";
import { PurchasesTable } from "../../components/tables";
import { Unavailable } from "../../components/Unavailable";
import { EntryDialog, type EntryDraft } from "../../components/finance/EntryDialog";
import { Badge, Button, Card, CopyText, Field, Money, Notice, Segmented, Skeleton } from "../../components/ui";
import { useCatalogItem, useCatalogItems } from "../../lib/picker";

// The company buying for itself, from the suppliers that serve the shops: a
// card to pay for a subscription, a top-up, a bill, cards to sell on for cash
// or to give away. Nothing comes out of a shop's wallet; the cost is the
// company's own spending on its books, and cash from a resale is written in
// the ledger as income (category voucher_resale, reference = the purchase).

type Purpose = "own_use" | "resale" | "gift" | "other";
const purposes: { id: Purpose; label: string }[] = [
  { id: "own_use", label: "لاستخدامنا" },
  { id: "resale", label: "للبيع نقداً" },
  { id: "gift", label: "هدية" },
  { id: "other", label: "أخرى" },
];

type Code = { code: string; serial?: string };
type CompanyAnswer = {
  purchase: Purchase & { codes?: Code[]; codes_pending?: boolean; receipt?: Record<string, string>; receipt_pending?: boolean; delivery?: string };
  receipt?: Record<string, string>;
  receipt_pending?: boolean;
};
type AccountCheck = { status: "valid" | "invalid" | "unconfirmed" | "unchecked"; name?: string; region?: string; account: string };

const companyKey = ["vouchers", "purchases", { buyer: "company" }];

function useCompanyPurchases() {
  return useQuery({
    queryKey: companyKey,
    queryFn: () => api.get<{ purchases: Purchase[] }>("/v1/vouchers/admin/purchases" + qs({ buyer: "company", limit: 200 })).then((r) => r.purchases ?? []),
    refetchInterval: 30_000,
    retry: false,
  });
}

/** Cash sales already written for a resale purchase, by its id. */
function useResales() {
  return useQuery({
    queryKey: financeKeys.entries({ category: "voucher_resale" }),
    queryFn: () =>
      api.get<{ entries: FinanceEntry[] }>("/v1/finance/entries" + qs({ category: "voucher_resale", direction: "income", limit: 500 })).then((r) => r.entries ?? []),
    retry: false,
  });
}

export function Company() {
  const purchases = useCompanyPurchases();
  const resales = useResales();
  const { text, setText, query } = useSearchText();
  const [buying, setBuying] = useState<null | "card" | "service">(null);
  const [revealing, setRevealing] = useState<Purchase | null>(null);
  const [selling, setSelling] = useState<EntryDraft | null>(null);

  const rows = purchases.data ?? [];
  const soldFor = useMemo(() => {
    const map = new Map<string, number>();
    for (const e of resales.data ?? []) if (e.reference) map.set(e.reference, (map.get(e.reference) ?? 0) + Number(e.amount));
    return map;
  }, [resales.data]);
  const month = libyaDay().slice(0, 7);
  const totals = useMemo(() => {
    let spent = 0;
    let n = 0;
    let unsold = 0;
    for (const p of rows) {
      if (p.status !== "succeeded" || p.test_mode) continue;
      if ((p.completed_at ?? p.created_at) && libyaDay(new Date(p.completed_at ?? p.created_at)).slice(0, 7) === month) {
        spent += Number(p.amount) || 0;
        n++;
      }
      if (p.purpose === "resale" && !soldFor.has(p.id)) unsold++;
    }
    return { spent, n, unsold };
  }, [rows, soldFor, month]);

  const extra: Column<Purchase>[] = [
    {
      key: "purpose",
      header: "الغرض",
      cell: (p) => {
        const purpose = purchasePurpose[p.purpose ?? ""] ?? { label: p.purpose ?? "—", tone: "neutral" as const };
        const sold = soldFor.get(p.id);
        return (
          <Stacked
            title={
              <span className="row" style={{ gap: 4 }}>
                <Badge tone={purpose.tone}>{purpose.label}</Badge>
                {sold !== undefined && <Badge tone="success">بيع بـ {money(sold.toFixed(3))}</Badge>}
              </span>
            }
            sub={[p.note, p.requested_by].filter(Boolean).join(" · ")}
          />
        );
      },
    },
  ];

  return (
    <>
      <PageHeader
        title="مشتريات الشركة"
        description="نشتري لأنفسنا ما نبيعه للمتاجر — بطاقة لاشتراك، شحن رصيد، فاتورة، أو بطاقات نبيعها نقداً — من نفس الموردين وبرصيدنا لديهم. لا تُخصم من أي متجر، وتُحسب في الدفتر مصروفاً على الشركة."
        actions={
          <>
            <Button variant="primary" icon={<CreditCard />} onClick={() => setBuying("card")}>
              شراء بطاقة
            </Button>
            <Button icon={<Smartphone />} onClick={() => setBuying("service")}>
              شحن رصيد أو فاتورة
            </Button>
          </>
        }
      />
      {purchases.isError ? (
        <Card>
          <Unavailable feature="vouchers" error={purchases.error} onRetry={() => void purchases.refetch()} />
        </Card>
      ) : (
        <div className="stack">
          <div className="grid kpis">
            <div className="card kpi money">
              <div className="kpi-label">أنفقنا هذا الشهر</div>
              <div className="kpi-value">{purchases.isLoading ? <Skeleton height={24} width={80} /> : <Money value={totals.spent.toFixed(3)} />}</div>
              <div className="kpi-foot">{count(totals.n)} عملية تمّت · بالتكلفة التقديرية</div>
            </div>
            <div className={`card kpi ${totals.unsold ? "attention" : ""}`}>
              <div className="kpi-label">للبيع نقداً ولم يُسجَّل بيعها</div>
              <div className="kpi-value">{count(totals.unsold)}</div>
              <div className="kpi-foot">سجّل ثمنها حين تبيعها ليظهر في الأرباح</div>
            </div>
          </div>
          <Card tight>
            <div className="toolbar stacks">
              <div className="search-input">
                <Search />
                <input className="input" placeholder="صنف، ملاحظة، رقم…" value={text} onChange={(e) => setText(e.target.value)} />
              </div>
            </div>
            <PurchasesTable
              purchases={rows.filter((p) => matches(query, p.name, p.note ?? "", p.id, p.supplier_order_id, p.target, p.requested_by ?? ""))}
              loading={purchases.isLoading}
              showShop={false}
              profit={false}
              resetKey={query}
              columnsBefore={extra}
              actions={(p) =>
                p.status === "succeeded" ? (
                  <div className="row">
                    {p.kind === "card" && p.target ? (
                      // Sent to an account: there is no code to reveal.
                      <Badge tone="money">شُحنت إلى الحساب</Badge>
                    ) : (
                      <Button size="sm" icon={<Eye />} onClick={() => setRevealing(p)}>
                        {p.kind === "card" ? "الأكواد" : "الإيصال"}
                      </Button>
                    )}
                    {p.purpose === "resale" && !p.test_mode && !soldFor.has(p.id) && (
                      <Button
                        size="sm"
                        variant="money"
                        icon={<Banknote />}
                        onClick={() =>
                          setSelling({
                            direction: "income",
                            category: "voucher_resale",
                            reference: p.id,
                            note: `${p.name}${p.quantity > 1 ? ` × ${p.quantity}` : ""}`,
                          })
                        }
                      >
                        سجّل البيع
                      </Button>
                    )}
                  </div>
                ) : null
              }
            />
          </Card>
        </div>
      )}
      {buying === "card" && <BuyCardDialog onClose={() => setBuying(null)} />}
      {buying === "service" && <BuyServiceDialog onClose={() => setBuying(null)} />}
      {revealing && <RevealDialog purchase={revealing} onClose={() => setRevealing(null)} />}
      <EntryDialog open={selling !== null} draft={selling ?? undefined} onClose={() => setSelling(null)} />
    </>
  );
}

function PurposeFields({ purpose, setPurpose, note, setNote }: { purpose: Purpose; setPurpose: (p: Purpose) => void; note: string; setNote: (n: string) => void }) {
  return (
    <>
      <Field label="لماذا نشتريها؟">
        <Segmented value={purpose} onChange={setPurpose} options={purposes} />
      </Field>
      <Field label="ملاحظة" htmlFor="company-note" help="ما الذي ستُستخدم فيه، أو لمن.">
        <input id="company-note" className="input" value={note} maxLength={200} onChange={(e) => setNote(e.target.value)} placeholder="مثلاً: اشتراك خادم، أو بيع لزبون" />
      </Field>
    </>
  );
}

/** What a purchase's answer shows when it did not hand back what was bought. */
function OutcomeNotice({ purchase }: { purchase: CompanyAnswer["purchase"] }) {
  if (purchase.status === "failed")
    return (
      <Notice tone="danger" icon={<TriangleAlert />}>
        لم تتم العملية ولم يُخصم شيء: {purchase.error_detail || purchase.error_code}
      </Notice>
    );
  if (purchase.status === "pending" || purchase.held_since)
    return (
      <Notice tone="warning" icon={<TriangleAlert />}>
        لم يؤكد المورّد النتيجة بعد. تظهر العملية «معلّقة» في القائمة حتى يتّضح أمرها، ولا تُكرّر الشراء.
      </Notice>
    );
  return null;
}

function BuyCardDialog({ onClose }: { onClose: () => void }) {
  const catalog = useCatalogItems();
  const [item, setItem] = useState("");
  const picked = useCatalogItem(item).data;
  const [quantity, setQuantity] = useState(1);
  const [purpose, setPurpose] = useState<Purpose>("own_use");
  const [note, setNote] = useState("");
  const [key] = useState(idempotencyKey);
  const [result, setResult] = useState<CompanyAnswer | null>(null);
  const [account, setAccount] = useState<Record<string, string>>({});
  const [checked, setChecked] = useState<AccountCheck | null>(null);
  const action = useAction<CompanyAnswer>({ passkey: true, invalidate: [["vouchers"], financeKeys.all] });
  const check = useAction<AccountCheck>({});

  const options = useMemo<ComboOption[]>(
    () =>
      (catalog.data?.items ?? []).map((i) => ({ value: i.key, label: i.name, group: i.brand })),
    [catalog.data],
  );
  const winner = picked?.suppliers?.find((s) => s.candidate && s.supplier !== "stock" && s.cost_lyd);
  const each = winner?.cost_lyd ?? picked?.unit_price;
  const testMode = !!catalog.data?.test_mode;
  // A card sent to an account (a game by player ID, Telegram, Steam) asks for it.
  const target = picked?.target ?? null;
  const accountReady = !target || target.fields.every((f) => (account[f.key] ?? "").trim() !== "");
  const pick = (next: string) => {
    setItem(next);
    setAccount({});
    setChecked(null);
    setQuantity(1);
  };

  if (result) {
    return (
      <Dialog open onClose={onClose} title="تم الشراء" subtitle={result.purchase.name} icon={<ShoppingBag />} iconTone="money" footer={<Button size="lg" onClick={onClose}>تم</Button>}>
        <PurchaseOutcome answer={result} />
      </Dialog>
    );
  }
  return (
    <Dialog
      open
      onClose={onClose}
      busy={action.busy}
      dirty={!!item}
      title="شراء بطاقة للشركة"
      icon={<CreditCard />}
      iconTone="money"
      footer={
        <>
          <Button
            variant="money"
            size="lg"
            loading={action.busy}
            disabled={!item || !accountReady}
            onClick={async () => {
              const answer = await action.run("POST", "/v1/vouchers/admin/company/cards", {
                item,
                quantity: target ? 1 : quantity,
                idempotency_key: key,
                purpose,
                note: note.trim(),
                ...(target ? { account } : {}),
              });
              if (answer) setResult(answer);
            }}
          >
            {each ? `اشترِ بنحو ${money((Number(each) * quantity).toFixed(3))}` : "اشترِ"}
          </Button>
          <Button size="lg" onClick={onClose} disabled={action.busy}>
            إلغاء
          </Button>
        </>
      }
    >
      <div className="form">
        {testMode && (
          <Notice tone="warning" icon={<FlaskConical />}>
            الخادم في الوضع التجريبي: الأكواد تجريبية ولا تعمل.
          </Notice>
        )}
        <Field label="البطاقة" htmlFor="company-item">
          {catalog.isLoading ? <Skeleton height={38} /> : <Combobox id="company-item" value={item} options={options} onChange={pick} />}
        </Field>
        {target && (
          <>
            {target.fields.map((f) => (
              <Field key={f.key} label={f.label} htmlFor={`company-account-${f.key}`}>
                {f.type === "select" ? (
                  <select
                    id={`company-account-${f.key}`}
                    className="input"
                    value={account[f.key] ?? ""}
                    onChange={(e) => (setAccount({ ...account, [f.key]: e.target.value }), setChecked(null))}
                  >
                    <option value="">اختر</option>
                    {(f.options ?? []).map((o) => (
                      <option key={o.value} value={o.value}>
                        {o.label}
                      </option>
                    ))}
                  </select>
                ) : (
                  <input
                    id={`company-account-${f.key}`}
                    className="input num"
                    dir="ltr"
                    value={account[f.key] ?? ""}
                    onChange={(e) => (setAccount({ ...account, [f.key]: e.target.value }), setChecked(null))}
                  />
                )}
              </Field>
            ))}
            {target.hint && <p className="faint">{target.hint}</p>}
            {/* A Telegram username and a Steam invite link have no check. */}
            {target.kind !== "telegram_username" && target.kind !== "steam_invite" && (
              <div className="row" style={{ gap: 8 }}>
                <Button
                  size="sm"
                  icon={<UserSearch />}
                  disabled={!accountReady}
                  loading={check.busy}
                  onClick={async () => setChecked((await check.run("POST", "/v1/vouchers/admin/accounts/check", { item, account })) ?? null)}
                >
                  تحقق من الحساب
                </Button>
                {checked && <AccountCheckBadge check={checked} />}
              </div>
            )}
          </>
        )}
        {picked && !picked.available && (
          <Notice tone="danger" icon={<TriangleAlert />}>
            غير متاحة الآن: {reasonText(picked.reason)}
          </Notice>
        )}
        {!target && (
          <Field label="العدد">
            <Segmented<string> value={String(quantity)} onChange={(v) => setQuantity(Number(v))} options={[1, 2, 3, 5, 10].map((n) => ({ id: String(n), label: count(n) }))} />
          </Field>
        )}
        <PurposeFields purpose={purpose} setPurpose={setPurpose} note={note} setNote={setNote} />
        {item && picked && (
          <Notice tone="info" icon={<Info />}>
            {winner
              ? `تُشترى من المورّد الأرخص الآن بنحو ${money(winner.cost_lyd)} للبطاقة، ويُخصم من رصيدنا لديه.`
              : `سعر المورّد غير معروف؛ التقدير بسعر المتاجر ${money(picked.unit_price)} للبطاقة، والتكلفة الحقيقية تُسجَّل بعد الشراء.`}{" "}
            لا يُؤخذ شيء من مخزوننا ولا من محفظة أي متجر.
          </Notice>
        )}
        <PasskeyHint />
      </div>
    </Dialog>
  );
}

type Operator = { id: number; name: string; amount_currency: string; amounts: { amount: string }[]; min?: string; max?: string };
type Plan = { id: number; amount: string; description: string };
type Biller = { id: number; name: string; requires_invoice: boolean; amount_currency: string; min?: string; max?: string; plans?: Plan[] };
type Country = { code: string; name: string; name_en: string; dial: string[]; airtime?: { operators?: Operator[] } | null; bills?: { billers?: Biller[] } | null };
type QuoteAnswer = { quote: { name: string; receive: { amount: string; currency: string }; approximate: boolean }; cost_lyd: string };

function BuyServiceDialog({ onClose }: { onClose: () => void }) {
  const directory = useQuery({
    // Its own key: the services page keeps a flattened copy under ["services", "directory"].
    queryKey: ["services", "directory", "wire"],
    queryFn: () => api.get<{ directory: { countries: Country[]; test_mode: boolean } }>("/v1/services/admin/directory"),
    retry: false,
    staleTime: 5 * 60_000,
  });
  const [kind, setKind] = useState<"airtime" | "bill">("airtime");
  const [country, setCountry] = useState("");
  const [target, setTarget] = useState("");
  const [amount, setAmount] = useState("");
  const [planId, setPlanId] = useState("");
  const [account, setAccount] = useState("");
  const [invoice, setInvoice] = useState("");
  const [purpose, setPurpose] = useState<Purpose>("own_use");
  const [note, setNote] = useState("");
  const [key] = useState(idempotencyKey);
  const [quote, setQuote] = useState<QuoteAnswer | null>(null);
  const [result, setResult] = useState<CompanyAnswer | null>(null);
  const quoting = useAction<QuoteAnswer>({});
  const action = useAction<CompanyAnswer>({ passkey: true, invalidate: [["vouchers"], financeKeys.all] });

  const countries = directory.data?.directory.countries ?? [];
  const chosen = countries.find((c) => c.code === country);
  const countryOptions = useMemo<ComboOption[]>(
    () =>
      countries
        .filter((c) => (c.airtime?.operators?.length ?? 0) + (c.bills?.billers?.length ?? 0) > 0)
        .map((c) => ({ value: c.code, label: c.name, sub: [c.code, ...(c.dial ?? []).map((d) => "+" + d), c.name_en].join(" · ") })),
    [countries],
  );
  const operators = chosen?.airtime?.operators ?? [];
  const billers = chosen?.bills?.billers ?? [];
  const providers = kind === "airtime" ? operators : billers;
  const operator = kind === "airtime" ? operators.find((o) => String(o.id) === target) : undefined;
  const biller = kind === "bill" ? billers.find((b) => String(b.id) === target) : undefined;
  const currency = operator?.amount_currency ?? biller?.amount_currency ?? "";
  const plans = biller?.plans ?? [];
  const tiles = operator?.amounts ?? [];

  const order = () => {
    const body: Record<string, unknown> = { kind, country, amount: plans.length ? plans.find((p) => String(p.id) === planId)?.amount ?? "" : amount };
    if (currency) body.amount_currency = currency;
    if (kind === "airtime") {
      body.operator_id = Number(target);
      body.phone = account.trim();
    } else {
      body.biller_id = Number(target);
      body.account = account.trim();
      if (biller?.requires_invoice) body.invoice_id = invoice.trim();
      if (planId) body.amount_id = Number(planId);
    }
    return body;
  };
  const ready = !!country && !!target && !!account.trim() && (plans.length ? !!planId : /^\d+(\.\d+)?$/.test(amount)) && (!biller?.requires_invoice || !!invoice.trim());
  const reset = (next: Partial<{ kind: "airtime" | "bill"; country: string; target: string }>) => {
    if (next.kind !== undefined) setKind(next.kind);
    if (next.country !== undefined) setCountry(next.country);
    setTarget(next.target ?? "");
    setAmount("");
    setPlanId("");
    setQuote(null);
  };

  if (result) {
    return (
      <Dialog open onClose={onClose} title="تمت العملية" subtitle={result.purchase.name} icon={<ShoppingBag />} iconTone="money" footer={<Button size="lg" onClick={onClose}>تم</Button>}>
        <PurchaseOutcome answer={result} />
      </Dialog>
    );
  }
  return (
    <Dialog
      open
      wide
      onClose={onClose}
      busy={action.busy}
      dirty={!!account.trim()}
      title="شحن رصيد أو دفع فاتورة للشركة"
      icon={<Smartphone />}
      iconTone="money"
      footer={
        <>
          {!quote ? (
            <Button
              variant="primary"
              size="lg"
              loading={quoting.busy}
              disabled={!ready}
              onClick={async () => {
                const { country: _c, phone: _p, account: _a, invoice_id: _i, ...priced } = order();
                setQuote((await quoting.run("POST", "/v1/services/admin/quote", priced)) ?? null);
              }}
            >
              احسب التكلفة
            </Button>
          ) : (
            <Button
              variant="money"
              size="lg"
              loading={action.busy}
              disabled={!ready}
              onClick={async () => {
                const answer = await action.run("POST", "/v1/vouchers/admin/company/services", { ...order(), idempotency_key: key, purpose, note: note.trim() });
                if (answer) setResult(answer);
              }}
            >
              نفّذ بنحو {money(quote.cost_lyd)}
            </Button>
          )}
          <Button size="lg" onClick={onClose} disabled={action.busy}>
            إلغاء
          </Button>
        </>
      }
    >
      <div className="form">
        {directory.data?.directory.test_mode && (
          <Notice tone="warning" icon={<FlaskConical />}>
            الخادم في الوضع التجريبي: لا يُشحن شيء حقيقي.
          </Notice>
        )}
        {directory.isError && <Unavailable feature="services" error={directory.error} onRetry={() => void directory.refetch()} />}
        <Segmented
          value={kind}
          onChange={(k) => reset({ kind: k })}
          options={[
            { id: "airtime", label: "شحن رصيد" },
            { id: "bill", label: "دفع فاتورة" },
          ]}
        />
        <div className="form-row">
          <Field label="الدولة" htmlFor="company-country">
            {directory.isLoading ? <Skeleton height={38} /> : <Combobox id="company-country" value={country} options={countryOptions} onChange={(c) => reset({ country: c })} />}
          </Field>
          <Field label={kind === "airtime" ? "المشغّل" : "الجهة"} htmlFor="company-provider">
            <Combobox
              id="company-provider"
              value={target}
              options={providers.map((p) => ({ value: String(p.id), label: p.name }))}
              onChange={(t) => reset({ target: t })}
              placeholder={chosen ? "اختر…" : "اختر الدولة أولاً"}
            />
          </Field>
        </div>
        {target && (
          <>
            {plans.length > 0 ? (
              <Field label="الباقة">
                <div className="chips">
                  {plans.map((p) => (
                    <button key={p.id} type="button" className={`chip ${String(p.id) === planId ? "on" : ""}`} onClick={() => (setPlanId(String(p.id)), setQuote(null))}>
                      {p.description || p.amount} · <span className="num">{p.amount} {currency}</span>
                    </button>
                  ))}
                </div>
              </Field>
            ) : (
              <Field
                label={`المبلغ (${currency})`}
                htmlFor="company-amount"
                help={(operator?.min || biller?.min) && (operator?.max || biller?.max) ? `من ${operator?.min ?? biller?.min} إلى ${operator?.max ?? biller?.max}` : undefined}
              >
                {tiles.length > 0 && (
                  <div className="chips" style={{ marginBottom: 6 }}>
                    {tiles.map((t) => (
                      <button key={t.amount} type="button" className={`chip ${t.amount === amount ? "on" : ""}`} onClick={() => (setAmount(t.amount), setQuote(null))}>
                        <span className="num">{t.amount}</span>
                      </button>
                    ))}
                  </div>
                )}
                <input id="company-amount" className="input num" inputMode="decimal" value={amount} onChange={(e) => (setAmount(e.target.value.trim()), setQuote(null))} />
              </Field>
            )}
            <div className="form-row">
              <Field label={kind === "airtime" ? "رقم الهاتف" : "رقم الحساب أو العدّاد"} htmlFor="company-account" help={kind === "airtime" && chosen?.dial?.length ? `بمفتاح الدولة +${chosen.dial[0]} أو بدونه` : undefined}>
                <input id="company-account" className="input num" dir="ltr" value={account} onChange={(e) => (setAccount(e.target.value), setQuote(null))} />
              </Field>
              {biller?.requires_invoice && (
                <Field label="رقم الفاتورة" htmlFor="company-invoice">
                  <input id="company-invoice" className="input num" dir="ltr" value={invoice} onChange={(e) => setInvoice(e.target.value)} />
                </Field>
              )}
            </div>
          </>
        )}
        <PurposeFields purpose={purpose} setPurpose={setPurpose} note={note} setNote={setNote} />
        {quote && (
          <dl className="facts">
            <div className="fact">
              <dt>الخدمة</dt>
              <dd>
                {quote.quote.name} {quote.quote.approximate && <Badge tone="warning">تقريبي</Badge>}
              </dd>
            </div>
            <div className="fact">
              <dt>يستلم</dt>
              <dd className="num">
                {quote.quote.receive.amount} {quote.quote.receive.currency}
              </dd>
            </div>
            <div className="fact">
              <dt>تكلفتها علينا</dt>
              <dd>
                <Money value={quote.cost_lyd} />
              </dd>
            </div>
          </dl>
        )}
        <PasskeyHint />
      </div>
    </Dialog>
  );
}

/** A top-up's or bill's receipt fields, in Arabic; test_mode is said by a notice instead. */
const receiptLabels: Record<string, string> = {
  transaction_id: "رقم العملية",
  operator: "المشغّل",
  phone: "الرقم",
  delivered_amount: "وصل",
  delivered_currency: "عملة ما وصل",
  operator_reference: "مرجع المشغّل",
  order_amount: "المبلغ المطلوب",
  order_currency: "عملة الطلب",
  biller: "الجهة",
  account: "الحساب",
  amount: "المبلغ",
  currency: "العملة",
  token: "رمز الشحن",
  units: "الوحدات",
  biller_reference: "مرجع الجهة",
  info: "معلومات",
};

/** The codes of a card, or the receipt of a top-up or bill, as just bought or revealed. */
/** What an account check found, in a word: the player's name when the game gave it. */
function AccountCheckBadge({ check }: { check: AccountCheck }) {
  switch (check.status) {
    case "valid":
      return <Badge tone="success">موجود{check.name ? `: ${check.name}` : ""}{check.region ? ` · ${check.region}` : ""}</Badge>;
    case "invalid":
      return <Badge tone="danger">لا يوجد حساب بهذا المعرّف</Badge>;
    case "unconfirmed":
      return <Badge tone="warning">تعذّر التأكد منه</Badge>;
    default:
      return <Badge tone="neutral">لا تحقق لهذه البطاقة</Badge>;
  }
}

function PurchaseOutcome({ answer }: { answer: CompanyAnswer }) {
  const p = answer.purchase;
  const codes = p.codes ?? [];
  const receipt = Object.fromEntries(Object.entries(answer.receipt ?? p.receipt ?? {}).filter(([k]) => k !== "test_mode"));
  const pending = p.codes_pending || answer.receipt_pending || p.receipt_pending;
  return (
    <div className="form">
      <OutcomeNotice purchase={p} />
      {p.test_mode && (
        <Notice tone="warning" icon={<FlaskConical />}>
          عملية تجريبية: لا قيمة لها.
        </Notice>
      )}
      {p.status === "succeeded" && (p.delivery === "account" || (p.kind === "card" && !!p.target)) && (
        <Notice tone="money" icon={<UserCheck />}>
          شُحنت إلى الحساب <span className="mono" dir="ltr">{p.target}</span> مباشرة، ولا كود لها.
        </Notice>
      )}
      {codes.length > 0 && (
        <dl className="facts">
          {codes.map((c, i) => (
            <div className="fact" key={i} style={{ gridColumn: "1 / -1" }}>
              <dt>{codes.length > 1 ? `الكود ${count(i + 1)}` : "الكود"}</dt>
              <dd>
                <CopyText value={c.code} display={<span className="mono" dir="ltr">{c.code}</span>} />
                {c.serial && <div className="faint mono" dir="ltr">{c.serial}</div>}
              </dd>
            </div>
          ))}
        </dl>
      )}
      {Object.keys(receipt).length > 0 && (
        <dl className="facts">
          {Object.entries(receipt).map(([k, v]) => (
            <div className="fact" key={k}>
              <dt>{receiptLabels[k] ?? k}</dt>
              <dd>{k === "token" ? <CopyText value={v} display={<span className="mono" dir="ltr">{v}</span>} /> : <span dir="auto">{v}</span>}</dd>
            </div>
          ))}
        </dl>
      )}
      {p.status === "succeeded" && pending && codes.length === 0 && Object.keys(receipt).length === 0 && !p.target && (
        <Notice tone="warning" icon={<TriangleAlert />}>
          تمّت العملية لكن تعذّرت قراءة {p.kind === "card" ? "الأكواد" : "الإيصال"} من المورّد الآن. افتحها من القائمة بعد قليل.
        </Notice>
      )}
      {p.status === "succeeded" && !p.test_mode && (
        <p className="muted">
          التكلفة التقديرية {money(p.amount)}
          {Number(p.supplier_cost) > 0 ? ` · خصم المورّد ${money(p.supplier_cost, p.supplier_currency === "LYD" ? undefined : p.supplier_currency)}` : ""}. تظهر في «الأرباح
          والخسائر» تحت «مشتريات الشركة».
        </p>
      )}
    </div>
  );
}

function RevealDialog({ purchase, onClose }: { purchase: Purchase; onClose: () => void }) {
  const action = useAction<CompanyAnswer>({ passkey: true });
  const [answer, setAnswer] = useState<CompanyAnswer | null>(null);
  return (
    <Dialog
      open
      onClose={onClose}
      busy={action.busy}
      title={purchase.kind === "card" ? "أكواد البطاقة" : "إيصال العملية"}
      subtitle={`${purchase.name}${purchase.quantity > 1 ? ` × ${purchase.quantity}` : ""}`}
      icon={<Eye />}
      footer={
        answer ? (
          <Button size="lg" onClick={onClose}>
            إغلاق
          </Button>
        ) : (
          <>
            <Button
              variant="primary"
              size="lg"
              loading={action.busy}
              onClick={async () => setAnswer((await action.run("POST", `/v1/vouchers/admin/company/purchases/${encodeURIComponent(purchase.id)}/reveal`)) ?? null)}
            >
              اعرض
            </Button>
            <Button size="lg" onClick={onClose} disabled={action.busy}>
              إلغاء
            </Button>
          </>
        )
      }
    >
      {answer ? (
        <PurchaseOutcome answer={answer} />
      ) : (
        <div className="form">
          <p className="muted">تُقرأ من المورّد من جديد ولا تُحفظ في اللوحة. من يرى الكود يستطيع استعماله.</p>
          <PasskeyHint />
        </div>
      )}
    </Dialog>
  );
}

